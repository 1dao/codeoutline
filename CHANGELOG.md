# 变更日志

本文件记录 CodeOutline 的主要变更。

## 0.2.0（未发布）

### 新增

- 语言服务器 `codeoutline lsp --stdio`：文档与工作区符号、定义跳转（在导入行上跳到被加载的文件）、悬停、签名帮助、引用、调用层级和补全。每次请求都包含未保存的修改；`initializationOptions.features` 可逐项关闭功能，以便与其他语言服务器并用，`includePaths` 可补充 C/C++ 头文件目录。各平台的启动方式见 README 的“编辑器集成（LSP）”。
- 工作区根目录的 `.codeoutline.json` 可定义跳转规则，把 Lua 调用中的字面量参数映射到注册位置，例如从 `xthread.post` 的消息名跳到对应的 `xthread.register`。
- VS Code 与 Cursor 共用的 VSIX 客户端，以及 Zed 扩展。两者都在仓库内构建，尚未上架扩展市场。两者默认都使用 npm 全局安装，无需任何设置：Windows 上 VSIX 无法直接启动 npm 的 `codeoutline.cmd`，会自行找到该安装并用 Node 运行它的启动器；Zed 从 PATH 找到 `codeoutline.cmd` 后通过 cmd.exe 启动。
- 全量索引并行解析：需要读取的文件不少于 32 个时，按需启动解析线程（Windows 8 个，其他平台 6 个），按文件大小均衡分配，由索引线程统一提交结果；空闲 60 秒后回收。`CODEOUTLINE_INDEX_THREADS` 可覆盖线程数，设为 `0` 关闭。在一个 5.6 万文件的项目上，Windows 冷启动的首次索引从约 55 秒降到约 14 秒。

### 变更

- 索引不再预先构建调用图，调用、调用方和调用路径改为查询时解析；单次查询最多展开 20,000 个节点，超出时在输出中注明。文件逐个提交，被中断的刷新会保留已提交的文件。`codeoutline_status` 不再报告边数。
- 索引缓存改为更紧凑的节点格式，旧缓存在首次启动时自动重建。
- 运行时改用系统内存分配器，不再使用 rpmalloc：8 线程全量索引后的提交内存从约 6 GB 降到约 0.8 GB，速度不变。

### 修复

- C/C++ 相对路径的 `#include "../x.h"` 改为相对包含它的文件解析，此前只按路径后缀匹配，头文件可能不被当作依赖。导航会跟随传递包含，头文件中的 static 辅助函数也能解析。
- 语言服务器和后台服务空闲时内存每秒上涨数 KB：LuaJIT 要等堆翻倍才开始下一轮回收，索引常驻时空闲产生的垃圾长期得不到回收。索引线程现在在空闲时分步回收（每步最多约 6 ms），自上轮回收以来的垃圾达到存活堆的 1/16（至少 16 MB）或移出项目后启动；移出项目的索引也会真正释放。

## 0.1.9 (2026-10-04)

### 修复

- npm 把 0.1.8 装到通过自动更新安装的 0.1.7 之上后，启动器仍然选择 0.1.7，新版本始终不生效。现在比初始安装旧的已安装更新会被跳过，启动器和后台服务都运行较新的初始安装。

## 0.1.8 (2026-10-04)

### 新增

- 共享的本机 HTTP 服务改为登录时启动的后台服务 `codeoutline daemon`。npm 全局安装时自动登记自启动（Windows 注册表 `Run` 项、macOS LaunchAgent、Linux systemd 用户单元），`CODEOUTLINE_AUTOSTART=0` 可跳过；`codeoutline install` / `uninstall` 用于手动登记和移除。同一端口只保留一个服务进程，安装更新后由新版本接替。
- 常驻服务监视项目目录：没有改动时查询跳过刷新，编辑只重新解析变化的文件。无法监视的目录退回全量刷新，每 5 分钟重试一次。

### 变更

- 移除 0.1.7 的 `codeoutline connect` 代理：服务在登录时已经启动，客户端只需登记一次地址。客户端不带参数启动 `codeoutline` 时改为得到 stdio 服务，0.1.7 的登记方式仍然可用。

### 性能

- 全量刷新按目录一次取得文件元数据，5.6 万个文件从 4.0 秒降到 0.4 秒（Windows）。
- 构建调用图时先按位置筛掉无关候选，评分过程不再逐个分配对象；5.6 万文件的项目从 18.3 秒降到 4.7 秒，结果不变。

## 0.1.7 (2026-10-03)

### 新增

- 不带参数运行 `codeoutline`：由客户端启动时作为 MCP 服务器使用，在终端中则显示帮助。新增 `codeoutline connect`，作为连接共享本机 HTTP 服务的 stdio 代理：没有服务在监听时在后台启动一个，服务重启后恢复会话。
- `serve` 在启动时和每小时检查一次更新。安装更新后，stdio 服务和由 connect 启动的服务在空闲时退出，下一次请求即运行新版本；`CODEOUTLINE_EXIT_ON_UPDATE` 可改变这一行为。

### 变更

- 安装更新后删除其他已安装的版本，正在运行的进程所用的版本会保留。移除 `update --rollback`；要回到初始安装，删除 `~/.codeoutline/updates` 即可。
- 磁盘上的索引缓存改用 deflate 压缩，体积降到原来的 15–19%（最大的本地项目从 203 MB 降到 37 MB）。旧格式缓存会自动重建。

## 0.1.6 (2026-10-03)

本版本只通过自动更新发布，没有发布到 npm。

### 性能

- 引用改为按列存储，调用边改为扁平数组，大型项目的索引内存和 GC 开销明显降低。缓存格式随之变化，旧缓存会自动重建。

## 0.1.5 (2026-10-02)

### 新增

- 自动更新支持仅更新脚本：复用本机已有的运行时，下载量更小；本机缺少所需运行时时，自动下载并校验它所引用的完整版本。0.1.4 的初始安装需要先通过 npm 或原生包升级一次，才能接收仅脚本的更新。

## 0.1.4 (2026-10-02)

### 变更

- 所有命令直接启动已验证的最新已安装版本，不访问网络。`serve` 改为在后台线程检查更新，更新服务器不可达时不再拖慢启动或请求，新版本在下次启动时生效。

## 0.1.3 (2026-10-02)

### 新增

- 签名的自动更新：npm 和原生启动器可以运行 `~/.codeoutline/updates` 中验证过签名的版本，npm 安装作为初始版本和恢复版本。新增 `codeoutline update`（`--check` 只检查）和 `update --rollback`；`serve` 启动前检查更新，`CODEOUTLINE_AUTO_UPDATE=0` 关闭自动检查。`codeoutline --version` 显示实际运行的版本。

## 0.1.2 (2026-10-02)

### 变更

- 本机监听的 `serve --http` 未传 `--allow-root` 时不再限制项目目录：一个共享服务要服务所有会话，而这些会话的项目可能分布在不同的盘上；只有本机进程能连到它，这些进程本来就有用户的文件访问权限。stdio 与远程 HTTP 的默认范围不变，仍为 `--project` 或启动目录。
- README 改为推荐共享一个 HTTP 服务：stdio 服务是客户端的子进程，每个会话各启动一份。安装改为 `npm install -g`，不再在客户端配置中使用 `npx -y`，因为 npx 会在每个服务旁常驻一个 npm 进程。

### 修复

- `--allow-root` 指向的目录不存在（如未挂载的盘）时，服务会启动失败。现在只输出警告，并按原样保留该路径，目录出现后即可访问。

## 0.1.1 (2026-09-30)

### 修复

- 在哪个目录运行 `codeoutline`，运行时就在该目录创建 `logs/` 并写入日志文件；MCP 客户端在项目根目录启动服务，因此会在用户项目中留下 `logs/`。启动器（npm、原生 `codeoutline` / `codeoutline.cmd`）现在默认传入 `LOG_FILE=0` 与 `LOG_LEVEL=WARN`：不写日志文件，终端只显示警告和错误。需要排查时可设置 `CODEOUTLINE_LOG_LEVEL` 调整级别、`CODEOUTLINE_LOG_DIR` 将日志写到指定目录。
- 一次性命令（如 `--version`）不再输出 `xthread.init: no handler set` 警告；命令行解析忽略运行时的 `LOG_*` 参数。
- `serve --http` 启动后的监听地址提示改为输出到 stdout，不再以 `[ERRR]` 错误日志的形式出现：xnet 将 Lua 的 `io.stderr` 写入统一记为错误日志；HTTP 模式下 stdout 不承载协议数据。

### 变更

- 安装包内部结构扁平化：运行时为 `bin/xnet`（Windows 为 `bin/xnet.exe`），HTTP 编解码器为 `lib/xhttp_codec.lua`，不再保留 `xnet2lua/` 目录结构。
- 安装包测试新增检查：包内结构、两种启动器的 `--version` 不向 stderr 输出，CLI 与 MCP 服务运行后项目目录中没有 `logs/`。

### 依赖

- xnet2lua 更新至 `f2c3ddf`：新增 `LOG_LEVEL`、`LOG_FILE`、`LOG_DIR` 启动参数；修复 `build.bat` 重新构建 LuaJIT 时误链 `luajit.lib`。

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
- 平台包改用作用域名称 `@codua/codeoutline-<平台>`：npm 反垃圾检查拒绝新的无作用域 `<名称>-<平台>` 包名。入口包仍为 `codeoutline`；各包声明 `publishConfig.access = public`。
- README 改为英文 `README.md` 与中文 `README.zh-CN.md`，开头互设切换链接，两者均随 npm 包发布；内容按发布后的状态重写：安装与 Claude Code / Cursor 配置、系统要求、支持的语言、命令行，去掉“尚未发布”等过时说法。新增 `.gitattributes`，Windows 检出同样使用 LF，Windows 构建的包不再带 CRLF 文本文件。
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
