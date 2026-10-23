# Project macro visibility

C/C++ bare calls whose name also has an indexed macro declaration now check
query-time macro visibility before ordinary name matching. A definitely visible
function-like macro points to that macro's declaration; existing calls extracted
from the macro body remain available. An explicitly absent/undefined macro cannot
win ordinary function lookup. Unknown, recursive-wrapper or unsupported expansion
states do not guess a same-name function. Explore/callers preserve proven macro
hops. Definition navigation uses the same ordering, including unsaved files;
when build conditions are unknown, F12 can show the indexed macro declaration
sites that may apply. These are inspection targets, not proven execution edges.
Known-false branches, directives after the call and superseded definitions are
excluded. Incomplete directive walks do not invent navigation targets.
Macro-body dependencies retain their existing lookup: expansion happens at the
using call site, so their definition line is not treated as an execution context.

The query reads directives in translation-unit order up to the call line. It
follows indexed includes through the existing configured include search, processes
define/undef and pragma once, and tracks conventional leading ifndef/define
header guards. Guards start absent unless source directives established a state;
arbitrary compiler-defined guard overrides are not modeled. Include cycles stop
at the active file. Ambiguous include targets or dynamic include expressions
make macro state uncertain. External/unindexed headers are not interpreted.

Conditions support numeric literals, numeric source defines, defined/ifdef/ifndef,
parentheses, negation, && and || with three-valued logic. Unspecified build flags
and unsupported expressions stay unknown. Writes under unknown conditions poison
the affected macro identity. Object-like callable expansion, token pasting,
argument substitution, recursive wrappers and complete compiler preprocessing
are outside this subset. Member-qualified spellings are outside this first pass.
The normal parser's branch extraction policy remains
unchanged, so unavailable declarations are not invented by this pass.

Comments and string contents are not directives. A query-only mask handles C++
raw string bodies in the directive scan while preserving physical lines. This
does not claim to replace general C++ parsing or repair every raw-string shape
in the underlying parser.

Full/incremental indexing creates no directive summaries, macro timelines or
visibility graph. Existing macro symbols and references provide the cheap name
prefilter. Queries tokenize validated source and collect directive events without
building another syntax tree or unrelated receiver/implementation evidence.
Already available ordinary-binding summaries can be reused. Source validation
and unsaved overlays are shared with ordinary-binding queries.
The parser checksum invalidates older index caches once.
In-memory embeddings without a project source loader can provide the same
transient evidence with `parse.parse(path, source, { ordinary_bindings = true })`.

Per query, retained summaries are limited to 128 files, 8 MiB of source and an
estimated 1 MiB of directive evidence. A file has at most 4096 directives; walks
have at most 20,000 evaluated events across the query and depth 32; memoized call
checks are capped at 4096. Limits produce incomplete relationships and suppress
unproven macro links. Summaries contain names, conditions, flags and positions; full source, tokens
and visibility results never enter resident or disk records.
