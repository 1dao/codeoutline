# 短超时等待调查结论

整理日期：2026-11-01。实测日期：2026-10-30。本文记录本轮结论，不改变生产实现。

## 实现决定

- 保留现有 xnet2lua timer、Windows WSAPoll、Linux epoll 和 socketpair 唤醒实现。
- 保留 worker 回复后由单次 timer 驱动分步 GC 的现有实现与默认 1ms 延迟；此值是调度请求，不是实际回调延迟保证。
- 不纳入未提交的 `xtimer_wait`／到期时 `poll(0)` 零延迟候选，不以持续轮询换取更短回调间隔。
- 不新增 io_uring、Windows 高分辨率可等待定时器后端，不在生产进程请求更高定时器分辨率，不改变线程优先级或亲和性。
- main 已包含 socket 初始化／释放按线程配对的生命周期修复及必要的 worker GC 改动，无需再次合并实验分支或更新子模块指针。

## 已确认的事实

### 系统 API 的返回也有长尾

独立 C 程序直接调用系统 API，不依赖 CodeOutline、xnet、Lua 或项目事件循环。初始化、输出和统计均在计时区间之外，使用单调高分辨率时钟计时，核验实际返回值及完成事件。

Linux 测试环境为 CentOS Stream 9、内核 `5.14.0-704.el9.x86_64`、2 vCPU KVM、普通调度，默认 timer slack 为 50μs。以下每行均为 20,000 次有效样本，时间单位为毫秒，包含请求的 1ms。

| 对照批次 | 等待方式 | P50 | P99 | 本次最大 |
| --- | --- | ---: | ---: | ---: |
| 原生 API 对照 | epoll_wait | 1.086759 | 1.819043 | 8.382362 |
| 原生 API 对照 | io_uring_enter，提交并等待 1ms timeout | 1.040780 | 1.852533 | 10.383971 |
| pwait2 对照 | epoll_wait | 1.082717 | 1.462931 | 5.013700 |
| pwait2 对照 | epoll_pwait2 | 1.082348 | 1.486250 | 7.551369 |
| timerfd 初测 | timerfd_settime + epoll_wait | 1.035500 | 1.506021 | 7.197305 |

不同批次不能用于严格性能排名。本次结果证明这些长尾可以在没有项目封装的情况下发生，不足以认定 Linux API 有缺陷，也不排除项目或后台进程另加延迟。

`epoll_pwait2` 改善的是超时参数分辨率：0.2ms 的 5,000 次测试 P50 为 0.277164ms。对于恰好 1ms 的输入，本轮没有观察到明显改善，纳秒参数不等于纳秒唤醒保证。

### 延迟发生在多个阶段

额外使用 timerfd 绝对到期时间与独立 ftrace instance 采样 20,000 次，追踪缓冲无丢失事件。该诊断运行有追踪开销，不与无追踪批次作性能排名。

| 诊断样本 | 已观察到的主要延迟 |
| --- | --- |
| 总耗时 7.368702ms | 请求在 1ms 到期；1.375351ms 线程已可运行；7.291351ms 才切入 CPU，就绪后相隔 5.916ms |
| 总耗时 6.036248ms | timerfd 回调比预定时刻晚 4.592901ms，随后还经过内核唤醒与线程调度 |

普通线程就绪后不保证立即执行。KVM 还增加宿主机对 vCPU 的调度层，但来宾侧追踪没有量化宿主机的贡献，不能把全部长尾归因于虚拟机、某个相邻线程、C-state 或 NO_HZ。早先未追踪的 10ms 样本也不能反向还原根因。

### Windows 的典型等待粒度与 Linux 长尾应分开看

Windows 11 build 26300，独立程序在有效回环 UDP socket 上直接调用 `WSAPoll(..., 1)`，只监听可读且核验超时返回。

- 一轮 1,000 次默认采样 P50 为 15.965300ms；同轮 `timeBeginPeriod(1)` 返回成功后仍为 16.016500ms。
- 后续同进程分组对照，每组 500 次：默认 P50 为 6.097300ms；请求 1ms 分辨率后为 1.136400ms；显式要求遵守该请求后为 1.077100ms；恢复策略并释放请求后为 15.650400ms。
- 分辨率请求可以显著改善短等待，但效果并非每轮都相同。Windows 11 文档允许某些状态下不保证采用更高分辨率；本轮未证明它是先前失效的确切原因。
- 系统时间更新参数曾报告 15.625ms，不能将其解释成所有操作系统的固定 tick 或 WSAPoll 的硬性最小等待时间。
- Windows 测试修改仅作用于测试进程；分辨率请求成功配对释放，显式进程策略成功恢复。

因此，默认多数样本约 10–16ms，应先检查等待分辨率及请求是否生效；通常约 1ms、偶发数毫秒，则需分析到期处理和调度长尾。相似的最大耗时不表示同一根因。

### 现有 socketpair 和 timer 初始化不是必要原因

旧运行时对照中，socketpair TCP、普通 TCP、UDP 与 Windows Event 的无事件 1ms 等待均约 15ms；有数据时 socketpair 的 send 至 poll 返回 P50 约 0.052ms，与普通 TCP 相近。

同一运行时、相同 worker 循环下，timer 在初始化阶段或首次请求时初始化的两组 P50 均约 15.5ms。本轮没有证据支持重写 socketpair 或挪动初始化位置来解决这类等待粒度。

### 零延迟候选不纳入

128 个串联单次 timer 的候选实验中，delay=0 的 P50 从约 30.7ms 降至约 1ms，但该段 CPU 时间从约 0.015625s 增至 0.125s；两组墙钟时长不同，不能把这些绝对 CPU 数值当作利用率比较。delay=1 仍约 15ms。

候选保留了空 timer 池的睡眠，却会在活跃的到期 timer 上请求非阻塞轮询；空池不空转不能证明活跃负载的 CPU 成本可忽略。现有默认延迟维持 1ms，不把配置 0 描述成同步执行或零成本的精确立即唤醒。

## 对外部方案的判断

Windows 周期性 Waitable Timer、Linux 周期性 timerfd 都有助于避免“任务执行完再相对睡眠”产生的持续漂移，但不能保证业务代码按每个截止时刻获得 CPU。

- Windows 如继续研究，应明确使用 `CreateWaitableTimerExW` 的 `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`，不能把普通 `CreateWaitableTimer` 或 100ns 参数单位直接视为精度保证；本轮未实测这个新后端，不据此修改生产实现。
- Windows timer HANDLE 不能直接放入 WSAPoll 的 socket 数组；替换方案必须同时处理网络事件与定时事件的共同等待。
- Linux 应读取并处理 timerfd 的到期计数，明确补执行、合并或跳过过期周期；不能读后丢弃计数却声称逐周期执行。
- 评估应记录实际开始时间相对目标截止时刻的迟到、P99/P99.9、漏周期数与任务执行时间，不能仅凭 200 次相邻间隔的平均值判断稳定。
- 提高优先级或绑核只能作为有界的受控对照；普通调度、高优先级和绑核都不等于硬实时保证。

## 资料与清理

保留本结论及会话目录中的最小独立复现源码。中间 CSV、完整 trace、临时日志、候选二进制及零延迟候选代码不进入 main；旧的 timer／socketpair 分散实验报告合并为本文。本次清理不涉及其他 allocator、GC 和内存分析工作的材料。

本结论保留汇总而非完整原始样本，不能用于重新计算全部分位数；再次验证应重新采样。既有服务进程没有因本轮收尾被重启或替换。

参考：[epoll_wait / epoll_pwait2](https://man7.org/linux/man-pages/man2/epoll_wait.2.html)、[timerfd](https://man7.org/linux/man-pages/man2/timerfd_create.2.html)、[Linux timerlat](https://docs.kernel.org/trace/timerlat-tracer.html)、[WSAPoll](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsapoll)、[timeBeginPeriod](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod)、[高分辨率 Waitable Timer](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw)、[被分析的知乎回答](https://www.zhihu.com/question/536739862/answer/2017143845486343716)。
