# LSP Development Preview

The `xlsp` branch provides an independent Lua stdio language server. This is an
intermediate implementation, not the shared MCP/LSP backend or a published editor
extension. Released CodeOutline 0.1.9 does not contain this command.

LSP now uses `main.lua` and the same INDEX worker submission/cancellation path
as MCP. The stdio command is available again. A process still selects either
MCP or LSP transport; simultaneous HTTP MCP and TCP LSP is a later batch.

## Launch

Rebuild the bundled runtime first. Windows needs `xutils.stdout_binary()` to keep
the CRLF separators in LSP frames intact; an older runtime is rejected explicitly.

```powershell
.\tools\build-runtime.ps1
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 LOG_FILE=0 lsp --stdio
```

On Linux/macOS, build with `sh tools/build-runtime.sh` and launch `bin/xnet` with
the same script and arguments. These platforms have not yet been runtime-tested
for the LSP preview. Configure an LSP client to start this process with piped
stdin/stdout; this is not an interactive console command.

Workspace folders come from `initialize`. `--project PATH` is an optional
fallback when the client supplies no workspace root. Resource lookup does not
depend on the editor's working directory. Runtime logs must go to stderr.

## Implemented

- LSP 3.17-style initialization, shutdown/exit, request cancellation and bounded
  Content-Length framing. Only implemented capabilities are advertised.
- `textDocument/documentSymbol`, hierarchical when supported, otherwise flat.
- `workspace/symbol`: case-insensitive substring matching, up to 200 results.
- Full-document open/change/close synchronization, monotonically increasing
  versions, session-local drafts and unsaved new files. Untitled documents support
  document symbols through `languageId`.
- Nine parser modules expose zero-based, half-open declaration/name byte ranges.
  Symbol positions use UTF-16, with UTF-8, CRLF, BOM and non-BMP handling. The cache
  schema version has changed, so earlier caches rebuild automatically.
- Multi-root workspaces collapse nested roots within a session and deduplicate
  project results. Open files hide all disk symbols for that file.
- Initial indexing reports work-done progress when supported. Document symbols
  remain synchronous on the main thread. If any workspace root is not ready,
  workspace queries immediately return only matching draft symbols without
  submitting a worker job. Once all roots are ready, queries combine disk matches
  from the worker with the request's draft symbols. Navigation
  requests during initial indexing receive RequestFailed (-32803); completion
  returns an empty incomplete list. These future capabilities are not advertised.
- The INDEX worker exclusively owns resident indexes and executes requests
  directly, without coroutine slices. LSP refreshes only index records and scans
  those records for workspace symbols; it does not build or retain a call graph.
  Existing graph consumers build lazily when needed, and an index-only refresh
  discards a stale graph after file changes. Safe batching with short-job
  interleaving is deferred until per-file commits are implemented.
- Cancellation responds immediately with -32800 and discards late results.
  Shutdown cancels session jobs; exit closes the stdio process with the appropriate
  exit code. Session close is separate from process stop for future transports.
- A one-second background poll drains native watcher events. Without a watcher,
  full refreshes are throttled to 45 seconds. Save and watched-file hints refresh
  named indexed files without enumerating the root; native watching admits new
  files and enforces ignore rules. Clients need not register a watcher.
- Installed updates do not terminate an active LSP connection, including the
  shutdown-to-exit interval. MCP-only processes retain their idle-exit policy.

## Limits And Pending Work

The independent server accepts 16 workspace folders, 128 open documents, 32 MiB
of draft text, 1.5 MB per document, 64 pending symbol requests and 4 MiB per incoming
wire message. Native parsing, enumeration, decoding and cache compression are bounded
operations but cannot be interrupted in the middle of a native call. Worker
requests are serialized, so a request can still wait behind a running refresh
after initial indexing. Per-file commits and fair batching remain pending.

Workspace symbols re-read matching disk files to produce correctly decoded
positions. Initial indexing is still encoding-lazy, so GBK identifiers may not
match until that file has been decoded. This preview does not add a complete
semantic resolver, rename, references, diagnostics, completion or incremental text
edits. Hover, definition and call hierarchy are not advertised yet.

The existing graph implementation for MCP and record-replacement transactions remain until
query-time relationship resolution is integrated and validated. No persistent
symbol table is copied to the main thread. TCP LSP, stdio bridging, a single
multi-protocol daemon, binary discovery and VS Code/Cursor/Zed extensions remain
subsequent batches. Do not configure the MCP HTTP endpoint as an LSP URL.

## Verification

```powershell
.\bin\xnet.exe tests/lua/lsp_spec.lua
npm test
```

The Node suite runs the Lua regressions with both native and pure-Lua scanners and
exercises the real stdio wire, progress responses, draft isolation, external
refresh and local queries during background indexing. These tests do not replace
real editor or cross-platform acceptance. Package staging requires committed native
runtime changes; no release or extension publication is performed by these tests.
