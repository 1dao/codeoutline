# Ordinary call bindings

Explore, recursive callers and LSP call-site navigation share these bounded
resolvers. They require no dispatch rules.

## JavaScript and TypeScript

Simple lexical function aliases (`const cb = save; cb()`) follow named functions,
named arrow-function bindings, imports and alias chains of at most eight hops.
Exported aliases can forward through ES imports and re-exported modules. Existing
module-path resolution also applies to these aliases.

The collector reuses dispatch alias validation: recognized writes, parameter
shadowing, destructuring writes and unsupported initializers block inference.
It conservatively rejects reassigned aliases even for a call textually preceding
the write. This is not control-flow or escape analysis. Object-property aliases,
destructuring propagation and CommonJS exports remain outside this addition.

## Python

Explicit renamed imports, module aliases, relative imports and package
`__init__.py` re-exports resolve ordinary calls. Absolute imports use exact
workspace-root module paths; relative imports start at the importing file.
Re-export cycles terminate and traversal is limited to eight hops. Recognized
lexical shadowing, reassignment and deleted import bindings prevent a guessed
same-name fallback. Existing `self`/`cls` member resolution remains available.

There is no execution of `sys.path`, import hooks or package initializers.
Namespace packages, wildcard imports and general class/member type inference
are not provided by this resolver. Missing module targets remain unresolved.

## C++

Simple named types written on parameters, local variables and preceding member
declarations constrain calls such as `a->save()` and `a.save()`. Pointer,
reference and value declarations are supported, including qualified type names.
Type lookup walks the caller's enclosing qualified scopes and uses same-file
or directly included class/struct declarations. Simple base-class method lookup
is cycle-safe and limited to eight hops.

A known declaration with no resolvable type or member does not fall back to an
unrelated same-name method. Primitive and `auto` declarations also act as
barriers to an enclosing receiver binding. This does not infer `auto`, templates,
type aliases, using-directives, smart pointers, chained field types, or virtual
runtime dispatch. Include resolution retains the existing graph's limitations.
Unsupported declaration forms can still use the existing generic resolver.

## Storage and validation

Full and incremental indexing skip this additional JS alias, Python import and
C++ declared-receiver analysis. Existing symbols, references, imports and JS
receiver metadata remain resident. No new binding evidence or Python import
descriptors are serialized. Parser checksums invalidate older disk caches.

Explore, callers and LSP share a query-local loader. It parses relevant files
only when binding evidence is needed, using unsaved documents in LSP requests.
Disk sources must match the indexed size/checksum and symbol/reference identities;
a changed source requires a refresh and retry. Temporary evidence uses a FIFO
cache bounded to 16 files and an estimated 8 MiB; source, tokens and duplicate
symbols are discarded. Evicted evidence can be regenerated without losing edges.
The cache is released with the query, so a later query pays the analysis cost again.

Reverse queries retain reference-name filtering. Renamed calls additionally use
existing import paths and alias hints to select plausible files, then resolve
their imported symbols before collecting evidence. C++ receivers never bypass
the method-name filter. A first query can therefore cost more than a name-only
lookup; the extra work is absent from full indexing. In-memory embedding without
source files can explicitly parse with `ordinary_bindings = true`.

Regression tests cover forward/reverse relationships, wrong-target exclusions,
cache reload, incremental edits, and LSP definitions/references with unsaved
target documents. Protocol tests do not establish behavior in a running editor.
