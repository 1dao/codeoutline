-- Reverse BFS over query-owned relationships. No persistent impact graph.
local graph = require('codeoutline.graph')
local control = require('codeoutline.control')
local text = require('codeoutline.text')
local M = {}

function M.validate(query, opts)
    require('codeoutline.explore').validate(query, opts)
    opts = opts or {}
    for _, item in ipairs({ { 'depth', 3, 8 }, { 'max_nodes', 200, 2000 } }) do
        local value = opts[item[1]]
        if value == nil then value = item[2] end
        assert(type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= item[3],
            item[1] .. ' must be an integer between 1 and ' .. item[3])
    end
end

function M.run(symbols, idx, query, opts)
    M.validate(query, opts)
    opts = opts or {}
    local depth, cap = opts.depth or 3, opts.max_nodes or 200
    local budget = require('codeoutline.explore').validate(query, opts)
    local Q = graph.query(symbols, opts)
    local result = { targets = {}, callers = {}, files = {}, depth = depth,
        node_limit_reached = false, depth_limit_reached = false }
    local function describe(id)
        return { id = id, name = Q.nodes[id].qualified, file = Q.files[Q.node_file[id]].path, line = Q.nodes[id].line }
    end
    local candidates = symbols.by_qualified[query] or symbols.by_name[query] or {}
    local ordered = {}
    for _, id in ipairs(candidates) do ordered[#ordered + 1] = id end
    table.sort(ordered, function(a, b) return graph.before(Q, a, b) end)
    local frontier, seen, next_hop = {}, {}, {}
    for _, id in ipairs(ordered) do
        if #frontier >= cap then result.node_limit_reached = true; break end
        frontier[#frontier + 1] = id; seen[id] = true
        result.targets[#result.targets + 1] = describe(id)
    end
    local files = {}
    for level = 1, depth do
        if #frontier == 0 then break end
        control.check()
        Q:load_incoming(frontier) -- one project reference scan per layer
        local pending, links = {}, {}
        for _, dst in ipairs(frontier) do
            local edges = Q.inn[dst] or {}
            for i = 1, #edges, graph.EDGE do
                if i % 384 == 1 then control.check() end
                local src = edges[i]
                if not seen[src] and not links[src] then
                    links[src] = { target = dst, line = edges[i + 1], kind = edges[i + 2] }
                    pending[#pending + 1] = src
                end
            end
        end
        table.sort(pending, function(a, b) return graph.before(Q, a, b) end)
        frontier = {}
        for _, src in ipairs(pending) do
            if #result.callers >= cap then result.node_limit_reached = true; break end
            seen[src], next_hop[src] = true, links[src]
            frontier[#frontier + 1] = src
            local entry = describe(src)
            entry.depth, entry.path = level, {}
            local current = src
            while next_hop[current] do
                local hop = describe(current)
                local edge = next_hop[current]
                hop.call_line, hop.kind = edge.line, edge.kind
                entry.path[#entry.path + 1] = hop
                current = edge.target
            end
            entry.path[#entry.path + 1] = describe(current)
            result.callers[#result.callers + 1] = entry
            files[entry.file] = true
        end
        if level == depth and #frontier > 0 then result.depth_limit_reached = true end
        if result.node_limit_reached then break end
    end
    for file in pairs(files) do result.files[#result.files + 1] = file end
    table.sort(result.files)
    -- Source validation may repair encodings and invalidate IDs: retry the query.
    local paths = {}
    for _, target in ipairs(result.targets) do paths[target.file] = true end
    for _, file in ipairs(result.files) do paths[file] = true end
    local changed = false
    for path in pairs(paths) do
        local source, repaired = idx:query_source(path)
        assert(source, 'cannot read source: ' .. path)
        changed = changed or repaired
    end
    if changed then return nil, { encoding_retry = true } end
    local lines = { string.format('Matched %d target(s); %d potential callers in %d files, searched up to %d levels.',
        #result.targets, #result.callers, #result.files, depth),
        'Static potential impact; each caller has one shortest path. This is not proof of runtime execution or complete impact coverage.' }
    if #result.targets == 0 then lines[#lines + 1] = 'No exact symbol matched; use a symbol name or qualified name.' end
    if #result.targets > 1 then lines[#lines + 1] = 'Multiple definitions matched; results cover the listed targets.' end
    if result.node_limit_reached then lines[#lines + 1] = 'Node limit reached; targets or callers were omitted.' end
    if result.depth_limit_reached then lines[#lines + 1] = 'Depth limit reached; callers beyond this depth were not checked.' end
    result.relationships_incomplete = Q.incomplete or false
    if result.relationships_incomplete then lines[#lines + 1] = 'Relationship candidate limit reached; some potential relationships were omitted.' end
    for _, target in ipairs(result.targets) do
        lines[#lines + 1] = string.format('Target: %s (%s:%d)', target.name, target.file, target.line)
    end
    for _, entry in ipairs(result.callers) do
        local path = {}
        for _, hop in ipairs(entry.path) do
            path[#path + 1] = string.format('%s (%s:%d)%s', hop.name, hop.file, hop.call_line or hop.line,
                hop.kind and ' [' .. hop.kind .. ']' or '')
        end
        lines[#lines + 1] = string.format('Depth %d: %s', entry.depth, table.concat(path, ' -> '))
    end
    if #result.files > 0 then lines[#lines + 1] = 'Affected caller files:\n' .. table.concat(result.files, '\n') end
    local output, cut = text.limit(table.concat(lines, '\n'), budget, result.node_limit_reached or result.relationships_incomplete)
    result.truncated, result.query_stats = cut, Q.stats
    return output, result
end

return M
