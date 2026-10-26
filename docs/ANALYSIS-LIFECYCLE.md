# Analysis lifecycle

Keep the main index small: basic definitions, import/export identities,
dependencies and compact syntactic call/value-reference sites. Detailed semantic
evidence belongs to open-file prewarming or on-demand LSP/agent queries, with
bounded memory caches and source validation. Do not compute a complete semantic
analysis during indexing merely to discard it or persist a reduced summary.

The one-second responsiveness target is for editor LSP interactions. Agent/MCP
project-wide queries may use longer bounded budgets with cancellation, progress
and explicit coverage limits. A text/name candidate is never a confirmed edge.

## Audit and changes

| Area | Base index | Open-file/query work |
| --- | --- | --- |
| Type references | Definitions/import aliases; no type-use lists | Candidate text search, type positions, generic/value barriers and identity resolution |
| Lua modules and locals | Module imports/exports and conservative binding-name hints | Per-reference bindings and local-table member maps |
| JS/TS/ArkTS | Import/export descriptors and syntactic references | Receiver types, lexical barriers and alias binding evidence |
| Static registries/function pointers | Cheap syntax/possible target-name hints | Scopes, alias validation, writes and registration/dispatch associations |
| C++/C#/Java/Kotlin bindings | Declarations/import identities | Existing query-only aliases, declared receivers and scope evidence |
| Go and Rust | Declarations/package or module import syntax | Existing query-only method sets, expression types and module visibility |
| Native Lua contracts | Existing host declarations and native module entry points | Existing query-only registration exports, guest signatures and member contracts |
| Interface/virtual bridges and type hierarchy | Declared base/header metadata | Existing query-only implementation edges, alias and base verification |
| Events, callbacks and shared emitters | Compact syntactic role/call hints | Existing query-only object identity, registrations, deliveries and callback expansion |

Basic Lua exports include names published by statically supported module/global
export conventions; they are part of symbol identity. Their admission still
checks the declaration's scope. This is distinct from deriving per-call local
bindings or cross-file execution relationships during full indexing.

Type-reference positions are separate transient records, so adding/removing
them cannot renumber ordinary references used by graph and binding caches.
Detailed parses can suppress a syntactic false-call position by its exact
reference index; another construction of the same type on that line is unaffected.

## Editor preparation and reuse

`didOpen` schedules work after a short delay. Draft changes debounce another
preparation. VS Code/Cursor additionally report the active document; document
symbol requests provide another scheduling opportunity for generic clients.
Standard LSP does not provide a universal active-tab-change notification.

Idle warming prepares the active file and at most three direct dependencies,
with file/source/time limits. C, C++, Go, Rust, JVM, C#, JS/TS/ArkTS, Python and
Lua reuse the actual semantic cache used by their queries. Full-file parsing
and ordinary binding loading share the prepared result. Outline-only document
parsing does not eagerly run type/receiver/registry analysis on the protocol thread.

Foreground requests cancel pending/active warming. Cooperative checkpoints
observe cancellation; a single native scanner operation is not preempted
halfway through. A first request can still need an unwarmed dependency or wait
for initial indexing, so preparation alone is not an unconditional latency bound.

Completion budgets use elapsed wall time, including source I/O. Cheap known
declarations are collected before C++ imported-alias expansion. Namespace/alias
enumeration observes the same deadline, prioritizes typed-prefix aliases and
returns an incomplete list when exhausted; editor-side fuzzy filtering remains.

Source size/checksum and node/reference identities are checked before reusing
evidence. Drafts are versioned, closed drafts restore disk views, and queries
apply current project/include/export configuration. Caches are bounded and are
never serialized as part of an index record.

## Validation

Run native and pure-Lua core, LSP and type-reference regressions, plus real
MCP/LSP protocol tests. Check persistence before queries, after queries and
after disk-cache reload. Test that warmed definition and completion requests
do not parse the same semantic file again, and that edits still invalidate it.
Measure full generation, saving, query-symbol preparation and cache bytes
separately from editor cold/warm requests and longer agent queries.

### Local gjqt comparison

The audit used 57,303 files (642 C/C++ fragments), 815,501 symbols and 8 parse
workers. An adjacent local comparison against `2d0d7ba` measured:

| Stage | Before | After |
| --- | ---: | ---: |
| Full generation | 21.953s | 15.072s |
| Saving | 2.047s | 1.694s |
| Generation plus saving | 24.000s | 16.766s |
| Query symbol preparation | 2.287s | 1.851s |
| All three stages | 26.287s | 18.617s |
| Compressed cache, decimal MB | 40.99 | 36.05 |
| Persistent reference positions | 3,579,383 | 2,520,951 |

File/symbol counts and unchanged-refresh behavior stayed intact. These are
single local samples, not a stable speedup guarantee. The extra 1,058,432 type
positions are now derived on demand instead of saved with ordinary references.

After cache loading, real navigation in `scene_system.cpp`, `path_editor.cpp`,
`utils_unicode.inl` and `ks_lua_base.inl` took 12–158ms for the first definition,
4–180ms for repeated definitions and 1–317ms for completion. The broad C++
completion returns an explicitly incomplete list at its analysis budget. Index
loading and explicit between-sample garbage collection were excluded. Protocol
regressions validate transport behavior separately; these measurements do not
claim a manual end-to-end test inside Zed, VS Code or Cursor.
