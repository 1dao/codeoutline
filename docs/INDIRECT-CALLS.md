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
