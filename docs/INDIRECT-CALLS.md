# Indirect calls

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
or `explore.run`. With no rules configured, no indirect dispatch edges are added.

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
