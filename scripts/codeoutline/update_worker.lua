-- Background update thread: network, verification and installation stay off the
-- service thread. An installed update applies to the next launch.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local updater = require('codeoutline.updater')

return {
    __init = function()
        assert(xnet.init()); xtimer.init(16)
        local ok, err = pcall(function()
            require('xupgate.client').open(updater.config()).update(function(update_error, result)
                xthread.post(1, 'update_result', update_error, result and result.version)
            end)
        end)
        if not ok then xthread.post(1, 'update_result', tostring(err)) end
    end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
