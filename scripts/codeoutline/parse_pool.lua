-- parse_pool.lua — spreads a full refresh's file reads and parses over
-- parse threads (parse_worker.lua) started by a long-lived host.
--
--   pool.configure(script, count)   -- create threads on the first parallel pass
--   pool.bind(co)                   -- the job coroutine allowed to wait
--   -- on every 'parsed' message: pool.receive(token), even after cancellation
--   -- then, while pool.waiting():
--   coroutine.resume(co, token, results, failure)
--   pool.sweep()                    -- host update: reclaim idle threads
--
-- The index stays owned by the host thread: workers only read and parse,
-- and every commit happens here as results arrive. Files are split up front
-- by size (largest first onto the least-loaded thread) and posted in chunks,
-- so results stream back and a cancelled pass stops within a chunk.

local control = require('codeoutline.control')

local M = {}
M.THREADS = package.config:sub(1, 1) == '\\' and 8 or 6
M.FIRST_ID = 20            -- xnet2lua XTHR_WORKER_GRP1
M.CHUNK_FILES = 32
M.CHUNK_BYTES = 1048576
M.IDLE_MS = 60000

local threads, owner, shared = {}, nil, nil
local job, waiting, token = nil, false, 0
local script_path, thread_count
local outstanding, running, idle_since = {}, false, nil

local function log(format, ...)
    xthread.log_info('[codeoutline parse] ' .. format, ...)
end

-- Configure without allocating threads; zero disables parallel parsing.
function M.configure(script, count)
    script_path, thread_count = script, count or M.THREADS
end

local function start_threads()
    shared = assert(xshared.dict('codeoutline_control'))
    owner = xthread.current_id()
    for i = 1, thread_count do
        local id = M.FIRST_ID + i - 1
        local ok, err = xthread.create_thread(id, 'PARSE' .. i, script_path)
        if ok then threads[#threads + 1] = id
        else io.stderr:write('[codeoutline] parse thread ', i, ': ', tostring(err), '\n') end
    end
    idle_since = xtimer.now_ms()
    log('pool started: threads=%d requested=%d', #threads, thread_count)
end

local function stop_threads(reason)
    local started, count, stopped = xtimer.now_ms(), #threads, 0
    if shared then shared:set('parse_abort', token) end
    for _, id in ipairs(threads) do
        local ok, err = xthread.shutdown_thread(id)
        if ok then stopped = stopped + 1
        else log('thread stop failed: id=%d reason=%s', id, tostring(err)) end
    end
    if count > 0 then
        log('pool stopped: threads=%d/%d reason=%s elapsed_ms=%d',
            stopped, count, reason or 'shutdown', xtimer.now_ms() - started)
    end
    threads = {}
    outstanding, idle_since = {}, nil
    -- Keep token monotonic across restarts: parse_abort and late messages
    -- may still refer to the previous pool's passes.
end

-- xthread releases its ownership reference only from the Lua state that
-- created the thread (coroutines have distinct lua_State pointers). Keep
-- both lifecycle calls on one coroutine across jobs and host updates.
local lifecycle = coroutine.wrap(function(action, reason)
    while true do
        if action == 'start' then start_threads() else stop_threads(reason) end
        action, reason = coroutine.yield()
    end
end)

function M.stop(reason) lifecycle('stop', reason) end

function M.bind(co) job = co end

-- Whether the running code may hand files to the pool and wait for them.
function M.ready()
    if job == nil or coroutine.running() ~= job or not script_path or thread_count < 1 then return false end
    if #threads == 0 then lifecycle('start') end
    return #threads > 0
end

function M.waiting() return waiting end

-- Account for every reply, including abandoned passes with no job to resume.
function M.receive(got)
    local pending = outstanding[got]
    if not pending then return false end
    outstanding[got] = pending > 1 and pending - 1 or nil
    if not running and not next(outstanding) then idle_since = xtimer.now_ms() end
    return true
end

function M.sweep()
    if not running and not next(outstanding) and idle_since
        and xtimer.now_ms() - idle_since >= M.IDLE_MS then
        M.stop(string.format('idle %dms', xtimer.now_ms() - idle_since))
    end
end

-- Size-balanced split: largest first, each onto the least-loaded thread.
local function partition(jobs, n)
    local order = {}
    for i, j in ipairs(jobs) do order[i] = j end
    table.sort(order, function(a, b)
        if a.weight ~= b.weight then return a.weight > b.weight end
        return a.rel < b.rel
    end)
    local buckets, loads = {}, {}
    for i = 1, n do buckets[i], loads[i] = {}, 0 end
    for _, j in ipairs(order) do
        local best = 1
        for b = 2, n do if loads[b] < loads[best] then best = b end end
        local bucket = buckets[best]
        bucket[#bucket + 1] = j
        loads[best] = loads[best] + j.weight
    end
    return buckets, loads
end
M.partition = partition

-- jobs: { rel, abs, weight, size?, crc? }; on_result(rel, load_file result)
-- runs in this thread, in arrival order. Must be called from the bound job.
function M.run(jobs, max_bytes, on_result)
    assert(M.ready(), 'parse pool is not available here')
    token = token + 1
    local current, pending = token, 0
    local started, completed = xtimer.now_ms(), 0
    local counts = { parsed = 0, unchanged = 0, skipped = 0, failed = 0 }
    log('pass started: token=%d files=%d threads=%d', current, #jobs, #threads)
    running, idle_since = true, nil
    local ok, err = pcall(function()
        for i, bucket in ipairs(partition(jobs, #threads)) do
            local chunk, bytes = {}, 0
            local function flush()
                if #chunk == 0 then return end
                local posted, why = xthread.post(threads[i], 'parse', owner, current, max_bytes, chunk)
                assert(posted, 'cannot post to parse thread: ' .. tostring(why))
                pending = pending + 1
                outstanding[current] = (outstanding[current] or 0) + 1
                chunk, bytes = {}, 0
            end
            for _, j in ipairs(bucket) do
                chunk[#chunk + 1] = { j.rel, j.abs, j.size or false, j.crc or false }
                bytes = bytes + j.weight
                if #chunk >= M.CHUNK_FILES or bytes >= M.CHUNK_BYTES then flush() end
            end
            flush()
        end
        while pending > 0 do
            waiting = true
            local got, results, failure = coroutine.yield()
            waiting = false
            if got == current then
                pending = pending - 1
                if failure then error('parse thread failed: ' .. tostring(failure), 0) end
                control.check()
                for _, res in ipairs(results) do
                    on_result(res.rel, res)
                    completed = completed + 1
                    counts[res.status] = counts[res.status] + 1
                end
            end
        end
    end)
    waiting = false
    running = false
    if not next(outstanding) then idle_since = xtimer.now_ms() end
    -- Wall time includes dispatch, waiting for workers and applying results.
    local status = ok and 'completed' or (control.is_interrupted(err) and err.code or 'failed')
    log('pass %s: token=%d files=%d/%d parsed=%d unchanged=%d skipped=%d failed=%d elapsed_ms=%d',
        status, current, completed, #jobs, counts.parsed, counts.unchanged, counts.skipped, counts.failed,
        xtimer.now_ms() - started)
    if not ok then
        -- Workers skip the rest of this pass; late results carry a stale token.
        shared:set('parse_abort', current)
        error(err, 0)
    end
end

return M
