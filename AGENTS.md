# Repository Guidelines

## Project Structure & Module Organization

This project was extracted from `../codua`, specifically `scripts/xagent/codeindex/`. Consult that source when tracing inherited behavior; keep this standalone library independent of Android application code.

CodeOutline is implemented in Lua. `scripts/codeoutline/` contains the indexing library, CLI, MCP protocol, HTTP transport, and index worker; `lang/` contains parsers. Use `codeoutline.service` for embedding and `main.lua` for MCP. Keep xagent integration in `adapters/xagent/`, Lua regressions in `tests/lua/`, and SDK interoperability tests in `tests/node/`. `xnet2lua/` is the native runtime submodule. Node is only a test dependency; do not introduce a JavaScript service layer. Distribution is not implemented yet.

## Build, Test, and Development Commands

Run commands from the repository root. Initialize the runtime source:

```powershell
git submodule update --init --recursive
```

Build from an MSVC developer terminal on Windows:

```powershell
Push-Location xnet2lua
.\build.bat release xnet xproc
Pop-Location
```

This includes native `xscan`; Windows `xproc` support is limited upstream and is not required by the indexing library.

```powershell
# Run the test suite.
.\xnet2lua\bin\xnet.exe tests/lua/codeoutline_spec.lua
.\xnet2lua\bin\xnet.exe tests/lua/stability_spec.lua
# Explore symbols in a project.
.\xnet2lua\bin\xnet.exe scripts/codeoutline/cli.lua ROOT=C:/src/project "Q=Session.save" BUDGET=16000
# Start the native MCP service.
.\xnet2lua\bin\xnet.exe scripts/codeoutline/main.lua STDIO=1 PROJECT=C:/src/project
```

Run `npm ci` and `npm test` for optional official SDK interoperability checks. Rebuild this submodule after native API changes; do not assume a sibling runtime is compatible.

## Coding Style & Naming Conventions

Follow existing Lua style: four-space indentation, single-quoted strings where practical, and `snake_case` for descriptive local functions and variables. Modules generally export a local `M` table and finish with `return M`. Require library modules through `codeoutline.*`. Keep language-specific parsing in `lang/<language>.lua` and shared helpers in `common.lua`. No formatter or lint configuration is currently tracked.

## Testing Guidelines

Tests use the custom `spec_helper.lua` harness with `spec.describe`, `spec.it`, and explicit assertions. Add behavior-focused cases to `codeoutline_spec.lua`, covering affected symbol locations, call relationships, incremental refresh, or cache behavior. No numerical coverage threshold is configured. For scanner or parser changes, run both the default scanner path and the fallback by setting `$env:XSCAN_PURE_LUA = '1'`; restore the environment afterward.

## Commit & Pull Request Guidelines

Use concise, descriptive commit subjects, following `初始化 CodeOutline 索引核心`. Keep commits focused. PRs should describe behavior, relevant issues, validation commands/results, and example queries for exploration changes. Explain submodule updates; exclude generated logs and binaries. Commit dependency changes before updating its parent pointer, only when committing is requested.

## Agent Instructions

If the repository root contains `.codegraph/`, use `codegraph_explore` or `codegraph explore "<symbol or question>"` before text searches or source reads to locate or understand code. Otherwise, skip CodeGraph; do not create an index without the user's direction.
