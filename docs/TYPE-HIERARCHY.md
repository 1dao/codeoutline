# Declared type hierarchy

Query explicit inheritance and interface declarations in C#, Java, Kotlin,
TypeScript and C++:

```sh
codeoutline type-hierarchy --project /path/to/project --query Store
codeoutline type-hierarchy --project /path/to/project --query api.Root --direction descendants --depth 4
```

MCP clients use `codeoutline_type_hierarchy`. Lua embeddings call
`service.type_hierarchy(root, query, opts)`, receiving text and structured info.
This is a library/CLI/MCP query; it does not add LSP type-hierarchy methods.

Selection matches an exact qualified name first, then an exact short name.
All matching supported declarations are listed, with their files, lines and
language. A shared short name can select types in multiple files or languages;
results explicitly cover those targets. C++ forward declarations are excluded
from selection; base resolution prefers visible definitions. IDs belong to the
current symbol-table generation and are not durable identifiers.

`direction` is `ancestors`, `descendants` or `both` (default). Breadth-first
traversal returns each type once per direction, with its minimum depth, one
shortest path from a matched target and declaration evidence. Depth 1 is direct;
larger depths are indirect. The structured `edges` retain selected child-to-base
relationships, including additional diamond paths. Seeds themselves are not
repeated in the ancestor/descendant lists. An `implements` edge means an explicit
interface declaration; it does not prove method completeness or instantiability.

The query reuses existing package/import/workspace, C# using/alias and C++
namespace/type-alias/include resolution. C++ multiple and virtual inheritance
are supported as declaration relationships: resolving a final virtual overrider
is a separate problem. Interfaces, abstract classes and concrete classes can
appear in either direction. Structural compatibility, implicit standard-library
bases, dynamic base expressions, generics/template substitution, TS nested or
ambient declarations, and Kotlin delegated bases are not inferred. Original base
syntax is verified on demand so generic erasure in compact headers cannot create
an unrelated non-generic edge. Ambiguous identities remain unresolved. Resolution
stays within each language; Java/Kotlin interoperability is not inferred.

Defaults: depth 8 (range 1–32), `max_nodes` 200 (range 1–2000), text `budget`
16000 bytes (range 256–262144). The node cap covers targets plus both result
lists. `depth_limit_reached` means a further unvisited type was found at the
boundary. `node_limit_reached`, `candidate_limit_reached`, `cycle_detected`,
`unresolved` and `relationships_incomplete` distinguish incomplete relationships
from text truncation (`truncated`). Cycles are reported, diamonds deduplicated.

Ancestor-only queries resolve selected base chains. Descendant queries scan
existing compact type headers in the selected languages (at most 1,000,000
nodes), then resolve at most 512 declarations with explicit bases. Literal
base-name matches are examined first, followed by other declarations to cover
aliases. Files are ordered deterministically. There is no separate resident
reverse-inheritance index. A reverse candidate with unknown/unsupported bases
is counted in `query_stats.reverse_unresolved`; it may hide a descendant, so
the result explicitly reports incomplete coverage even if other edges resolve.
Narrowing to `ancestors` avoids that project-wide reverse candidate work.

Source validation and parsing reuse the ordinary query FIFO (16 files/about
8 MiB). A query opens at most 128 distinct source files and 8 MiB of source,
including alias dependencies. Only bounded declaration/alias summaries survive
FIFO eviction for the query's lifetime. Source changes fail explicitly; encoding
repairs retry selection before returning IDs. Existing cancellation checkpoints
remain active. No hierarchy summaries, reverse maps or edges are saved in index
records, attached to resident symbol tables, or constructed by full indexing.
Each declaration is limited to 64 direct bases; at most 4096 selected edges are
retained. These limits also report incomplete relationships.

Structured info includes `targets`, `ancestors`, `descendants`, `edges`,
`unresolved`, limits and `query_stats` (header scan, candidate, source and shared
parser-cache counts). MCP/CLI render the text; Lua callers can inspect the info.
