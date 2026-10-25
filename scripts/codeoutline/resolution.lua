-- Bounded diagnostics for reference sites actually examined by this query.
local M = { MAX_SITES = 512 }
function M.new()
    local result = { scope = 'examined_reference_sites', observed_sites = 0,
        unresolved_sites = 0, ambiguous_sites = 0, heuristic_matches = 0, counts_limited = false }
    local seen = {}
    local function record(file, reference, kind, targets, reason)
        if result.counts_limited or kind ~= 'call' and kind ~= 'member_call' then return end
        local key = file .. ':' .. reference
        if seen[key] then return end
        if result.observed_sites >= M.MAX_SITES then result.counts_limited = true; return end
        seen[key] = true; result.observed_sites = result.observed_sites + 1
        local count = targets and #targets or 0
        reason = reason or ''
        if count == 0 then result.unresolved_sites = result.unresolved_sites + 1 end
        if count > 1 or reason:find('ambigu', 1, true) or reason:find('multiple name/', 1, true) then
            result.ambiguous_sites = result.ambiguous_sites + 1
        end
        if count > 0 and reason:find('name/locality', 1, true) then result.heuristic_matches = result.heuristic_matches + 1 end
    end
    return result, record
end
return M
