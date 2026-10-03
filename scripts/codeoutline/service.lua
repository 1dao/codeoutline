-- Requests within one Lua state are serialized by the owning transport.
local index = require('codeoutline.index')
local graph = require('codeoutline.graph')
local explore = require('codeoutline.explore')
local paths = require('codeoutline.path')
local M = {}
local projects = {}
local sequence = 0
local limits = { max_projects = 8, idle_seconds = 900 }
-- Long-lived hosts watch resident projects so a query refreshes only what
-- changed; one-shot commands would pay for a watcher they never read.
local watch = false

local function drop(key)
    local p = projects[key]
    projects[key] = nil
    if p then p.idx:close() end
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

function M.sweep(now)
    now = now or os.time()
    local count = 0
    local idle = {}
    for key, p in pairs(projects) do
        if now - p.used >= limits.idle_seconds then idle[#idle + 1] = key else count = count + 1 end
    end
    for _, key in ipairs(idle) do drop(key) end
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

local function key_for(root)
    local canonical, err = index.check_root(root)
    assert(canonical, err)
    return paths.key(canonical), canonical
end

function M.get(root, opts)
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
    local stats = p.idx:refresh()
    if not p.G or p.G.generation ~= p.idx.generation then p.G = graph.build(p.idx) end
    -- A failed save leaves the index behind its cache, so the next call retries.
    if p.idx:needs_save() then
        local saved, err = p.idx:save()
        stats.cache_saved, stats.cache_error = saved, err
    end
    stats.seconds = os.clock() - t0
    sequence = sequence + 1
    p.used, p.stats, p.order = os.time(), stats, sequence
    projects[key] = p
    M.sweep()
    return p.idx, p.G, stats
end

function M.explore(root, query, opts)
    explore.validate(query, opts)
    local idx, G, stats = M.get(root, opts)
    idx.query_sources = {}
    local ok, text, info = pcall(function()
        while true do
            local output, details = explore.run(G, idx, query, opts)
            if not details.encoding_retry then return output, details end
            G = graph.build(idx)
        end
    end)
    idx.query_sources = nil
    -- A partial encoding repair can precede an error in another file. Keep
    -- the resident graph consistent even when the query itself fails.
    local p = projects[paths.key(idx.root)]
    if p.G.generation ~= idx.generation then
        p.G = G.generation == idx.generation and G or graph.build(idx)
    end
    if idx:needs_save() then
        local saved, err = idx:save()
        stats.cache_saved, stats.cache_error = saved, err
    end
    if not ok then error(text, 2) end
    info.refresh = stats
    return text, info
end

function M.status(root, opts)
    local idx, G, stats = M.get(root, opts)
    local languages = {}
    for _, rec in ipairs(G.files) do languages[rec.language] = (languages[rec.language] or 0) + 1 end
    return { projectPath = idx.root, files = #G.files, symbols = #G.nodes, edges = G.edge_count,
        generation = idx.generation, languages = languages, refresh = stats,
        cachePath = idx.cache_path, cacheLoaded = idx.cache_loaded, cacheWarning = idx.cache_error,
        enumerator = idx.enumerator, scanner = xscan and os.getenv('XSCAN_PURE_LUA') ~= '1' and 'native' or 'lua',
        residentProjects = M.sweep(), maxProjects = limits.max_projects, idleSeconds = limits.idle_seconds }
end

-- Forget drops memory only. Rebuild bypasses cache and publishes after success.
function M.forget(root)
    local key = key_for(root)
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
