# Explicit type references

```powershell
codeoutline type-references --project C:/src/project --query api::User --max-nodes 200
```

MCP exposes `codeoutline_type_references` with `query`, optional `projectPath`,
`max_nodes` (1–2000, default 200) and `budget` (256–262144 bytes). The embedding
API is `service.type_references(root, query, opts)`, returning text and details.
`lang:`, `kind:`, `path:` and `name:` filters select type declarations; references
may occur in other files. Exact qualified names isolate same-name types.

LSP `textDocument/references` on supported type names uses the same resolver.
Definition navigation from indexed explicit type positions also shares it.
Drafts overlay saved records, UTF-16 positions are reconstructed from validated
source, and closing a draft restores the disk view. `includeDeclaration` controls
the queried declarations in LSP results. Existing callable references continue
to use the call/reference graph.

## Scope

The initial implementation covers explicit nominal positions in C/C++, C#,
Java, Kotlin, TypeScript/ArkTS, Go and Rust: declared parameters, return types,
fields, properties, simple locals/globals, declared bases, aliases, explicit
construction and selected casts. Go defined-type underlying declarations remain
distinct from Go aliases. Token locations are indexed compactly; declaration
names, comments and strings are excluded. Type parameters and local value
shadows remain barriers rather than borrowing an unrelated global type.

Lookup reuses C++ scope/include/type aliases, C tag/typedef visibility, C# using
aliases, JVM package/import identity, ES module aliases, Go packages and Rust
module identities. Standalone Rust files can resolve same-file declared types.
Unresolved or ambiguous candidates are reported instead of being confirmed.
Plain nominal aliases can add alias spellings to the bounded query. Compound
aliases still reference their element types, but do not become those identities.

This is not a complete compiler/type checker. Arbitrary inferred types, macro
expansion, general dependent/template substitution, reflection, dynamic loading,
unindexed dependency sources, arbitrary casts and all language-specific type
expressions are not inferred. Python/JavaScript class construction and Lua
annotation comments are outside this initial type-reference API. A zero result
is scoped to indexed supported positions, not proof that a type is unused.

## Index and query costs

Normal parsing adds `kind='type'` entries to the existing compact reference
columns, including the name, qualifier, owner and line. Type sites never become
execution edges. Reference counts, cache bytes and resident reference arrays
therefore grow; there is no additional persistent type-use graph. Parser checksums
invalidate older caches once. C#/Rust import records retain small alias hints.

Detailed roles, byte ranges, lexical barriers and binding evidence are parsed
only when queried. They reuse the source-validated ordinary FIFO (16 files,
about 8 MiB); they are not serialized. Candidate selection reads resident type
reference names, not every source file. A query is bounded to 16 source files,
8 MiB of source, 32 alias spellings, 4096 candidate sites, the requested result
cap, and a 600ms cooperative analysis budget. Existing resolver bounds also
apply. The result cap also bounds selected target declarations. Target files
are validated first; their directory is visited before other candidates.
Native parsing cannot be interrupted halfway through a single parse;
cold index loading, refresh and formatting have additional costs.

Details include `targets`, `references`, `unresolved_sites`, `ambiguous_sites`,
`incomplete` and `query_stats`. References carry file, line, zero-based byte
`first`/`last`, role, written spelling and temporary query identities.
`coverage.reasons` distinguishes result, file, source, alias, site, binding and
time limits. Partial results retain confirmed positions already checked before
a limit. Snapshot mismatches fail the query; an encoding repair retries with
fresh node IDs. No temporary node identity should be saved across requests.

### Local performance check

An adjacent comparison on `gjqt` (57,303 files, including 642 C/C++ fragments,
8 parse workers) measured generation plus saving at 26.11s before this feature
and 26.05s after it. This single pair is not a stable speedup claim. File and
symbol counts stayed unchanged; compact references grew from 2,520,951 to
3,579,383. Compressed caches grew from 36.65 MB to 41.00 MB (about 11.9%).

Three queries each for `lua_State`, `luaL_Buffer` and `VisTypedEngineObject_cl`
took 204–438ms after initial cache loading. These large-project queries returned
confirmed partial results with result/file limit reasons, rather than claiming
complete coverage. Ten existing explore/callers/hierarchy query cases also
remained below one second, with unchanged rendered-output hashes after the
lightweight C++ hierarchy optimization. Cache loading, full refresh and explicit
garbage collection between samples were excluded from query timings.
