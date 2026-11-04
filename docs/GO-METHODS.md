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
  composite/new initializers supply receiver evidence. Direct functions and methods
  with indexed, ordinary result declarations also supply types, including individual
  slots in multiple-result assignments. Types retain their declaring package.
- Methods on direct call results, including `GetManager().IsChild()`, imported
  factories, parenthesized receivers and bounded method-call chains, reuse the
  same declared result types for navigation, agent edges and completion. Returned
  values are not implicitly addressable: calling a pointer method on a returned
  value requires an actual pointer result or an addressable local variable.
- `range` declarations infer channel elements, slice/array indices and elements,
  and map keys/values, including named collection types and simple local aliases.
  Loop variables are scoped to the loop body. Send-only channels, mismatched result
  counts, unresolved factories, field/index/assertion chains, local shadowing and unsupported syntax
  remain barriers. Dependency source must already be indexed in a supported local
  module; this does not download dependencies or read the global module cache.
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

## Agent framework paths

Explore, callers and impact queries also derive bounded framework relationships
from source through the same validated ordinary binding cache:

- `net/http.Handle`/`HandleFunc` and local `NewServeMux` registrations, including
  Go 1.22 `"METHOD /path"` patterns.
- Local Gin, Echo, Fiber and Chi router constructors; literal group prefixes;
  named local/imported functions and supported typed method values as handlers.
  Gin `Use`, group middleware and the indexed `Context.Next` handler-slice dispatcher connect to
  registered middleware/handlers as possible execution targets.
- Generated `*_grpc.pb.go` server assertions connect to server interface methods.
  Generated server-interface and `Unimplemented...Server` methods connect to
  matching handwritten methods only when the concrete type actually embeds that
  service's indexed generated stub. Parameter/result shapes must match, including
  package-qualified types; unavailable external names retain their import paths.

Paths use `possible:go-route METHOD /path`, `possible:go-middleware`,
`possible:go-gin middleware dispatch` and `possible:go-grpc ...` labels. Evidence
includes registration locations. These links do not establish execution order,
router-instance identity or an actual RPC across processes. Route registrations
are anchored to their enclosing function; no persistent route nodes are added.

Framework evidence is absent during compact indexing. Each framework query is
bounded to 64 parsed files, 8 MiB of source, 256 sites per collection, 512 emitted
links, 512 gRPC candidates, 4096 file-discovery visits and a 1500 ms soft deadline;
the shared Go method-analysis and source-cache limits also apply. Exhaustion
reports `go_framework_analysis_incomplete` (or the relevant shared-analysis reason).

Dynamic paths, inline closures, handler factories, routers passed through arbitrary
variables/parameters, computed registrations, Chi callback groups and full gRPC
client/server transport inference remain unsupported. Constructor reassignment,
import shadowing and out-of-scope router bindings are rejected. Gin dispatch
lists possible registrations across the indexed project, not one runtime engine.
Framework bridges are agent relationships, not new LSP definition targets.
