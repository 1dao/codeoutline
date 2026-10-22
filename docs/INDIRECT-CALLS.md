# Indirect calls

## Static registries and function pointers

Explore and recursive callers automatically follow these bounded static patterns:

```lua
local function save() end
local handlers = { save = save }
function run() handlers['save']() end
```

```c
struct Ops { const char *name; void (*call)(void); };
void save(void) {}
static struct Ops entries[] = { { "save", save } };
void run(struct Ops *ops) { ops->call(); }
```

Lua supports same-file lexical `local` tables with named function values,
identifier or simple quoted keys, and explicit `handlers.save = save` or
`handlers['save'] = save` registrations. Calls can use a dot or a quoted index.
Unknown/overwritten registrations, repeated slot writes, replaced tables,
computed writes, and shadowed bindings do not produce inferred edges. Dynamic
read keys are reported as unresolved; they are not expanded to every handler.
Ordinary anonymous/named table-function definitions keep their existing binding
resolution. Imported/global registries, metatables, escaped keys and
numeric indices are outside this first implementation.

Simple same-file lexical aliases are supported: `local active = handlers`
shares the registry's registrations, and `local callback = save` can supply a
named local function to a registration such as `{ go = callback }`. Both may
chain through at most eight aliases:

```lua
local function save() end
local callback = save
local handlers = { go = callback }
local active = handlers
function run() active.go() end -- potential run -> save edge
```

Initializers resolve before the new local
binding, so `local handlers = handlers` uses the enclosing binding. Writes
through registry aliases share slot invalidation; reassignment, repeated slot
writes, computed writes and parameter/local/loop-variable shadowing prevent
unproven edges. Invalidation is deliberately conservative across the file,
without control-flow or execution-order analysis. Only single-name local
initializers containing a bare identifier are propagated; tuple assignments,
call results, global/imported aliases and extracted callbacks such as
`local callback = handlers.go` are not inferred by this collector. This feature
feeds explore/callers, not LSP definition resolution.

Alias summaries remain transient. Existing compact target/member hints include
the newly recognized sites, so index contents may grow with alias coverage;
there is no new index field or persisted alias graph. The parser checksum
invalidates older caches automatically.

C/C++ supports named structs/classes with inline function-pointer fields and
explicitly typed variables/parameters. Positional or designated initializers
(including arrays of structs) and direct field assignments register named
functions, optionally prefixed with `&`. Calls through `ops->call()`,
`ops.call()`, `entries[index].call()` and `(*ops->call)()` share those candidates.
The type declaration, registration and dispatch must be in the same source file;
the registered function itself may resolve through existing cross-file lookup.
Matching uses the declared type and field, not the field name alone. Instances
of the same type share potential targets: this is not instance-sensitive or
control-flow analysis. Typedef-based pointer fields, included type definitions,
macro tables, inheritance and field-to-field propagation are not inferred.

Edges are labelled `indirect:registry` or `indirect:fn-pointer` and include a
registration location in explore's relationship evidence. They describe static
potential execution, not proof that a registration or call runs at runtime.
Recognized indirect sites suppress ordinary same-name call guesses.

Indexing collects compact target-name and dispatch-position hints only for files with
recognized dispatch sites. Files without executable declarations are skipped;
a token prefilter requires a local table and matching receiver call in Lua, or
a named struct/class pointer field and matching member call in C/C++, before
detailed scope and registration analysis. This filter does not infer edges.
Incoming queries filter files by target name before
parsing. Query parsing validates source checksums and node identities, then
retains lightweight site/registration summaries (including empty results) for
the query lifetime. Each candidate is parsed at most once per query; source,
tokens and inferred edges are not saved in the disk index. A query exceeding
100,000 combined file/site/registration entries fails explicitly instead of
silently dropping edges. This trades additional indexing work for cheaper queries.
Embeddings without a project root can parse with `{ static_dispatch = true }`
to supply the transient data explicitly. LSP definition navigation is unchanged;
this addition feeds the shared graph used by exploration and caller queries.

## Automatic Node EventEmitter deliveries

JS/TS exploration and recursive callers recognize this finite pattern without configuration:

```typescript
import { EventEmitter } from 'node:events';
const bus = new EventEmitter();
function handled() {}
bus.on('ready', handled);
export function publish() { bus.emit('ready'); }
```

The `automatic:event` edge from `publish` to `handled` means a possible delivery through
the same local emitter and literal event name. Evidence includes the registration location.
Named, default and namespace ES imports from `events` or `node:events` identify the builtin
constructor. The object must be an unexported, single-name `const` initialized with a zero-argument
constructor in this file. Registrations accept `on`, `once` and `addListener`, with a named
function, variable-bound arrow function, lexical function alias or resolvable imported export.
Imported handlers reuse module/re-export/workspace resolution; emitter objects do not cross files.

Registration and emission must be standalone calls. Emissions require an indexed callable source;
file-scope emissions are not synthesized as file nodes. Registration must occur at module scope
or earlier in the same enclosing callable as the emission.
Separate setup functions are not assumed to have run. Parameter/block shadows, receiver or member
writes, object aliases/exports/escapes, listener removal, chained calls and dynamic/escaped event
keys conservatively block that object. Files containing anonymous function/arrow scopes without
parser nodes are skipped, since their parameters could shadow a receiver. Class/type name
collisions also block uncertain constructor/handler bindings. Custom emitters, subclasses,
CommonJS constructors, inline anonymous handlers, symbol events, lifecycle/once-consumption
analysis and listener-array traversal are outside this pass. Ordinary definition navigation is
unchanged. Configured event rules remain available for project-specific conventions.

No new persistent candidate index is created: existing import and dispatch-call summaries select
files, and incoming queries reuse the handler's reverse import closure. Detailed object, scope,
registration and callback evidence is parsed only on demand through the ordinary source cache
(16 files/about 8 MiB), with source checksum and node/reference identity validation. Query results
are bounded to 128 candidate files, 512 recognized sites or deliveries per file, and 64 returned
deliveries per file scan. Hitting a limit reports incomplete relationships. Source tokens and
`automatic_events` evidence are excluded from saved/resident records.
Embeddings without a project root can request transient evidence with
`parse.parse(path, source, { ordinary_bindings = true })`.

## Automatic Lua callback collection traversal

Explore and recursive callers recognize a closed same-file local array of local functions:

```lua
local function save() end
local function load() end
local callbacks = { save }
local active = callbacks
table.insert(active, load)
function run()
    for _, callback in ipairs(active) do callback() end
end
```

This produces possible `automatic:callback-loop` edges from `run` to `save` and `load`,
with registration locations. `pairs` and `ipairs` must be unshadowed builtins, and the loop
must bind two identifiers and iterate a bare collection identifier. Callback invocation must
be a direct call of the value variable in the loop's immediate body. The collector reuses
the static registry's scope, local function identity, alias and invalidation analysis.
Function/collection aliases follow at most eight links. Literal arrays and two-argument
`table.insert` calls in the collection's declaration block supply registrations; only
registrations textually before the loop contribute targets.

The collection must remain closed: replacement, alias writes, field/index mutation, removal,
metatables, returned/exported/passed collections and unknown entries block inference. Iterator
or table-library shadows/writes/escapes, environment access and overwritten loop value bindings also
block inference. Files with unknown/global collections still retain a query-time barrier
against treating a loop value call as an unrelated global function of the same name.
Nested conditional scopes and unindexed anonymous function owners are not inferred as callback
deliveries; calls deferred into nested functions are not attributed to the outer function. Global/imported
handlers or collections, keyed/sparse/mixed arrays, numeric-index loops, append syntax using
`#callbacks`, parameter-driven registration functions and inline anonymous functions are
outside this pass. Ordinary definition navigation is unchanged.

Detailed callback evidence is generated only for explicit ordinary-binding queries. Existing
dispatch-call summaries identify candidate files; incoming queries open only the local
handler's own file. Only collections referenced by supported loops are inspected. Source
validation and the ordinary 16-file/about-8-MiB FIFO cache are shared with other query bindings;
no callback-loop hints, bindings or edges are added to the resident/disk index. Limits of 128
candidate files, 128 loop headers per file, 64 registrations per collection and 512 call sites
or weighted deliveries per file report incomplete results. Embeddings without a project root
can supply transient evidence with `{ ordinary_bindings = true }` when parsing.

## Call-path breakpoint reports

Explore also reports **Call-path breakpoints** from unresolved evidence already
encountered while searching between the selected symbols. Each site includes
its known indexed prefix, file/line, call and resolver reason. A single-symbol
query reports only unresolved sites in that symbol. A reverse search does not
produce a breakpoint when the pair already connects in the other direction.

These are observations, not proof that a particular dynamic call explains a
missing connection. Search depth/frontier and relationship expansion limits
are reported separately from unresolved call sites. At most four sites are
shown, prioritizing dynamic/ambiguous dispatch and longer known prefixes;
site/evidence/output limits are explicit. Prefix files are source-validated
before their labels are emitted. The report creates no edges, performs no
extra graph expansion or parsing, and is never stored in the index. Existing
MCP arguments and relationship evidence remain available.

## Configured API contracts

Configure exact API contracts in project-root `.codeoutline.json` under `rules`.
One contract serves both editor definition navigation and explore/callers.
Rules are read per request; editing them does not require rebuilding.

```json
{
  "rules": [
    { "kind": "target", "language": "lua", "call": "worker.post", "argument": 2 },
    { "kind": "callback", "call": "schedule", "argument": 2 },
    {
      "kind": "event", "language": "lua", "call": "bus.emit", "argument": 1,
      "register": "bus.on", "keyArgument": 1, "handlerArgument": 2
    }
  ]
}
```

- `target`: `worker.post(worker_id, 'handle')` links the caller to `handle`.
- `callback`: `schedule(delay, handle)` links to the named callback. C/C++
  `&handle` is accepted too.
- `event`: `bus.emit('tick')` links to handlers registered with
  `bus.on('tick', handle)`, including registrations in other indexed files.
  Keys are matched within each rule and language; unrelated API names do not match.

Arguments are one-based explicit source arguments (Lua colon receivers are not
counted). Nested parentheses/brackets do not change argument positions. API names
are exact, with no wildcard matching. A maximum of 32 rules is allowed.

These edges participate in explore paths, neighbors, and reverse callers.
Neighbor lists label them `indirect:event#3`, for example, identifying the rule
kind and its one-based position in the normalized relationship rules. They are potential execution
relationships, not proof that registration or callback invocation runs at runtime.

For editor definitions, `event` selects the matching registration key, `target`
selects the named declaration, and `callback` selects the resolved callback
declaration. Event navigation can find an anonymous or dynamic registration even
when its handler cannot produce a graph edge. Shared navigation uses the same
bounded alias resolution as relationships, with request-local site reuse and
candidate filtering. String target navigation lists same-language declarations
across the project, including table members such as `CMD.handle`, without
requiring a lexical dependency between remote services. Optional `qualifiers`
filter the declaration owners for navigation only. Lua target/event navigation also
keeps explicit written-API matching when the receiver cannot be inferred.
These candidate lookups do not broaden graph edges. Open/unsaved documents are included. Matching
still obeys the rule's language and exact canonical API name.

Use `kind: "definition"` with the existing `targetKind`, `target`,
`targetArgument` and optional `qualifiers` fields for Lua navigation-only
call/declaration/key rules; these never create relationship edges. See [LSP
rules](LSP.md#configurable-definition-rules).

Legacy `definitionRules` (navigation only) and `dispatchRules` (relationships
only) remain supported with their original semantics. They are appended after
`rules`; identical consumer contracts are deduplicated, preferring the shared
rule. Each array and each combined consumer list is capped at 32 rules. Migrate
to `rules` to enable both consumers without maintaining duplicate configuration.
Old definition rules do not guess a callback argument or acquire graph edges.

The collector uses the existing language parsers and tokenizers. Named callback
expressions and simple quoted literals are supported. Lua, JavaScript/TypeScript,
Python and C/C++ additionally expand bounded lexical aliases during queries:

| Language | Additional supported forms |
| --- | --- |
| Lua | Single-name `local api = bus`, `local cb = handler`, literal aliases, and `require`/`dofile` module aliases |
| JavaScript/TypeScript | Simple `const`/`let`/`var` aliases, simple type annotations, ES named/namespace imports and renamed imports |
| Python | Simple name assignments, absolute `import ... as ...` and `from ... import ... as ...` aliases |
| C/C++ | Single initialized callback variables, including `void (*cb)(void) = &handler` and `auto cb = handler` |

For example, a `bus.emit`/`bus.on` event contract also matches:

```typescript
import { on as subscribe, emit as publish } from 'bus';
import { handle as callback } from './handlers';
const cb = callback;
subscribe('tick', cb);
function run() { publish('tick'); }
```

Bare dotted module identifiers, such as `bus` or `pkg.bus`, provide canonical
API names. Relative paths and filesystem paths are never shortened to a guessed
module basename; configure the actual API spelling in those cases. Imported
callback targets reuse Lua/ES module resolution (including existing exports and
JS project path configuration). Python callback imports require an exact
workspace-root module file or package initializer. There is no arbitrary runtime
loader or Python `sys.path` evaluation. JS default-object members, CommonJS
imports, Python relative imports, destructuring propagation, anonymous callbacks,
call results, arbitrary pointer assignments and interface/virtual dispatch are
not added by alias expansion. Other languages keep their existing direct rules.

Alias chains are limited to eight hops. Parameters, lexical shadowing,
reassignment and recognized member/multiple/destructuring writes conservatively
block uncertain aliases; unsupported initializers never fall back to their
original variable name. This is not control-flow, escape or runtime mutation
analysis. Dynamic keys and escaped/interpolated strings remain unresolved.
Qualified names without import evidence still require an indexed qualified
symbol. Registrations are static possibilities, so unsubscription,
conditional registration, and distinct runtime instances sharing the same API
spelling are not modeled. Use distinct exact API rules where instances must be
isolated. File-scope registrations are supported, while file-scope sends have no
caller symbol and do not create edges. Missing edges do not prove non-reachability.

Lua embeddings can pass the same rule array as `dispatch_rules` to `graph.query`
or `explore.run`. With no rules configured, no API-contract dispatch edges are
added; the automatic static registry patterns above remain available.

The resident index stores only distinct dispatch API names and conservative
alias-root hints per file, not every call's arguments or an alias graph. Hints
are restricted to aliases reachable from syntactic call receivers/callees; they
do not validate scope or infer edges. Alias validation runs only for queries with
dispatch rules. Additional hints may slightly increase index size. Outgoing
edges are resolved when a caller is expanded. Incoming
queries examine all project files matching the configured APIs; event registration
searches also cover the entire project. Candidate files are checksum-checked and
reparsed on demand. Source changes during a query cause an explicit retry error,
not a silently incomplete caller list.

Parsed call sites live only for the current query, with a FIFO cache capped at
16 files and an estimated 8 MiB source/site budget. Large files can be processed
without caching; eviction affects speed, not matching coverage. No source or
tokens are retained in this cache, and rule/source changes cannot reuse it across
queries. Old disk caches are invalidated by the parser checksum.

Query parsing uses the normal declaration and call attribution logic, but skips
Lua/JS binding evidence and compact index-record packing. Each candidate is
processed against all applicable rules before moving to the next file, and
dependency resolution is reused within the query. These optimizations add no
persistent index fields or cross-query cache.

For in-memory embeddings without a project root, parse with `{ dispatch = true }`
to supply explicit call-site data. Normal parsing and index builds use compact
candidates by default.

### Query explanations

`explore` includes a bounded relationship report. Configured dispatch matches
name the API, rule number and argument position; event matches also show the
first matching registration location. These are static rule matches, not proof
that a callback runs at runtime. Ordinary calls distinguish JS/TS or Lua binding
resolution from name/locality matching. Multiple candidates remain identified
as candidates; explanations do not change edge selection.

For expanded callers, failed configured dispatch reports a dynamic/unsupported
or missing argument, an unresolved/ambiguous target, or the absence of a resolved
registration for the event key. Ordinary unresolved references may be external
APIs or missing index coverage, not necessarily broken code. This report covers
indexed references and configured rules; it does not detect every unconfigured
framework or computed call that the language parser cannot extract.

The report retains at most 64 explanations per query and uses at most 4 KiB or
one quarter of the output budget. Evidence omission, call-path depth/frontier
limits and normal output truncation are reported separately. Source reads still
fail explicitly on unreadable or changed files rather than returning a clean
but incomplete result. Structured explore info includes `evidence`,
`evidence_scope`, `evidence_truncated` and `path_search_limited`.

Embedded graph queries can opt in with `graph.query(G, { explain = true })` and
read `Q.report`. Normal graph queries do not retain reports. No explanation data
is attached to resident symbol tables or saved to disk.
