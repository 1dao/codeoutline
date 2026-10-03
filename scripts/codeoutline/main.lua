-- Native entry point: xnet main.lua STDIO=1 PROJECT=... or HTTP=1 PORT=19876.
-- DAEMON=1 (with HTTP=1) runs the shared background service; see daemon.lua.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
local install = assert(scripts:match('^(.*)/scripts$'))
package.path = scripts .. '/?.lua;' .. package.path
local paths = require('codeoutline.path')
local mcp = require('codeoutline.mcp')
local http = require('codeoutline.http')
local daemon = require('codeoutline.daemon')
local options = { ALLOW_ROOT = {}, ALLOW_HOST = {}, ALLOW_ORIGIN = {} }
for _, argument in ipairs(arg or {}) do
    local key, value = argument:match('^([A-Z_]+)=(.*)$')
    if key then
        if type(options[key]) == 'table' then table.insert(options[key], value) else options[key] = value end
    end
end
assert((options.STDIO == '1') ~= (options.HTTP == '1'), 'Specify exactly one of STDIO=1 or HTTP=1')
local managed = options.DAEMON == '1'
assert(not managed or options.HTTP == '1', 'DAEMON=1 requires HTTP=1')
local config = { roots = {}, project = options.PROJECT and assert(paths.canonical(options.PROJECT)),
    workdir = options.STDIO == '1' and paths.canonical('.') or nil, host = options.HOST or '127.0.0.1', port = tonumber(options.PORT or '19876'),
    token = os.getenv('CODEOUTLINE_TOKEN'), hosts = options.ALLOW_HOST, origins = options.ALLOW_ORIGIN }
assert(config.port and config.port % 1 == 0 and config.port >= 1 and config.port <= 65535, 'Invalid PORT')
if config.token == '' then config.token = nil end
-- Stdio mode owns stdout for protocol messages, so its notices go to stderr.
local function notice(text)
    local stream = options.STDIO == '1' and io.stderr or io.stdout
    stream:write('[codeoutline] ', text, '\n'); stream:flush()
end
-- A missing root (an unmounted drive, say) is kept as written and matches once
-- it exists: failing startup would take down a service started at login.
for _, root in ipairs(options.ALLOW_ROOT) do
    local canonical, err = paths.canonical(root)
    if not canonical then notice('warning: allowed root ' .. root .. ' is unavailable (' .. err .. ')') end
    config.roots[#config.roots + 1] = canonical or paths.normalize(root)
end
if #config.roots == 0 then
    if options.HTTP == '1' and (config.host == '127.0.0.1' or config.host == 'localhost' or config.host == '::1') then
        -- One loopback service serves every project of every session. Only local
        -- processes reach it, and they already hold the user's file access.
        config.roots = false
    else
        config.roots[1] = config.project or assert(paths.canonical('.'))
    end
end
local shared = assert(xshared.create('codeoutline_control', 65536, 256))
local jobs, next_id, job_count, worker_ready = {}, 0, 0, false
local endpoint, stdio, input = nil, nil, ''
local updating = false
local startup = xtimer.now_ms()
-- After installing an update, exit once idle so the next start runs it: MCP
-- clients restart stdio servers on demand, and the background service starts
-- its replacement itself. A manually started HTTP service keeps running unless asked.
local exit_on_update = os.getenv('CODEOUTLINE_EXIT_ON_UPDATE')
if managed then exit_on_update = true
elseif exit_on_update == nil or exit_on_update == '' then exit_on_update = options.STDIO == '1'
else exit_on_update = exit_on_update == '1' end
local installed_update
-- Background service: listening starts once the port proved free.
local codec, next_stop_check = nil, 0

local function submit(req, done)
    if job_count >= 64 then return nil, 'Request queue is full; retry later' end
    next_id = next_id + 1
    local id = tostring(next_id)
    req.deadline = xtimer.now_ms() + 120000
    jobs[id], job_count = { done = done, request = req }, job_count + 1
    if worker_ready then
        local ok, err = xthread.post(2, 'run', id, req)
        if not ok then jobs[id], job_count = nil, job_count - 1; return nil, tostring(err) end
    end
    return id
end
local function cancel(id) if id and jobs[id] then shared:set('cancel:' .. id, true) end end
local function send(response)
    if response then io.stdout:write(xutils.json_pack(response), '\n'); io.stdout:flush() end
end
local function listen()
    endpoint = http.start(config, submit, cancel, codec)
    -- A status line, not an error: xnet routes io.stderr through the
    -- error log. HTTP mode leaves stdout free (stdio mode owns it).
    io.stdout:write(string.format('[codeoutline] listening http://%s:%d/mcp\n', config.host, config.port))
    io.stdout:flush()
end
local stopping, indexing = false, false
local function stop(code) stopping = true; xthread.stop(code) end

return {
    __tick_ms = 5,
    __init = function()
        assert(xnet.init())
        if managed then
            xtimer.init(16)
            -- One background service runs the newest installed version.
            if not daemon.is_current(install) then
                notice('starting the newest installed version')
                assert(daemon.spawn(daemon.current_root(install), config.port), 'cannot start the newest version')
                stop(0); return
            end
            os.remove(daemon.stop_file(config.port))
        end
        assert(xthread.create_thread(2, 'INDEX', scripts .. '/codeoutline/index_worker.lua'))
        indexing = true
        -- Launchers enable this for serve; the background service updates unless
        -- disabled. Updating never delays or blocks requests.
        local auto_update = os.getenv('CODEOUTLINE_AUTO_UPDATE')
        if auto_update == '1' or (managed and auto_update ~= '0') then
            updating = xthread.create_thread(3, 'UPDATE', scripts .. '/codeoutline/update_worker.lua') and true
        end
        if options.STDIO == '1' then
            assert(xutils.read_stdin, 'Rebuild runtime for nonblocking stdin support')
            stdio = mcp.new(config, submit, cancel)
        else
            -- Packages ship the codec as lib/xhttp_codec.lua; a source checkout
            -- reads it from the xnet2lua submodule.
            local codec_path = options.RUNTIME_ROOT and options.RUNTIME_ROOT .. '/scripts/core/share/xhttp_codec.lua'
                or install .. '/lib/xhttp_codec.lua'
            local probe = io.open(codec_path, 'rb')
            if probe then probe:close()
            else codec_path = install .. '/xnet2lua/scripts/core/share/xhttp_codec.lua' end
            codec = dofile(codec_path)
            if not managed then listen()
            else
                -- Windows lets a second listener bind the same port, so the
                -- background service checks for a running one first.
                daemon.probe(config.port, function(listening)
                    if stopping then return end
                    if listening then notice('a service already listens on port ' .. config.port); stop(0); return end
                    listen()
                end)
            end
        end
    end,
    __thread_handle = function(_, op, id, ok, result)
        if op == 'worker_ready' then
            worker_ready = true
            for job_id, job in pairs(jobs) do
                local posted, err = xthread.post(2, 'run', job_id, job.request)
                if not posted then jobs[job_id], job_count = nil, job_count - 1; job.done(false, tostring(err)) end
            end
        elseif op == 'worker_result' then
            local job = jobs[id]
            if job then jobs[id], job_count = nil, job_count - 1; job.done(ok, result) end
        elseif op == 'update_result' then
            -- Arguments: error, installed version (nil when already current).
            if id then notice('update unavailable: ' .. tostring(id))
            elseif ok then
                installed_update = ok
                notice('update ' .. tostring(ok) .. ' installed; ' .. (exit_on_update and 'exiting when idle' or 'restart to use it'))
            end
        end
    end,
    __update = function()
        if stopping then return end
        if not worker_ready and xtimer.now_ms() - startup > 10000 then error('Index worker failed to start') end
        if installed_update and exit_on_update and job_count == 0
            and not (stdio and next(stdio.pending)) and not (endpoint and endpoint.busy()) then
            notice('exiting to start update ' .. tostring(installed_update))
            if managed then
                -- Free the port, then start the update as this service's replacement.
                if endpoint then endpoint.close(); endpoint = nil end
                if not daemon.spawn(daemon.current_root(install), config.port) then notice('cannot start update ' .. tostring(installed_update)) end
            end
            stop(0); return
        end
        if managed and xtimer.now_ms() >= next_stop_check then
            next_stop_check = xtimer.now_ms() + 1000
            if xutils.stat(daemon.stop_file(config.port)).exists then notice('stop requested'); stop(0); return end
        end
        if stdio then
            local data, err = xutils.read_stdin(65536)
            if not data then
                local incomplete = err == 'eof' and input:find('%S') ~= nil
                if incomplete then send(mcp.error(nil, -32700, 'EOF before message newline')) end
                if err == 'stdio requires redirected stdin' then err = 'run by an MCP client; see codeoutline --help' end
                if err ~= 'eof' then io.stderr:write(tostring(err) .. '\n') end
                stdio:close(); shared:set('shutdown', true); xthread.stop(err == 'eof' and not incomplete and 0 or 1); return
            end
            input = input .. data
            while true do
                local pos = input:find('\n', 1, true)
                if not pos then break end
                local line = input:sub(1, pos - 1)
                input = input:sub(pos + 1)
                if #line > 1048576 then send(mcp.error(nil, -32600, 'Message too large')); xthread.stop(1); return end
                local msg, decode_error = mcp.decode(line)
                if not msg then send(decode_error) else stdio:dispatch(msg, send) end
            end
            if #input > 1048576 then send(mcp.error(nil, -32600, 'Message too large')); xthread.stop(1); return end
            stdio:tick()
        elseif endpoint then endpoint.tick() end
    end,
    __uninit = function()
        shared:set('shutdown', true)
        if stdio then stdio:close() end
        if endpoint then endpoint.close() end
        if indexing then xthread.shutdown_thread(2) end
        if updating then xthread.shutdown_thread(3) end
        xnet.uninit()
    end,
}
