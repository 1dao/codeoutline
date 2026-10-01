# CodeOutline

English | [简体中文](README.zh-CN.md)

Lightweight code indexing and exploration for coding agents, as an MCP server. Powered by Lua.

CodeOutline answers symbol queries with line-numbered source, call paths, and callers/callees, refreshes incrementally, and caches the index on disk. The MCP protocol and both transports (stdio and Streamable HTTP) are implemented in Lua, so the service does not depend on Node; in the npm package, Node only locates and starts the runtime for your platform.

## Installation and setup

Requires Node.js 20 or newer. npm downloads the runtime for your platform automatically; no compiler or Lua installation is needed. Install it globally rather than configuring clients with `npx -y`: npx keeps a full npm process running beside every server it starts.

```sh
npm install -g codeoutline
codeoutline --version
```

### Recommended: one shared HTTP service

A stdio server is a child process of its client, so every agent session (each Claude Code session, each Cursor window) starts its own copy and builds its own in-memory index. One HTTP service serves all sessions from a single process and a single index.

```sh
codeoutline serve --http
```

The service listens on `127.0.0.1:19876` and, without `--allow-root`, serves projects anywhere on the machine, so switching between projects on different drives needs no configuration. Only local processes can reach it, and they already have your file access. To restrict it anyway, repeat `--allow-root` for each directory tree to allow; a tree that is unavailable at startup, such as an unmounted drive, is reported and becomes usable once it appears.

**Claude Code** (added globally, available in every project):

```sh
claude mcp add --transport http codeoutline --scope user http://127.0.0.1:19876/mcp
```

**Cursor** (`~/.cursor/mcp.json`):

```json
{ "mcpServers": { "codeoutline": { "url": "http://127.0.0.1:19876/mcp" } } }
```

A shared service has no project of its own: it uses the client's roots when the client provides them, and otherwise the agent passes `projectPath`, which the tools ask for when it is missing. Clients do not start an HTTP service, so start it at login (Task Scheduler on Windows, launchd on macOS, a systemd user unit on Linux). On Windows, supervise the native launcher rather than the npm one; see [DISTRIBUTION.md](docs/DISTRIBUTION.md).

### Alternative: stdio, one process per session

Use stdio when you do not want a resident service. Each session then starts and stops its own server.

```sh
claude mcp add codeoutline --scope user -- codeoutline serve --stdio
```

On Windows, Claude Code cannot start the `codeoutline.cmd` shim directly; use `-- cmd /c codeoutline serve --stdio`. For Cursor, set `"command": "codeoutline", "args": ["serve", "--stdio"]`.

When no project is specified, the service uses, in order: the `projectPath` argument of the call, the `--project` option, the client's roots (the first directory returned by `roots/list`), and the directory the service was started in. Clients usually start a stdio service in the project directory, so a global configuration needs no project path. Access defaults to `--project` or the start directory; repeat `--allow-root` to allow more.

Three tools are provided:

| Tool | Purpose |
| --- | --- |
| `codeoutline_explore` | Query source, call paths, and callers/callees by symbol or file name (`query`; optional `projectPath`, `budget`) |
| `codeoutline_status` | Refresh and report index, cache, scanner, and parser statistics |
| `codeoutline_rebuild` | Rebuild fully, bypassing the cache |

Without Node, download the native archive for your platform from [GitHub Releases](https://github.com/1dao/codeoutline/releases), extract it, and run `codeoutline` (`codeoutline.cmd` on Windows).

## System requirements

| Platform | Requirements |
| --- | --- |
| Windows | x64, Windows 10 / Server 2016 or newer (Windows 8 for the native archive); Windows 11 on ARM64 runs it under x64 emulation. No Visual C++ redistributable needed |
| Linux | x64, glibc 2.28 or newer: RHEL / Rocky / Alma 8 and 9, CentOS Stream 9, Debian 10+, Ubuntu 20.04+. Alpine/musl is not supported |
| macOS | macOS 11 or newer; one universal binary for Apple Silicon and Intel |

On Linux, decoding GBK sources needs the GBK module of the system iconv. Minimal EL8/EL9 installs and container images lack it: `dnf install glibc-gconv-extra`. UTF-8 projects work without it, and `codeoutline doctor` reports when it is missing.

## Supported languages

C, C++, C#, Go, Java, JavaScript / TypeScript (including JSX/TSX), Lua, Python, and Rust.

## Command line

```sh
codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
codeoutline serve --http [--host HOST] [--port PORT] [--project PATH] [--allow-root PATH ...]
codeoutline explore --project PATH --query QUERY [--budget BYTES]
codeoutline status [--project PATH]
codeoutline rebuild [--project PATH]
codeoutline doctor [--project PATH]
```

`status`, `rebuild`, and `doctor` print JSON; a failed diagnostic exits nonzero. One-shot commands default to the current directory as the project.

The runtime logs only warnings and errors, to stderr, and writes no log files, so starting it in a project leaves nothing behind. For troubleshooting, set `CODEOUTLINE_LOG_LEVEL` (`DEBUG`, `INFO`, `WARN`, `ERROR`, ...) and `CODEOUTLINE_LOG_DIR` to write log files to that directory.

## MCP service details

The protocol baseline is [MCP 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). Query budgets range from 256 to 262144 bytes (default 16000); truncated output stays valid UTF-8 and ends with a truncation notice. Paths always refer to the machine running the service.

In stdio mode, stdout carries only MCP messages and logs go to stderr. HTTP listens on the local machine by default; clients connect to `http://127.0.0.1:19876/mcp`. Remote listening requires a `CODEOUTLINE_TOKEN` of at least 16 bytes and hosts allowed explicitly with `--allow-host`; clients send `Authorization: Bearer ...`. Unlike local HTTP, a remote service without `--allow-root` is limited to `--project` or its start directory. Repeat `--allow-origin` to allow full browser origins; unlisted origins are rejected. Protect the token with a TLS reverse proxy for remote deployments.

The main thread handles the protocol while a resident index thread serves queries one at a time. Requests with a progress token receive progress every second (over SSE for HTTP); there is no standalone GET/SSE endpoint (it returns 405). Limits: 64 sessions, 64 queued or running jobs, a 120-second job deadline, and sessions expire after 15 idle minutes. Cancellation takes effect at per-file checkpoints, so a single file's parse cannot be interrupted (files are capped at 1.5 MB); after a cancellation the possibly incomplete in-memory index is discarded and the next query recovers from the cache.

## Indexing behavior and limits

The cache lives at `.codeoutline/cache/<SHA-256 of path>.idx` in the user's home directory. It is integrity-checked and rebuilt automatically if corrupt; every write goes to a separate temporary file that atomically replaces the old one, which survives a failed write. Up to 8 projects stay resident by default, and idle ones are evicted after 15 minutes. Directory aliases and links resolve to real absolute paths; on Windows, ASCII case is ignored.

Source encodings are confirmed on demand: the first index pass does not check each file, only the files a query touches. UTF-8 (with or without BOM) is tried first, then strict GBK conversion; a GBK file is reparsed and the call graph rebuilt before the query runs, without modifying the file. Encoding results are cached and invalidated when a file changes, and a matched file that cannot be decoded is reported as an error. When both encodings are valid, UTF-8 wins. GBK files that no query has touched yet may still be misparsed, so Chinese identifiers can be missed; querying the file name triggers its repair.

Files are listed with ripgrep (`rg`) when available, honoring every `.gitignore`. Without `rg`, a directory walk supports only the common rules of the root `.gitignore` (no negation, no nested ignore files) and skips hidden directories, `node_modules`, `__pycache__`, and symbolic links. Project root paths must not contain `"`, `%`, `!`, `$`, backticks, backslashes, or line breaks.

## Building from source

The runtime comes from the [xnet2lua](https://github.com/1dao/xnet2lua) submodule:

```sh
git submodule update --init --recursive
```

The build scripts compile the LuaJIT runtime (with xproc, MPSCQ, and HTTPS) and copy it to `bin/` at the repository root. On Windows, run from an MSVC developer terminal; the result links the C runtime statically. On macOS, the result is a universal binary for macOS 11 or newer.

```powershell
.\tools\build-runtime.ps1
```

```sh
sh tools/build-runtime.sh
```

When running from source, pass `LOG_STDERR=1` explicitly; the installed `codeoutline` adds it for you:

```powershell
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 serve --stdio --project C:/src/project
```

Tests:

```powershell
.\bin\xnet.exe tests/lua/codeoutline_spec.lua
.\bin\xnet.exe tests/lua/stability_spec.lua
npm ci
npm test
npm run test:package
```

`npm test` checks both transports with the official MCP SDK; `npm run test:package` builds real packages and verifies an installation outside the checkout. Set `XSCAN_PURE_LUA=1` to exercise the pure-Lua scanner. Packaging and publishing are described in [DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Embedding

```lua
package.path = 'scripts/?.lua;' .. package.path
local service = require('codeoutline.service')
local text, info = service.explore('C:/src/project', 'Session.save', { budget = 16000 })
```

`get`, `explore`, and `status` refresh automatically; `forget` clears only the in-memory index, and `rebuild` reindexes without the disk cache. `service.configure` adjusts the resident project count and idle timeout. When embedding on Android, the host must call `xutils_android_init(JavaVM*)` once before starting worker threads; otherwise GBK conversion reports an error.

## Origin and license

The code was extracted from Codua and uses the `codeoutline.*` namespace. CodeOutline is licensed under [BSD-2-Clause](LICENSE); third-party notices are in [THIRD_PARTY.md](docs/THIRD_PARTY.md).
