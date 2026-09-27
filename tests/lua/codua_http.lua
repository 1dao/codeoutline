-- Opt-in interoperability test against the unmodified sibling client's code.
local assets = assert(os.getenv('CODEOUTLINE_CODUA_SCRIPTS')):gsub('\\', '/')
package.path = assets .. '/?.lua;' .. package.path
local client = require('xagent.mcp.client')
local fetch_tools = require('xagent.mcp.fetch_tools')
local project = assert(os.getenv('CODEOUTLINE_TEST_PROJECT')):gsub('\\', '/')
local function run()
    local c = client.new('codeoutline', { type = 'http', url = assert(os.getenv('CODEOUTLINE_TEST_URL')) })
    assert(c:connect())
    assert(c.transport.protocol_version == '2025-06-18')
    local tools = assert(fetch_tools.fetch(c))
    assert(#tools == 3)
    local explore
    for _, tool in ipairs(tools) do if tool.name:find('codeoutline_explore', 1, true) then explore = tool end end
    assert(explore)
    local first = explore.call({ projectPath = project, query = 'before_edit' })
    assert(not first.is_error and first.content:find('return 11', 1, true))
    local again = explore.call({ projectPath = project, query = 'before_edit' })
    assert(not again.is_error and again.content:find('return 11', 1, true))
    local f = assert(io.open(project .. '/client.lua', 'wb'))
    assert(f:write('function after_edit() return 22 end\n')); f:close()
    local changed = explore.call({ projectPath = project, query = 'after_edit' })
    assert(not changed.is_error and changed.content:find('return 22', 1, true))
    io.write('CODUA_HTTP_OK: initialize, discover, first/repeat query, edit refresh\n'); io.flush()
end
return {
    __init = function()
        assert(xnet.init())
        local co = coroutine.create(function()
            local ok, err = pcall(run)
            if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
            xthread.stop(0)
        end)
        assert(coroutine.resume(co))
    end,
    __uninit = function() xnet.uninit() end,
}
