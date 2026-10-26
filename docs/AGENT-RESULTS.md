# Agent query results

`codeoutline_explore`, `codeoutline_callers`, `codeoutline_affected`,
`codeoutline_type_hierarchy` and `codeoutline_type_references` keep their text result and also return compact MCP
`structuredContent`. The embedded service returns the same coverage in `info`;
the xagent `CodeExplore` adapter exposes it in `metadata`.

```json
{
  "operation": "codeoutline_explore",
  "projectPath": "C:/src/project",
  "generation": 12,
  "state": "partial",
  "coverage": {
    "scope": "indexed_static_analysis",
    "partial": true,
    "reasons": ["shared_events.unsupported_syntax"],
    "output_truncated": false,
    "relationships_incomplete": true,
    "selection_limited": false
  }
}
```

`state` is `ok`, `partial`, or `error`. `ok` means no reported limit or unresolved/
ambiguous examined call in this query's indexed static analysis. It does not establish runtime completeness,
coverage of ignored files, or support for every language construct. Empty
`coverage.reasons` is an array. Generation identifies the index revision, not a
transaction over the entire filesystem. Text/source is emitted only once.

Query results also expose `resolution` when reference sites were examined:
`scope: "examined_reference_sites"`, `observed_sites`, `unresolved_sites`,
`ambiguous_sites`, `heuristic_matches` and `counts_limited`. A site is counted
once, including synthetic dispatch sites reported by collectors. Ambiguous
and unresolved counts can overlap. Name/locality matching is counted as
heuristic; it does not establish lexical binding. These diagnostics use at most
512 site identities per query; after that counts are lower bounds and
`counts_limited` is true. They describe examined/reported sites, not every call
in the project. No additional source parsing is performed for these counts.
Nonzero unresolved/ambiguous counts produce `unresolved_calls`/`ambiguous_calls`
coverage reasons; the count cap produces `resolution_count_limit`.

Reasons are sorted codes. They distinguish output/selection limits
(`output_truncated`, `seed_selection_limited`, `seed_candidate_limit`), traversal
limits (`path_search_limit`, `depth_limit`, `node_limit`, `time_limit`), omitted
explanations (`evidence_omitted`, `definition_candidates_omitted`,
`path_breakpoints_omitted`), unresolved files/types, and shared-event analysis.
Graph limits identify `graph_expansion_limit`, `candidate_scan_limit`,
`tied_candidate_limit` and `include_closure_limit`. Other incomplete analysis
identifies the responsible stage, such as `cpp_macro_analysis_incomplete`,
`go_module_analysis_incomplete`, `go_method_set_analysis_incomplete`,
`cpp_receiver_analysis_incomplete`, `js_workspace_analysis_incomplete`,
`rust_resolution_incomplete`, `implementation_analysis_incomplete`,
`automatic_event_analysis_incomplete` and `lua_callback_analysis_incomplete`.
Stage-level reasons can cover unsupported evidence as well as resource limits;
they do not falsely assert which internal cap was reached.
Shared events report `shared_events.unsupported_syntax` separately from
`shared_events.file_limit`, `source_byte_limit`, `file_size_limit`, `site_limit`,
`target_limit`, `depth_limit` and `time_limit` (each with the same prefix).
Cycles and ambiguous exports have their own codes. A relationship can remain
incomplete even when all generated text fits the output budget.

Query execution errors retain `isError: true` and text, with
`error: {code, retryable}` in structured content. A source snapshot mismatch is
`source_changed` with `retryable: true`; the agent can issue a new query to
refresh. Query queue saturation or waiting more than 750ms is `busy`, with
`retryAfterMs: 250`; an exceeded execution deadline is
`deadline_exceeded`. Other failures use `query_failed`. Validation/protocol
errors continue to use the existing JSON-RPC error response.

Queued explore/callers/affected/type-hierarchy/type-references requests expire independently of
the active job. The worker acknowledges their cancellation before their queue
slots are reclaimed, retaining the 64-job bound. Running jobs remain serialized
and keep their execution deadline; this does not preempt an active query or make
cold indexing finish within one second. Clients should back off on `busy`.

Explore labels non-call hops in relationship paths and neighbor lists. `[ref]`
means retaining or passing a function value; it does not prove execution.
`[possible implementation]`, `[possible event]` and configured callback/event
hops describe static possibilities. Direct calls keep the ordinary `->` form.
The underlying dependency edges remain available to callers/impact analysis.

Explore checks source snapshots for rendered source, locations, evidence and
pointers. It caps the extra-match pointer window at 15 instead of reading every
same-name match. Source needed to resolve relationships or construct a candidate
snippet may also be read. An encoding repair aborts rendering and restarts with
fresh IDs before publishing text. This bounds unnecessary validation work; it
does not introduce a universal end-to-end deadline or change worker scheduling.
