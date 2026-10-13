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

`dofile` paths are normalized for `./` and `../` and interpreted relative to the
project root by default, not relative to the caller's source file. Configure the
program's working directory in project-root `.codeoutline.json` when needed:

```json
{ "luaRuntimeDirectory": "scripts" }
```

The directory must be project-relative and stay within the project. Configuration
is reread for each query/request. Absolute paths and files outside the indexed
project are not resolved. `require` retains the index's suffix lookup for
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
evaluate source, follow metatables, infer dynamic exports, propagate arbitrary
variable aliases, or model control flow and mutations across function calls.
Multiple assignment/destructuring-style bindings and chained module expressions
are outside the supported binding forms. Missing edges do not prove that code
cannot run.

Bindings participate in explore, reverse callers and LSP call-site navigation.
Metadata survives disk cache reload, source updates replace old bindings, and
LSP resolution uses unsaved module overlays. Tests exercise the server API;
they do not verify a running editor's UI.
