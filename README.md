# CodeOutline

Lightweight code indexing and exploration for coding agents, designed for MCP integration and distribution through npm and other package managers. Powered by Lua.

从 Codua 提取的独立 Lua 代码索引库：符号查询、带行号源码、调用关系、增量刷新和磁盘缓存。当前已迁移核心、CLI、测试和 xagent 适配器，MCP 服务端尚未实现。

目标是提供独立 MCP 服务，并通过 npm 等包管理平台分发；目前尚未发布安装包。

## 目录

- `scripts/codeoutline/`：索引、图、查询、词法扫描器和各语言解析器。
- `adapters/xagent/code_explore.lua`：使用独立库的 CodeExplore 工具适配器。
- `tests/lua/`：解析、跨文件关系、增量刷新、查询和缓存测试。
- `xnet2lua/`：运行时 submodule。

## 运行

以下命令在仓库根目录执行。初始化运行时源码：

```powershell
git submodule update --init --recursive
```

Windows 下在 MSVC 开发者终端构建：

```powershell
Push-Location xnet2lua
.\build.bat release xnet xproc
Pop-Location
```

该构建包含原生 xscan。xproc 在 Windows 上的可用性受上游限制，索引库本身不依赖 xproc。

```powershell
.\xnet2lua\bin\xnet.exe scripts/codeoutline/cli.lua ROOT=C:/src/project "Q=Session.save" BUDGET=16000
.\xnet2lua\bin\xnet.exe tests/lua/codeoutline_spec.lua
```

本地开发也可使用相邻仓库的现有运行时：

```powershell
..\xnet2lua\bin\xnet.exe tests/lua/codeoutline_spec.lua
```

设置环境变量 `XSCAN_PURE_LUA=1` 可验证纯 Lua 扫描器路径。

## 嵌入调用

```lua
package.path = 'scripts/?.lua;' .. package.path
local service = require('codeoutline.service')
local text, info = service.explore('C:/src/project', 'Session.save', { budget = 16000 })
```

服务按项目根目录保存内存索引，查询前增量刷新。默认缓存位于用户目录 `.codeoutline/cache/`，可用 `cache_path` 选项覆盖。

使用 xutils 文件系统能力、cmsgpack 序列化、xcompress 校验；优先使用原生 xscan，提供纯 Lua 回退。文件列表优先使用 ripgrep，缺少 rg 时使用目录遍历，后者仅支持部分 gitignore 规则。

## 来源及后续

代码来自 Codua，命名空间已改为 `codeoutline.*`。

后续 MCP 入口复用 `service.explore`，添加协议分发和 Streamable HTTP 传输；stdio 可另行添加。CLI 会输出运行时日志，不能直接当作 stdio MCP 服务使用。
