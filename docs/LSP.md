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
  (not advertised yet) returns an empty incomplete list.
- The INDEX worker exclusively owns resident indexes and executes requests
  directly, without coroutine slices. LSP refreshes only index records and scans
  those records for workspace symbols; it does not build symbol tables. Once a
  consumer has built them, every refresh keeps them current file by file.
- Navigation (see below): `textDocument/definition`, `textDocument/hover`,
  `textDocument/references` and call hierarchy (`prepareCallHierarchy`,
  `incomingCalls`, `outgoingCalls`).
- `initializationOptions.features` can disable `documentSymbol`, `workspaceSymbol`,
  `definition`, `hover`, `references` or `callHierarchy`, e.g. to run beside another
  language server; disabled features are neither advertised nor answered.
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
of draft text, 1.5 MB per document, 64 pending requests and 4 MiB per incoming
wire message. Native parsing, enumeration, decoding and cache compression are bounded
operations but cannot be interrupted in the middle of a native call. Worker
requests are serialized, so a request can still wait behind a running refresh
after initial indexing. Index updates now commit per file; batching refreshes so
short requests run between them remains pending.

Workspace symbols re-read matching disk files to produce correctly decoded
positions. Initial indexing is still encoding-lazy, so GBK identifiers may not
match until that file has been decoded. Navigation uses the same heuristic,
name-based resolver as explore, not a type checker. Rename, diagnostics,
completion and incremental text edits are not implemented.

No symbol table is copied to the main thread. TCP LSP, stdio bridging, a single
multi-protocol daemon, binary discovery and VS Code/Cursor/Zed extensions remain
subsequent batches. Do not configure the MCP HTTP endpoint as an LSP URL.

## Navigation

Navigation runs in the INDEX worker against the index's maintained symbol tables
for the document's workspace root (roots never resolve across each other).
Each request carries the session's open-document set and the text of versions
the worker has not seen yet, so drafts are sent once per version and the worker
applies them even when the request itself is cancelled. Per request, open
documents (and the queried file) are layered over the resident tables: an open
file hides its disk symbols, and unsaved new files resolve as targets. The
overlay never writes to the resident tables.

- The cursor is matched to a declaration name, an indexed call/reference (exact
  name ranges now come from full parses), or another identifier, which binds
  only to nearby definitions unless it names a type. Calls use the explore
  resolver: same file, then included/imported files, then the same directory,
  never across languages; ties return several targets. Recursive calls resolve
  to their enclosing function. From a C/C++ prototype, definition goes to the
  bodies.
- Hover shows the target's signature, kind, qualified name and location.
- References support functions, methods, constructors, destructors and macros;
  types, fields and variables get RequestFailed rather than incomplete results.
  A declaration and its definitions count as one target. Results come from one
  scan of reference names; hit files are reparsed for exact ranges.
- Call hierarchy items carry the root, file, node index and names, and are
  relocated by name after edits; file-scope calls appear under a file item.
- Reference scans stop after 1,000 results or 3 s, and position reparsing after
  2 s; truncation is reported with `window/showMessage`.
- Target positions come from reparsing the target file; a file edited since
  indexing is matched by name and line, or falls back to the start of the line.

## Symbol tables and query-time relationships

The index keeps no call graph. Its only persistent state is the per-file
records; symbol and path tables derive from them and change one file at a time:

- `Index:commit(rel, record)` replaces (or, with `nil`, removes) one record,
  updates the symbol tables and bumps the generation as one unit. It contains no
  cancellation checkpoint, so an interrupted refresh leaves each file either old
  or new and needs no rollback: the next refresh simply runs a full pass. A failed
  table update drops the tables, and the next use rebuilds them from the records.
  Refresh, removal and GBK repair all commit through it.
- `Index:symbols()` builds the tables on first use. Hosts that never resolve
  names (an LSP session that only lists symbols) never pay for them.
- Name lists stay in path, then node order, maintained by binary insertion and
  removal, so results match a fresh build regardless of edit history. File and
  node ids are not reused; iterate `file_order` and compare with `graph.before`.
- Calls, callers and call paths are resolved per query (`graph.query`). Outgoing
  edges are computed only for visited nodes, with a 20,000-node expansion limit
  reported in output and `info.relationships_incomplete`; callers of all seeds
  share one scan of reference names.

The record-replacement transactions, copy-on-write records and the eager graph
are gone. Before removing the eager graph, explore output on the xnet2lua tree
(92 queries) was recorded with it and matched exactly afterwards.

Measure a local project (no project files or index cache are written):

```powershell
.\bin\xnet.exe tools/benchmark-relationships.lua ROOT=C:/src/project QUERIES=90 UPDATES=300
```

It reports the table build, per-file commit timings with a parity check against
a fresh build, and explore timings. On one Windows machine, a 56,661-file tree
(799,334 symbols) built its tables in 1.4 s and 229 MB of Lua heap; 500 sampled
commits took p50 0 ms, p99 1 ms and at most 15 ms (a 3,658-symbol file); 90
explore queries took p50 51 ms, p90 65 ms, max 99 ms while other tests ran. These
are Lua-accounted measurements, not process RSS or editor latency guarantees.

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
