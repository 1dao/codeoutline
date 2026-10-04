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
    spec.truthy(pool.ready())
    local idx = index.open(project, { cache_path = root .. '/pool.idx', lister = 'walk', rebuild = true,
        max_file_bytes = MAX_BYTES })
    local stats = idx:refresh()
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
end }

return {
    __init = function()
        assert(xnet.init())
        assert(xshared.create('codeoutline_control', 65536, 256))
        spec.equal(pool.start('scripts/codeoutline/parse_worker.lua', 4), 4)
        step()
    end,
    __thread_handle = function(_, op, token, results, failure)
        if op == 'parsed' and job and pool.waiting() then
            delivered = delivered + 1
            local ok, err = coroutine.resume(job, token, results, failure)
            if not ok then io.stderr:write(tostring(err), '\n'); os.exit(1) end
            step()
        end
    end,
    __uninit = function() xnet.uninit() end,
}
