-- Reproducible step-3 oracle/performance check; does not write project files/cache.
-- bin/xnet tools/benchmark-relationships.lua ROOT=C:/src/project QUERIES=90
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
local started = clock()
local idx = index.open(assert(options.ROOT, 'ROOT required'))
local loaded = clock() - started
started = clock(); idx:refresh()
report('index', { load_ms = loaded, refresh_ms = clock() - started, cache_loaded = idx.cache_loaded })
local base = memory()
started = clock(); local G = graph.build(idx)
report('eager_build', { ms = clock() - started, mib = memory() - base,
    files = #G.files, nodes = #G.nodes, edges = G.edge_count })
G = nil; base = memory()
started = clock(); G = graph.build(idx, { edges = false })
report('symbols_build', { ms = clock() - started, mib = memory() - base })
G = nil; memory(); G = graph.build(idx)
local ids = {}
for id = 1, #G.nodes do ids[#ids + 1] = id end
local lazy = graph.query(G, { max_expanded = #G.nodes + 1 })
started = clock()
lazy:load_incoming(ids)
for id = 1, #G.nodes do
    for _, direction in ipairs({ 'out', 'inn' }) do
        local a, b = G[direction][id] or {}, lazy[direction][id] or {}
        assert(#a == #b, direction .. ' count mismatch: ' .. graph.where(G, id))
        for i = 1, #a do assert(a[i] == b[i], direction .. ' edge mismatch: ' .. graph.where(G, id)) end
    end
    if id % 100000 == 0 then report('edge_progress', { nodes = id }) end
end
report('edge_parity', { nodes = #G.nodes, ms = clock() - started, scans = lazy.stats.incoming_scans })
lazy, ids = nil, nil; memory()
local queries, count, candidates = {}, tonumber(options.QUERIES) or 90, {}
for id, node in ipairs(G.nodes) do
    if (node.kind == 'function' or node.kind == 'method' or node.kind == 'constructor')
        and #node.name >= 4 and #G.by_name[node.name] <= 3
        and node.name:match('^[%a_][%w_]*$') and text.valid(node.qualified) == node.qualified then
        candidates[#candidates + 1] = id
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
local function run(query, mode)
    idx.query_sources = {}
    local deadline = clock() + 10000
    control.callback = function() if clock() > deadline then error(control.deadline(), 0) end end
    local ok, output, info = pcall(function()
        while true do
            local result, details = explore.run(G, idx, query, { relationships = mode })
            if not details.encoding_retry then return result, details end
            G = graph.build(idx)
        end
    end)
    control.callback, idx.query_sources = nil, nil
    assert(ok, mode .. ' query failed: ' .. query .. ': ' .. tostring(output))
    return output, info
end
-- Confirm selected encodings outside measured queries, then use identical records.
for i, query in ipairs(queries) do
    run(query, 'eager')
    if i % 15 == 0 then report('warmup_progress', { queries = i }) end
end
local timings = { eager = {}, lazy = {} }
local scans, expanded = 0, 0
for i, query in ipairs(queries) do
    local output = {}
    -- Alternate order to reduce filesystem-cache and GC ordering bias.
    for _, mode in ipairs(i % 2 == 0 and { 'lazy', 'eager' } or { 'eager', 'lazy' }) do
        local t = clock()
        local result, info = run(query, mode)
        timings[mode][#timings[mode] + 1] = clock() - t
        output[mode] = result
        assert(not info.relationships_incomplete, 'expansion limit reached: ' .. query)
        if info.query_stats then
            scans = scans + info.query_stats.incoming_scans
            expanded = expanded + info.query_stats.expanded
        end
    end
    assert(output.lazy == output.eager, 'explore output mismatch: ' .. query)
    if i % 15 == 0 then report('query_progress', { matched = i }) end
end
local function percentiles(list)
    table.sort(list)
    return { p50 = list[math.ceil(#list * .5)], p90 = list[math.ceil(#list * .9)], max = list[#list] }
end
report('query_parity', { matched = #queries, eager_ms = percentiles(timings.eager),
    lazy_ms = percentiles(timings.lazy), incoming_scans = scans, expanded = expanded })
idx:close()
return { __init = function() xthread.stop(0) end, __thread_handle = function() end }
