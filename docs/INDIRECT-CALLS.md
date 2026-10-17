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
resolution. Imported/global registries, aliases, metatables, escaped keys and
numeric indices are outside this first implementation.

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

The resident index stores a candidate boolean only. Query parsing validates
source checksums and node identities, then retains registration/site data in a
query-local FIFO (16 files, estimated 8 MiB budget); no source/tokens or inferred
edges are saved in the disk index. Cache eviction preserves matching coverage.
Embeddings without a project root can parse with `{ static_dispatch = true }`
to supply the transient data explicitly. LSP definition navigation is unchanged;
this addition feeds the shared graph used by exploration and caller queries.

## Configured API contracts

Configure exact API contracts in project-root `.codeoutline.json`. Rules are
read on every explore request; editing them does not require rebuilding.
Existing `definitionRules` for editor navigation remain independent.

```json
{
  "dispatchRules": [
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
kind and its one-based position in `dispatchRules`. They are potential execution
relationships, not proof that registration or callback invocation runs at runtime.

The collector uses the existing language parsers and tokenizers. Named callback
expressions and simple quoted literals are supported. Dynamic keys, escaped or
interpolated strings, anonymous callbacks, variable alias propagation, arbitrary
function-pointer assignments, and interface/virtual dispatch are not inferred.
Qualified handler names must match an indexed qualified symbol; module aliases
are not expanded here. Registrations are static possibilities, so unsubscription,
conditional registration, and distinct runtime instances sharing the same API
spelling are not modeled. Use distinct exact API rules where instances must be
isolated. File-scope registrations are supported, while file-scope sends have no
caller symbol and do not create edges. Missing edges do not prove non-reachability.

Lua embeddings can pass the same rule array as `dispatch_rules` to `graph.query`
or `explore.run`. With no rules configured, no API-contract dispatch edges are
added; the automatic static registry patterns above remain available.

The resident index stores only distinct dispatch API names per file, not every
call's arguments. Outgoing edges are resolved when a caller is expanded. Incoming
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
