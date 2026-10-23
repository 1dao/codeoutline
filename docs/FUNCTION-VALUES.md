# Function values

Explore and callers retain `ref` dependencies for supported function values in
JavaScript, TypeScript, ArkTS and Python, and Java/Kotlin method references.
Passing a function to an API, assigning it, or placing it in a supported literal
is a reference dependency. It does not prove that the callback runs.

The collector accepts simple bare names and one receiver/member pair in explicit
value positions. Bare candidates must name a same-file callable, an explicit
import or a simple alias candidate. Import aliases, namespace members, lexical
shadowing and typed receivers reuse existing binding resolution. Java `::` and
existing Kotlin `::` sites reuse JVM declared-receiver/type lookup. Unknown and
chained receivers do not fall back to unrelated same-name methods. Targets are
restricted to functions and methods; constructors and ordinary variables are
not callback targets. Reference edges remain distinct from configured callback
or event delivery edges at the same statement.

This is a finite static subset, not general data flow: computed properties,
anonymous callback bodies without indexed identities, arbitrary returned
functions, reflection and general callable objects are not inferred. Complex
value expressions and language-specific wrappers may remain unresolved.
Files with unrepresented anonymous JS/TS/ArkTS function/arrow scopes or Python
lambdas skip the new collection pass: their parameters could otherwise borrow
an unrelated outer function identity. Existing ordinary calls are unchanged.
Kotlin reference extraction predates this feature; typed method-value resolution
is now shared with Java. C/C++ value references retain their existing behavior.

Full indexing retains compact name/kind/location/receiver sites, so reference
counts and cache size can grow. Detailed binding evidence is generated on demand
through the ordinary 16-file/about-8-MiB query cache, with source checksum and
node/reference identity validation. No callback execution graph or full lexical
binding graph is persisted. Parser checksums invalidate earlier index caches.
Confirming UTF-8/BOM source encoding keeps a resident hint and joins the next
normal cache save; it no longer forces a full cache rewrite during a query.
GBK repairs still commit corrected records and retain their persistence behavior.

Callers can now include variable or field initializers that retain a function,
in addition to callable users. Consumers must inspect `ref` versus call/delivery
edges before interpreting a result as execution flow.
