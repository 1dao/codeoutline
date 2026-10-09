local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local service = require('codeoutline.service')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local documents = require('codeoutline.documents')
local lsp = require('codeoutline.lsp')
local navigation = require('codeoutline.navigation')
local pool = require('codeoutline.parse_pool')
require('codeoutline.completion') -- registers lsp_completion
service.configure({ watch = true })
local shared = assert(xshared.dict('codeoutline_control'))

local function execute(req)
    if navigation.handles(req.method) then return navigation.execute(req) end
    if req.method == 'lsp_close' then navigation.close(req.session); return true end
    if req.method == 'lsp_symbols' then
        local result = {}
        if req.limit <= 0 then return result end
        local needle = req.query:lower()
        for _, root in ipairs(req.roots) do
            local idx = service.resident(root)
            local files = {}
            for path in pairs(idx.files) do files[#files + 1] = path end
            table.sort(files)
            for _, rel in ipairs(files) do
                control.check()
                local rec, matched = idx.files[rel], false
                local path = idx:abs(rel)
                if not req.exclude[paths.key(path)] then
                    for i, node in ipairs(rec.nodes) do
                        if i % 128 == 0 then control.check() end
                        if node.qualified:lower():find(needle, 1, true) then matched = true; break end
                    end
                end
                if matched then
                    local canonical = xutils.realpath(path)
                    local doc = canonical and paths.contains(root, paths.normalize(canonical)) and documents.read(path)
                    if doc then
                        for _, symbol in ipairs(lsp.document_symbols(doc, false)) do
                            local name = symbol.containerName and (symbol.containerName .. '.' .. symbol.name) or symbol.name
                            if name:lower():find(needle, 1, true) then
                                if #result >= req.limit then return result end
                                result[#result + 1] = symbol
                            end
                        end
                    end
                end
            end
        end
        return result
    end
    local root = assert(paths.canonical(req.projectPath))
    assert(paths.allowed(req.allowedRoots, root), 'project path is outside allowed roots')
    if req.method == 'lsp_refresh' then
        service.configure({ max_projects = lsp.MAX_ROOTS })
        service.refresh(root, { full_interval = 45, paths = req.paths })
        return true
    elseif req.method == 'explore' then
        local text, info = service.explore(root, req.query, { budget = req.budget })
        return { text = text, truncated = info.truncated or false, refresh = info.refresh }
    elseif req.method == 'status' then return service.status(root)
    elseif req.method == 'rebuild' then return service.rebuild(root)
    else error('unknown operation') end
end

-- Execute serially until per-file commits allow safe short-job interleaving.
-- Each job runs in a coroutine so a full refresh can wait for the parse
-- threads; jobs arriving meanwhile queue behind it.
local queue, active = {}, nil

local function run(id, req)
    -- Draft text applies even to a cancelled request: the session counts it as sent.
    if req.session and req.open then
        local synced, err = pcall(navigation.sync, req)
        if not synced then io.stderr:write('[codeoutline lsp] ', tostring(err), '\n') end
    end
    control.callback = function()
        if shared:get('shutdown') or shared:get('cancel:' .. id) then error(control.cancelled(), 0) end
        if xtimer.now_ms() > req.deadline then error(control.deadline(), 0) end
    end
    local ok, result = pcall(function() control.check(); return execute(req) end)
    control.callback = nil
    if not ok then result = tostring(result) end
    shared:delete('cancel:' .. id)
    assert(xthread.post(1, 'worker_result', id, ok, result))
end

local function resume(...)
    local ok, err = coroutine.resume(active, ...)
    if not ok then io.stderr:write('[codeoutline] index job failed: ', tostring(err), '\n') end
    if coroutine.status(active) == 'dead' then active = nil; pool.bind(nil) end
end

local function pump()
    while not active and #queue > 0 do
        local item = table.remove(queue, 1)
        active = coroutine.create(run)
        pool.bind(active)
        resume(item[1], item[2])
    end
end

return {
    __init = function()
        assert(xnet.init())
        local threads = tonumber(os.getenv('CODEOUTLINE_INDEX_THREADS') or '') or pool.THREADS
        pool.configure(scripts .. '/codeoutline/parse_worker.lua', math.max(0, math.floor(threads)))
        assert(xthread.post(1, 'worker_ready'))
    end,
    -- A suspended job still holds its project: sweeping waits for it.
    __update = function()
        pool.sweep()
        if not active then service.sweep() end
    end,
    __thread_handle = function(_, op, id, req, failure)
        if op == 'run' then
            queue[#queue + 1] = { id, req }
            pump()
        elseif op == 'parsed' then
            -- (token, results, failure); stale tokens are dropped by the pool.
            if pool.receive(id) and active and pool.waiting() then resume(id, req, failure); pump() end
        end
    end,
    __uninit = function()
        pool.stop()
        xnet.uninit()
    end,
}
