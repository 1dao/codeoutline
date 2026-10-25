-- Small agent-facing status, independent of source text and temporary node IDs.
local M = {}

function M.relations(info)
    local result = {}
    local stats = info.query_stats or {}
    local shared = stats.events and stats.events.shared
    for reason in pairs(shared and shared.incomplete_reasons or {}) do
        result[#result + 1] = 'shared_events.' .. reason
    end
    if info.relationships_incomplete and #result == 0 then result[1] = 'relationship_analysis_incomplete' end
    table.sort(result); return result
end

function M.summarize(info)
    info = info or {}
    local reasons, seen = {}, {}
    local function add(reason)
        if not seen[reason] then seen[reason] = true; reasons[#reasons + 1] = reason end
    end
    for _, reason in ipairs(M.relations(info)) do add(reason) end
    local flags = {
        truncated = 'output_truncated', seed_selection_limited = 'seed_selection_limited',
        seed_limit_reached = 'seed_candidate_limit', path_search_limited = 'path_search_limit',
        depth_limit_reached = 'depth_limit', node_limit_reached = 'node_limit', time_limit_reached = 'time_limit',
        candidate_limit_reached = 'candidate_limit', cycle_detected = 'inheritance_cycle',
        evidence_truncated = 'evidence_omitted', unresolved_candidates_truncated = 'definition_candidates_omitted',
        path_breakpoints_truncated = 'path_breakpoints_omitted', on_demand_truncated = 'on_demand_limit',
    }
    for flag, reason in pairs(flags) do if info[flag] then add(reason) end end
    if info.unresolved_files and #info.unresolved_files > 0 then add('unresolved_files') end
    if info.files_without_symbols and #info.files_without_symbols > 0 then add('files_without_symbols') end
    if info.on_demand_rejected and #info.on_demand_rejected > 0 then add('on_demand_rejected') end
    if info.unresolved and #info.unresolved > 0 then add('unresolved_types') end
    if info.query_stats and (info.query_stats.reverse_unresolved or 0) > 0 then add('unresolved_reverse_types') end
    if info.incomplete and #reasons == 0 then add('analysis_incomplete') end
    table.sort(reasons)
    return { scope = 'indexed_static_analysis', partial = #reasons > 0, reasons = reasons,
        output_truncated = info.truncated == true, relationships_incomplete = info.relationships_incomplete == true,
        selection_limited = info.seed_selection_limited == true or info.seed_limit_reached == true }
end

function M.error(message)
    message = tostring(message or '')
    local code, retryable = 'query_failed', false
    if message:find('source changed', 1, true) or message:find('source snapshot changed', 1, true) then
        code, retryable = 'source_changed', true
    elseif message:find('deadline exceeded', 1, true) then code, retryable = 'deadline_exceeded', true
    elseif message:find('queue is full', 1, true) then code, retryable = 'busy', true
    elseif message:lower():find('cancelled', 1, true) then code = 'cancelled' end
    return { code = code, retryable = retryable }
end

return M
