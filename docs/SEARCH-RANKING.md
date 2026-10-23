# Project search ranking

`explore` can prefer business definitions over generated or third-party code.
Add project-relative directory prefixes to the existing `.codeoutline.json`:

```json
{
  "deprioritize": ["generated/", "third_party/", "services/payments/vendor/"]
}
```

Matching files stay indexed and searchable. A match subtracts six points from
the normal starting-symbol score; overlapping prefixes do not stack. This
affects ambiguous short names, fuzzy matches and filters-only searches. A unique
symbol still matches even when its directory has a penalty.

These are literal, case-sensitive directory prefixes relative to the project
root, not globs, regexes, basename matches or `.gitignore` patterns. `generated/`
matches `generated/a.lua` and its subdirectories, but not `generated_extra/a.lua`
or `apps/generated/a.lua`. List nested directories explicitly. Backslashes,
repeated separators, `.` components and an omitted trailing slash normalize to
the same prefix. Spaces and Lua pattern characters are literal. Absolute paths,
parent traversal, wildcard characters `*`/`?`, NUL and line breaks are rejected.
At most 32 entries of 1,024 UTF-8 bytes each are accepted; the existing 64 KiB
project-config size limit also applies.

If the field is omitted, the existing built-in vendor/third-party directory
heuristics and their scores remain unchanged. An explicit array replaces those
defaults; include any vendor paths you still want demoted. An empty array turns
off directory penalties:

```json
{"deprioritize": []}
```

Explicitly named files retain their normal outline/source output. Explicitly
qualified symbols (including the existing `module.function` lookup) bypass
configured penalties. `path:` filters continue to select matching files,
including deprioritized ones. Existing query budgets and seed caps still apply;
a precise query is not a guarantee of unlimited output.

Filters-only queries fill their 512-candidate window from preferred files first,
then deprioritized files, before normal score ordering. The existing
`seed_limit_reached` notice still reports omitted matches. Fuzzy name matching
retains its existing candidate limit; ranking does not make that search
exhaustive.

Only explore starting-symbol selection changes. Call paths, supporting source,
callers, implementation links, type hierarchy and file-impact traversal do not
filter or penalize dependencies. In particular a Lua starting symbol can still
reach a native C export under a deprioritized directory. This is not an exclusion
setting and does not detect generated code by file contents.

The library, CLI and MCP read the same project config. Changes take effect on the
next explore request without rebuilding or reparsing source records. Each query
owns its policy and a file-path score cache; shared services do not reuse one
project's policy for another. Lua results expose policy counters through
`info.query_stats.ranking`. No ranking policy, source or derived graph is stored
in the persistent index. LSP workspace-symbol/completion ranking is unchanged.
