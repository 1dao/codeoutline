# Go method queries

CodeOutline builds Go method sets when queried. Existing compact type, method,
field and import records locate candidates; source-validated query evidence supplies
receiver modes, signatures and lexical bindings. No Go compiler, module download,
parallel persistent method index or native-runtime change is required.

## Supported behavior

- Ordinary interfaces, including non-generic embedded interfaces.
- Concrete structs and ordinary named types with declared methods, including
  methods declared in other files of the same package.
- Distinct value/pointer method sets and promotion through embedded values or
  pointers. Addressable declared variables may call pointer receiver methods;
  interface satisfaction still checks the value and pointer sets independently.
- Signature comparison by resolved type identity, rather than method name or
  arity alone. Parameter/result names are ignored; grouped declarations, variadics,
  simple aliases, pointers, slices, fixed literal array lengths, maps, channels and
  function types are supported. `byte` and `rune` retain their built-in alias identity.
- Struct fields and shallower declarations block deeper promotions. Same-depth
  conflicts, including repeated paths to the same method, are not guessed through.
- Named parameters, method receivers, explicitly typed variables and simple
  composite/new initializers supply receiver evidence. Unknown factories, chains,
  local shadowing and unsupported parameter syntax are barriers.
- Private method identity includes the declaring package, not just its written name.
  Package names alone never unify types from different directories/modules.

These rules follow the Go specification's [method sets](https://go.dev/ref/spec#Method_sets),
[struct promotion](https://go.dev/ref/spec#Struct_types) and
[type identity](https://go.dev/ref/spec#Type_identity). They are bounded source
analysis, not a complete assignability or runtime-dispatch checker.

## Shared queries

Agent explore/callers and editor definition, implementation, references and
completion use the same method sets. Interface-to-method links are labelled
`possible Go implementation (method set and exact signature)`. Structs embedding
interfaces may satisfy a contract, but an abstract embedded method is not emitted
as a concrete implementation body. Multiple structural matches are retained.

Detailed evidence is loaded through the ordinary binding cache. File identity,
size/checksum and decoded source validation apply equally to disk files and drafts.
Changing a signature, editing an embedding, closing a draft or reloading an index
cannot reuse a previous query's method set. Full indexing does not create or
serialize this evidence.

## Bounds and conservative cases

Each query is bounded to 16 source files, 8 MiB of source, 512 method-set entries
computed across types/modes/name filters, depth 16, 512 implementation candidates,
64 matches per contract and a 500 ms soft method-analysis deadline. Shared source
cache storage is also bounded. A native file parse cannot stop in the middle;
normal file-size limits still apply. Limits mark results incomplete rather than
confirming a partial interface contract. Explicit own methods can remain reliable
when an unavailable embedding cannot shadow them; affected promoted methods stay
unresolved.

Generic bodies, instantiated embedded types, type-set constraints, unknown external
type identities, structural anonymous types, complex factory/assignment flow and
ambiguous build-tag variants are not inferred. Control-header declarations are
kept conservative. Empty interfaces are excluded from implementation enumeration.
This change does not add Go to declared type-hierarchy queries.
