-- parse_pool.lua — spreads a full refresh's file reads and parses over
-- parse threads (parse_worker.lua) started by a long-lived host.
--
--   pool.start(script)              -- host thread: create the parse threads
--   pool.bind(co)                   -- the job coroutine allowed to wait
--   -- on each 'parsed' message, while pool.waiting():
--   coroutine.resume(co, token, results, failure)
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

local threads, owner, shared = {}, nil, nil
local job, waiting, token = nil, false, 0

-- Returns the number of threads started; 0 leaves every pass serial.
function M.start(script, count)
    count = count or M.THREADS
    shared = assert(xshared.dict('codeoutline_control'))
    owner = xthread.current_id()
    for i = 1, count do
        local id = M.FIRST_ID + i - 1
        local ok, err = xthread.create_thread(id, 'PARSE' .. i, script)
        if ok then threads[#threads + 1] = id
        else io.stderr:write('[codeoutline] parse thread ', i, ': ', tostring(err), '\n') end
    end
    return #threads
end

function M.stop()
    if shared then shared:set('parse_abort', token) end
    for _, id in ipairs(threads) do xthread.shutdown_thread(id) end
    threads = {}
end

function M.bind(co) job = co end

-- Whether the running code may hand files to the pool and wait for them.
function M.ready()
    return #threads > 0 and job ~= nil and coroutine.running() == job
end

function M.waiting() return waiting end

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
    local ok, err = pcall(function()
        for i, bucket in ipairs(partition(jobs, #threads)) do
            local chunk, bytes = {}, 0
            local function flush()
                if #chunk == 0 then return end
                local posted, why = xthread.post(threads[i], 'parse', owner, current, max_bytes, chunk)
                assert(posted, 'cannot post to parse thread: ' .. tostring(why))
                pending = pending + 1
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
                for _, res in ipairs(results) do on_result(res.rel, res) end
            end
        end
    end)
    waiting = false
    if not ok then
        -- Workers skip the rest of this pass; late results carry a stale token.
        shared:set('parse_abort', current)
        error(err, 0)
    end
end

return M
