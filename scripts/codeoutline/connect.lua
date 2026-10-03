-- stdio MCP proxy for the shared local HTTP service. It starts the service when
-- nothing listens, and re-establishes its session after the service restarts
-- (an installed update, say). Messages pass through unchanged.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
local install = assert(scripts:match('^(.*)/scripts$'))
package.path = scripts .. '/?.lua;' .. package.path
local mcp = require('codeoutline.mcp')
local u = require('xutils')
local options = {}
for _, value in ipairs(arg or {}) do
    local k, v = value:match('^([A-Z_]+)=(.*)$'); if k then options[k] = v end
end
local HOST = '127.0.0.1'
local port = tonumber(options.PORT or '19876')
assert(port and port % 1 == 0 and port >= 1 and port <= 65535, 'Invalid PORT')
local windows = package.config:sub(1, 1) == '\\'
local START_TIMEOUT_MS = 20000

local function notice(text) io.stderr:write('[codeoutline connect] ', text, '\n') end
local function emit(message)
    io.stdout:write(type(message) == 'string' and message or xutils.json_pack(message), '\n'); io.stdout:flush()
end
local function later(ms, fn) xtimer.add(ms, fn, 1) end

-- One POST per message; the service closes every connection after responding.
-- on_event receives each SSE data payload as it arrives; on_done(status,
-- headers, body) has status nil when no response header arrived.
local function post(body, session, on_event, on_done)
    local buffer, status, headers, sse = '', nil, nil, false
    local finished = false
    local function finish()
        if finished then return end
        finished = true
        on_done(status, headers or {}, sse and '' or buffer)
    end
    local function events()
        while true do
            local stop = buffer:find('\n\n', 1, true)
            if not stop then return end
            local event = buffer:sub(1, stop - 1)
            buffer = buffer:sub(stop + 2)
            local data = {}
            for line in (event .. '\n'):gmatch('([^\n]*)\n') do
                local value = line:gsub('\r$', ''):match('^data: ?(.*)$')
                if value then data[#data + 1] = value end
            end
            if #data > 0 then on_event(table.concat(data, '\n')) end
        end
    end
    local request = 'POST /mcp HTTP/1.1\r\nHost: ' .. HOST .. ':' .. port .. '\r\n'
        .. 'Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\n'
        .. (session and 'Mcp-Session-Id: ' .. session .. '\r\n' or '')
        .. 'Content-Length: ' .. #body .. '\r\nConnection: close\r\n\r\n' .. body
    local conn = xnet.connect(HOST, port, {
        on_connect = function(c)
            c:set_framing({ type = 'raw', max_packet = 4194304 })
            c:send(request)
        end,
        on_packet = function(_, data)
            buffer = buffer .. data
            if not headers then
                local stop = buffer:find('\r\n\r\n', 1, true)
                if not stop then return #data end
                local head = buffer:sub(1, stop - 1)
                buffer = buffer:sub(stop + 4)
                status = tonumber(head:match('^HTTP/%d%.%d (%d%d%d)'))
                headers = {}
                for name, value in head:gmatch('\r\n([^:\r\n]+):%s*([^\r\n]*)') do headers[name:lower()] = value end
                sse = (headers['content-type'] or ''):find('text/event-stream', 1, true) ~= nil
            end
            if sse then events() end
            return #data
        end,
        on_close = function() finish() end,
    })
    if not conn then later(1, finish) end
end

-- Prefer the verified installed update, as the launchers do; a source checkout
-- (no build-info.json) runs itself.
local function service_root()
    if not u.stat(install .. '/build-info.json').exists then return install end
    local ok, current = pcall(function()
        return require('xupgate.client').open(require('codeoutline.updater').config()).current()
    end)
    return ok and current and current.root or install
end

-- Start the service detached from this session: it must outlive the client
-- that started it and must not inherit its stdio pipes.
local function spawn_service()
    local root = service_root()
    local runtime = root .. (windows and '/bin/xnet.exe' or '/bin/xnet')
    local entry = root .. '/scripts/codeoutline/command.lua'
    local home = (os.getenv('USERPROFILE') or os.getenv('HOME') or '.'):gsub('\\', '/')
    local logs = home .. '/.codeoutline/logs'
    u.mkdir_p(logs)
    if windows then
        for _, path in ipairs({ runtime, entry, logs }) do assert(not path:find('[%%"\r\n]'), 'unsupported path: ' .. path) end
        -- Paths travel through the environment, keeping the script ASCII and unquoted.
        local script = "$ProgressPreference='SilentlyContinue';$env:CODEOUTLINE_AUTO_UPDATE='1';$env:CODEOUTLINE_EXIT_ON_UPDATE='1';"
            .. "Start-Process -WindowStyle Hidden -WorkingDirectory $env:CO_LOGS -FilePath $env:CO_RUNTIME -ArgumentList "
            .. "('\"'+$env:CO_ENTRY+'\"'),'LOG_STDERR=0','LOG_LEVEL=WARN',('\"LOG_DIR='+$env:CO_LOGS+'\"'),"
            .. "'serve','--http','--port','" .. port .. "'"
        local encoded = {}
        for i = 1, #script do encoded[#encoded + 1] = script:sub(i, i) .. '\0' end
        os.execute('set "CO_RUNTIME=' .. runtime .. '" && set "CO_ENTRY=' .. entry .. '" && set "CO_LOGS=' .. logs
            .. '" && powershell -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' .. u.base64_encode(table.concat(encoded)) .. ' >NUL 2>&1')
    else
        local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
        os.execute('cd ' .. quote(logs) .. ' && S=; command -v setsid >/dev/null 2>&1 && S=setsid; '
            .. 'CODEOUTLINE_AUTO_UPDATE=1 CODEOUTLINE_EXIT_ON_UPDATE=1 $S nohup ' .. quote(runtime) .. ' ' .. quote(entry)
            .. ' LOG_STDERR=0 LOG_LEVEL=WARN ' .. quote('LOG_DIR=' .. logs) .. ' serve --http --port ' .. port
            .. ' </dev/null >/dev/null 2>&1 &')
    end
end

local queue, blocking, starting = {}, false, false
local session, initialize, initialized, internal_id = nil, nil, false, 0
local pump

local function fail(message, text)
    if message.method and message.id ~= nil then emit(mcp.error(message.id, -32000, text)) end
end

-- Wait until the port accepts connections, starting the service once.
local function ensure_service()
    if starting then return end
    starting = true
    notice('starting the shared service on port ' .. port)
    local ok, err = pcall(spawn_service)
    if not ok then notice('cannot start the service: ' .. tostring(err)) end
    local deadline = xtimer.now_ms() + START_TIMEOUT_MS
    local function probe()
        local connected = false
        local conn = xnet.connect(HOST, port, {
            on_connect = function(c) connected = true; c:close('probe') end,
            on_packet = function(_, data) return #data end,
            on_close = function()
                if connected then starting = false; pump(); return end
                if xtimer.now_ms() >= deadline then
                    starting = false
                    notice('the service did not start; see ~/.codeoutline/logs')
                    local failed = queue
                    queue = {}
                    for _, item in ipairs(failed) do fail(item.message, 'CodeOutline service did not start') end
                    return
                end
                later(250, probe)
            end,
        })
        if not conn then later(250, probe) end
    end
    probe()
end

-- Replay the client's handshake on a new session after the service restarted.
local function reinitialize(after)
    internal_id = internal_id + 1
    local replay = {}
    for k, v in pairs(initialize) do replay[k] = v end
    replay.id = 'codeoutline-connect-' .. internal_id
    post(xutils.json_pack(replay), nil, function() end, function(status, headers)
        if status ~= 200 or not headers['mcp-session-id'] then after(false); return end
        session = headers['mcp-session-id']
        if not initialized then after(true); return end
        post('{"jsonrpc":"2.0","method":"notifications/initialized"}', session, function() end, function(done)
            after(done == 202 or done == 204)
        end)
    end)
end

local function send(item)
    local message = item.message
    local request = message.method ~= nil and message.id ~= nil
    -- The handshake and notifications complete before later messages, which
    -- keeps their order; requests run concurrently (a tool call stays open
    -- while the client answers roots/list).
    if message.method == 'initialize' or not request then blocking = true end
    local answered = false
    local function deliver(data)
        local decoded = mcp.decode(data)
        if request and decoded and decoded.id == message.id and decoded.method == nil then answered = true end
        emit(data)
    end
    post(item.raw, message.method ~= 'initialize' and session or nil, deliver, function(status, headers, body)
        if not status then
            -- Nothing answered: the service is down. Start it and resend; the
            -- stale session then gets 404 and is replaced below.
            table.insert(queue, 1, item)
            blocking = false
            ensure_service(); return
        end
        if status == 404 and session and message.method ~= 'initialize' then
            -- The service restarted or expired this session.
            session = nil
            if not initialize then fail(message, 'CodeOutline session lost'); blocking = false; pump(); return end
            blocking = true
            reinitialize(function(ok)
                blocking = false
                if ok then table.insert(queue, 1, item) else fail(message, 'CodeOutline session could not be restored') end
                pump()
            end)
            return
        end
        if message.method == 'initialize' and status == 200 then
            local decoded = mcp.decode(body)
            local info = decoded and type(decoded.result) == 'table' and decoded.result.serverInfo
            if not (type(info) == 'table' and info.name == 'codeoutline') then
                notice('port ' .. port .. ' is not a CodeOutline service')
                fail(message, 'Port ' .. port .. ' is used by another program'); xthread.stop(1); return
            end
            session = headers['mcp-session-id']
        end
        if body ~= '' then
            if status >= 400 and request then
                local decoded = mcp.decode(body)
                local text = decoded and type(decoded.error) == 'table' and decoded.error.message or ('HTTP ' .. status)
                emit(mcp.error(message.id, -32000, tostring(text)))
            else deliver(body) end
        elseif request and not answered then
            fail(message, 'CodeOutline service closed the request; retry')
        end
        if message.method == 'initialize' or not request then blocking = false end
        pump()
    end)
end

pump = function()
    while not blocking and not starting and #queue > 0 do send(table.remove(queue, 1)) end
end

local function accept(line)
    local message, decode_error = mcp.decode(line)
    if not message then emit(decode_error); return end
    if message.method == 'initialize' then initialize = message end
    if message.method == 'notifications/initialized' then initialized = true end
    queue[#queue + 1] = { raw = line, message = message }
    pump()
end

local input = ''
local closing = false
return {
    __tick_ms = 5,
    __init = function()
        assert(xnet.init()); xtimer.init(16)
        assert(xutils.read_stdin, 'Rebuild runtime for nonblocking stdin support')
    end,
    __update = function()
        if closing then return end
        local data, err = xutils.read_stdin(65536)
        if not data and err == 'stdio requires redirected stdin' and not session and #queue == 0 then
            -- Started from a Windows console rather than by an MCP client.
            closing = true
            io.write('Run by an MCP client; see codeoutline --help.\n'); io.stdout:flush()
            xthread.stop(0); return
        end
        if not data then
            if err ~= 'eof' then notice(tostring(err)) end
            closing = true
            -- Let the service free this session now rather than at idle expiry.
            local stop = function() xthread.stop(err == 'eof' and 0 or 1) end
            if not session then stop(); return end
            local conn = xnet.connect(HOST, port, {
                on_connect = function(c)
                    c:set_framing({ type = 'raw' })
                    c:send('DELETE /mcp HTTP/1.1\r\nHost: ' .. HOST .. ':' .. port .. '\r\nMcp-Session-Id: ' .. session
                        .. '\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                end,
                on_packet = function(_, d) return #d end,
                on_close = stop,
            })
            if not conn then stop() else later(1000, stop) end
            return
        end
        input = input .. data
        while true do
            local pos = input:find('\n', 1, true)
            if not pos then break end
            local line = input:sub(1, pos - 1):gsub('\r$', '')
            input = input:sub(pos + 1)
            if line:find('%S') then accept(line) end
        end
        if #input > 1048576 then emit(mcp.error(nil, -32600, 'Message too large')); xthread.stop(1) end
    end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
