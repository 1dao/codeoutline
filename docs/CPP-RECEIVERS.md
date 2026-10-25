# C/C++ call-result receivers

Definition navigation, agent call edges and completion can follow an ordinary
function's declared return type before looking up a member:

```cpp
Manager* get_manager();
get_manager()->run();

Manager get_value();
get_value().run();
```

C structure fields work the same way: `get_record()->value` uses the returned
structure's field, rather than all fields named `value`.

Supported evidence includes named value, pointer and reference returns, ordinary
C structure typedefs, C++ namespace/using/include visibility, trailing named return
types, parenthesized results, and bounded chains of methods and fields. Pointer
levels and `.` versus `->` are checked. Const returned objects only admit methods
with an explicit const declaration. When multiple visible callable declarations
are possible, their resolved return types must all agree; this does not implement
C++ overload selection by argument types.

Detailed declaration and expression evidence is parsed only when queried and
reuses the source-validated ordinary binding cache. It is not serialized into the
index. A compact presence flag identifies files with namespace using-directives
so ordinary type lookup need not inspect unrelated headers. Draft changes, source
edits and cache reloads use fresh query contexts.
Alias lookup can cache a lightweight declaration-only parse and upgrades it to
full binding evidence only when needed; macro summaries remain independently
available. Both forms share the same bounded cache and source validation.
Within one query, compact validated alias lists can survive eviction from that
cache, up to 256 files and approximately 1 MiB. This avoids reparsing the same
transitive headers for each name. These summaries retain no source text, tokens
or full binding records, and the next query validates source again.
Each query admits at most 16 evidence files, 8 MiB of evidence source, depth 12,
256 candidates per lookup and a 400 ms soft deadline. Reaching a bound reports
incomplete results. Native parsing and existing include/name lookup retain their
own bounds; the soft deadline is not a hard wall-clock interrupt.

Unknown factories, function-pointer shadows, conflicting return types, deduced
`auto` without an explicit trailing type, templates, decorated C++ type aliases,
smart pointers and overloaded `operator->`, casts, indexing, and unknown macro
decorations remain unresolved. An unsupported expression does not fall back to
unrelated same-name members. This is bounded source analysis, not a C++ compiler.

Lua, JS/TS, C#, Java and Python factory-result inference is separate from this
feature. Existing language-specific loader and native binding support is retained.
