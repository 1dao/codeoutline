# 变更日志

本文件记录 CodeOutline 的主要变更。首个发布版本为 `0.1.0`。

## 0.1.0 (2026-09-30)

### 新增

- 按需识别源码编码：查询涉及的文件依次确认 UTF-8、带 BOM 的 UTF-8 和 GBK，GBK 文件经 `xutils.to_utf8` 严格转码后重新解析并重建调用图，编码结果随索引缓存保存。首次索引不额外检查编码。
- `doctor` 检查运行时是否提供 `xutils.to_utf8`。
- 未传 `projectPath` 且未配置 `PROJECT` 时，自动向支持 roots 的客户端请求 `roots/list` 并使用第一个目录（HTTP 经本次响应的 SSE 流发送），结果按会话缓存并在 `roots/list_changed` 后刷新；stdio 模式再回退到服务启动目录。全局配置 MCP 时不必再写死项目路径。

### 修复

- HTTP 收到客户端发回的 JSON-RPC 响应时返回 `202 Accepted`（此前为 204），符合 Streamable HTTP 规范。
- 无法确定项目目录时，错误信息改为明确提示需要 `projectPath`，不再返回含义不清的路径校验错误。
- 刷新时文件大小与修改时间都未变、且上次读取晚于修改时间 1 秒以上的文件直接跳过，不再每次查询读取全部源码并计算校验和；同一秒内的修改仍会重新读取。把修改时间恢复为旧值且大小不变的特殊工具不在检测范围内。
- 从缓存加载且源码未变化时，不再重写整个缓存文件。只有文件被解析、删除或编码结果更新时才保存；保存失败会在下次调用时重试。大型项目带缓存重启约快 0.3 秒，多进程共享缓存时也不再用未改动的快照覆盖他人的更新。
- 未安装 ripgrep 时跳过 rg 枚举测试，并在该测试失败时清理临时文件，避免后续稳定性用例连带失败（macOS 上 3 项失败的根因）。
- HTTP 令牌校验改用算术实现的常量时间比较，不再使用 LuaJIT 无法解析的位运算符；LuaJIT 运行时下 HTTP 模式可正常启动。
- 系统 iconv 缺少 GBK 模块（EL8/EL9 最小安装与容器镜像不含 `glibc-gconv-extra`）时：查询涉及 GBK 文件的报错附带安装提示，`doctor` 新增 `gbk` 检查（仅警告，UTF-8 项目不受影响），稳定性测试跳过 GBK 用例。CI 在原版 AlmaLinux 8 上要求跳过、在装有 `glibc-gconv-extra` 的 CentOS Stream 9 上要求执行 GBK 用例，由 `tools/ci-distro-test.sh` 校验。

### 变更

- 版本号定为 `0.1.0`，MCP `serverInfo` 改为读取 `version.lua`。打包工具新增 `RELEASE=1`：仅在干净的检出、正式版本号且 `TAG` 与版本一致时去掉 `private: true`，并在清单中补充仓库、主页与关键词；CI 仅对标签推送生成可发布产物，原生压缩包去掉 `-preview` 后缀。
- 平台包改用作用域名称 `@chybin/codeoutline-<平台>`：npm 反垃圾检查拒绝新的无作用域 `<名称>-<平台>` 包名。入口包仍为 `codeoutline`；各包声明 `publishConfig.access = public`。
- 开发用运行时改放在仓库根目录 `bin/`：`tools/build-runtime.ps1` 与新增的 `tools/build-runtime.sh` 构建后复制到此处，测试、打包、CI 和文档统一使用 `bin/xnet`。发布包内部结构不变。
- Linux 运行时改在 `manylinux_2_28`（AlmaLinux 8，glibc 2.28）容器中构建，原先在 CI 主机 ubuntu-22.04（glibc 2.35）上构建的包无法在 CentOS Stream 9（glibc 2.34）等系统运行。CI 检查二进制所需的最高 glibc 符号版本不超过 2.28，并在 AlmaLinux 8 与 CentOS Stream 9 容器中运行测试；npm 启动器遇到低于 2.28 的 glibc 时给出明确提示。
- Windows 平台包同时声明 `arm64`，启动器在 Windows 11 ARM64 上回退到 x64 包经仿真运行，不再报不支持的平台。分发文档补充 Windows 系统要求：x64、静态 CRT、无需 VC++ 运行库，原生包最低 Windows 8 / Server 2012。
- macOS 平台包改为通用二进制 `darwin-universal`（arm64 + x86_64），Intel Mac 也可安装；`build-runtime.sh` 固定最低版本为 macOS 11，原先 CI 在 macos-14 上构建会要求 macOS 14。CI 检查两个架构切片及其最低版本，并在 Rosetta 下运行 x86_64 切片的测试。
- 运行时改用 LuaJIT，并开启 MPSCQ（xproc、HTTPS 保持开启），发布包与本地构建一致；完整重建约快 25%。`build-runtime.*` 每次重新编译 LuaJIT，macOS 按架构分别编译；发布包改附 LuaJIT 许可证，`build-info.json` 记录 Lua 版本，`doctor` 显示 LuaJIT 版本。LuaJIT 编译后的代码不触发计数 hook，取消改由显式检查点保证：调用图构建的两个按文件循环补上检查点（此前只有解析阶段有）。取消测试的索引规模加大到 36 个文件，并在取消前确认索引仍在运行，此前在更快的 LuaJIT 下索引会在取消前完成。

### 依赖

- xnet2lua 更新至 `8aac7a2`，新增 `xutils.to_utf8`：Windows 使用代码页 936，Linux/macOS 使用 iconv，iOS 使用 CoreFoundation，Android 使用 JNI CharsetDecoder（宿主需调用一次 `xutils_android_init`）。
- xnet2lua 更新至 `c9fbc0d`：LuaJIT 后端恢复可用（C 兼容层、`utf8` 库、协程内定时器回调修复、脚本去除 5.3+ 语法），并修复 `build.bat` 测试覆盖脚本与 nohttps 链接失败。CodeOutline 的 Lua 代码与测试在 LuaJIT 运行时下全部通过；默认仍为内置 Lua 5.5。

## 2026-09-27

### 新增

- 统一 CLI：`serve`、`explore`、`status`、`rebuild`、`doctor`、`--help`、`--version`。
- 跨平台分发预览：npm 平台启动薄层（`launcher/`）、`tools/package.lua` 打包、`tools/build-runtime.ps1` 静态 CRT 构建、CI 工作流与第三方许可证。
- Lua 实现的 MCP 服务（协议基线 2025-06-18），支持 stdio 与 Streamable HTTP，提供 `codeoutline_explore`、`codeoutline_status`、`codeoutline_rebuild`；常驻索引线程、取消与进度报告、会话与任务上限、远程访问令牌与 Host/Origin 校验。
- 索引稳定性：路径规范化、原子替换缓存与完整性校验、损坏缓存自动重建、枚举失败时保留已缓存记录。
- 官方 MCP SDK 互操作测试与 Codua 客户端互操作测试。

## 2026-09-26

### 新增

- 从 Codua `scripts/xagent/codeindex/` 提取独立索引核心：符号查询、带行号源码、跨文件调用关系、增量刷新和磁盘缓存。
- 支持 Lua、C、C++、C#、Go、Java、JavaScript/TypeScript、Python、Rust 解析；原生 xscan 扫描器与纯 Lua 回退。
- xagent `CodeExplore` 工具适配器。
