# CodeOutline

[English](README.md) | 简体中文

Lightweight code indexing and exploration for coding agents, as an MCP server. Powered by Lua.

面向编程智能体的轻量代码索引与查询服务：按符号查询带行号的源码、调用路径和上下游关系，自动增量刷新并缓存到磁盘。MCP 协议、stdio 与 Streamable HTTP 传输均由 Lua 实现，服务运行不依赖 Node；npm 包中的 Node 只负责找到对应平台的程序并启动。

## 安装与配置

需要 Node.js 20 或更新版本。npm 会按系统自动下载对应平台的运行时，无需编译器或 Lua。请全局安装，不要在客户端配置里写 `npx -y`：npx 会在它启动的每个服务旁边常驻一个完整的 npm 进程。

```sh
npm install -g codeoutline
codeoutline --version
```

### 推荐：共享一个 HTTP 服务

stdio 服务是客户端的子进程，每个智能体会话（每个 Claude Code 会话、每个 Cursor 窗口）都会各自启动一份，并各自建一份内存索引。HTTP 服务只用一个进程、一份索引，供所有会话共用。

通过 npm 全局安装时，会在后台启动这个服务，并登记为登录时自动启动：Windows 写入注册表 `Run` 项，macOS 添加 LaunchAgent，Linux 添加 systemd 用户单元；没有 systemd 用户管理器时（WSL、容器），请自行在登录时运行 `codeoutline daemon`。服务会自行安装更新并重启到新版本，因此安装后只需登记一次它的地址。

**Claude Code**（全局添加，在任意项目中可用）：

```sh
claude mcp add --transport http codeoutline --scope user http://127.0.0.1:19876/mcp
```

**Cursor**（`~/.cursor/mcp.json`）：

```json
{ "mcpServers": { "codeoutline": { "url": "http://127.0.0.1:19876/mcp" } } }
```

原生安装或使用 `--ignore-scripts` 安装后，运行 `codeoutline install` 完成同样的操作；`--port` 可指定 19876 以外的端口。安装时设置 `CODEOUTLINE_AUTOSTART=0` 可不登记自启动。`codeoutline uninstall` 会停止服务并删除自启动项；`npm uninstall -g codeoutline` 不会运行包脚本，请先运行它。服务日志位于 `~/.codeoutline/logs`。

服务监听 `127.0.0.1:19876`，可访问本机任意位置的项目，在不同盘的项目之间切换无需额外配置；只有本机进程能连到它，而本机进程本来就有你的文件访问权限。共享服务没有自己的项目：客户端提供 roots 时使用 roots，否则由智能体传入 `projectPath`，缺少时工具会提示需要它。

如需自行运行 HTTP 服务（例如只允许访问部分目录），启动 `codeoutline serve --http`，并为每个允许的目录树重复一次 `--allow-root`；启动时不可用的目录（如未挂载的盘）只会给出提示，出现后即可使用。这样的服务会安装更新，但在重启前继续运行旧版本；Windows 上请托管原生启动器而不是 npm 启动器，原因见 [DISTRIBUTION.md](docs/DISTRIBUTION.md)。

### 备选：stdio，每个会话一个进程

不想常驻服务时使用 stdio，每个会话自行启动和关闭自己的服务进程。

```sh
claude mcp add codeoutline --scope user -- codeoutline serve --stdio
```

Windows 上 Claude Code 无法直接启动 `codeoutline.cmd`，请改用 `-- cmd /c codeoutline serve --stdio`。Cursor 配置为 `"command": "codeoutline", "args": ["serve", "--stdio"]`。客户端不带参数启动 `codeoutline`（0.1.7 推荐的写法）时，得到的也是这个 stdio 服务。

未指定项目时，服务依次使用：调用参数 `projectPath`、启动参数 `--project`、客户端 roots（`roots/list` 返回的第一个目录）、服务启动目录。客户端通常在项目目录中启动 stdio 服务，因此全局配置无需写项目路径。访问范围默认为 `--project` 或启动目录，可用可重复的 `--allow-root` 扩大。

提供三个工具：

| 工具 | 用途 |
| --- | --- |
| `codeoutline_explore` | 按符号或文件名查询源码、调用路径与上下游（参数 `query`，可选 `projectPath`、`budget`） |
| `codeoutline_status` | 刷新并报告索引、缓存、扫描器与解析统计 |
| `codeoutline_rebuild` | 绕过缓存完整重建 |

不使用 Node 时，可从 [GitHub Releases](https://github.com/1dao/codeoutline/releases) 下载对应平台的原生压缩包，解压后直接运行 `codeoutline`（Windows 为 `codeoutline.cmd`）。

## 系统要求

| 平台 | 要求 |
| --- | --- |
| Windows | x64，Windows 10 / Server 2016 或更新（原生压缩包最低 Windows 8）；Windows 11 ARM64 经 x64 仿真运行。无需 VC++ 运行库 |
| Linux | x64，glibc 2.28 或更新：RHEL / Rocky / Alma 8 与 9、CentOS Stream 9、Debian 10+、Ubuntu 20.04+。不支持 Alpine/musl |
| macOS | macOS 11 或更新，Apple Silicon 与 Intel 共用一个通用程序 |

Linux 上解码 GBK 源码需要系统 iconv 的 GBK 模块；EL8/EL9 最小安装与容器镜像需另行安装：`dnf install glibc-gconv-extra`。缺少时 UTF-8 项目不受影响，`codeoutline doctor` 会给出提示。

## 支持的语言

C、C++、C#、Go、Java、JavaScript / TypeScript（含 JSX/TSX）、Lua、Python、Rust。

## 命令行

```sh
codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
codeoutline serve --http [--host HOST] [--port PORT] [--project PATH] [--allow-root PATH ...]
codeoutline explore --project PATH --query QUERY [--budget BYTES]
codeoutline status [--project PATH]
codeoutline rebuild [--project PATH]
codeoutline doctor [--project PATH]
```

`status`、`rebuild`、`doctor` 输出 JSON；诊断失败返回非零退出码。一次性命令的项目默认为当前目录。

`xlsp` 分支已提供独立 stdio LSP 开发预览，支持文件符号和项目符号，详见 [LSP.md](docs/LSP.md)。它尚未包含在已发布的 0.1.9 中，也尚未接入共享 HTTP 后台。

运行时只把警告和错误输出到 stderr，不写日志文件，在项目中启动不会留下任何文件。排查问题时可设置 `CODEOUTLINE_LOG_LEVEL`（`DEBUG`、`INFO`、`WARN`、`ERROR` 等）调整级别，设置 `CODEOUTLINE_LOG_DIR` 将日志文件写到该目录。

## MCP 服务细节

协议基线为 [MCP 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)。查询预算为 256–262144 字节，默认 16000；超限输出保持 UTF-8 有效并附截断提示。路径均指服务所在机器。

stdio 模式下 stdout 只输出 MCP 消息，日志写入 stderr。HTTP 默认只监听本机，客户端地址为 `http://127.0.0.1:19876/mcp`。远程监听需设置至少 16 字节的 `CODEOUTLINE_TOKEN` 并用 `--allow-host` 显式允许主机，客户端使用 `Authorization: Bearer ...`；与本机 HTTP 不同，远程服务未传 `--allow-root` 时只允许访问 `--project` 或启动目录；`--allow-origin` 可重复指定允许的完整 Origin，未配置的浏览器 Origin 被拒绝。远程部署应由 TLS 反向代理保护令牌。

主线程处理协议，常驻索引线程串行处理查询。请求含进度 token 时每秒报告进度，HTTP 使用 SSE；没有独立的 GET/SSE 订阅端点（返回 405）。最多 64 个会话、64 个排队或执行中的任务；任务期限 120 秒，会话空闲 15 分钟过期。取消在显式检查点生效，单个文件的原生解析期间无法中断（单文件上限 1.5 MB）。更新被取消时回滚至上一份完整的内存索引；取消只读查询不会丢弃索引。

## 索引行为与限制

缓存位于用户目录 `.codeoutline/cache/<路径 SHA-256>.idx`，带完整性校验，损坏后自动重建；每次写入独立临时文件再原子替换，失败时保留旧文件。默认最多驻留 8 个项目，空闲 15 分钟淘汰。服务使用真实绝对路径统一目录别名与链接，Windows 上忽略 ASCII 大小写。

源码编码按需确认：首次索引不逐个检查编码，查询涉及文件时才确认，UTF-8（含 BOM）优先，失败后严格转码 GBK，重新解析并更新该文件的符号后再执行本次查询，不修改原文件。编码结果随缓存保存，文件改变后失效；无法解码的命中文件会明确报错。两种编码都合法时默认 UTF-8。未被查询过的 GBK 文件仍可能有误解析，中文标识符可能漏匹配；用文件名查询可触发该文件的修正。

优先用 ripgrep（`rg`）枚举文件并遵守各级 `.gitignore`；未安装 `rg` 时改用目录遍历，只支持根目录 `.gitignore` 的常见规则（不支持否定规则与嵌套忽略文件），并跳过隐藏目录、`node_modules`、`__pycache__` 与符号链接。项目根路径不能包含 `"`、`%`、`!`、`$`、反引号、反斜杠或换行。

## 从源码构建

运行时来自 [xnet2lua](https://github.com/1dao/xnet2lua) 子模块：

```sh
git submodule update --init --recursive
```

构建脚本编译 LuaJIT 运行时（开启 xproc、MPSCQ 与 HTTPS），复制到仓库根目录的 `bin/`。Windows 在 MSVC 开发者终端执行，产物静态链接 CRT；macOS 生成最低支持 macOS 11 的通用程序。

```powershell
.\tools\build-runtime.ps1
```

```sh
sh tools/build-runtime.sh
```

从源码运行时需显式带 `LOG_STDERR=1`，安装后的 `codeoutline` 会自动添加：

```powershell
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 serve --stdio --project C:/src/project
```

测试：

```powershell
.\bin\xnet.exe tests/lua/codeoutline_spec.lua
.\bin\xnet.exe tests/lua/stability_spec.lua
npm ci
npm test
npm run test:package
```

`npm test` 使用官方 MCP SDK 验证 stdio 与 HTTP 两种传输；`npm run test:package` 生成真实安装包并在仓库外安装验证。设置 `XSCAN_PURE_LUA=1` 可验证纯 Lua 扫描器路径。打包与发布流程见 [分发说明](docs/DISTRIBUTION.md)。

## 嵌入调用

```lua
package.path = 'scripts/?.lua;' .. package.path
local service = require('codeoutline.service')
local text, info = service.explore('C:/src/project', 'Session.save', { budget = 16000 })
```

`get`、`explore`、`status` 自动刷新；`forget` 只清除内存索引，`rebuild` 绕过磁盘缓存完整重建；`service.configure` 可调整驻留项目数与空闲时间。嵌入 Android 时，宿主须在启动工作线程前调用一次 `xutils_android_init(JavaVM*)`，否则 GBK 转换会明确报错。

## 来源与许可

代码提取自 Codua，命名空间为 `codeoutline.*`。项目采用 [BSD-2-Clause](LICENSE)，第三方依赖声明见 [第三方说明](docs/THIRD_PARTY.md)。
