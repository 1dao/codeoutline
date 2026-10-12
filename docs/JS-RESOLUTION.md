# JavaScript / TypeScript resolution

Explore and LSP call-site navigation use explicit ES module bindings before
name/locality scoring. No configuration is required for relative imports.

Supported module evidence:

- Named imports, including `import { save as persist } from './store'`.
- Default imports of named exported declarations, and namespace imports such as
  `import * as api from './store'; api.save()`.
- Local export lists, exported declarations, named re-exports, and `export *`.
  Re-export traversal is cycle-safe and limited to eight hops. Multiple reachable
  definitions remain candidates; resolution does not silently choose the first.
- Relative paths, extension/index lookup, and `.js` specifiers naming `.ts`/`.tsx`
  sources.
- Project-root `tsconfig.json`, `jsconfig.json`, or fallback `tsconfig.base.json`
  `compilerOptions.paths`. JSON comments/trailing commas and relative `extends`
  chains are supported. Targets are relative to `baseUrl`, or the configuration
  declaring `paths` when `baseUrl` is absent. Specific aliases precede wildcards;
  each replacement is tried in order. Aliases cannot escape the indexed root.

Configuration and resolution caches live for one query/request, so edits to
configuration take effect without reparsing source files. Import/export and
receiver metadata survive the disk cache; parser changes invalidate old caches.

For `const s = new Store(); s.save()` and `function run(s: Store) { s.save(); }`,
the resolver restricts the target to members of the selected `Store` declaration.
Imported type renames and namespace-qualified types are supported. Locally bound
unknown receivers, simple reassignment, and lexical shadowing suppress global
same-name guesses. Local named/arrow functions keep their own callable bindings.
An explicit import that cannot resolve, or a known type without the requested
method, produces no target instead of falling back to an unrelated definition.

This is bounded static evidence, not a compiler type checker. The current batch
does not model package `exports`, workspace packages, package-based `extends`,
per-directory tsconfig selection, CommonJS export bindings, anonymous default
exports, namespace re-exports, destructured receiver declarations, field chains,
inheritance, generics/unions, factory return types, or control-flow type narrowing.
Complex mutations and destructuring remain outside the supported inference
patterns. Other languages retain their existing resolver behavior. Missing edges
do not prove that code is unreachable.

LSP validation covers definitions, references, and unsaved target-file overlays
through the server API; it does not establish behavior in a running editor UI.
