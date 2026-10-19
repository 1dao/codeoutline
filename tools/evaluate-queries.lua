-- Run from the repository root. No project cache is saved or modified.
-- bin/xnet tools/evaluate-queries.lua ROOT=... CASES=... OUT=tmp/evaluation.json
package.path = 'scripts/?.lua;tools/?.lua;' .. package.path
local eval = require('query-evaluation')
local index = require('codeoutline.index')
local graph = require('codeoutline.graph')
local paths = require('codeoutline.path')
local parser = require('codeoutline.parse')
local control = require('codeoutline.control')
local pool = require('codeoutline.parse_pool')
local options = {}
for _, arg in ipairs(arg or {}) do
    local k, v = arg:match('^([A-Z_]+)=(.*)$'); if k then options[k] = v end
end
local function read(path)
    local f = assert(io.open(path, 'rb')); local data = f:read('*a'); f:close(); return data
end
local function write(path, value)
    local f = assert(io.open(path, 'wb')); f:write(assert(xutils.json_pack(value))); f:close()
end
local idx, job, report, original_parse = nil, nil, nil, parser.parse
local function run()
    local out = assert(options.OUT, 'OUT required')
    -- Never leave an older successful report looking like this failed run.
    write(out, { schema = 1, complete = false, created_at = os.time() })
    local pending = assert(io.open(out .. '.md', 'wb'))
    pending:write('# Evaluation incomplete\n\nInspect the JSON and process exit status; no verdict is available for this run.\n')
    pending:close()
    local root = assert(paths.canonical(assert(options.ROOT, 'ROOT required')))
    local source = read(assert(options.CASES, 'CASES required'))
    local manifest = assert(xutils.json_unpack(source)); eval.validate(manifest)
    local timeout = tonumber(options.TIMEOUT_MS) or 30000
    assert(timeout > 0, 'TIMEOUT_MS must be positive')
    report = { schema = 1, engine = 'codeoutline', version = require('codeoutline.version'), root = root,
        runtime = _VERSION, created_at = os.time(), complete = false,
        manifest_sha256 = xutils.sha256_hex(source), scanner = require('codeoutline.xscan') == _G.xscan and 'native' or 'lua',
        threads = pool.THREADS, cases = {}, source_hashes = {}, passed = 0, failed = 0,
        timing_scope = 'query only, round 1 first access / round 2 same process; not cold disk; index excluded' }
    -- Check evidence before running. Changes invalidate the corpus rather than passing vacuously.
    for _, case in ipairs(manifest.cases) do
        for _, e in ipairs(case.evidence) do
            local bytes = read(root .. '/' .. e.file)
            assert(bytes:find(e.contains, 1, true), 'source evidence changed: ' .. case.id .. ' / ' .. e.file)
            report.source_hashes[e.file] = xutils.sha256_hex(bytes)
        end
    end
    local reference = options.CODEGRAPH and assert(xutils.json_unpack(read(options.CODEGRAPH)))
    if reference then
        assert(reference.complete == true, 'CodeGraph collection incomplete')
        assert(reference.manifest_sha256 == report.manifest_sha256, 'CodeGraph manifest mismatch')
        assert(paths.key(reference.root) == paths.key(root), 'CodeGraph project mismatch')
        for file, hash in pairs(report.source_hashes) do
            assert(reference.source_hashes and reference.source_hashes[file] == hash, 'CodeGraph source snapshot mismatch: ' .. file)
        end
        report.codegraph = reference
    end
    idx = index.open(root, { rebuild = true, cache_path = out .. '.unused-cache' })
    local t = xtimer.now_ms(); report.refresh = idx:refresh_all(); report.index_ms = xtimer.now_ms() - t
    assert(report.refresh.failed == 0, 'indexing errors invalidate evaluation')
    local G = idx:symbols(); pool.stop('evaluation index complete')
    report.files, report.symbols = G.file_count, G.node_count
    collectgarbage('collect'); report.resident_lua_kib = collectgarbage('count')
    for _, case in ipairs(manifest.cases) do
        local entry = { id = case.id, query = case.query, mode = case.mode, runs = {} }
        report.cases[#report.cases + 1] = entry
        for round = 1, 2 do
            local parses = 0
            parser.parse = function(...) parses = parses + 1; return original_parse(...) end
            idx.query_sources = {}
            local start = xtimer.now_ms()
            control.callback = function() if xtimer.now_ms() - start > timeout then error('evaluation query deadline', 0) end end
            local result = { round = round, nodes = {}, matched = 0 }
            local ok, err = pcall(function()
                local Q = graph.query(G)
                local ids = G.by_qualified[case.query] or G.by_name[case.query] or {}
                result.matched = #ids
                if case.mode == 'callers' then Q:load_incoming(ids) end
                local seen = {}
                for _, id in ipairs(ids) do
                    local edges = case.mode == 'callers' and Q.inn[id] or Q.out[id]
                    for i = 1, #(edges or {}), graph.EDGE do
                        local target = edges[i]
                        if not seen[target] then
                            seen[target] = true
                            local n = G.nodes[target]
                            result.nodes[#result.nodes + 1] = { name = n.name, qualified = n.qualified,
                                file = G.files[G.node_file[target]].path, line = n.line }
                        end
                    end
                end
                result.incomplete, result.query_stats = Q.incomplete, Q.stats
                table.sort(result.nodes, function(a,b) return a.file .. ':' .. a.name .. ':' .. a.line < b.file .. ':' .. b.name .. ':' .. b.line end)
            end)
            result.ms, result.parses = xtimer.now_ms() - start, parses
            control.callback, idx.query_sources, parser.parse = nil, nil, original_parse
            if not ok then result.error = tostring(err) end
            result.output_bytes = #assert(xutils.json_pack(result.nodes))
            result.score = eval.score(case, result)
            entry.runs[#entry.runs + 1] = result
            if result.score.pass then report.passed = report.passed + 1 else report.failed = report.failed + 1 end
        end
        if reference then
            for _, ref in ipairs(reference.cases or {}) do
                if ref.id == case.id then
                    entry.codegraph = ref
                    for _, r in ipairs(ref.runs or {}) do r.score = eval.score(case, r) end
                end
            end
        end
        print(case.id .. ': ' .. (entry.runs[1].score.pass and entry.runs[2].score.pass and 'PASS' or 'FAIL'))
        write(out, report)
    end
    -- Evidence hashes also guard against edits during the measurement.
    for file, hash in pairs(report.source_hashes) do
        assert(xutils.sha256_hex(read(root .. '/' .. file)) == hash, 'source changed during evaluation: ' .. file)
    end
    local md = assert(io.open(out .. '.md', 'wb')); md:write(eval.markdown(report)); md:close()
    report.complete = true; write(out, report)
    print(string.format('Query evaluation: %d passed, %d failed; %s', report.passed, report.failed, out))
end
local function resume(...)
    local ok, err = coroutine.resume(job, ...)
    if not ok then
        control.callback, parser.parse = nil, original_parse
        if report then report.complete, report.error = false, tostring(err); pcall(write, options.OUT, report) end
        io.stderr:write(tostring(err), '\n'); pool.bind(nil); pool.stop(); if idx then idx:close() end; xthread.stop(1)
    elseif coroutine.status(job) == 'dead' then
        pool.bind(nil); pool.stop(); if idx then idx:close() end; xthread.stop(report.failed == 0 and 0 or 1)
    end
end
return {
    __init = function()
        assert(xnet.init()); assert(xshared.create('codeoutline_control', 65536, 256))
        pool.configure(assert(xutils.realpath('scripts/codeoutline/parse_worker.lua')), pool.THREADS)
        job = coroutine.create(run); pool.bind(job); resume()
    end,
    __thread_handle = function(_, op, token, results, failure)
        if op == 'parsed' and pool.receive(token) and pool.waiting() then resume(token, results, failure) end
    end,
    __uninit = function() pool.stop(); xnet.uninit() end,
}
