# CodeOutline

English | [简体中文](README.zh-CN.md)

Lightweight code indexing and exploration for coding agents, as an MCP server, and for editors, as a language server. Powered by Lua.

CodeOutline answers symbol queries with line-numbered source, call paths, and callers/callees, refreshes incrementally, and caches the index on disk. Editors get symbols, definitions, references, call hierarchy, and completion from the same index through LSP. The MCP protocol with both transports (stdio and Streamable HTTP) and the language server are implemented in Lua, so neither depends on Node; in the npm package, Node only locates and starts the runtime for your platform.

## Installation and setup

Requires Node.js 20 or newer. npm downloads the runtime for your platform automatically; no compiler or Lua installation is needed. Install it globally rather than configuring clients with `npx -y`: npx keeps a full npm process running beside every server it starts.

```sh
npm install -g codeoutline
codeoutline --version
```

### Recommended: one shared HTTP service

A stdio server is a child process of its client, so every agent session (each Claude Code session, each Cursor window) starts its own copy and builds its own in-memory index. One HTTP service serves all sessions from a single process and a single index.

A global npm installation starts that service in the background and registers it to start at login: a `Run` registry value on Windows, a LaunchAgent on macOS, and a systemd user unit on Linux; without a systemd user manager (WSL, containers), start `codeoutline daemon` at login yourself. The service installs updates and restarts itself into them, so after installation the only setup is registering its URL once.

**Claude Code** (added globally, available in every project):

```sh
claude mcp add --transport http codeoutline --scope user http://127.0.0.1:19876/mcp
```

**Cursor** (`~/.cursor/mcp.json`):

```json
{ "mcpServers": { "codeoutline": { "url": "http://127.0.0.1:19876/mcp" } } }
```

`codeoutline install` does the same for a native installation, or after installing with `--ignore-scripts`; `--port` selects a port other than 19876. Set `CODEOUTLINE_AUTOSTART=0` when installing to skip the login entry. `codeoutline uninstall` stops the service and removes the entry; run it before `npm uninstall -g codeoutline`, which does not run package scripts. The service logs to `~/.codeoutline/logs`.

The service listens on `127.0.0.1:19876` and serves projects anywhere on the machine, so switching between projects on different drives needs no configuration. Only local processes can reach it, and they already have your file access. A shared service has no project of its own: it uses the client's roots when the client provides them, and otherwise the agent passes `projectPath`, which the tools ask for when it is missing.

To run an HTTP service yourself instead, for example restricted to some directories, start `codeoutline serve --http` and repeat `--allow-root` for each directory tree to allow; a tree that is unavailable at startup, such as an unmounted drive, is reported and becomes usable once it appears. Such a service installs updates but keeps running the old version until restarted; on Windows, supervise the native launcher rather than the npm one; see [DISTRIBUTION.md](docs/DISTRIBUTION.md).

### Alternative: stdio, one process per session

Use stdio when you do not want a resident service. Each session then starts and stops its own server.

```sh
claude mcp add codeoutline --scope user -- codeoutline serve --stdio
```

On Windows, Claude Code cannot start the `codeoutline.cmd` shim directly; use `-- cmd /c codeoutline serve --stdio`. For Cursor, set `"command": "codeoutline", "args": ["serve", "--stdio"]`. A client that starts `codeoutline` with no arguments, as 0.1.7 recommended, gets the same stdio server.

When no project is specified, the service uses, in order: the `projectPath` argument of the call, the `--project` option, the client's roots (the first directory returned by `roots/list`), and the directory the service was started in. Clients usually start a stdio service in the project directory, so a global configuration needs no project path. Access defaults to `--project` or the start directory; repeat `--allow-root` to allow more.

Three tools are provided:

| Tool | Purpose |
| --- | --- |
| `codeoutline_explore` | Query source, call paths, and callers/callees by symbol or file name (`query`; optional `projectPath`, `budget`) |
| `codeoutline_callers` | [Find recursive callers and affected files](docs/CALLERS.md) for an exact symbol/qualified name (`query`; optional `projectPath`, `depth` default 3, `max_nodes` default 200, `budget`) |
| `codeoutline_status` | Refresh and report index, cache, scanner, and parser statistics |
| `codeoutline_rebuild` | Rebuild fully, bypassing the cache |

Without Node, download the native archive for your platform from [GitHub Releases](https://github.com/1dao/codeoutline/releases), extract it, and run `codeoutline` (`codeoutline.cmd` on Windows).

## Editor integration (LSP)

`codeoutline lsp --stdio` is a language server over the same indexer. Each editor window starts its own server process with its own index; it does not connect to the shared MCP service, and the MCP URL is not an LSP endpoint.

| Feature | Scope |
| --- | --- |
| Document and workspace symbols | Workspace symbols match substrings, case-insensitively |
| Definition, hover, signature help | Definition also goes from import lines (`require`, `#include`, module imports) to the files they load |
| References, call hierarchy | Functions, methods, constructors, and macros; incoming and outgoing calls |
| Method implementations | C#, Java, Kotlin and TypeScript interface/abstract methods and C++ virtual overrides; `textDocument/implementation` |
| Completion | Locals, the file's definitions and imports, declarations from included C/C++ headers, and members after `.`, `->`, `::`, `?.`, or Lua `:` |

Resolution is name-based, the same as `codeoutline_explore`; it is not a type checker. Rename, diagnostics, and formatting are not provided, so CodeOutline works best beside a language's own server or where none is available. Unsaved edits are included in every request. A `.codeoutline.json` file in the workspace root can map Lua call arguments to registration sites for Go to Definition. Behavior, limits, and options are described in [LSP.md](docs/LSP.md).

Thin clients are in this repository: one VSIX for [VS Code and Cursor](adapters/vscode/README.md), and a [Zed](adapters/zed/README.md) extension. They are not published to an extension marketplace yet; install them as described in their READMEs. Other editors can start the same command through their generic LSP support; only VS Code, Cursor, and Zed have been tested.

Clients start the server directly, without a shell:

- **Linux and macOS**: the npm installation puts an executable `codeoutline` on PATH, so the client defaults (`codeoutline` with `lsp --stdio`) work. An editor started from the desktop may not inherit PATH entries added by your shell profile (nvm, for example); then configure the absolute path printed by `command -v codeoutline`.
- **Windows**: npm installs `codeoutline.cmd`, a batch file. The VS Code/Cursor client finds the npm installation itself, and Zed starts `codeoutline.cmd` from PATH through cmd.exe, so neither needs settings. For clients that cannot start a batch file, configure `node` as the command, with the arguments `<global npm folder>/codeoutline/launcher/codeoutline.cjs`, `lsp`, `--stdio`; `npm root -g` prints the global folder, usually `C:\Users\<you>\AppData\Roaming\npm\node_modules`. For the native archive, run its `bin/xnet.exe` with `<archive>/scripts/codeoutline/command.lua`, `LOG_STDERR=1`, `LOG_FILE=0`, `lsp`, `--stdio`.

The server uses the newest installed version when it starts and does not install updates itself; an update installed by the background service takes effect the next time the editor starts the server. Started directly from the native archive, the server always runs that archive's version.

## System requirements

| Platform | Requirements |
| --- | --- |
| Windows | x64, Windows 10 / Server 2016 or newer (Windows 8 for the native archive); Windows 11 on ARM64 runs it under x64 emulation. No Visual C++ redistributable needed |
| Linux | x64, glibc 2.28 or newer: RHEL / Rocky / Alma 8 and 9, CentOS Stream 9, Debian 10+, Ubuntu 20.04+. Alpine/musl is not supported |
| macOS | macOS 11 or newer; one universal binary for Apple Silicon and Intel |

On Linux, decoding GBK sources needs the GBK module of the system iconv. Minimal EL8/EL9 installs and container images lack it: `dnf install glibc-gconv-extra`. UTF-8 projects work without it, and `codeoutline doctor` reports when it is missing.

## Supported languages

C, C++, C#, Go, Java, JavaScript / TypeScript (including JSX/TSX), ArkTS (`.ets`), Kotlin (`.kt` / `.kts`), Lua, Python, and Rust.

ArkTS reuses the JS/TS parser: component `struct` declarations are indexed as classes,
with decorated fields, methods, local module imports and ArkUI calls. Declarative UI
blocks remain calls rather than method declarations. This is heuristic indexing, not
ArkTS type checking; SDK `@kit.*`/`@ohos.*` resolution, resource references and generated
UI lifecycle/state behavior are not modeled. Zed requires a separate ArkTS language extension.

Kotlin includes declarations, constructor properties, extension functions, expression bodies,
package imports (including aliases), and ordinary, generic and trailing-lambda calls.
Resolution is heuristic: compiler-generated members, implicit lambda receivers, string-template
expressions, Java interop and coroutine/framework dispatch are not modeled.

C++ lookup covers named type aliases, namespace aliases, `using ns::Type`, `using ns::function`,
and bounded `using namespace` chains across included headers. Calls, navigation and completion
share this lookup; local imports respect their declaration position and block scope, and
ambiguous imported names remain unresolved. Import evidence is generated on demand rather
than stored in the index. This is heuristic lookup: preprocessing/include order, compiler
include-search configuration, dependent templates, ADL and full overload resolution are not modeled.

JS/TS package imports resolve local npm/Yarn workspaces (`workspaces` arrays or `packages` lists)
and pnpm `packages` lists. Package discovery reuses indexed directories; manifests and resolution
maps exist only during a query. The nearest workspace owns an import, pnpm configuration takes
precedence, and relative imports and existing tsconfig paths retain their priority. Supported globs
are `*`, `**`, `?` and `!` exclusions; pnpm accepts block string lists or JSON flow lists.
Lookup covers scoped names, subpaths, exact/wildcard exports, ordered `types`/`import`/`require`/
`node`/`default` conditions, and legacy `types`/`typings`/`module`/`main` entries. An unavailable
declared export stays unresolved rather than guessing a source directory. Duplicate package names
also stay unresolved. Configuration changes apply on the next query without reindexing sources.
Discovery is bounded to 4,096 directories, 512 packages, 1,024 configuration probes and 8 MiB of
configuration per query (1 MiB per file); exceeded limits report incomplete results. This is source
navigation, not full Node/TypeScript module resolution: dependency installation, lockfiles, package
`imports`, custom conditions, arbitrary YAML, and CommonJS export analysis are not provided.

Go imports use the nearest in-project `go.mod` and `go.work`: declared module paths,
workspace `use` lists, and relative local `replace` targets locate indexed packages.
Workspace replacements override module replacements; version-specific replacements
require an agreed direct requirement across workspace modules. Module boundaries,
duplicate names and conflicting replacements prevent speculative matches. Package calls,
navigation and completion share explicit aliases and declared package names (including
imports ending in `/v2`). Imported packages exclude test files and non-Go files;
unqualified function lookup stays within the current package. With no module metadata,
directory-suffix lookup remains available only when it finds a unique package.
Configuration is query-owned and reloaded on the next request. Limits are 1,024 config
probes, 1 MiB per config, 8 MiB total, 256 workspace modules, 512 files, 8,192 scanned
nodes and 64 matching declarations per package lookup (4,096 legacy directory candidates);
exceeded limits report incomplete results. Lookup stays inside
the indexed project and does not invoke Go or download dependencies. The full module
version graph, host `GOWORK`/`GOPATH`, vendor/module caches, build tags, dot imports,
lexical shadowing and full receiver/type inference are not modeled. Configuration accepts
standard line/block directives and JSON-compatible quoted paths; absolute local paths
and other Go string escape forms are outside this supported subset.

Rust Cargo lookup reads local path dependencies and inherited `workspace.dependencies`
on demand, including renamed packages, hyphenated crate names and custom `[lib]` names/paths.
Workspace dependency paths are relative to their defining workspace manifest; sibling packages
are not inferred as dependencies. `crate`/`self`/`super`, declared file/inline modules, grouped
`use` aliases and bounded named public re-exports share resolution across calls, navigation
and module completion. Detailed import, path and visibility evidence reuses the bounded query
source cache and is excluded from serialized indexes. External lookups require public items.
Manifest edits apply on the next request. Limits include 1,024 manifest probes, 1 MiB per
manifest, 8 MiB total, 512 dependencies per package, 8,192 nodes per module and 64 alias-source
files per caller query; exceeded limits report incomplete results. Supported TOML includes
basic/literal strings, arrays, inline dependency tables, dotted dependency properties and
dependency subtables. Lookup stays within the indexed root and never invokes Cargo. Registry/
Git downloads, dev/build/target-specific dependencies, lockfile/feature/target selection,
patch/replace overrides, glob re-exports,
`#[path]`/generated modules, custom binary targets, block-local imports and full Rust type,
privacy or macro analysis are not modeled. Without Cargo metadata, legacy Rust lookup remains.

C#, Java and Kotlin implementation relationships use declared inheritance and matching named
parameter types. Explore and callers label these edges `implementation`: they describe possible
implementations, not calls made by the method or a proven runtime receiver. Go to Implementation
uses the same lookup; Go to Definition continues to return the declaration. Detailed method
evidence is generated per query and excluded from the index. Candidate, result and hierarchy
limits report incomplete results. Generic substitution, inherited-only interface implementations,
and default-interface conflict resolution are not modeled.

TypeScript interface and explicitly abstract methods use the same bounded query path. Only
explicit `implements`/`extends` relationships between ordinary top-level named types are linked;
named/default/namespace imports, re-exports, workspace packages and tsconfig paths reuse module
resolution. Parameter and return annotations must match exactly after resolving primitive or
named types (including simple arrays); named type identity includes its declaring module.
Both signatures must have explicit annotations. Generic heritage/methods, aliases, unions,
optional/rest/default parameters, accessors, arrow fields, declaration merging, nested types,
inferred returns and structural implementations are excluded. Class overload signatures are
not treated as abstract contracts. These links do not perform TypeScript assignability checks.

C++ uses the same query path for non-template, single, non-virtual inheritance. It matches
ordinary named/builtin parameter and return types, pointer/reference and cv decoration, and
member `const`/`volatile`/reference qualifiers. Overrides can omit `virtual`/`override`; private
virtual methods participate, while `final` blocks further overrides. Namespace imports, aliases
and indirect includes use the existing bounded C++ lookup. Matching out-of-line definitions are
preferred over class declarations; an unmatched body cannot stand in for an edited declaration.
Pure virtual overrides remain contracts. Multiple/virtual inheritance, templates, covariant
returns, function-pointer/array parameters and decorated type aliases in signatures are excluded.
These links describe possible implementations, without proving virtual dispatch at a call site.
Each query retains at most 128 alias-file arrays and 1 MiB of alias evidence from the shared
source loader. Reaching either limit reports incomplete relationships and suppresses uncertain
C++ links; alias data is never persisted.

C/C++ include lookup can use ordered project search paths in `.codeoutline.json`:

```json
{
  "includePaths": ["shared/include"],
  "includePathRules": [
    { "directory": "apps/client", "paths": ["apps/client/include"] },
    { "directory": "apps/server", "paths": ["apps/server/include"] }
  ]
}
```

Quoted includes first search the including file's directory. Other searches use the longest
matching directory rule, then project `includePaths`, then LSP `initializationOptions.includePaths`,
in array order, stopping at the first existing header. Rule directories match whole path
components; `apps/client` does not match `apps/client-tools`. Paths are relative to the workspace root or absolute;
rule directories must stay inside the workspace (`.` matches the root). Each including file
selects its own rule. Configuration is reloaded per query and shared by explore, callers,
definition, implementation navigation and completion. Existing same-directory source files take
priority when pairing a header with its implementation; C++ class-outside members must belong to
the selected class, rather than another same-named class.
With configured paths, a paired source must directly include the selected header; unsupported
build/forced-include relationships remain declarations instead of guessed definitions.

An explicit `includePaths` (including `[]`), a matching directory rule, or nonempty LSP search
paths disables whole-project suffix guesses for that file. Without configuration, legacy suffix
lookup remains. External/unindexed headers can be opened from include lines but do not contribute
indexed symbols or fall through to indexed duplicates. There are at most 128 rules and 128
effective directories per file; paths are literal, without globs. These are per-file lookup rules,
not compiler build configurations, forced includes or full preprocessor/translation-unit analysis.
Only query-owned configuration and bounded path caches are added; no include maps are persisted.

## Command line

```sh
codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
codeoutline serve --http [--host HOST] [--port PORT] [--project PATH] [--allow-root PATH ...]
codeoutline lsp --stdio [--project PATH]
codeoutline explore --project PATH --query QUERY [--budget BYTES]
codeoutline status [--project PATH]
codeoutline rebuild [--project PATH]
codeoutline doctor [--project PATH]
```

`status`, `rebuild`, and `doctor` print JSON; a failed diagnostic exits nonzero. One-shot commands default to the current directory as the project. `lsp --stdio` is started by an editor and speaks LSP on stdin and stdout; it is not an interactive command. Its workspace comes from the editor, and `--project` is used only when the editor sends none.

The runtime logs only warnings and errors, to stderr, and writes no log files, so starting it in a project leaves nothing behind. For troubleshooting, set `CODEOUTLINE_LOG_LEVEL` (`DEBUG`, `INFO`, `WARN`, `ERROR`, ...) and `CODEOUTLINE_LOG_DIR` to write log files to that directory.

## MCP service details

The protocol baseline is [MCP 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports). Query budgets range from 256 to 262144 bytes (default 16000); truncated output stays valid UTF-8 and ends with a truncation notice. Paths always refer to the machine running the service.

In stdio mode, stdout carries only MCP messages and logs go to stderr. HTTP listens on the local machine by default; clients connect to `http://127.0.0.1:19876/mcp`. Remote listening requires a `CODEOUTLINE_TOKEN` of at least 16 bytes and hosts allowed explicitly with `--allow-host`; clients send `Authorization: Bearer ...`. Unlike local HTTP, a remote service without `--allow-root` is limited to `--project` or its start directory. Repeat `--allow-origin` to allow full browser origins; unlisted origins are rejected. Protect the token with a TLS reverse proxy for remote deployments.

The main thread handles the protocol while a resident index thread serves queries one at a time. Requests with a progress token receive progress every second (over SSE for HTTP); there is no standalone GET/SSE endpoint (it returns 405). Limits: 64 sessions, 64 queued or running jobs, a 120-second job deadline, and sessions expire after 15 idle minutes. Cancellation takes effect at explicit checkpoints, so a single file's native parse cannot be interrupted (files are capped at 1.5 MB). Cancelled updates roll back to the last complete in-memory index; cancelling a read-only query does not discard it.

## Indexing behavior and limits

The service starts parse workers on demand for full scans with at least 32 files that need reading, while the index thread commits their results. It uses 8 parse threads on Windows and 6 elsewhere; set `CODEOUTLINE_INDEX_THREADS` to override the count, or `0` to disable them. Workers are reused and shut down after 60 seconds idle, once all outstanding batches have returned, then recreated when needed.

The cache lives at `.codeoutline/cache/<SHA-256 of path>.idx` in the user's home directory. It is integrity-checked and rebuilt automatically if corrupt; every write goes to a separate temporary file that atomically replaces the old one, which survives a failed write. Up to 8 projects stay resident by default, and idle ones are evicted after 15 minutes. Directory aliases and links resolve to real absolute paths; on Windows, ASCII case is ignored.

Source encodings are confirmed on demand: the first index pass does not check each file, only the files a query touches. UTF-8 (with or without BOM) is tried first, then strict GBK conversion; a GBK file is reparsed and its symbols updated before the query runs, without modifying the file. Encoding results are cached and invalidated when a file changes, and a matched file that cannot be decoded is reported as an error. When both encodings are valid, UTF-8 wins. GBK files that no query has touched yet may still be misparsed, so Chinese identifiers can be missed; querying the file name triggers its repair.

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
.\bin\xnet.exe tests/lua/parse_pool_spec.lua
.\bin\xnet.exe tests/lua/lsp_spec.lua
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
