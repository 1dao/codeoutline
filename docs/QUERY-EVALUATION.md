# Query quality evaluation

Run from the repository root with the bundled runtime. Evaluation tools live under
`tools/`; they do not change the service, MCP tools, index format or project cache.

```powershell
New-Item -ItemType Directory -Force tmp/query-evaluation | Out-Null
.\bin\xnet.exe tests/lua/query_evaluation_spec.lua
.\bin\xnet.exe tools/evaluate-queries.lua ROOT=tests/evaluation/fixtures CASES=tests/evaluation/cases.json OUT=tmp/query-evaluation/native.json

$env:XSCAN_PURE_LUA = '1'
try {
    .\bin\xnet.exe tools/evaluate-queries.lua ROOT=tests/evaluation/fixtures CASES=tests/evaluation/cases.json OUT=tmp/query-evaluation/pure.json
} finally { Remove-Item Env:XSCAN_PURE_LUA }
```

The committed corpus has nine reviewed cases: direct local calls, module imports,
static table dispatch, parameter shadowing, reassigned registrations, unknown
keys, reverse callers and C function pointers. Each runs twice. A failed golden
assertion, missing query symbol, query deadline or incomplete expansion exits
nonzero. The evaluator's own tests check that wrong-file matches, incomplete
results and empty negative queries cannot produce a passing verdict.

Outputs are JSON and an adjacent `.json.md` report. Check `complete: true` before
using any report: partial JSON remains available if collection is interrupted.
Each report records source hashes, manifest hash, runtime query parse counts,
index statistics, selected scanner path, output size and elapsed query time.
Evidence snippets are checked before indexing, and evidence files must still
have the same hashes when evaluation finishes.

## Add a real-project corpus

Use the same JSON schema as `tests/evaluation/cases.json`, stored outside tracked
files when it contains private project information. `ROOT` is the project root;
all node/evidence paths are relative to it, with `/` separators.

- `query`: exact symbol or qualified name. Multiple matches are a union, as in
  the graph query API; use unique qualified names where possible.
- `mode`: `callers` or `callees`, one hop. Both use the same query-owned graph as
  MCP exploration/callers. This is a relationship-quality evaluation, not an
  end-to-end MCP transport or rendered-source evaluation. Configured custom
  dispatch rules are not loaded by this initial evaluator.
- `expected`: manually verified relationships that must exist.
- `forbidden`: manually verified relationships that must not exist.
- Nodes use `file` and bare `name`, plus optional definition `line` for overloads
  or repeated anonymous member declarations. Qualified names are also recorded
  in CodeOutline output but are not matched across engines, whose naming differs.
- `exhaustive: true`: the expected list is complete; additional nodes fail.
  Omit it for partial real-world assertions. Extra nodes are then **unjudged**,
  not false positives. Do not infer a precision score from partial labels.
- `evidence`: nonempty `{ "file": "...", "contains": "literal source snippet" }`
  entries supporting the expected or forbidden relationship. Review registration,
  invocation and binding scope, not just the function name. Snippets guard
  against obvious source drift; review hashes when reusing historical results.

For example, a dispatch case should include both the registration and the call
site in its evidence. Do not generate golden expectations from either engine:
that would hide their mistakes. Keep known gaps as failing cases, and explain
them instead of weakening the assertions to make a benchmark pass.

## Compare with an existing CodeGraph index

The optional PowerShell 7.2+ collector uses the installed CodeGraph CLI. It never
initializes, rebuilds or upgrades an index. It requires `.codegraph` at `ROOT`.
Creating or refreshing that index is a separate explicit user decision.

```powershell
.\tools\compare-codegraph.ps1 -Root C:/src/project -Cases tmp/project-cases.json -Out tmp/query-evaluation/codegraph.json
.\bin\xnet.exe tools/evaluate-queries.lua ROOT=C:/src/project CASES=tmp/project-cases.json CODEGRAPH=tmp/query-evaluation/codegraph.json OUT=tmp/query-evaluation/comparison.json
```

Use the identical manifest and source snapshot for both runs. The evaluator
rejects mismatched manifest hashes, project roots and evidence-file hashes.
CodeGraph version, status, stderr and raw JSON are preserved. An older-index
warning remains visible: matching current source hashes does **not** establish
that CodeGraph indexed those bytes. Refresh and repeat before interpreting a
disagreement as an engine-quality difference.

The collector checks exact query matches, flags ambiguous roots and treats a
list at the configured limit as incomplete. Errors and timeouts are recorded
explicitly, never treated as empty passing results. Negative cases cannot pass
when the root symbol was not found. CodeGraph failures do not change CodeOutline's
exit status; inspect their separate verdicts.

CodeGraph CLI wall time includes a fresh process for each command. CodeOutline
timing covers only in-process graph queries, excluding indexing. They are **not
comparable speed measurements**. Likewise, CodeOutline output bytes measure its
normalized node JSON, while CodeGraph bytes measure its raw CLI JSON. Use these
metrics for repeated runs of the same engine, not a cross-engine size contest.
Round 1 is first access in the evaluation process, not cold disk. Round 2 does
not promise retention of query-owned caches. Run multiple alternating trials
before drawing performance conclusions.
