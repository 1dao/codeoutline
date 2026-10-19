-- Golden assertions are independent of either engine's output.
local M = {}

function M.matches(actual, expected)
    return actual.file == expected.file and actual.name == expected.name
        and (not expected.line or actual.line == expected.line)
end

function M.score(case, run)
    local result = { missing = {}, forbidden = {}, unjudged = {}, unexpected = {} }
    local function contains(rows, needle)
        for _, row in ipairs(rows) do if M.matches(row, needle) then return true end end
        return false
    end
    for _, expected in ipairs(case.expected) do
        if not contains(run.nodes or {}, expected) then result.missing[#result.missing + 1] = expected end
    end
    for _, forbidden in ipairs(case.forbidden) do
        if contains(run.nodes or {}, forbidden) then result.forbidden[#result.forbidden + 1] = forbidden end
    end
    for _, actual in ipairs(run.nodes or {}) do
        local known = false
        for _, expected in ipairs(case.expected) do if M.matches(actual, expected) then known = true; break end end
        if not known then
            local bucket = case.exhaustive and result.unexpected or result.unjudged
            bucket[#bucket + 1] = actual
        end
    end
    result.recall = #case.expected > 0 and (#case.expected - #result.missing) / #case.expected or nil
    result.pass = not run.error and not run.incomplete and run.matched > 0
        and #result.missing == 0 and #result.forbidden == 0 and #result.unexpected == 0
    result.status = run.error and 'ERROR' or run.incomplete and 'INCOMPLETE'
        or run.matched == 0 and 'UNMATCHED' or result.pass and 'PASS' or 'FAIL'
    return result
end

function M.validate(manifest)
    assert(manifest.schema == 1 and type(manifest.cases) == 'table' and #manifest.cases > 0, 'invalid evaluation manifest')
    local ids = {}
    local function node(n)
        assert(type(n.file) == 'string' and n.file ~= '' and not n.file:find('\\')
            and not n.file:find(':') and n.file:sub(1, 1) ~= '/' and not n.file:match('%.%.'), 'relative file required')
        assert(type(n.name) == 'string' and n.name ~= '', 'node name required')
        assert(not n.line or type(n.line) == 'number' and n.line > 0 and n.line % 1 == 0, 'invalid node line')
    end
    for _, case in ipairs(manifest.cases) do
        assert(type(case.id) == 'string' and not ids[case.id], 'unique case id required'); ids[case.id] = true
        assert(case.mode == 'callees' or case.mode == 'callers', 'mode must be callers or callees')
        assert(type(case.query) == 'string' and case.query ~= '', 'query required')
        assert(type(case.expected) == 'table' and type(case.forbidden) == 'table', 'expected/forbidden arrays required')
        assert(#case.expected + #case.forbidden > 0 or case.exhaustive == true, 'case has no assertions')
        for _, n in ipairs(case.expected) do node(n) end
        for _, n in ipairs(case.forbidden) do node(n) end
        assert(type(case.evidence) == 'table' and #case.evidence > 0, 'source evidence required')
        for _, e in ipairs(case.evidence) do
            node({file = e.file, name = 'evidence'})
            assert(type(e.contains) == 'string' and e.contains ~= '', 'source evidence must contain a literal snippet')
        end
    end
end

function M.markdown(report)
    local lines = { '# Query quality evaluation', '',
        'Golden assertions are manually reviewed source facts; CodeGraph is a comparison, not an oracle.', '',
        string.format('CodeOutline: %d passed / %d failed runs. %d cases, two rounds each.', report.passed, report.failed, #report.cases),
        'Timing excludes indexing. Round 1 is first access in this process; round 2 reuses the process, not necessarily query-local caches.',
        'Node counts are one-hop potential relationships, not proof of runtime execution.', '',
        '| Case | Round | Verdict | Missing | Forbidden | Unexpected | Unjudged | ms | Parses | Output bytes |',
        '|---|---:|---|---:|---:|---:|---:|---:|---:|---:|' }
    local function safe(s) return tostring(s):gsub('[\r\n|]', ' ') end
    for _, case in ipairs(report.cases) do
        for _, run in ipairs(case.runs) do
            local s = run.score
            lines[#lines + 1] = string.format('| %s | %d | %s | %d | %d | %d | %d | %.2f | %d | %d |',
                safe(case.id), run.round, s.pass and 'PASS' or 'FAIL', #s.missing, #s.forbidden,
                #s.unexpected, #s.unjudged, run.ms, run.parses, run.output_bytes)
        end
    end
    if report.codegraph then
        lines[#lines + 1] = '\n## CodeGraph comparison\n'
        lines[#lines + 1] = 'Existing index only. CLI latency includes process startup and must not be compared directly to CodeOutline query latency. Ambiguous roots, errors and capped results cannot support a complete verdict.'
        lines[#lines + 1] = '\n| Case | Round | Verdict | Missing | Forbidden | Unexpected | Unjudged | CLI ms |'
        lines[#lines + 1] = '|---|---:|---|---:|---:|---:|---:|---:|'
        for _, case in ipairs(report.cases) do
            for _, run in ipairs(case.codegraph and case.codegraph.runs or {}) do
                local s = run.score
                local verdict = s.status
                lines[#lines + 1] = string.format('| %s | %d | %s | %d | %d | %d | %d | %.2f |',
                    safe(case.id), run.round, verdict, #s.missing, #s.forbidden, #s.unexpected, #s.unjudged, run.ms or 0)
            end
        end
        lines[#lines + 1] = '\nCodeGraph status (captured before queries):\n\n```text\n'
            .. tostring(report.codegraph.status and report.codegraph.status.stdout or 'unavailable'):gsub('```', '') .. '\n```'
    end
    lines[#lines + 1] = '\nSee the adjacent JSON for source hashes, individual nodes, errors, query statistics and raw CodeGraph output.'
    return table.concat(lines, '\n') .. '\n'
end

return M
