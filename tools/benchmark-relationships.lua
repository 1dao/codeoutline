-- Reproducible symbol-table and query-time relationship check; does not write
-- project files or the index cache.
-- bin/xnet tools/benchmark-relationships.lua ROOT=C:/src/project QUERIES=90 UPDATES=300
package.path = 'scripts/?.lua;' .. package.path
local index = require('codeoutline.index')
local graph = require('codeoutline.graph')
local explore = require('codeoutline.explore')
local text = require('codeoutline.text')
local control = require('codeoutline.control')
local options = {}
for _, value in ipairs(arg or {}) do
    local key, item = value:match('^([A-Z_]+)=(.*)$')
    if key then options[key] = item end
end
local function clock() return os.clock() * 1000 end
local function memory() collectgarbage('collect'); return collectgarbage('count') / 1024 end
local function report(label, fields)
    print(label .. ' ' .. xutils.json_pack(fields)); io.stdout:flush()
end
local function percentiles(list)
    table.sort(list)
    return { p50 = list[math.ceil(#list * .5)], p90 = list[math.ceil(#list * .9)],
        p99 = list[math.ceil(#list * .99)], max = list[#list] }
end
local started = clock()
local idx = index.open(assert(options.ROOT, 'ROOT required'))
-- Measurements must not replace the user's cache.
idx.save = function() return true end
local loaded = clock() - started
started = clock(); idx:refresh()
report('index', { load_ms = loaded, refresh_ms = clock() - started, cache_loaded = idx.cache_loaded })
local base = memory()
started = clock(); local G = idx:symbols()
report('symbols_build', { ms = clock() - started, mib = memory() - base, files = G.file_count, nodes = G.node_count })

-- Per-file commits: replace a sample of records with themselves (remove + add).
local rels = {}
for _, f in ipairs(G.file_order) do rels[#rels + 1] = G.files[f].path end
local updates, timings, largest = tonumber(options.UPDATES) or 300, {}, { nodes = 0 }
for i = 1, math.min(updates, #rels) do
    local rel = rels[1 + math.floor((#rels - 1) * (i - 1) / math.max(updates - 1, 1))]
    local rec = idx.files[rel]
    local t = clock()
    idx:commit(rel, rec)
    local ms = clock() - t
    timings[#timings + 1] = ms
    if #rec.nodes > largest.nodes then largest = { nodes = #rec.nodes, ms = ms, path = rel } end
end
assert(idx.symbol_tables == G, 'a commit dropped the symbol tables')
local longest = 0
for _, list in pairs(G.by_name) do longest = math.max(longest, #list) end
report('file_commits', { count = #timings, ms = percentiles(timings), largest = largest, longest_name_list = longest })
started = clock()
local fresh = graph.build(idx)
assert(fresh.node_count == G.node_count and fresh.file_count == G.file_count, 'count mismatch')
for _, name in ipairs({ 'by_name', 'by_lname', 'by_qualified' }) do
    for key, list in pairs(fresh[name]) do
        local mine = G[name][key]
        assert(mine and #mine == #list, name .. ' size mismatch: ' .. key)
        for i, id in ipairs(list) do
            local a, b = mine[i], id
            assert(G.files[G.node_file[a]].path == fresh.files[fresh.node_file[b]].path
                and a - G.id_of[G.node_file[a]][1] == b - fresh.id_of[fresh.node_file[b]][1], name .. ' order mismatch: ' .. key)
        end
    end
end
report('commit_parity', { ms = clock() - started })
fresh = nil; memory()

local queries, count, candidates = {}, tonumber(options.QUERIES) or 90, {}
for _, f in ipairs(G.file_order) do
    for n, node in ipairs(G.files[f].nodes) do
        if (node.kind == 'function' or node.kind == 'method' or node.kind == 'constructor')
            and #node.name >= 4 and #G.by_name[node.name] <= 3
            and node.name:match('^[%a_][%w_]*$') and text.valid(node.qualified) == node.qualified then
            candidates[#candidates + 1] = G.id_of[f][n]
        end
    end
end
assert(#candidates > 0, 'no callable query candidates')
for i = 1, count do
    local n = 1 + math.floor((#candidates - 1) * (i - 1) / count)
    local query = G.nodes[candidates[n]].qualified
    if i % 2 == 0 then query = query .. ' ' .. G.nodes[candidates[math.min(n + 1, #candidates)]].qualified end
    queries[#queries + 1] = query
end
report('query_sample', { count = #queries, candidates = #candidates, kind = 'callable names with at most three definitions' })
local function run(query)
    idx.query_sources = {}
    local deadline = clock() + 10000
    control.callback = function() if clock() > deadline then error(control.deadline(), 0) end end
    local ok, output, info = pcall(function()
        while true do
            local result, details = explore.run(idx:symbols(), idx, query)
            if not details.encoding_retry then return result, details end
        end
    end)
    control.callback, idx.query_sources = nil, nil
    assert(ok, 'query failed: ' .. query .. ': ' .. tostring(output))
    return output, info
end
-- Confirm selected encodings outside measured queries.
for _, query in ipairs(queries) do run(query) end
local ms, scans, expanded = {}, 0, 0
for _, query in ipairs(queries) do
    local t = clock()
    local _, info = run(query)
    ms[#ms + 1] = clock() - t
    assert(not info.relationships_incomplete, 'expansion limit reached: ' .. query)
    if info.query_stats then
        scans = scans + info.query_stats.incoming_scans
        expanded = expanded + info.query_stats.expanded
    end
end
report('queries', { count = #queries, ms = percentiles(ms), incoming_scans = scans, expanded = expanded })
idx:close()
return { __init = function() xthread.stop(0) end, __thread_handle = function() end }
