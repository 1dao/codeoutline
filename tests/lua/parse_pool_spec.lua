-- Real parse threads: a pooled full pass must commit exactly what a serial
-- pass does, and a cancelled one must leave stale results unused.
package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local index = require('codeoutline.index')
local pool = require('codeoutline.parse_pool')
local control = require('codeoutline.control')
local root = assert(xutils.temp_file(os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')):gsub('\\', '/')
os.remove(root)
local project = root .. '/project'
assert(xutils.mkdir_p(project .. '/sub'))
local function write(path, data)
    local f = assert(io.open(path, 'wb')); assert(f:write(data)); assert(f:close())
end
for i = 1, 120 do
    local body = {}
    for j = 1, i % 17 + 1 do body[#body + 1] = string.format('function f%d_%d() return f%d_%d() end', i, j, i, j + 1) end
    write(string.format('%s/%s%d.lua', project, i % 3 == 0 and 'sub/' or '', i), table.concat(body, '\n') .. '\n')
end
write(project .. '/c.c', 'static int helper(int x) { return x; }\nint main(void) { return helper(1); }\n')
write(project .. '/big.lua', string.rep('-- padding\n', 2000))
local MAX_BYTES = 16384

-- Canonical text of a record without `checked`, which says when a pass read it.
local function canonical(v, skip)
    if type(v) ~= 'table' then return type(v) .. ':' .. tostring(v) end
    local keys = {}
    for k in pairs(v) do if k ~= skip then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. canonical(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end

local function snapshot(idx)
    local out = {}
    for rel, rec in pairs(idx.files) do out[rel] = canonical(rec, 'checked') end
    return out
end

local serial = index.open(project, { cache_path = root .. '/serial.idx', lister = 'walk', rebuild = true,
    max_file_bytes = MAX_BYTES })
local serial_stats = serial:refresh()
local expected = snapshot(serial)

local job, steps, delivered = nil, {}, 0
local draining, created, baseline_handles = false, 0, 0
local function retained_handles()
    local registry, count = debug.getregistry(), 0
    for _, value in pairs(registry) do
        if type(value) == 'userdata' and getmetatable(value) == registry['xthread.ThreadData'] then
            count = count + 1
        end
    end
    return count
end

local function sweep_after(ms)
    local clock = xtimer.now_ms
    xtimer.now_ms = function() return clock() + ms end
    local ok, err = pcall(pool.sweep)
    xtimer.now_ms = clock
    assert(ok, err)
end

local function alive()
    local count = 0
    for id = pool.FIRST_ID, pool.FIRST_ID + 3 do
        if xthread.stats(id) then count = count + 1 end
    end
    return count
end
local function step()
    if job and coroutine.status(job) ~= 'dead' then return end
    local nxt = table.remove(steps, 1)
    if not nxt then
        pool.stop()
        if spec.finish() > 0 then os.exit(1) end
        xthread.stop(0); return
    end
    job = coroutine.create(function() spec.it(nxt[1], nxt[2]) end)
    pool.bind(job)
    assert(coroutine.resume(job))
    step()
end

steps[#steps + 1] = { 'keeps startup and small refreshes free of parse threads', function()
    spec.equal(alive(), 0)
    assert(xutils.mkdir_p(root .. '/small'))
    write(root .. '/small/one.lua', 'function only_one() end\n')
    local idx = index.open(root .. '/small', { cache_path = root .. '/small.idx', lister = 'walk', rebuild = true })
    spec.equal(idx:refresh().parsed, 1)
    spec.equal(alive(), 0); spec.equal(created, 0)
    idx:close()
end }

steps[#steps + 1] = { 'balances threads by size, largest first', function()
    local jobs = {}
    for i, w in ipairs({ 10, 70, 30, 40, 50, 20, 60 }) do jobs[i] = { rel = tostring(i), weight = w } end
    local buckets, loads = pool.partition(jobs, 3)
    spec.equal(#buckets, 3)
    spec.equal(buckets[1][1].weight, 70); spec.equal(buckets[2][1].weight, 60); spec.equal(buckets[3][1].weight, 50)
    table.sort(loads)
    spec.truthy(loads[3] - loads[1] <= 10, 'loads differ by at most the smallest file')
end }

steps[#steps + 1] = { 'commits the same records as a serial pass', function()
    local idx = index.open(project, { cache_path = root .. '/pool.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    local stats = idx:refresh()
    spec.equal(alive(), 4); spec.equal(created, 4)
    spec.truthy(delivered >= 4, 'every parse thread returned results')
    spec.equal(stats.parsed, serial_stats.parsed); spec.equal(stats.skipped, 1)
    spec.equal(stats.parsed, 121)
    local got = snapshot(idx)
    for rel, packed in pairs(expected) do spec.equal(got[rel], packed, rel) end
    for rel in pairs(got) do spec.truthy(expected[rel], 'unexpected ' .. rel) end
    -- An unchanged tree settles by stat or checksum without new records.
    local generation = idx.generation
    stats = idx:refresh()
    spec.equal(stats.parsed, 0); spec.equal(idx.generation, generation)
    sweep_after(0)
    spec.equal(alive(), 4, 'retain threads during the idle grace period')
    idx:close()
end }

steps[#steps + 1] = { 'abandons a cancelled pass and ignores its late results', function()
    local idx = index.open(project, { cache_path = root .. '/cancel.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    control.callback = function()
        if idx.generation >= 40 then error(control.cancelled(), 0) end
    end
    local ok, err = pcall(idx.refresh, idx)
    control.callback = nil
    spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
    local partial = 0
    for _ in pairs(idx.files) do partial = partial + 1 end
    spec.truthy(partial > 0 and partial < 121, 'committed ' .. partial)
    local stats = idx:refresh()
    spec.equal(stats.mode, 'full'); spec.equal(stats.parsed + stats.unchanged, 121)
    local got = snapshot(idx)
    for rel, packed in pairs(expected) do spec.equal(got[rel], packed, rel) end
    spec.equal(created, 4, 'reuse workers across passes and cancellation')
    idx:close()
end }

steps[#steps + 1] = { 'reclaims idle workers and restarts them for the next full pass', function()
    sweep_after(pool.IDLE_MS + 1)
    spec.equal(alive(), 0)
    spec.equal(retained_handles(), baseline_handles, 'release native ownership references after shutdown')
    local idx = index.open(project, { cache_path = root .. '/restart.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    spec.equal(idx:refresh().parsed, 121)
    spec.equal(created, 8); spec.equal(alive(), 4)
    local got = snapshot(idx)
    for rel, packed in pairs(expected) do spec.equal(got[rel], packed, rel) end
    idx:close()
end }

steps[#steps + 1] = { 'drains cancelled work before reclaiming workers without an active pass', function()
    local idx = index.open(project, { cache_path = root .. '/drain.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    local chunk_files = pool.CHUNK_FILES
    pool.CHUNK_FILES = 1
    control.callback = function() if idx.generation >= 1 then error(control.cancelled(), 0) end end
    local ok, err = pcall(idx.refresh, idx)
    control.callback = nil
    pool.CHUNK_FILES = chunk_files
    spec.equal(ok, false); spec.truthy(control.is_interrupted(err))
    sweep_after(pool.IDLE_MS + 1)
    spec.equal(alive(), 4, 'cancelled pass still has outstanding replies')
    local partial = snapshot(idx)
    draining = true
    coroutine.yield()
    spec.equal(alive(), 0)
    spec.equal(retained_handles(), baseline_handles, 'repeated lifecycles must not retain native handles')
    local got = snapshot(idx)
    for rel, packed in pairs(partial) do spec.equal(got[rel], packed, rel) end
    for rel in pairs(got) do spec.truthy(partial[rel], 'late reply committed ' .. rel) end
    idx:close()
end }

steps[#steps + 1] = { 'preserves serial mode when parse threads are disabled', function()
    pool.configure('scripts/codeoutline/parse_worker.lua', 0)
    spec.equal(pool.ready(), false)
    local idx = index.open(project, { cache_path = root .. '/disabled.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    spec.equal(idx:refresh().parsed, 121)
    spec.equal(alive(), 0); spec.equal(created, 8)
    idx:close()
end }

return {
    __init = function()
        assert(xnet.init())
        assert(xshared.create('codeoutline_control', 65536, 256))
        baseline_handles = retained_handles()
        local create = xthread.create_thread
        xthread.create_thread = function(...)
            local ok, err = create(...)
            if ok then created = created + 1 end
            return ok, err
        end
        pool.configure('scripts/codeoutline/parse_worker.lua', 4)
        step()
    end,
    __thread_handle = function(_, op, token, results, failure)
        if op ~= 'parsed' or not pool.receive(token) then return end
        if draining then
            sweep_after(pool.IDLE_MS + 1)
            if alive() == 0 then
                draining = false
                assert(coroutine.resume(job))
                step()
            end
        elseif job and pool.waiting() then
            delivered = delivered + 1
            sweep_after(pool.IDLE_MS + 1)
            assert(alive() == 4, 'never reclaim workers during an active pass')
            local ok, err = coroutine.resume(job, token, results, failure)
            if not ok then io.stderr:write(tostring(err), '\n'); os.exit(1) end
            step()
        end
    end,
    __uninit = function() xnet.uninit() end,
}
