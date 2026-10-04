# LSP Development Preview

The `xlsp` branch provides an independent Lua stdio language server. This is an
intermediate implementation, not the shared MCP/LSP backend or a published editor
extension. Released CodeOutline 0.1.9 does not contain this command.

> **Temporarily unavailable.** The standalone stdio server and its main-thread
> scheduler have been removed while the LSP moves onto the shared index worker
> used by MCP. `lsp --stdio` reports an error until that lands; the rest of this
> page describes the removed preview and will be rewritten with the new design.

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
- Initial indexing reports work-done progress when the client supports it.
  Queries use drafts and published snapshots, returning available or empty results
  while indexing, rather than waiting for the project index.
- Background indexing and project queries yield at explicit checkpoints. Document
  queries have priority over project queries; roots advance round-robin. Cancelled
  updates roll back record replacements; pure query cancellation retains the index.
- `didSave` schedules refresh. A five-second background pass drains native watcher
  changes or performs a full refresh when watching is unavailable. Queries do not
  initiate refresh. No automatic update/restart loop runs in the LSP process.

## Limits And Pending Work

The independent server accepts 16 workspace folders, 128 open documents, 32 MiB
of draft text, 1.5 MB per document, 64 pending symbol requests and 4 MiB per incoming
wire message. Native parsing, enumeration, decoding and cache compression are bounded
operations but cannot yield in the middle of a native call. Large files can still
produce latency spikes; the 10 ms checkpoint budget is not a hard latency bound.

Workspace symbols re-read matching disk files to produce correctly decoded
positions. Initial indexing is still encoding-lazy, so GBK identifiers may not
match until that file has been decoded. This preview does not add a complete
semantic resolver, rename, references, diagnostics, completion or incremental text
edits. Hover, definition and call hierarchy are not advertised yet.

MCP retains its existing worker and request queue. Its cancellation now preserves
consistent resident state, but MCP and LSP do not yet share a scheduler or process.
TCP LSP, the stdio bridge, shared daemon lifecycle, dynamic watched-file registration,
periodic watcher reconciliation, binary discovery and VS Code/Cursor/Zed extensions
remain subsequent batches. Do not configure the MCP HTTP endpoint as an LSP URL.

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
