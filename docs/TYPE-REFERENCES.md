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
Definition navigation from on-demand explicit type positions also shares it.
Drafts overlay saved records, UTF-16 positions are reconstructed from validated
source, and closing a draft restores the disk view. `includeDeclaration` controls
the queried declarations in LSP results. Existing callable references continue
to use the call/reference graph.

## Scope

The initial implementation covers explicit nominal positions in C/C++, C#,
Java, Kotlin, TypeScript/ArkTS, Go and Rust: declared parameters, return types,
fields, properties, simple locals/globals, declared bases, aliases, explicit
construction and selected casts. Go defined-type underlying declarations remain
distinct from Go aliases. Token locations are generated on demand; declaration
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

Full indexing does not collect or save type-use positions. The base reference
arrays retain syntactic calls/value references only. Type positions, roles,
byte ranges, lexical barriers and binding evidence are generated at file-open
prewarming or query time and kept separate from those arrays. Type positions
never become execution edges. Parser checksums invalidate older caches once.
C#/Rust import records retain small import-alias descriptors.

Detailed evidence reuses the source-validated ordinary FIFO (16 files, about
8 MiB); it is not serialized. Project-wide reference search scans text for type
and alias spellings, then parses candidate files and verifies actual type
identity. Text hits in comments/strings are not confirmed references. Candidate
reads validate source snapshots and are bounded to 20,000 reads/256 MiB.

Agent/CLI queries admit up to 64 evidence files/8 MiB, 32 alias spellings, 4096
candidate positions, the requested result cap and a 5s cooperative analysis
budget. LSP type-reference queries use 16 evidence files and a 600ms analysis
budget instead; the editor latency target does not constrain agent-wide work.
Existing resolver bounds also apply. The cap also bounds selected declarations. Target files
are validated first; their directory is visited before other candidates.
Native parsing cannot be interrupted halfway through a single parse;
cold index loading, refresh and formatting have additional costs.

Details include `targets`, `references`, `unresolved_sites`, `ambiguous_sites`,
`incomplete` and `query_stats`. References carry file, line, zero-based byte
`first`/`last`, role, written spelling and temporary query identities.
`coverage.reasons` distinguishes result, file, source, candidate scan, alias, site, binding and
time limits. Partial results retain confirmed positions already checked before
a limit. Snapshot mismatches fail the query; an encoding repair retries with
fresh node IDs. No temporary node identity should be saved across requests.

See [analysis lifecycle](ANALYSIS-LIFECYCLE.md) for the audit of eager analysis,
cache boundaries and separate editor/agent performance requirements.
