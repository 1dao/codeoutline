# CodeOutline

[English](README.md) | 简体中文

CodeOutline 是由 Lua 实现的代码探索工具（code_explore）和 LSP Server。

- **面向编程智能体的代码探索**：通过 MCP 工具 `codeoutline_explore` 查询符号、带行号的源码、调用路径和上下游关系；终端中可使用 `codeoutline explore` 完成同类查询。
- **面向编辑器的 LSP Server**：通过 `codeoutline lsp --stdio` 提供符号、定义跳转、引用、悬停、调用层级、补全和签名提示；安装内置的 VS Code、Cursor 或 Zed 客户端即可在编辑器中使用。

面向编程智能体的轻量代码索引与查询服务：按符号查询带行号的源码、调用路径和上下游关系，自动增量刷新并缓存到磁盘。编辑器通过 LSP 使用同一套索引，获得符号、定义跳转、引用、调用层级和补全。MCP 协议（含 stdio 与 Streamable HTTP 传输）和语言服务器均由 Lua 实现，运行不依赖 Node；npm 包中的 Node 只负责找到对应平台的程序并启动。

## 安装与配置

需要 Node.js 20 或更新版本。npm 会按系统自动下载对应平台的运行时，无需编译器或 Lua。请全局安装，不要在客户端配置里写 `npx -y`：npx 会在它启动的每个服务旁边常驻一个完整的 npm 进程。

```sh
npm install -g codeoutline
codeoutline --version
codeoutline --help
```

如需安装时检测 Agent 和编辑器，选择注册哪些应用的 MCP、安装哪些编辑器的 LSP 客户端，运行：

```sh
npm install -g codeoutline --foreground-scripts
```

Agent MCP 注册和编辑器 LSP 安装分别选择，默认均为 `none`（跳过）。
LSP 客户端可输入 `vscode,cursor`、`zed` 或 `all`（全部检测到的编辑器）。
安装后也可以交互选择，或直接指定编辑器：

```sh
codeoutline editors                             # 检测并交互选择
codeoutline editors --list                      # 只查看检测结果
codeoutline editors --editors all               # 为全部检测到的编辑器安装
codeoutline editors --editors vscode            # 只安装 VS Code 客户端
codeoutline editors --editors cursor            # 只安装 Cursor 客户端
codeoutline editors --editors zed               # 只安装 Zed 客户端
codeoutline editors --editors vscode,cursor      # 指定多个编辑器，用逗号分隔
```

无人值守的全局 npm 安装可设置环境变量 `CODEOUTLINE_EDITORS` 为同样的选择，`none` 表示跳过。
没有交互终端时不会等待输入，本地 npm 安装不会修改编辑器安装。
发布包内置客户端，无需 Rust 工具链或从扩展市场下载。
完成后重载 VS Code/Cursor 窗口或重启 Zed。检测覆盖 PATH 和常见安装位置；
自定义位置请把编辑器 CLI 加入 PATH。Zed 使用默认用户数据目录，已有编辑器设置会保留。
VS Code/Cursor 客户端默认启用完整导航；如只需工作区符号搜索，可将 `codeoutline.mode` 设为 `auxiliary`。服务端能力见 [LSP.md](docs/LSP.md)。

### 推荐：共享一个 HTTP 服务

stdio 服务是客户端的子进程，每个智能体会话（每个 Claude Code 会话、每个 Cursor 窗口）都会各自启动一份，并各自建一份内存索引。HTTP 服务只用一个进程、一份索引，供所有会话共用。

通过 npm 全局安装时，会在后台启动这个服务，并登记为登录时自动启动：Windows 写入注册表 `Run` 项，macOS 添加 LaunchAgent，Linux 添加 systemd 用户单元；没有 systemd 用户管理器时（WSL、容器），请自行在登录时运行 `codeoutline daemon`。服务会自行安装更新并重启到新版本。Agent 只需注册一次：

```sh
codeoutline install --yes                         # 自动检测 Agent、配置 MCP 并启动服务
codeoutline install --target cursor,claude,codex   # 指定需要配置的 Agent
codeoutline agents                               # 交互选择，不重启服务
codeoutline agents --list                         # 查看检测结果和配置路径
codeoutline agents --target all                   # 为全部检测到的 Agent 配置 MCP
codeoutline agents --print codex                  # 只预览配置，不写文件
codeoutline agents --target cursor --remove       # 只移除 CodeOutline 的 MCP 配置项
```

支持的目标标识：`claude`、`cursor`、`codex`、`gemini`、`opencode`、`hermes`、
`kiro`、`antigravity`、`copilot-vscode`、`copilot-cli`、`copilot-jetbrains`。
检测依据为已有应用配置目录、配置文件或 PATH 上的 CLI；未检测到时也可显式指定标识。
`all`、`auto` 表示全部检测到的目标，`none` 表示跳过。
`install --yes` 默认不安装 LSP 客户端，需要时另加 `--editors all` 或指定编辑器。

默认写入用户级配置；使用 `--location local --project PATH` 可写入项目级配置，
Hermes、Antigravity、Copilot CLI 和 Copilot JetBrains 仅支持用户级。
`--port` 同时指定注册地址和服务启动端口。`agents` 只编辑配置，`install` 还会启动服务并登记自启动。
完成后重启对应 Agent，即可发现 `codeoutline_explore` 等 MCP 工具；应用自身的工具审批仍然有效。
安装器不会添加提示钩子、修改指令文件或自动放行权限。

已有其他设置和 JSONC 注释会保留；首次修改非空配置文件前，会保存原始文件到 `<配置文件>.codeoutline.bak`。
重复安装同样配置不会重写文件；已有不同的 `codeoutline` 配置会保留，需要显式加 `--force` 才替换。
不能安全编辑的复杂 TOML/YAML 布局会提示使用 `agents --print 标识` 手动配置。
无人值守的全局 npm 安装可设置 `CODEOUTLINE_AGENTS` 为 `auto`、`all`、`none` 或逗号分隔的目标标识；
没有终端且未指定选择时，不会修改 Agent 配置。本地 npm 安装不会注册 Agent。

也可以手动配置：

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

提供五个工具：

| 工具 | 用途 |
| --- | --- |
| `codeoutline_explore` | 按符号或文件名查询源码、调用路径与上下游（参数 `query`，可选 `projectPath`、`budget`） |
| `codeoutline_callers` | [递归查询潜在调用者与涉及文件](docs/CALLERS.md)（参数 `query`，可选 `projectPath`、`depth` 默认 3、`max_nodes` 默认 200、`budget`） |
| `codeoutline_type_hierarchy` | [查询类型的祖先与派生/实现类型](docs/TYPE-HIERARCHY.md)，覆盖 C#、Java、Kotlin、TS、C++（参数 `query`，可选 `projectPath`、`direction`、`depth` 默认 8、`max_nodes` 默认 200、`budget`） |
| `codeoutline_status` | 刷新并报告索引、缓存、扫描器与解析统计 |
| `codeoutline_rebuild` | 绕过缓存完整重建 |

不使用 Node 时，可从 [GitHub Releases](https://github.com/1dao/codeoutline/releases) 下载对应平台的原生压缩包，解压后直接运行 `codeoutline`（Windows 为 `codeoutline.cmd`）。

## 编辑器集成（LSP）

`codeoutline lsp --stdio` 是基于同一索引器的语言服务器。每个编辑器窗口各自启动一个服务进程、各建一份索引，不连接共享的 MCP 服务；MCP 地址也不能当作 LSP 地址使用。

| 功能 | 范围 |
| --- | --- |
| 文档符号、工作区符号 | 工作区符号按子串匹配，不区分大小写 |
| 定义跳转、悬停、签名帮助 | 在导入行（`require`、`#include`、模块导入）上跳转定义会打开被加载的文件 |
| 引用、调用层级 | 函数、方法、构造函数和宏；支持调入与调出 |
| 补全 | 局部变量、本文件的定义与导入、C/C++ 所包含头文件中的声明，以及 `.`、`->`、`::`、`?.`、Lua `:` 之后的成员 |
| 方法实现 | C#、Java、Kotlin、TypeScript 的接口与抽象方法，C++ 虚方法；支持 `textDocument/implementation` |

解析基于名称，与 `codeoutline_explore` 相同，不做类型检查；不提供重命名、诊断和格式化，适合与语言自身的服务器并用，或用于没有语言服务器的场景。每次请求都会带上未保存的修改。工作区根目录的 `.codeoutline.json` 可以把 Lua 调用参数映射到注册位置，用于跳转定义。具体行为、限制和选项见 [LSP.md](docs/LSP.md)。

仓库内提供轻量客户端：[VS Code 与 Cursor](adapters/vscode/README.md) 共用的 VSIX，以及 [Zed](adapters/zed/README.md) 扩展。它们尚未发布到扩展市场，请按各自 README 安装。其他编辑器可通过通用 LSP 支持启动同一命令；目前只在 VS Code、Cursor 和 Zed 上验证过。

客户端不经过 shell 直接启动服务器：

- **Linux 与 macOS**：npm 安装会在 PATH 中放一个可执行的 `codeoutline`，客户端默认配置（`codeoutline` 加 `lsp --stdio`）即可使用。从桌面启动的编辑器可能拿不到 shell 配置文件里追加的 PATH（例如 nvm），此时请配置 `command -v codeoutline` 输出的绝对路径。
- **Windows**：npm 安装的是批处理文件 `codeoutline.cmd`。VS Code/Cursor 客户端会自行找到 npm 安装；Zed 会从 PATH 找到 `codeoutline.cmd` 并通过 cmd.exe 启动，两者都无需设置。无法启动批处理文件的客户端，请把命令配置为 `node`，参数为 `<npm 全局目录>/codeoutline/launcher/codeoutline.cjs`、`lsp`、`--stdio`；`npm root -g` 可输出全局目录，通常为 `C:\Users\<用户名>\AppData\Roaming\npm\node_modules`。使用原生压缩包时，运行其中的 `bin/xnet.exe`，参数为 `<解压目录>/scripts/codeoutline/command.lua`、`LOG_STDERR=1`、`LOG_FILE=0`、`lsp`、`--stdio`。

服务器启动时使用已安装的最新版本，自身不安装更新；后台服务安装的更新在编辑器下次启动服务器时生效。直接从原生压缩包启动时，始终运行该压缩包的版本。

## 系统要求

| 平台 | 要求 |
| --- | --- |
| Windows | x64，Windows 10 / Server 2016 或更新（原生压缩包最低 Windows 8）；Windows 11 ARM64 经 x64 仿真运行。无需 VC++ 运行库 |
| Linux | x64，glibc 2.28 或更新：RHEL / Rocky / Alma 8 与 9、CentOS Stream 9、Debian 10+、Ubuntu 20.04+。不支持 Alpine/musl |
| macOS | macOS 11 或更新，Apple Silicon 与 Intel 共用一个通用程序 |

Linux 上解码 GBK 源码需要系统 iconv 的 GBK 模块；EL8/EL9 最小安装与容器镜像需另行安装：`dnf install glibc-gconv-extra`。缺少时 UTF-8 项目不受影响，`codeoutline doctor` 会给出提示。

## 支持的语言

C、C++、C#、Go、Java、JavaScript / TypeScript（含 JSX/TSX）、ArkTS（`.ets`）、Kotlin（`.kt` / `.kts`）、Lua、Python、Rust。

ArkTS 复用 JS/TS 解析器，将组件 `struct` 按类索引，支持带装饰器的字段、方法、
本地模块导入和 ArkUI 调用；声明式 UI 块不会被当作方法声明。
这是启发式索引，不执行 ArkTS 类型检查；尚不解析 SDK `@kit.*`/`@ohos.*`、资源引用，
也不模拟生成的 UI 生命周期或状态行为。Zed 需要另外安装 ArkTS 语言扩展。

Kotlin 支持声明、主构造器属性、扩展函数、表达式函数体、包导入与别名，以及普通、泛型和尾随 lambda 调用。
关系解析仍是启发式的；不建模编译器生成成员、lambda 隐式接收者、字符串模板内的表达式、Java 互操作或协程/框架分派。

C++ 支持具名类型别名、命名空间别名、`using ns::Type`、`using ns::function`，以及所包含头文件中有界的
`using namespace` 导入链。调用关系、导航和补全共用解析；局部导入遵循声明位置和块作用域，
有歧义的导入名称保留为未解析。详细导入证据按需生成，不写入索引。
这仍是启发式解析，不建模预处理与 include 顺序、编译器头文件搜索配置、依赖模板、ADL 或完整重载决议。

C#、Java、Kotlin 的实现关系依据显式继承和匹配的具名参数类型生成。Explore 与 callers 将这类边标为
`implementation`，表示可能的实现，不表示该方法调用了实现方法，也不证明运行时接收者的类型。
“转到实现”共用这套解析，“转到定义”仍返回声明。详细方法证据按查询生成，不写入索引；
候选、结果或继承层次达到限制时会报告结果不完整。暂不处理泛型替换、仅由继承成员满足的接口实现、
默认接口实现冲突。C++ 虚方法的支持范围见英文 README。

TypeScript 接口和显式抽象方法复用同一套有界查询，只关联顶层具名类型之间显式的
`implements` / `extends`。导入别名、默认导入、命名空间导入、重导出、workspace 包和
tsconfig 路径复用现有模块定位；参数及返回类型须显式标注，解析后完全一致，支持简单数组，
具名类型按声明模块区分。暂不处理泛型继承或方法、类型别名、联合类型、可选/剩余/默认参数、
访问器、箭头函数字段、声明合并、嵌套类型、返回类型推断和结构化实现。类的普通重载声明不作为
抽象契约；这不是 TypeScript 可赋值性检查。证据按查询生成，索引不保存额外实现关系。

JS/TS 还可无需配置地识别有限的 Node EventEmitter 模式：显式导入内置构造器、当前文件的
未导出 const 实例、字面量事件名和具名处理器。Explore/callers 用 `automatic:event` 标注可能的
事件投递，按实例隔离；遇到对象转交、重赋值、移除监听器、未知作用域或动态事件名时保守跳过。
详细证据只在查询时生成，不写入索引。支持范围、数量限制及排除情况见
[间接调用文档](docs/INDIRECT-CALLS.md#automatic-node-eventemitter-deliveries)。

Lua 还可自动关联本文件 local 回调数组：由具名局部函数、字面量数组或 `table.insert` 注册，
再在内置 `pairs` / `ipairs` 循环中直接调用值变量。Explore/callers 用
`automatic:callback-loop` 标注可能调用，复用静态注册表的作用域和别名解析；遇到集合转交、
修改、未知来源或作用域不确定时保守跳过。详细证据按查询生成，不新增持久化索引字段。
支持范围和限制见[间接调用文档](docs/INDIRECT-CALLS.md#automatic-lua-callback-collection-traversal)。

## 命令行

```sh
codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
codeoutline serve --http [--host HOST] [--port PORT] [--project PATH] [--allow-root PATH ...]
codeoutline lsp --stdio [--project PATH]
codeoutline explore --project PATH --query QUERY [--budget BYTES]
codeoutline status [--project PATH]
codeoutline rebuild [--project PATH]
codeoutline doctor [--project PATH]
```

`status`、`rebuild`、`doctor` 输出 JSON；诊断失败返回非零退出码。一次性命令的项目默认为当前目录。`lsp --stdio` 由编辑器启动，通过 stdin/stdout 收发 LSP 消息，不是交互式命令；工作区由编辑器提供，编辑器未提供时才使用 `--project`。

运行时只把警告和错误输出到 stderr，不写日志文件，在项目中启动不会留下任何文件。排查问题时可设置 `CODEOUTLINE_LOG_LEVEL`（`DEBUG`、`INFO`、`WARN`、`ERROR` 等）调整级别，设置 `CODEOUTLINE_LOG_DIR` 将日志文件写到该目录。

## MCP 服务细节

协议基线为 [MCP 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)。查询预算为 256–262144 字节，默认 16000；超限输出保持 UTF-8 有效并附截断提示。路径均指服务所在机器。

stdio 模式下 stdout 只输出 MCP 消息，日志写入 stderr。HTTP 默认只监听本机，客户端地址为 `http://127.0.0.1:19876/mcp`。远程监听需设置至少 16 字节的 `CODEOUTLINE_TOKEN` 并用 `--allow-host` 显式允许主机，客户端使用 `Authorization: Bearer ...`；与本机 HTTP 不同，远程服务未传 `--allow-root` 时只允许访问 `--project` 或启动目录；`--allow-origin` 可重复指定允许的完整 Origin，未配置的浏览器 Origin 被拒绝。远程部署应由 TLS 反向代理保护令牌。

主线程处理协议，常驻索引线程串行处理查询。请求含进度 token 时每秒报告进度，HTTP 使用 SSE；没有独立的 GET/SSE 订阅端点（返回 405）。最多 64 个会话、64 个排队或执行中的任务；任务期限 120 秒，会话空闲 15 分钟过期。取消在显式检查点生效，单个文件的原生解析期间无法中断（单文件上限 1.5 MB）。更新被取消时回滚至上一份完整的内存索引；取消只读查询不会丢弃索引。

## 索引行为与限制

全量扫描有至少 32 个文件需要读取时，服务按需启动解析线程，由索引线程统一提交结果。Windows 默认使用 8 个解析线程，其他平台使用 6 个；可通过 `CODEOUTLINE_INDEX_THREADS` 覆盖，设为 `0` 禁用。线程复用至所有在途批次返回，空闲 60 秒后关闭，下次需要时重新创建。

缓存位于用户目录 `.codeoutline/cache/<路径 SHA-256>.idx`，带完整性校验，损坏后自动重建；每次写入独立临时文件再原子替换，失败时保留旧文件。默认最多驻留 8 个项目，空闲 15 分钟淘汰。服务使用真实绝对路径统一目录别名与链接，Windows 上忽略 ASCII 大小写。

进行隔离缓存或内存实验时，可将 `CODEOUTLINE_MEMORY_CACHE` 设为缓存文件路径。
非空值优先于嵌入 API 的 `cache_path` 和默认路径；空值或未设置时沿用正常路径选择。
它为该进程的所有项目指定同一个文件，因此只适用于单项目运行，不适用于共享多项目服务。
缓存仍会校验源项目并使用原子写入。

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
.\bin\xnet.exe tests/lua/parse_pool_spec.lua
.\bin\xnet.exe tests/lua/lsp_spec.lua
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
