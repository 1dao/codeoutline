# Changed file impact

`affected` selects indexed symbols from an explicit list of changed files and
walks their potential callers together. It reuses the same query-time graph as
`explore` and `callers`, including configured dispatch and Lua/native links.
There is no additional resident or serialized impact graph.

```powershell
codeoutline affected --project C:/src/project --file scripts/store.lua --file native/store.c
git -c core.quotepath=false diff --name-only --relative | codeoutline affected --project . --files-from -
codeoutline affected --project . --files-from changed-files.txt --depth 4 --max-nodes 500
```

`--file` is repeatable. `--files-from` accepts a UTF-8 newline-delimited file, or
`-` for stdin (up to 64 KiB). CRLF and a leading UTF-8 BOM are accepted. Paths
with spaces are preserved. This is a plain path list, not Git's quoted filename
format; pass quoted or escaped Git filenames explicitly with `--file` after
decoding them. Paths containing NUL or line breaks are rejected. The command does not
execute Git or modify files. Run Git from the selected project root when piping
project-relative paths. `git diff` above selects unstaged tracked changes only;
use the appropriate Git options or an explicit list for staged/untracked files.

MCP exposes `codeoutline_affected`:

```json
{"files":["scripts/store.lua","native/store.c"],"depth":3,"max_nodes":200,"budget":16000}
```

The Lua API is `service.affected(root, files, opts)`, returning text and a details
table. Options include the normal project cache options, `depth` (1–8, default
3), `max_nodes` (1–2000, default 200), and `budget` (256–262144 bytes, default
16000). The same node cap separately bounds starting symbols and discovered
callers. Up to 128 input paths are accepted. Paths must be exact project-relative
files or absolute files inside the project; no globs, directory expansion or
outside-root traversal. Equivalent paths are deduplicated, with case folding on
Windows.

Details include `changed_files`, `targets`, `callers`, `files`, `tests`,
`unresolved_files`, `files_without_symbols`, `query_stats`, `incomplete` and
`truncated`. Each caller has one shortest path to one selected starting symbol;
this does not enumerate all paths or attribute every affected symbol to every
changed file. `files` includes matched changed files and discovered caller files.
`tests` is a subset identified by naming (`test`/`tests`/`spec` directories,
`test_`, `_test`, `.test`, `_spec`, `.spec`, and JVM/.NET `Test(s)` filenames).
These are test candidates, not verified test entry points or commands.

All input symbols share one incoming-reference scan per traversal layer. A
cooperative 700 ms traversal budget returns verified work with
`time_limit_reached`; it does not silently turn omitted work into an empty
result. A timed-out layer may include verified edges from the scanned file
prefix; these are never published as complete incoming lists. Seed/node/depth
and relationship caps have separate flags. Input selection, refresh, encoding
repair, source validation and formatting also take
time; the traversal budget alone is not a one-second end-to-end guarantee.
Resident-service benchmarks include those costs. Initial index loading and
rebuilding are measured separately.

Coverage is limited to existing indexed symbol relationships. This does not
add complete type-reference, top-level import, configuration, resource, build,
reflection or runtime dependency analysis. Even a result with `incomplete=false`
is not proof that all affected code has been found or that unlisted tests may be
skipped. File-level seeding is deliberately conservative: all indexed symbols in
a changed file participate, rather than only symbols overlapping changed lines.

Refresh happens before the query. Deleted, old renamed, unsupported, ignored or
otherwise unindexed paths appear in `unresolved_files` and make the result
incomplete. Empty indexed files appear in `files_without_symbols`. There is no
historical graph: submit both rename paths to see the missing old path and the
current new file, but old callers cannot be reconstructed from the new index.
