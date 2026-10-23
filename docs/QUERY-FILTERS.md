# Explicit query filters

Explore, callers and type-hierarchy accept filters inside the existing query:

```text
lang:lua path:service/ connect
lang:c native_saved
lang:ts kind:class Child
lang:lua name:connect
path:"apps/my app" name:save
```

Filters select starting symbols only. Explore paths, supporting source and
neighbors, recursive callers and type ancestors/descendants retain their normal
resolution across languages, files and node kinds. In particular a Lua seed can
still reach a native C export, and a C target can still have Lua callers.
Filtering does not alter indexing, foreign bindings, graph evidence or caching.

| Field | Matching |
| --- | --- |
| `lang:` / `language:` | Exact language; aliases js, ts, py, c++, c#, cs, kt, rs |
| `kind:` | Exact parser kind, such as function, method, class, interface, macro |
| `path:` | Literal substring of project-relative path; backslashes normalize to slashes |
| `name:` | Literal substring of qualified symbol name |

Values are case-insensitive; separate fields combine with AND, repeated values
of one field with OR. No glob/regex evaluation. Double quotes permit whitespace
in a value; escaped quotes are not supported. Empty/malformed values and unknown
languages are errors. Unknown field prefixes remain ordinary query text. An
unknown kind simply matches no symbol. Recognized field prefixes are reserved
syntax at the start of a query token.

Explore keeps its existing free-text name/file matching. A filters-only explore
scans compact headers in deterministic file order, retaining at most 512 matching
candidates before normal ranking and seed caps. If more candidates match it
reports `seed_limit_reached` and a text notice; narrow the filters to search beyond
that candidate window. This flag is separate from graph incompleteness and text
truncation. File outlines use the same predicates. Full source blocks can include
other declarations because the filter does not edit source text.

Callers and type-hierarchy still require an exact symbol/type name in addition to
filters; they do not turn into project-wide listing queries. Filtering happens
before target caps and same-name disambiguation. MCP and CLI reuse the same query
string syntax as Lua service calls; no new protocol parameter is required.

Generated-code ranking is a separate proposed improvement. These explicit
filters do not automatically exclude or demote generated files.

Query performance also reuses compact Lua export/local-member names to avoid
resolving unrelated bound Lua calls during reverse traversal. Native targets
with `luaopen_*` retain the broader lookup needed for renamed C exports.

Query-discovered GBK repairs persist as compact records in a bounded atomic
`<cache>.repairs` overlay instead of rewriting the whole project cache. The
overlay is checked against the base payload hash, parser version, project root
and original file checksum/size/language, then validated like base records.
Corrupt/stale overlays are ignored; source queries can regenerate repairs.
A save following ordinary index changes merges repairs and removes the overlay.
At most 256 records and 8 MiB are persisted there; publication/limit failures remain visible as cache-save
errors without changing the resident query result. No query binding graph,
source text or tokens are added to the overlay.
