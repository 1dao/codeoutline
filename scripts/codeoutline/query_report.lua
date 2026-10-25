-- Bounded, query-owned explanations; never stored on index records.
local M = { MAX_PATH_BREAKPOINTS = 4 }
function M.edge_label(kind)
    if kind == 'ref' then return 'ref' end
    if kind == 'implementation' then return 'possible implementation' end
    if kind == 'automatic:event' then return 'possible event' end
    if kind == 'call' or kind == 'member_call' or kind == 'new' then return nil end
    return kind
end
local function renderer(G, initial)
    local lines, references, size = {}, {}, 0
    local function append(line, ids, registration)
        line = require('codeoutline.text').valid(line)
        local files, seen = {}, {}
        local function add(f) if f and not seen[f] then seen[f] = true; files[#files + 1] = f end end
        for _, id in ipairs(ids or {}) do add(G.node_file[id]) end
        if registration then add(G.file_index[registration:match('^(.*):%d+$') or '']) end
        if #files > 0 then references[#references + 1] = { at = size, files = files } end
        lines[#lines + 1] = line; size = size + #line + 1
    end
    for _, line in ipairs(initial) do append(line) end
    return append, function() return table.concat(lines, '\n'), references end
end

function M.new(limit)
    local report = { entries = {}, truncated = false, scope = 'indexed references, possible implementations, automatic callbacks and configured dispatch rules' }
    local seen = {}
    function report:add(entry)
        local key = table.concat({ entry.source or '', entry.target or '', entry.line or '',
            entry.kind or '', entry.reason or '', entry.rule or '', entry.call or '' }, ':')
        if seen[key] then return end
        if #self.entries >= (limit or 64) then self.truncated = true; return end
        seen[key] = true
        self.entries[#self.entries + 1] = entry
    end
    return report
end

-- Capture only evidence already produced by a failed BFS. The predecessor
-- table is not retained, and this never loads edges or parses another file.
function M.capture_paths(report, prev, root, via)
    local result = {}
    for _, entry in ipairs(report.entries) do
        if entry.reason and not entry.target and prev[entry.source] then
            local path, id = { entry.source }, entry.source
            while id ~= root do
                id = prev[id]
                table.insert(path, 1, id)
            end
            local hops = {}
            for i = 2, #path do hops[#hops + 1] = via and via[path[i]] or { kind = 'call' } end
            result[#result + 1] = { evidence = entry, path = path, hops = hops }
        end
    end
    return result
end

function M.path_breakpoints(report, G, searches, connected)
    local candidates = {}
    for _, search in ipairs(searches) do
        local goal
        for _, target in ipairs(search.targets) do
            -- A reverse path already explains how these two symbols connect.
            if not (connected[target] and connected[target][search.root]) then goal = target; break end
        end
        if goal or search.single then
            for _, site in ipairs(search.sites) do
                local e = site.evidence
                local priority = e.reason:find('dynamic', 1, true) and 3
                    or e.reason == 'no indexed target' and 1 or 2
                candidates[#candidates + 1] = { status = 'unresolved', from = search.root, goal = goal,
                    path = site.path, hops = site.hops, source = e.source, line = e.line, call = e.call, reason = e.reason,
                    rule = e.rule, argument = e.argument, evidence = e, priority = priority }
            end
            if search.limited or search.incomplete then
                candidates[#candidates + 1] = { status = 'search_limit', from = search.root, goal = goal,
                    path = { search.root }, reason = search.incomplete and 'relationship expansion limit reached'
                        or 'path depth/frontier limit reached', priority = 0 }
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        if #a.path ~= #b.path then return #a.path > #b.path end
        if a.from ~= b.from then return require('codeoutline.graph').before(G, a.from, b.from) end
        if (a.line or 0) ~= (b.line or 0) then return (a.line or 0) < (b.line or 0) end
        return (a.call or '') < (b.call or '')
    end)
    local result, seen = { entries = {}, truncated = report.truncated }, {}
    for _, entry in ipairs(candidates) do
        local key = entry.evidence and (entry.source .. ':' .. (entry.line or 0) .. ':' .. (entry.call or ''))
            or ('limit:' .. math.min(entry.from, entry.goal or entry.from)
                .. ':' .. math.max(entry.from, entry.goal or entry.from))
        if not seen[key] then
            seen[key] = true
            if #result.entries >= M.MAX_PATH_BREAKPOINTS then result.truncated = true
            else
                entry.evidence, entry.priority = nil, nil
                result.entries[#result.entries + 1] = entry
            end
        end
    end
    return result
end

function M.render_breakpoints(report, G)
    if #report.entries == 0 then return nil end
    local graph = require('codeoutline.graph')
    local function label(id) return G.nodes[id].qualified .. ' (' .. graph.where(G, id) .. ')' end
    local special = false
    for _, entry in ipairs(report.entries) do
        for _, hop in ipairs(entry.hops or {}) do if M.edge_label(hop.kind) then special = true end end
    end
    local append, finish = renderer(G, { special and '\n## Relationship-path breakpoints' or '\n## Call-path breakpoints',
        'Unresolved sites on explored indexed prefixes; these are not proven causes of disconnection.' })
    for _, entry in ipairs(report.entries) do
        local destination = entry.goal and (' toward ' .. label(entry.goal)) or ''
        if entry.status == 'search_limit' then
            append('- Search from ' .. label(entry.from) .. destination .. ': ' .. entry.reason
                .. '; continuation was not checked completely.', { entry.from, entry.goal })
        else
            local path = {}
            for i, id in ipairs(entry.path) do
                if i > 1 then
                    local hop = entry.hops and entry.hops[i - 1]
                    local kind = M.edge_label(hop and hop.kind or 'call')
                    path[#path + 1] = kind and (' -[' .. kind .. ']-> ') or ' -> '
                end
                path[#path + 1] = label(id)
            end
            local file = G.files[G.node_file[entry.source]].path
            local reason = entry.reason
            if entry.rule then reason = reason .. string.format(' (rule #%d, argument %d)', entry.rule, entry.argument) end
            local ids = {}; for _, id in ipairs(entry.path) do ids[#ids + 1] = id end
            ids[#ids + 1] = entry.source
            if entry.goal then ids[#ids + 1] = entry.goal end
            append(string.format('- %s; unresolved at %s:%d via %s: %s; continuation%s is unverified.',
                table.concat(path), file, entry.line or 0, entry.call or '?', reason, destination), ids)
        end
    end
    if report.truncated then append('Additional sites or relationship evidence were omitted.') end
    return finish()
end

function M.render(report, G)
    local append, finish = renderer(G, { '\n## Relationship evidence / unresolved references',
        'Scope: indexed references, possible implementations and configured dispatch rules; unresolved does not mean no runtime call.' })
    for _, e in ipairs(report.entries) do
        local source = G.nodes[e.source]
        local path = source and G.files[G.node_file[e.source]].path or '?'
        local target = e.target and G.nodes[e.target].qualified
        local detail = e.reason or e.kind
        if e.call then detail = detail .. ' via ' .. e.call end
        if e.rule then detail = detail .. ' (rule #' .. e.rule .. ', argument ' .. e.argument .. ')' end
        if e.registered_at then detail = detail .. '; registered at ' .. e.registered_at end
        append(string.format('- %s:%d %s%s: %s', path, e.line or 0,
            source and source.qualified or '?', target and ' -> ' .. target or '', detail), { e.source, e.target }, e.registered_at)
    end
    if report.truncated then append('Evidence limit reached; additional explanations omitted.') end
    return finish()
end

return M
