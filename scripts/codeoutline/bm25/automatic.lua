-- Foreground coordinator. The lexical index is built in a separate Lua state
-- from the saved base snapshot, never in the foreground request coroutine.
local snapshot = require('codeoutline.bm25.snapshot')
local control = require('codeoutline.shared.control')
local M = {worker_id = 6}
local queue, active, failure = {}, nil, nil
local lookup, next_lookup = nil, 0

local function enqueue(index, file, stamp, repair)
    if index:needs_save() then return 'unavailable' end
    if active and active.file == file and active.stamp == stamp then return 'building' end
    if failure and failure.file == file and failure.stamp == stamp and xtimer.now_ms() < failure.retry then
        return 'unavailable'
    end
    local item = {root = index.root, cache = index.cache_path, file = file, stamp = stamp, repair = repair}
    for i, pending in ipairs(queue) do
        if pending.file == file then
            if pending.stamp ~= stamp or repair then queue[i] = item end
            return 'building'
        end
    end
    -- A wide burst of projects should not reserve a full build for each one.
    if #queue >= 8 then return 'unavailable' end
    queue[#queue + 1] = item
    return 'building'
end

function M.prepare(index)
    local file = index.cache_path .. '.bm25'
    local stamp = snapshot.stamp(index)
    if not snapshot.current(file, stamp) then enqueue(index, file, stamp) end
    return function(query, accept, match)
        local current = snapshot.stamp(index)
        if not snapshot.current(file, current) then return nil, enqueue(index, file, current) end
        local ok, result = pcall(require('codeoutline.bm25.index').search, index, file, query,
            {limit = 20, accept = accept, match = match})
        if ok then return result, 'searched' end
        if control.is_interrupted(result) then error(result, 0) end
        -- The header may have changed after the quick check, or a block may
        -- be corrupt. Regenerate and preserve the original zero-match result.
        return nil, enqueue(index, file, current, true)
    end
end

function M.definition(index, query, deadline, prefix)
    local file = index.cache_path .. '.bm25'
    local stamp = snapshot.stamp(index)
    if not snapshot.current(file, stamp) then
        return nil, enqueue(index, file, stamp) == 'building' and 'bm25_building' or true
    end
    local now = xtimer.now_ms()
    if active or lookup or now >= deadline then return nil, true end
    next_lookup = next_lookup + 1
    -- Let a cold header warm in the background after F12 returns.
    local work_until = now + 2000
    local posted = xthread.post(M.worker_id, 'bm25_lookup', xthread.current_id(), next_lookup,
        {root = index.root, stamp = stamp, file = file, query = query, deadline = work_until, prefix = prefix})
    if not posted then return nil, true end
    lookup = {token = next_lookup, wait_until = math.min(now + 180, deadline), work_until = work_until}
    local ok, result = coroutine.yield()
    control.check()
    if ok then return result, false end
    if type(result) == 'string' and (result:find('corrupt BM25', 1, true)
        or result:find('invalid BM25', 1, true)) then
        return nil, enqueue(index, file, stamp, true) == 'building' and 'bm25_building' or true
    end
    return nil, true
end

function M.receive_lookup(token)
    if not lookup or lookup.token ~= token then return false end
    local waiting = lookup.wait_until ~= nil
    lookup = nil
    return waiting
end

function M.expire_lookup()
    if not lookup then return false end
    local now = xtimer.now_ms()
    local expired = lookup.wait_until and now >= lookup.wait_until
    if expired then lookup.wait_until = nil end
    if now >= lookup.work_until then lookup = nil end
    return expired
end

function M.pump()
    if active or lookup or #queue == 0 then return end
    local item = table.remove(queue, 1)
    local posted = xthread.post(M.worker_id, 'bm25_build', xthread.current_id(), item)
    if posted then active = item
    else failure = {file = item.file, stamp = item.stamp, retry = xtimer.now_ms() + 1000} end
end

function M.finish(file, stamp, ok)
    if not active or active.file ~= file or active.stamp ~= stamp then return end
    if not ok then failure = {file = file, stamp = stamp, retry = xtimer.now_ms() + 1000} end
    active = nil
end

return M
