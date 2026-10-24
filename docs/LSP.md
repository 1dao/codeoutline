# LSP Server

`codeoutline lsp --stdio` is a Lua language server on stdin and stdout. Releases
include it from 0.2.0; the README's
[Editor integration](../README.md#editor-integration-lsp) section covers
installation and how each platform's editors start it.

Clients are available for [VS Code/Cursor](../adapters/vscode/README.md)
and [Zed](../adapters/zed/README.md). The VS Code/Cursor client uses one common
VSIX and supports capability selection, server configuration, restart and logs.

The server shares `main.lua` and the INDEX worker's submission and cancellation
path with MCP. A process serves either MCP or LSP: the language server does not
join the shared MCP HTTP service, and there is no TCP transport.

Concurrent position-navigation requests over the same identifier share in-flight
work. Each request receives its own response and may be cancelled independently;
the worker is cancelled only after the last waiter leaves. Document and workspace
notifications invalidate sharing, and completed results are never reused. Signature
help and completion retain their cursor-sensitive request behavior.

Exact target positions reuse the existing bounded full-parse cache, with disk
size/checksum validation before every reuse. Unsaved documents keep their own
versioned parses. This does not add fields to the persistent index.

Navigation also reuses per-file ordinary binding evidence across requests in a
shared FIFO capped at 16 files and about 8 MiB. Overlay wrappers share evidence
only when their parsed node identity and validated source match. Every query
checks source before reuse, and file/configuration-dependent resolution remains
query-local. Cursor lookups reuse the full-parse token cache, so background
definition requests for parameters in large headers do not reparse that header
at every position. Neither tokens nor detailed binding evidence are serialized.

Opening a document schedules best-effort navigation warming after 150 ms of idle
time; edits settle for 500 ms. Only the latest requested file is queued, and
foreground worker requests cancel active warming before capturing their drafts.
Closed documents, auxiliary-only sessions and sources above 1 MiB are skipped.
Warming reuses the normal caches for the current file and up to three direct
dependencies (at most 2 MiB of explicitly warmed source). Dependency work stops
after a 500 ms soft budget; cold symbol-table preparation may take longer and
the complete idle job has a 5-second cooperative deadline. No definition results
are cached or added to the persistent index.

The VS Code/Cursor adapter reports active/visible editor changes through the
`codeoutline/visibleDocument` notification with `{ textDocument: { uri, version } }`.
The document must already be open and its version must still match. LSP itself
has no standard active-tab notification. Zed extension API 0.7.0 has no equivalent
editor callback, so Zed uses `didOpen` and document-symbol requests as warming
opportunities; switching an already-open tab alone is not guaranteed to notify
the server. Rapid and repeated hints are coalesced. Warming is opportunistic:
an immediate foreground request still works through ordinary on-demand lookup.

## Launch

From an installation, the editor runs `codeoutline lsp --stdio`. On Windows, npm
installs `codeoutline.cmd`, a batch file. Zed starts it from PATH through
cmd.exe. The VS Code/Cursor client, whose Node-based spawn rejects batch files,
finds the npm installation and runs its launcher with Node itself. Clients that
cannot start a batch file run `node` with the npm launcher
(`<npm root -g>/codeoutline/launcher/codeoutline.cjs lsp --stdio`) or the native
archive's `bin/xnet.exe` with its `scripts/codeoutline/command.lua`, as below.

From a source checkout, rebuild the bundled runtime first. Windows needs
`xutils.stdout_binary()` to keep the CRLF separators in LSP frames intact; an
older runtime is rejected explicitly.

```powershell
.\tools\build-runtime.ps1
.\bin\xnet.exe scripts/codeoutline/command.lua LOG_STDERR=1 LOG_FILE=0 lsp --stdio
```

On Linux/macOS, build with `sh tools/build-runtime.sh` and launch `bin/xnet` with
the same script and arguments. Linux CI runs the VS Code client against this
server; macOS has not been runtime-tested yet. Configure an LSP client to start
this process with piped stdin/stdout; this is not an interactive console command.

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
- Ten parser modules expose zero-based, half-open declaration/name byte ranges.
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
  returns an empty incomplete list.
- LSP queries run in individual main-thread Lua coroutines. Queries that need
  INDEX results wait through `xthread.rpc`; stdin framing, document notifications,
  cancellation and lifecycle messages stay on the main loop. Each query captures
  its draft versions before yielding. Cancelled requests suppress late replies;
  worker waits have a 120-second deadline and share the 64-job transport limit.
  MCP explore/callers and background refresh retain their callback/post transport.
- The INDEX worker exclusively owns resident indexes and executes requests
  serially. A task may yield while waiting for parser threads, but subsequent
  tasks stay queued until it finishes. LSP refreshes only index records and scans
  those records for workspace symbols; it does not build symbol tables. Once a
  consumer has built them, every refresh keeps them current file by file.
- Navigation (see below): `textDocument/definition`, `textDocument/hover`,
  `textDocument/signatureHelp`, `textDocument/references` and call hierarchy
  (`prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`).
- Completion (see below), triggered by typing or by `.`, `:` and `>`.
- `initializationOptions.features` can disable `documentSymbol`, `workspaceSymbol`,
  `definition`, `hover`, `signatureHelp`, `references`, `callHierarchy` or
  `completion`, e.g. to run beside another language server; disabled features are
  neither advertised nor answered.
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
name-based resolver as explore, not a type checker, and completion infers types
from declarations only. Rename, diagnostics and incremental text edits are not
implemented.

No symbol table is copied to the main thread. TCP LSP, a single daemon serving
both protocols, and automatic runtime downloads by the editor clients are not
implemented. The VS Code/Cursor and Zed clients are built from this repository
and are not yet published to an extension marketplace. Do not configure the MCP
HTTP endpoint as an LSP URL.

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
- On an import line (`require`/`dofile` strings or names, `#include`, JS/TS module
  strings, Python/Go/Java/Kotlin/Rust imports), definition goes to the loaded file,
  resolved by the same dependency rules as explore. C/C++ headers not in the
  project are searched in project `includePathRules`/`includePaths` and
  `initializationOptions.includePaths`, then INCLUDE/CPATH
  variables, then the compiler's list (`cc -E -v`) or, on Windows, the newest
  Windows Kits and the MSVC found by vswhere (probed once). Symbols inside system
  headers are not indexed. Relative `#include "../x.h"` resolves against the
  including file. When definitions are too far apart to choose between, a visible
  prototype is the target.
  Project include configuration also controls indexed C/C++ type/member lookup,
  implementations and completion. Quoted local headers win; configured directories
  are ordered and stop at the first existing header. Explicit paths suppress
  whole-project suffix guesses, even when the selected header is outside the index.
  See the README for directory rules, limits and a multi-project example.
- C/C++ macro calls can navigate to possible macro definitions when build flags
  or unconfigured include paths are ambiguous, including object-like proxy macros.
  Alternative headers are evaluated independently within the existing query limits;
  configured include order still selects one header. These navigation candidates
  do not create execution edges in the call graph.
- When ordinary definition lookup has insufficient evidence, F12 can suggest
  exact-name symbols in the same language family elsewhere in the project.
  Explicit qualifications must match; known import/local/receiver barriers,
  C/C++ include policies and Go/Rust/C# package or project binding remain strict.
  Suggestions exclude call sites, unrelated private locals and source-file statics.
  If no macro declaration is visible and there is no explicit undef or uncertain
  macro state, definition lookup may suggest same-name macro definitions elsewhere
  in the project. Implementations take precedence over repeated API declarations;
  declarations remain available when no implementation is indexed.
  Lookup checks at most 256 same-name entries and selects at most eight targets;
  exact source positions are limited to four files, 2 MiB and a 500 ms soft budget.
  References, rename, hover, implementations and call hierarchy do not use this
  fallback. Multiple definition results are candidates for inspection, not proof
  of a runtime binding.
- Unknown suffixes use the editor's supported language ID, or conservative source
  detection when no supported ID is supplied. The chosen language is retained for
  binding extraction, completion and position lookup. These documents remain session
  overlays and do not change persistent indexing or global suffix associations.
  C/C++ definition navigation can also read identifier tokens in another preprocessor
  branch; this lexical fallback does not add references or execution relationships.
- Hover shows the target's signature, kind, qualified name and location.
- Signature help, triggered by `(` and `,`, finds the innermost open call before
  the cursor (commas inside nested calls, literals and brackets do not count),
  resolves its name like definition, and lists each target's signature with
  parameters split from the declaration. The active parameter follows the
  argument count; unsaved edits are included.
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

## Configurable definition rules

Create `.codeoutline.json` in the workspace root. A shared event contract under
`rules` maps an event argument to its registration for navigation, and also
connects senders to resolved handlers in explore/callers:

```json
{
  "rules": [
    {
      "kind": "event",
      "language": "lua",
      "call": "xthread.post",
      "argument": 2,
      "register": "xthread.register",
      "keyArgument": 1,
      "handlerArgument": 2
    }
  ]
}
```

With this rule, Go to Definition on `'xmysql_business_done'` in
`xthread.post(MAIN_ID, 'xmysql_business_done', ...)` finds
`xthread.register('xmysql_business_done', ...)` in the same workspace root.
The destination selects the matching string at the registration site. Multiple
registrations return multiple locations; thread routing is not inferred.
Navigation still works for anonymous or unresolved handlers: reaching a
registration does not establish an executable call edge. Shared `callback`
rules navigate to the resolved callback, while `target` rules navigate to the
named declarations across the project, including remote service table members
such as `Ntf.handle`. Multiple matching declarations return multiple locations;
these navigation candidates do not establish graph edges. Shared contracts reuse the bounded, query-time alias
resolution described in [Indirect calls](INDIRECT-CALLS.md#configured-api-contracts).
Lua, JS/TS, Python and C/C++ aliases have the same supported forms as graph
queries; other languages retain direct contract matching. Shared API matching
is exact and does not use the legacy method-segment shortcut below. Lua `target`/`event`
navigation also honors the explicitly written API when its receiver cannot be
inferred (for example, a conditionally assigned `dservice`). This yields
declaration candidates without creating graph edges. Its optional `qualifiers`
array filters those navigation candidates by owner, as with declaration rules.
Lua strings, including quoted escapes and long strings, are compared by value;
commas inside preceding anonymous functions do not change argument numbering.
When shared and legacy rules both match, their navigation results are combined
and deduplicated. Use `kind: "definition"` to preserve the legacy method-name
shortcut while keeping that rule out of graph inference.

Lua `target` navigation can narrow RPC declarations to a known service file.
For example, `local redis = skynet.uniqueservice("redisSrv")` followed by
`dservice.call(redis, "init")` searches `init` declarations in indexed
`redisSrv.lua` files. `skynet.newservice` and bounded local aliases also work;
handles declared earlier and assigned once before use are supported too:
`local target; target = skynet.uniqueservice("redisSrv")`. The assignment and
use must be in the same block; conditional initialization outside that block,
multiple writes and assignments in other functions do not establish the source.
Shadowed bindings are not used to narrow candidates. Skynet module
aliases are resolved before recognizing the factory. Matching uses exact relative
path suffixes; duplicate service filenames remain multiple candidates. A known
indexed service without the requested handler returns no unrelated declarations.
If the service cannot be inferred or no service file is indexed, ordinary
declaration candidates remain available. Dynamic forwarding to another module
is not inferred.

For `skynet.call`/`skynet.send`, the service is argument 1. Other target rules
inspect the argument preceding the command; `serviceArgument` can override this
one-based position. Literal service names are supported for explicit
`serviceArgument` and the `dservice`, `skynet` and `cluster` RPC conventions.
This narrowing is query-time navigation only; it adds no index fields or graph
edges. Existing `definitionRules` and `kind: "definition"` retain their original
declaration lookup behavior.

For Lua navigation-only rules, `"kind": "definition"` with
`"targetKind": "declaration"` maps the literal to a function or method
declaration whose name equals the literal, resolved through the symbol tables:

```json
{
  "rules": [
    {
      "kind": "definition",
      "language": "lua",
      "call": "dservice.send",
      "argument": 2,
      "targetKind": "declaration",
      "qualifiers": ["CMD", "Ntf"]
    }
  ]
}
```

With this rule, Go to Definition on `"raw_execute_n"` in
`dservice.send(pool, "raw_execute_n", sql)` finds `function Ntf.raw_execute_n`
in the same workspace root. `qualifiers` is optional and restricts matches to
declarations whose owner table (`T` in `function T.name` or `function T:name`)
is listed; without it any same-named function or method matches. Declaration
rules must not set `target` or `targetArgument`.

`"targetKind": "key"` maps the literal to a string table key being written:
`t["name"] = ...` assignments and `{ ["name"] = ... }` constructor fields.
For key rules `qualifiers` restricts assignments to the named table (`t` in
`t["name"] = ...`). Only plain table identifiers bind qualifiers;
`other.t["name"]` does not bind the qualifier `t`. Constructor keys have no owner and only match when
`qualifiers` is absent.

For `kind: "definition"` and legacy `definitionRules`, argument numbers start
at 1 and count explicit arguments in the source, including
for colon calls. Function names must match the written name exactly, except
that a rule naming only the method segment also binds colon calls
(`self:callCluster` matches the rule `callCluster`). Calls must
use parentheses, and matching arguments must be single string literals; quoted
escapes and Lua long strings are compared by value. Variables, computed strings
and function aliases are not resolved. Nested calls and anonymous functions in
other arguments do not change argument numbering.

Configuration is read on each definition request, so edits take effect without
restarting the server. Searches include unsaved documents and unsaved new files.
Each root has its own configuration, limited to 64 KiB and 32 rules per array
and combined consumer list; argument
numbers are limited to 1 through 32. Invalid configuration fails the definition
request with a validation message. Searches stop after 1,000 locations or 3 s
and report truncation through `window/showMessage`. Definition-only rules never
generate graph edges. Legacy `definitionRules` and `dispatchRules` keep their
original scope; shared `rules` are processed first and duplicate contracts are
removed. Configuration edits affect both consumers on the next request without
an index rebuild. Existing callers need not change their configuration.

## Completion

Kotlin files (`.kt`, `.kts`) and untitled documents with `languageId: kotlin`
use the shared symbol, navigation, signature and completion handlers. Kotlin
completion handles declared parameter/property/return types and `val`/`var`
constructor initializers. The VS Code/Cursor and Zed clients include Kotlin in
their language lists; the editor must also recognize Kotlin as a language.
This is heuristic source indexing, not Kotlin compiler analysis: implicit
lambda receivers, generated data-class members, Java interop, string-template
expressions and coroutine/framework dispatch are not resolved.

Completion also runs in the worker over the same overlay. It does not offer
project-wide global names and leaves case-insensitive filtering to the editor.
Items keep their collection order, except that when a request exceeds the item
limit, names starting with the typed prefix come first.

- Without a member operator: locals and parameters visible at the cursor
  (nested functions that end earlier keep theirs), the file's definitions and
  imports, members of the enclosing class, and in C/C++ the top-level
  declarations of headers the file includes, directly or transitively (not of
  paired implementation files, whose private symbols are not visible).
- After `.`, `->`, `::`, `?.` or Lua `:` (methods only): the receiver chain is
  typed from `self`/`this`/`cls`, declared types of locals, parameters, fields and
  return types read from signatures, initializers (`new T`, `T(...)`, `T{...}`,
  `&T{...}`, `T::new(...)`, factory methods such as `new`/`create`), Lua `require`,
  Python/JS/Go imports and static type or namespace names. Pointers, references,
  generics and wrappers such as `Option<Box<T>>` or `unique_ptr<T>` are unwrapped.
- Members are children, members defined out of line in any file (the symbol
  tables index qualifiers in `by_owner`), attributes assigned through
  `self.`/`this.`, Lua table fields, and up to three levels of base classes. In
  dynamic languages an untyped receiver falls back to a global table's members
  or, for a local, to the fields this file assigns or its table literal declares.
- C and Rust field types come from full parses only (compact index records omit
  them); type files are reparsed on demand, cached for 64 files, and skipped above
  512 KB. Each request has a 300 ms budget and 500 items; exceeding either marks
  the list incomplete. Trigger characters outside member operators, and positions
  inside strings, return nothing.

Lua native modules also support definition, hover and member completion when
their C/C++ sources are indexed in the same workspace. Static `luaL_Reg` entries
connected by `luaL_newlib`, `luaL_setfuncs`, or `luaL_register` inside
`luaopen_NAME` map Lua export names to C implementations in that file.
Both `local m = require('NAME'); m.method()` and an unshadowed `NAME.method()`
use this mapping (the latter assumes the host exposes that module globally).
Hover, signature help and completion detail show the guest interface, while
definition still opens the C implementation. For example, `luaL_checkinteger(L, 1)`
assigned to `id` contributes `id:int`; an unnamed read uses `arg1:int`.
Literal positive argument indices, common `luaL_check*`, `luaL_opt*`, `lua_to*`
and `lua_is*` calls supply types. Optional arguments retain literal defaults,
missing slots use `unknown`, and dynamic indices add an unknown argument tail.
Upvalues, negative stack indices and other Lua states are excluded. C documents
keep the original C signature. Return values and helper-mediated argument reads
are not inferred. This is a static registration heuristic, not a Lua stack interpreter:
custom registration macros, helper-driven registration, dynamic table mutation,
and userdata instance methods are not inferred. Restart the language server
after updating its scripts; the parser checksum invalidates older disk caches.

The shared `foreign` model stores exports by guest language and module, and
stores structured guest parameters separately from host signatures. Registration,
module lookup and LSP signature formatting are shared; `foreign_lua` is the
current binding API adapter. JS (for example N-API or QuickJS) and Python
(CPython) need their own registration and argument-reading adapters and resolver
integration; those adapters are not implemented yet.

Unlike the original plan, dependencies are not pre-parsed on `didOpen`; type files
are parsed when a completion first needs them. On a 56,661-file tree, 200 sampled
member operators completed in p50 1 ms, p90 8 ms, max 84 ms. Most empty results
were Lua calls on engine-bound objects with no static declaration.

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
