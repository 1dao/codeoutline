-- Requests within one Lua state are serialized by the owning transport.
local index = require('codeoutline.index')
local explore = require('codeoutline.explore')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local M = {}
local projects = {}
local sequence = 0
local limits = { max_projects = 8, idle_seconds = 900 }
-- Long-lived hosts watch resident projects so a query refreshes only what
-- changed; one-shot commands would pay for a watcher they never read.
local watch = false
-- LuaJIT starts a collection cycle only once the heap has doubled since the
-- last one. A resident index makes the heap large, so the garbage of polls
-- and requests (and a dropped project's whole index) would build up toward
-- the index's own size; hosts collect it on idle ticks with M.collect.
local gc = { live = collectgarbage('count'), running = false }
-- A 512 KB step takes about 1 ms (6 ms at most) on a 650 MB heap.
M.GC_MIN_KB, M.GC_STEP_KB = 16384, 512

local function drop(key)
    local p = projects[key]
    projects[key] = nil
    if p then p.idx:close(); gc.running = true end
end

function M.configure(opts)
    if opts.watch ~= nil then
        assert(type(opts.watch) == 'boolean', 'watch must be a boolean')
        watch = opts.watch
    end
    for _, name in ipairs({ 'max_projects', 'idle_seconds' }) do
        local v = opts[name]
        if v ~= nil then
            assert(type(v) == 'number' and v >= 1 and v < math.huge and v % 1 == 0, name .. ' must be a positive integer')
        end
    end
    for name in pairs(limits) do if opts[name] ~= nil then limits[name] = opts[name] end end
    M.sweep()
end

-- Hosts sweep on every tick: allocate only when something is dropped.
function M.sweep(now)
    now = now or os.time()
    local count, idle = 0, nil
    for key, p in pairs(projects) do
        if now - p.used >= limits.idle_seconds then
            idle = idle or {}
            idle[#idle + 1] = key
        else count = count + 1 end
    end
    if idle then for _, key in ipairs(idle) do drop(key) end end
    while count > limits.max_projects do
        local oldest
        for key, p in pairs(projects) do
            if not oldest or p.order < projects[oldest].order then oldest = key end
        end
        drop(oldest)
        count = count - 1
    end
    return count
end

-- Run one bounded incremental GC step on an idle tick; returns whether a cycle
-- is still in progress. A cycle starts once the garbage since the last one
-- reaches a sixteenth of the live heap (at least GC_MIN_KB), or a project is
-- dropped, and then advances one step per call until it completes.
function M.collect()
    if not gc.running then
        if collectgarbage('count') - gc.live < math.max(M.GC_MIN_KB, gc.live / 16) then return false end
        gc.running = true
    end
    if collectgarbage('step', M.GC_STEP_KB) then gc.running, gc.live = false, collectgarbage('count') end
    return gc.running
end

local function key_for(root)
    local canonical, err = index.check_root(root)
    assert(canonical, err)
    return paths.key(canonical), canonical
end

-- Files commit one at a time, so an interrupted refresh needs no rollback:
-- the index stays consistent and the next refresh resumes with a full pass.
local function refresh(root, opts, with_symbols)
    opts = opts or {}
    local key, canonical = key_for(root)
    M.sweep()
    local p = projects[key]
    if p then
        for _, name in ipairs({ 'cache_path', 'max_file_bytes', 'lister' }) do
            if opts[name] ~= nil and opts[name] ~= p.opts[name] then
                error('project option changed; forget the project before changing ' .. name, 2)
            end
        end
    else
        p = { idx = index.open(canonical, opts), opts = {
            cache_path = opts.cache_path, max_file_bytes = opts.max_file_bytes, lister = opts.lister,
        } }
        if watch then p.idx:watch() end
    end
    local t0 = os.clock()
    local ok, stats = pcall(function()
        local refresh_opts = opts
        if not projects[key] and opts.paths then refresh_opts = { full_interval = opts.full_interval } end
        local result = p.idx:refresh(refresh_opts)
        if with_symbols then p.idx:symbols() end
        return result
    end)
    if not ok then
        if not projects[key] then p.idx:close() end
        error(stats, 0)
    end
    sequence = sequence + 1
    p.used, p.stats, p.order = os.time(), stats, sequence
    projects[key] = p
    M.sweep()
    -- A failed save leaves the index behind its cache, so the next call retries.
    if p.idx:needs_save() then
        local saved, err = p.idx:save()
        stats.cache_saved, stats.cache_error = saved, err
    end
    stats.seconds = os.clock() - t0
    return p.idx, with_symbols and p.idx:symbols() or nil, stats
end

-- LSP refreshes records; symbol tables are kept current only once built.
function M.refresh(root, opts)
    local idx, _, stats = refresh(root, opts, false)
    return idx, stats
end

-- Refresh, and return the symbol tables relationships resolve against.
function M.get(root, opts)
    return refresh(root, opts, true)
end

-- Worker-owned resident state; callers must serialize access with get/explore.
-- This does not refresh the filesystem or build symbol tables.
function M.resident(root)
    local key = key_for(root)
    local p = assert(projects[key], 'Project is indexing; retry when indexing completes')
    p.used = os.time()
    return p.idx, p.idx.symbol_tables
end

function M.explore(root, query, opts)
    explore.validate(query, opts)
    local idx, _, stats = refresh(root, opts, true)
    idx.query_sources = {}
    local ok, result = pcall(function()
        while true do
            -- A GBK repair commits the decoded file, which renumbers its nodes.
            local output, details = explore.run(idx:symbols(), idx, query, opts)
            control.check()
            if not details.encoding_retry then return { text = output, info = details } end
        end
    end)
    idx.query_sources = nil
    if not ok then error(result, 0) end
    if idx:needs_save() then
        local saved, err = idx:save()
        stats.cache_saved, stats.cache_error = saved, err
    end
    result.info.refresh = stats
    return result.text, result.info
end

function M.status(root, opts)
    local idx, G, stats = M.get(root, opts)
    local languages = {}
    for _, rec in pairs(idx.files) do languages[rec.language] = (languages[rec.language] or 0) + 1 end
    return { projectPath = idx.root, files = G.file_count, symbols = G.node_count,
        generation = idx.generation, languages = languages, refresh = stats,
        cachePath = idx.cache_path, cacheLoaded = idx.cache_loaded, cacheWarning = idx.cache_error,
        enumerator = idx.enumerator, scanner = xscan and os.getenv('XSCAN_PURE_LUA') ~= '1' and 'native' or 'lua',
        residentProjects = M.sweep(), maxProjects = limits.max_projects, idleSeconds = limits.idle_seconds }
end

-- Forget drops memory only. Rebuild bypasses cache and publishes after success.
function M.forget(root)
    -- A resident canonical root can disappear after a checkout or deletion.
    local key = type(root) == 'string' and paths.key(root)
    if not key or not projects[key] then key = key_for(root) end
    local existed = projects[key] ~= nil
    drop(key)
    return existed
end

function M.rebuild(root, opts)
    local key = key_for(root)
    local previous = projects[key]
    local config = {}
    for k, v in pairs(opts or (previous and previous.opts) or {}) do config[k] = v end
    config.rebuild = true
    projects[key] = nil
    local ok, result = pcall(M.status, root, config)
    if not ok then
        drop(key)
        projects[key] = previous
        error(result, 2)
    end
    if previous then previous.idx:close() end
    return result
end

return M
