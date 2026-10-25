# Shared EventEmitter queries

JavaScript and TypeScript queries can follow a Node EventEmitter shared through
ES module imports and exports. The receiver must resolve to one module-level
`const` initialized by an unshadowed, explicitly imported Node EventEmitter
with empty constructor arguments.
Event names alone never establish a shared bus identity.

```typescript
// bus.ts
import { EventEmitter } from 'node:events';
export const bus = new EventEmitter();

// subscribe.ts
import { bus } from './bus';
export function handled() {}
bus.on('saved', handled);

// publish.ts
import { bus } from './bus';
export function publish() { bus.emit('saved'); }
```

Explore, callers and changed-file impact can follow the possible delivery from
`publish` to `handled`. Evidence includes the registration file and line. F12 on
the `'saved'` literal in `emit` can navigate to the handler definition. Ordinary
identifier definitions retain their existing resolution path.

Named/default imports, renamed imports, simple local aliases of imported buses,
named/star re-exports and imported handlers reuse existing module/workspace
resolution and lexical validation. Different exported emitter instances remain
separate even when event names match. Registration must be at module scope and
use `on`, `once` or `addListener` with a literal event and a named handler.
Registration and emission use direct statement calls in this first version.
Only cross-file deliveries are added; the existing closed same-file emitter
analysis retains its own behavior and ordering rules.

## Indexing and query costs

Normal parsing reuses the existing unique `dispatch_calls` names and ES import
records to retain one sparse integer `event_roles` per candidate file: emission,
registration, listener removal, or a Node events import. There is no source
rescan, object-identity analysis or event-edge synthesis during indexing. Files
without these roles receive no additional field. Existing call/reference
locations remain the site index. The parser checksum invalidates old caches once.

Queries first check role bits and indexed call sites. They then parse only the
relevant module/import closure, through the existing source-validated ordinary
binding cache. Compact identity/site evidence, derived links and lookup caches
belong to that query and are never serialized or attached to resident records.
No additional analysis thread or persistent event graph is introduced.

The shared analysis is limited to 32 parsed files, 2 MiB of source, 256 KiB per
file, 512 combined entity/site records, 64 delivery edges, import depth 8 and a
200 ms cooperative analysis budget. Parsing a single file is not preempted by
that soft deadline. Exhausted or incomplete discovery does not confirm a partial
bus mapping; query results report incomplete coverage. Normal index loading,
symbol preparation and other query work have their own costs and bounds.

## Conservative cases

This first version does not implement general observer fields or shared callback
arrays, arbitrary object/data flow, CommonJS/custom emitters, namespace bus access,
typed/mutable bus initializers, inline anonymous handlers, dynamic/symbol event
keys, chained APIs or registration inside setup functions. Unsupported anonymous
scopes prevent analysis of that file. Shadowed receivers and constructors stay
unresolved. Reassigned bindings cannot supply a receiver. Listener removal or
escape identified on a resolved receiver in analyzed candidate consumers prevents
pairing that bus.

The analysis does not inspect every non-event consumer for arbitrary runtime
effects, execute module initialization, model listener lifetime/`once` consumption,
or prove that a conditional registration runs. Edges are possible static
deliveries, not proof of execution. Missing edges are not proof of no listeners.
Source changes, drafts, module resolution changes and index reloads use fresh
query contexts; stale source snapshots fail validation.
