# CodeOutline

Lightweight code indexing and exploration for coding agents, designed for MCP integration and distribution through npm and other package managers. Powered by Lua.

从 Codua 提取的独立 Lua 代码索引库：符号查询、带行号源码、调用关系、增量刷新和磁盘缓存。MCP 协议、stdio、Streamable HTTP 和工具分发均由 Lua 实现，运行服务不依赖 Node。

目标是提供独立 MCP 服务，并通过 npm 等包管理平台分发；目前尚未发布安装包。

## 目录

- `scripts/codeoutline/`：索引、图、查询、词法扫描器和各语言解析器。
- `scripts/codeoutline/main.lua`：原生 MCP 入口；`mcp.lua`、`http.lua` 处理协议，`index_worker.lua` 在独立 Lua 线程中索引。
- `adapters/xagent/code_explore.lua`：使用独立库的 CodeExplore 工具适配器。
- `tests/lua/`：解析、跨文件关系、增量刷新、查询和缓存测试。
- `tests/node/`：官方 MCP SDK 客户端互操作测试；仅开发测试需要 Node。
- `xnet2lua/`：运行时 submodule。
- `launcher/`：npm 平台运行时启动薄层；命令解析与服务逻辑均为 Lua。
- `tools/`：构建与分发包生成；`docs/DISTRIBUTION.md` 说明离线安装和发布条件。

## 运行

以下命令在仓库根目录执行。初始化运行时源码：

```powershell
git submodule update --init --recursive
```

构建运行时并复制到仓库根目录 `bin/`（已被 Git 忽略）。Windows 在 MSVC 开发者终端执行，产物静态链接 CRT：

```powershell
.\tools\build-runtime.ps1
```

Linux/macOS：

```sh
sh tools/build-runtime.sh
```

测试、打包和文档中的命令都使用 `bin/` 中的副本；直接在 `xnet2lua/` 内构建后，需重新运行上述脚本复制。

该构建使用 LuaJIT 运行时，开启 xproc、MPSCQ 与 HTTPS，包含原生 xscan；发布包使用同一构建。LuaJIT 编译后的代码不触发计数 hook，取消在每个文件的显式检查点生效，单个文件解析期间无法中断（单文件上限 1.5 MB）。

```powershell
.\bin\xnet.exe scripts/codeoutline/cli.lua ROOT=C:/src/project "Q=Session.save" BUDGET=16000
.\bin\xnet.exe tests/lua/codeoutline_spec.lua
```

必须重新构建本仓库运行时：当前核心使用新增的 `xutils.realpath`、`temp_file`、`replace_file`，stdio 还需要 `read_stdin` 和启动日志分流。旧的相邻仓库二进制不一定具有这些接口。

按需编码处理还需要运行时提供 `xutils.to_utf8`；`doctor` 会检查该能力。Windows 使用系统代码页 936，Linux/macOS 使用 iconv，iOS 使用 CoreFoundation，Android 使用 JNI CharsetDecoder，不内置 GBK 映射表。Android 宿主须在启动工作线程前调用一次 C 接口 `xutils_android_init(JavaVM*)`，无需逐个 Lua 状态注册；iOS 无需额外初始化。未初始化的 Android GBK 转换会明确报错，UTF-8 不受影响。

## MCP 服务

统一入口（源码运行时需显式带 `LOG_STDERR=1`；安装后的 `codeoutline` 自动添加）：

```powershell
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 doctor --project C:/src/project
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 serve --stdio --project C:/src/project
```

统一 CLI 支持 `serve`、`explore --query ...`、`status`、`rebuild`、`doctor`、`--help` 和 `--version`。
`status`、`rebuild`、`doctor` 输出 JSON；诊断失败返回非零退出码。`serve` 必须指定 `--stdio` 或 `--http`。
HTTP 使用 `--host`、`--port`，访问范围使用可重复的 `--allow-root`、`--allow-host`、`--allow-origin`。

```powershell
# stdout 仅输出 MCP 消息；STDIO=1 会在运行时启动阶段将日志分流至 stderr。
.\bin\xnet.exe scripts/codeoutline/main.lua STDIO=1 PROJECT=C:/src/project

# HTTP 默认仅监听本机；客户端使用 http://127.0.0.1:19876/mcp。
.\bin\xnet.exe scripts/codeoutline/main.lua HTTP=1 PROJECT=C:/src/project PORT=19876
```

从其他工作目录启动时，将可执行文件和 `main.lua` 写成绝对路径。`PROJECT` 默认不设置；`ALLOW_ROOT` 默认是 `PROJECT` 或启动目录，可重复传入以允许多个目录。调用未传 `projectPath` 时依次使用 `PROJECT`、客户端 roots（`roots/list` 返回的第一个 `file://` 目录，按会话缓存，收到 `roots/list_changed` 后重新获取，10 秒无响应则跳过）、stdio 模式的启动目录；都没有时返回错误。结果仍须位于 `ALLOW_ROOT` 内。因此全局配置无需写 `PROJECT`。路径指向服务所在机器，不是客户端机器。

协议基线为 [MCP 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)。提供 `codeoutline_explore`（`projectPath`、`query`、可选 `budget`）、`codeoutline_status` 和 `codeoutline_rebuild`。查询预算为 256–262144 字节，默认 16000；超限输出保持 UTF-8 有效并附截断提示。

主线程处理协议，常驻索引线程串行处理查询。取消通过共享标记和 Lua 检查点执行；取消后丢弃可能不完整的内存索引，下次查询从缓存恢复。原生扫描和文件系统调用需返回后才能检查取消，单文件默认上限 1.5 MB。请求含进度 token 时每秒报告运行进度，HTTP 使用 SSE；普通响应使用 JSON。没有独立 GET/SSE 订阅端点（返回 405）。最多 64 个会话、64 个排队/执行任务；任务期限 120 秒，会话空闲 15 分钟过期。

远程监听需设置至少 16 字节的 `CODEOUTLINE_TOKEN`，并显式传入 `ALLOW_HOST`。客户端用 `Authorization: Bearer ...`。`ALLOW_ORIGIN` 可重复指定完整 Origin，未配置的浏览器 Origin 被拒绝。远程网络部署应由 TLS 反向代理保护令牌；默认本机使用不需要额外配置。

## 测试

```powershell
.\bin\xnet.exe tests/lua/codeoutline_spec.lua
.\bin\xnet.exe tests/lua/stability_spec.lua

# 可选：官方 SDK 双传输互操作测试，包含上述原生/纯 Lua 测试。
npm ci
npm test

# 可选：使用相邻 Codua 的未修改客户端与工具适配器。
$env:CODEOUTLINE_CODUA_SCRIPTS = 'C:/source/ops/codua/scripts'
npm test
```

根目录 `package.json` 为开发测试配置，SDK 仅列在 `devDependencies`。`npm run test:package` 会生成真实 tarball，在仓库外安装并验证原生入口、CLI 和 MCP 双传输。Windows x64 已验证 npm/pnpm 离线安装；Linux/macOS 和 Android 界面尚未验收。分发包生成与安装方法见 [分发说明](docs/DISTRIBUTION.md)，当前预览包仍禁止直接发布。

独立验证纯 Lua 扫描器：

```powershell
$env:XSCAN_PURE_LUA = '1'
.\bin\xnet.exe tests/lua/codeoutline_spec.lua
Remove-Item Env:XSCAN_PURE_LUA
```

设置环境变量 `XSCAN_PURE_LUA=1` 可验证纯 Lua 扫描器路径。

## 嵌入调用

```lua
package.path = 'scripts/?.lua;' .. package.path
local service = require('codeoutline.service')
local text, info = service.explore('C:/src/project', 'Session.save', { budget = 16000 })
```

服务使用真实绝对路径统一目录别名和链接，Windows 键忽略 ASCII 大小写。默认最多驻留 8 个项目、空闲 15 分钟淘汰，可用 `service.configure` 调整。`get`/`explore`/`status` 自动刷新，`forget` 仅清内存，`rebuild` 绕过磁盘缓存完整重建。

缓存位于用户目录 `.codeoutline/cache/<路径SHA-256>.idx`，可用 `cache_path` 覆盖。缓存有完整性校验，损坏后自动重建；每次写入独立临时文件再原子替换，失败保留旧文件并通过刷新统计报告。并发写入采用最后成功发布的快照，下次查询仍会检查源文件。

源码支持按需确认 UTF-8、带 BOM 的 UTF-8 和 GBK。首次索引不额外遍历所有文件检查编码；查询涉及文件时才确认编码，UTF-8 优先，校验失败后尝试严格 GBK 转码。GBK 文件会重新解析、更新调用图，再重新执行本次查询，源码中的中文注释和字符串随之正确显示，不修改原文件。编码结果随索引缓存保存，文件内容改变后失效；无法解码的命中文件会明确报错。两种编码都合法时默认 UTF-8，不能保证自动消除歧义。

未查询文件的索引仍可能包含 GBK 误解析：ASCII 函数名通常可命中，但中文标识符或特殊字符串可能造成漏匹配和不完整的调用关系。可以用文件名查询触发该文件的修正；当前不在查询未命中时全项目扫描，也不增加注释全文检索或函数前置注释提取。

使用 xutils 文件系统能力、cmsgpack 序列化、xcompress 校验；优先使用原生 xscan，提供纯 Lua 回退。优先用 rg 枚举并遵守 gitignore；目录遍历回退仅支持根目录 `.gitignore` 的常见规则，不支持否定规则和嵌套忽略文件，并跳过隐藏目录、`node_modules`、`__pycache__` 及符号链接。枚举失败和超限明确报错。当前拒绝包含 shell 特殊字符（如 `%`、`$`、引号）的项目根路径。

## 来源及后续

代码来自 Codua，命名空间已改为 `codeoutline.*`。

统一入口使用 `command.lua`；保留 `cli.lua`、`main.lua` 的原有参数兼容性。已提供 npm/原生预览打包与三平台 CI，跨平台运行验证和正式发布仍待完成。C 运行时改动已推送至 xnet2lua 上游提交 `1086e0d`，本项目子模块绑定该提交。

项目采用 [BSD-2-Clause](LICENSE)，依赖声明见 [第三方说明](docs/THIRD_PARTY.md)。
