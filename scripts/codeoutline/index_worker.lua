local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local service = require('codeoutline.service')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local shared = assert(xshared.dict('codeoutline_control'))

local function execute(req)
    local root = assert(paths.canonical(req.projectPath))
    assert(paths.allowed(req.allowedRoots, root), 'project path is outside allowed roots')
    if req.method == 'explore' then
        local text, info = service.explore(root, req.query, { budget = req.budget })
        return { text = text, truncated = info.truncated or false, refresh = info.refresh }
    elseif req.method == 'status' then return service.status(root)
    elseif req.method == 'rebuild' then return service.rebuild(root)
    else error('unknown operation') end
end

return {
    __init = function() assert(xthread.post(1, 'worker_ready')) end,
    __update = function() service.sweep() end,
    __thread_handle = function(_, op, id, req)
        if op ~= 'run' then return end
        control.callback = function()
            if shared:get('shutdown') or shared:get('cancel:' .. id) then error('Request cancelled', 0) end
            if xtimer.now_ms() > req.deadline then error('Indexing deadline exceeded', 0) end
        end
        -- Lua graph/parse loops are interruptible. Native scanning is bounded
        -- by max_file_bytes; explicit checkpoints also cover protected parses.
        debug.sethook(control.check, '', 20000)
        local ok, result = pcall(function() control.check(); return execute(req) end)
        debug.sethook()
        control.callback = nil
        if not ok then pcall(service.forget, req.projectPath) end
        shared:delete('cancel:' .. id)
        assert(xthread.post(1, 'worker_result', id, ok, result))
    end,
}
