-- Background update thread: network, verification and installation stay off the
-- service thread. Checks at startup and then hourly while the service runs.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local updater = require('codeoutline.updater')
local INTERVAL_MS = 3600000
local checking = false

local function check()
    if checking then return end
    checking = true
    local ok, err = pcall(function()
        require('xupgate.client').open(updater.config()).update(function(update_error, result)
            checking = false
            xthread.post(1, 'update_result', update_error, result and result.version)
        end)
    end)
    if not ok then checking = false; xthread.post(1, 'update_result', tostring(err)) end
end

return {
    __init = function()
        assert(xnet.init()); xtimer.init(16)
        check()
        xtimer.add(INTERVAL_MS, check, -1)
    end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
