-- Bounded, query-owned explanations; never stored on index records.
local M = { MAX_PATH_BREAKPOINTS = 4 }

function M.new(limit)
    local report = { entries = {}, truncated = false, scope = 'indexed references, possible implementations/events and configured dispatch rules' }
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
function M.capture_paths(report, prev, root)
    local result = {}
    for _, entry in ipairs(report.entries) do
        if entry.reason and not entry.target and prev[entry.source] then
            local path, id = { entry.source }, entry.source
            while id ~= root do
                id = prev[id]
                table.insert(path, 1, id)
            end
            result[#result + 1] = { evidence = entry, path = path }
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
                    path = site.path, source = e.source, line = e.line, call = e.call, reason = e.reason,
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
    local lines = { '\n## Call-path breakpoints',
        'Unresolved sites on explored indexed prefixes; these are not proven causes of disconnection.' }
    for _, entry in ipairs(report.entries) do
        local destination = entry.goal and (' toward ' .. label(entry.goal)) or ''
        if entry.status == 'search_limit' then
            lines[#lines + 1] = '- Search from ' .. label(entry.from) .. destination .. ': ' .. entry.reason
                .. '; continuation was not checked completely.'
        else
            local path = {}
            for _, id in ipairs(entry.path) do path[#path + 1] = label(id) end
            local file = G.files[G.node_file[entry.source]].path
            local reason = entry.reason
            if entry.rule then reason = reason .. string.format(' (rule #%d, argument %d)', entry.rule, entry.argument) end
            lines[#lines + 1] = string.format('- %s; unresolved at %s:%d via %s: %s; continuation%s is unverified.',
                table.concat(path, ' -> '), file, entry.line or 0, entry.call or '?', reason, destination)
        end
    end
    if report.truncated then lines[#lines + 1] = 'Additional sites or relationship evidence were omitted.' end
    return table.concat(lines, '\n')
end

function M.render(report, G)
    local lines = { '\n## Relationship evidence / unresolved references',
        'Scope: indexed references, possible implementations and configured dispatch rules; unresolved does not mean no runtime call.' }
    for _, e in ipairs(report.entries) do
        local source = G.nodes[e.source]
        local path = source and G.files[G.node_file[e.source]].path or '?'
        local target = e.target and G.nodes[e.target].qualified
        local detail = e.reason or e.kind
        if e.call then detail = detail .. ' via ' .. e.call end
        if e.rule then detail = detail .. ' (rule #' .. e.rule .. ', argument ' .. e.argument .. ')' end
        if e.registered_at then detail = detail .. '; registered at ' .. e.registered_at end
        lines[#lines + 1] = string.format('- %s:%d %s%s: %s', path, e.line or 0,
            source and source.qualified or '?', target and ' -> ' .. target or '', detail)
    end
    if report.truncated then lines[#lines + 1] = 'Evidence limit reached; additional explanations omitted.' end
    return table.concat(lines, '\n')
end

return M
