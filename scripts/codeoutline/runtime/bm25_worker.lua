local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/runtime/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local indexing = require('codeoutline.indexing.index')
local bm25 = require('codeoutline.bm25.index')
local snapshot = require('codeoutline.bm25.snapshot')
local control = require('codeoutline.shared.control')
local pool = require('codeoutline.indexing.parse_pool')
local shared = assert(xshared.dict('codeoutline_control'))
local job, owner, item

local function build(item)
    control.check()
    local index = indexing.open(item.root, {cache_path = item.cache})
    local ok, err = pcall(function()
        assert(index.cache_loaded and snapshot.stamp(index) == item.stamp, 'base snapshot changed before BM25 build')
        if item.repair or not snapshot.current(item.file, item.stamp) then bm25.build(index, item.file) end
    end)
    index:close()
    if not ok then error(err, 0) end
end

local function advance(...)
    local ok, err = coroutine.resume(job, ...)
    if ok and coroutine.status(job) ~= 'dead' then return end
    if not ok and not control.is_interrupted(err) then
        io.stderr:write('[codeoutline bm25] ', tostring(err), '\n')
    end
    job = nil
    pool.bind(nil)
    -- The owner joins this thread so closing its Lua state releases the build heap.
    xthread.post(owner, 'bm25_done', item.file, item.stamp, ok)
end

local function lookup(request)
    local previous = control.callback
    control.callback = function()
        previous()
        if xtimer.now_ms() >= request.deadline then error(control.deadline(), 0) end
    end
    local ok, result = pcall(function()
        control.check()
        local accept
        if request.candidates then
            accept = function(path, name, kind, first, last)
                local lines = request.candidates[path]
                local entries = lines and lines[first]
                if not entries then return end
                for _, candidate in ipairs(entries) do
                    if candidate[1] == name and candidate[2] == kind and candidate[3] == last then return candidate[4] end
                end
            end
        end
        local hits = bm25.search(snapshot.reader(request.root, request.stamp), request.file, request.query, {
            match = 'all', limit = request.limit or 20, prefix = request.prefix, accept = accept,
        })
        control.check()
        if accept then
            local ranks = {}
            for i, hit in ipairs(hits) do
                ranks[accept(hit.path, hit.symbol, hit.kind, hit.start_line, hit.end_line)] = i
            end
            return ranks
        end
        return hits
    end)
    control.callback = previous
    return ok, ok and result or tostring(result)
end

return {
    __init = function()
        -- Keep worker IDs separate from the foreground index's parse pool.
        pool.FIRST_ID = 256
        pool.configure(scripts .. '/codeoutline/runtime/parse_worker.lua', pool.configured_threads())
        control.callback = function()
            if shared:get('shutdown') then error(control.cancelled(), 0) end
        end
    end,
    __thread_handle = function(_, op, owner_or_token, item_or_results, failure)
        if op == 'bm25_lookup' then
            local ok, result = lookup(failure)
            xthread.post(owner_or_token, 'bm25_lookup_done', item_or_results, ok, result)
        elseif op == 'bm25_build' then
            owner, item = owner_or_token, item_or_results
            job = coroutine.create(build)
            pool.bind(job)
            advance(item)
        elseif op == 'parsed' and pool.receive(owner_or_token) and job and pool.waiting() then
            advance(owner_or_token, item_or_results, failure)
        end
    end,
    __uninit = function() pool.stop() end,
}
