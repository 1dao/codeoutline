# Recursive callers

Find potential upstream impact without storing a persistent call graph:

```sh
codeoutline callers --project /path/to/project --query save_file
codeoutline callers --project /path/to/project --query Session.save --depth 2 --max-nodes 100
```

MCP clients use `codeoutline_callers` with the same `query`, `depth`, `max_nodes`
and optional `projectPath`/`budget` fields. Lua embeddings use
`service.callers(root, query, opts)` and receive text plus structured query info.

The query matches an exact qualified name first, then an exact short name.
Multiple definitions are listed explicitly. The reverse breadth-first search
batches incoming resolution once per level, deduplicates cycles and repeated
call sites, and returns one shortest path from each discovered caller to any
matched target. Paths include file locations, call-site lines and relation kinds,
including configured indirect dispatch. These are static potential relationships,
not proof of runtime execution. Returned `files` contains affected caller files;
target locations are listed separately in `targets`.

Defaults: depth 3 (range 1–8), up to 200 callers (range 1–2000), output budget
16000 bytes (range 256–262144). The same node cap also bounds matching targets.
`node_limit_reached` means targets or callers were omitted. A nonempty frontier
at the requested depth sets `depth_limit_reached`: further callers were not
checked, which does not assert that more callers exist. `truncated` reports
output/node truncation separately. Increase the matching limit or depth to widen
the query. A precise qualified name reduces ambiguous target matches.

The structured result contains `targets`, `callers` (with `depth` and `path`),
`files`, limit flags and `query_stats`. Source changes/read failures are explicit
errors; encoding repairs retry selection before returning IDs. Cancellation
uses the existing query checkpoints. Index records and disk-cache format do not
gain caller graphs; query-owned edges and returned paths consume temporary
memory, and retained result objects remain live until their callers release them.
