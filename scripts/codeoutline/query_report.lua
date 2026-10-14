-- Bounded, query-owned explanations; never stored on index records.
local M = {}

function M.new(limit)
    local report = { entries = {}, truncated = false, scope = 'indexed references and configured dispatch rules' }
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

function M.render(report, G)
    local lines = { '\n## Relationship evidence / unresolved references',
        'Scope: indexed references and configured dispatch rules; unresolved does not mean no runtime call.' }
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
