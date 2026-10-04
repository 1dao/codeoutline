local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local service = require('codeoutline.service')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
service.configure({ watch = true })
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
        local function abort(reason)
            control.callback = nil
            error(reason, 0)
        end
        control.callback = function()
            if shared:get('shutdown') or shared:get('cancel:' .. id) then abort(control.cancelled()) end
            if xtimer.now_ms() > req.deadline then abort(control.deadline()) end
        end
        -- Check only at explicit safe points: a count hook can interrupt
        -- transaction rollback/publication. A file parse is size-bounded.
        local ok, result = pcall(function() control.check(); return execute(req) end)
        control.callback = nil
        if not ok then result = tostring(result) end
        shared:delete('cancel:' .. id)
        assert(xthread.post(1, 'worker_result', id, ok, result))
    end,
}
