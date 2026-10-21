# C# using and member resolution

Explore, callers and LSP navigation/completion share query-time C# bindings.
No dispatch rules or compiler process are required.

## Supported source evidence

- Named type aliases: `using Store = MyApp.Data.Store;`.
- Namespace aliases: `using Data = MyApp.Data;`, including `Data.Store` and
  namespace-alias-qualified `Data::Store` access.
- `global::` names, escaped identifiers, file-scoped and block namespaces.
- File and namespace using scopes, including separately opened namespace bodies.
- Ordinary namespace imports and `using static`, including named nested types and
  static member calls/completion. Instance members are not imported as static calls.
- `global using`, `global using Alias = ...` and `global using static ...` from
  indexed source files in the same detected project.
- Simple declared parameter/local/field receiver types and `var value = new Type()`.
  These narrow member calls to the declared type and its simple bases, rather than
  other same-name methods. Explicit constructor calls through aliases participate
  in forward/reverse queries. Overload selection by argument types is not attempted.

An unqualified call prefers the enclosing type's members before static imports.
Static/instance distinctions and basic public/internal versus own-private member
access are checked from query-only declaration evidence. This is not a complete
accessibility, overload, extension-method or virtual-dispatch implementation.

## C# alias rules

Aliases are using directives, not C++ typedef declarations. They cannot be
declared inside a method. A using directive's right-hand side is resolved without
other usings in its immediately containing scope; outer namespace aliases can
still be visible. Same-scope alias chains are therefore not inferred. Conflicting
alias declarations, unsupported targets and missing targets stop same-name guesses.
Nested types and generic type parameters can shadow an outer alias; unresolved
generic parameters remain unknown.

The implementation follows the source-language distinctions documented in the
[C# using reference](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/keywords/using-directive)
and [namespace specification](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/namespaces).

## Project boundary

Global usings are grouped by the nearest ancestor directory containing one
`.csproj`, within the indexed workspace root. Nested projects form separate groups.
If several project files share a directory, ambiguous files do not share global
usings or inferred type identities across files. Without project files, the
workspace root is treated as one source compilation.

This is a physical-directory approximation. MSBuild conditions, linked Compile
items, project references, SDK implicit usings, project-file `<Using>` entries and
binary metadata are not evaluated. `extern alias` requires assembly identity and
remains unresolved. Unsaved global-using documents participate in their session's
overlay and do not alter other sessions or resident records.

## Storage and limits

Normal indexing retains existing import paths plus a compact `global` candidate
flag on global using directives. It does not build alias tables, receiver/type
evidence, static/accessibility maps or inferred edges. Parser checksums invalidate
older disk caches automatically.

Queries parse only referenced source/candidate global-using files, verify indexed
source snapshots and use the shared FIFO cache (16 files, estimated 8 MiB). Temporary
scopes, generic-parameter barriers and using targets are released with the query.
Aliases needed only for an in-memory graph can be collected explicitly with
`ordinary_bindings = true`.

Generic constructed aliases, tuples, nullable/array/pointer alias bodies, delegate
variable aliases, extension methods, field-chain typing in call relationships and
full flow analysis are outside this batch. Unsupported aliases remain known but
unresolved, rather than being reduced to an unrelated named type.

Validation covers native/pure-Lua parsing, query/index separation, forward/reverse
relationships, cache reloads, project isolation, incremental edits, and LSP alias,
namespace/static completion and navigation with unsaved global-using files. Actual
editor UI behavior requires a separate editor smoke test.
