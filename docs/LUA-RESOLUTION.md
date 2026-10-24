# Lua module bindings

Lua call resolution connects a statically loaded module variable to the members
of its returned table, before considering unrelated same-named functions.

```lua
-- lib.lua
local M = {}
local function write_impl() end
M.save = write_impl
function M.close() end
return M

-- client.lua
local lib = dofile('./lib.lua')
function run() lib.save() end -- resolves to write_impl in lib.lua
```

Supported forms include `local lib = require('pkg.lib')`, parenthesis-free
`require 'pkg.lib'`, `return M` after a table initializer, and
`return { save = function() end, close = named_function }`. Both dot and colon
calls use the returned member map. Plain quoted literal paths and Lua long-string
literals are accepted; escaped quoted strings are currently not decoded.

A returned object can also come from a cache or factory. Unconditional members
attached after its last possible replacement are known exports, for example:

```lua
local M = rawget(_G, 'router')
if type(M) ~= 'table' then M = {} end
function M.set_log_prefix(prefix) end
return M
```

Conditional member definitions are not definite exports. Replacing the object
discards older members; later conditional member writes invalidate that member.

One member can be extracted directly from a static loader result:

```lua
local to_bool = dofile('misc.lua').to_bool
local convert = require('misc').to_bool
to_bool(true)
convert(false)
```

Both the selected member and subsequent calls resolve to the exported function,
including renamed local bindings. Selecting the value records a reference, not
an execution edge. Parameter/local shadowing and reassignment block stale aliases.
Further selectors, member calls in the initializer, operators and dynamic paths
are not treated as the extracted function itself.

`dofile` paths are normalized for `./` and `../` and interpreted relative to the
project root by default, not relative to the caller's source file. Configure the
program's working directory in project-root `.codeoutline.json` when needed:

```json
{ "luaRuntimeDirectory": "scripts" }
```

The directory must be project-relative and stay within the project. Configuration
is reread for each query/request. Absolute paths and files outside the indexed
project are not resolved. If the exact runtime-relative path is absent, quoted loader
paths also match indexed Lua files by their complete path suffix, allowing a
workspace opened above the runtime directory. Exact matches take precedence;
multiple suffix matches remain candidates rather than choosing arbitrarily. `require` retains the index's suffix lookup for
`pkg/lib.lua` and `pkg/lib/init.lua`, including source-root prefixes. Multiple
matching module files remain candidates; runtime `package.path` ordering,
`package.preload`, custom searchers and C modules are not simulated.

`loadfile` still contributes a file dependency, but its result is a chunk
function, not a module table: `local chunk = loadfile('lib.lua'); chunk.save()`
does not resolve to `lib.save`. Tracking a later `chunk()` execution and its
return value is outside this batch.

Known dynamic paths, missing exports, parameter/local shadowing and simple
reassignment suppress unrelated name guesses. Conditional or multiple top-level
returns are not treated as a definite module contract. Resolution does not
evaluate source, follow arbitrary Lua metatables, infer dynamic exports, propagate arbitrary
variable aliases, or model control flow and mutations across function calls.
Multiple assignment/destructuring-style bindings and deeper module expressions
are outside the supported binding forms. Missing edges do not prove that code
cannot run.

Bindings participate in explore, reverse callers and LSP call-site navigation.
Metadata survives disk cache reload, source updates replace old bindings, and
LSP resolution uses unsaved module overlays. Tests exercise the server API;
they do not verify a running editor's UI.

## Global export tables

A project can publish a local function under a global alias:

```lua
local function get_design_list(player) end
g_exports.phantom_system_get_phantom_design_list = get_design_list
```

Configure the table names in the workspace root's `.codeoutline.json`:

```json
{ "luaGlobalExportTables": ["__global_exports", "custom_exports"] }
```

`g_exports` is always built in and needs no configuration. The list adds other
export tables; `[]` or an omitted setting keeps only `g_exports`. Repeating
`g_exports` or another name does not duplicate it. Entries must be simple Lua identifiers.
Every configured table uses the same publication and navigation rules; the table
name does not select a different implementation. For example,
`local aaa = function() end; __global_exports.aaa = aaa` supports the same direct
jump from `aaa()` or the export's dotted key as the equivalent `g_exports` form.
Dot keys and literal string keys (such as `g_exports['get_list'] = impl`) are
supported for assignments of a named function. Locally defined export tables
are excluded, and function-call results are not treated as function aliases.

Same-name publication is supported too: `local aaa = function() end;
g_exports.aaa = aaa` and `local function aaa() end; g_exports.aaa = aaa`
retain explicit export evidence without adding duplicate name-index entries.
Bare calls prefer a known published function over unrelated private functions
with that spelling; same-file local definitions still take precedence. Direct
definitions such as `g_exports.aaa = function() end` use the same export evidence.

Aliases use the existing name index for definitions, references and callers.
Configuration is reread on the next query/request, including unsaved documents.
Changing the list rebuilds symbol tables from cached records without reparsing
unchanged source files. It does not execute the export table's runtime behavior.

Native Lua C bindings expose registered metatable methods to completion and
navigation. Both use the same lexical receiver bindings and constructor chains,
including module aliases and local/parameter shadowing. Return types are inferred
only from recognized userdata constructor tails and file-local helpers. Discarded
objects, conflicting normal returns and uncertain stack mutations yield unknown
types; this is not general C control-flow or Lua stack analysis.

Native export maps, guest signatures and constructor return types are query-only.
The index stores ordinary C symbols, which identify `luaopen_*` candidate files;
only a requested native module is reparsed for its binding contract. The results
use bounded in-memory caches, shared with full-file query parsing, and are never
attached to persistent index records. Record replacement and document versions
invalidate the cached contracts. Loading an index from disk reconstructs these
contracts on demand from source rather than restoring them from the index file.
Disk reads used for these details validate the indexed byte size and checksum
before decoding or reparsing. A changed file requires a refresh/retry; unsaved
documents use their session version instead. Read and parse failures are not
retained across queries, while successfully parsed files without exports remain
cached. Within one query, a failed native load is skipped to avoid repeated I/O.

Ordinary symbol signatures are also omitted from resident/index-file records for
files within the shared 1 MiB query-parse limit. Hover, signature help, completion
and MCP outlines restore them through the same bounded full-file cache. Larger
indexed files retain signatures so the query size limit does not remove existing
information. Complete reference columns and binding lookup metadata remain in the
index to preserve MCP caller-search candidate selection.
