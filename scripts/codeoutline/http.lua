local mcp = require('codeoutline.mcp')
local M = {}
local MAX_BODY, MAX_HEADER = 1048576, 16384

function M.start(config, submit, cancel, codec)
    local host, port = config.host, config.port
    local local_only = host == '127.0.0.1' or host == 'localhost' or host == '::1'
    assert(local_only or (config.token and #config.token >= 16 and #config.hosts > 0),
        'Remote HTTP requires CODEOUTLINE_TOKEN (at least 16 bytes) and ALLOW_HOST')
    local hosts, origins = {}, {}
    if local_only then hosts['127.0.0.1'], hosts.localhost, hosts['[::1]'] = true, true, true end
    for _, h in ipairs(config.hosts) do hosts[h] = true end
    for _, o in ipairs(config.origins) do origins[o] = true end
    local sessions, connections = {}, {}
    local session_count, connection_count = 0, 0
    local handler = {}

    local function respond(conn, req, status, body, headers)
        if not connections[conn] then return end
        headers = headers or {}
        headers['Content-Type'] = 'application/json'
        req.keep_alive = false
        codec.send_response(conn, req, { status = status, body = body or '', headers = headers,
            content_type = 'application/json' }, { server_name = 'CodeOutline' })
        conn:close('response complete')
    end
    local function fail(conn, req, status, message, code)
        respond(conn, req, status, xutils.json_pack(mcp.error(nil, code or -32000, message)))
    end
    local function authorized(header)
        if not config.token then return true end
        local expected = 'Bearer ' .. config.token
        if type(header) ~= 'string' or #header ~= #expected then return false end
        -- Constant time without bitwise operators, which LuaJIT cannot parse.
        local diff = 0
        for i = 1, #expected do
            local d = header:byte(i) - expected:byte(i)
            diff = diff + d * d
        end
        return diff == 0
    end
    local function remove_session(sid)
        local session = sessions[sid]
        if session then session:close(); sessions[sid] = nil; session_count = session_count - 1 end
    end

    local function request(conn, req)
        local h = req.headers
        local hostname = (h.host or ''):match('^(%[[%x:]+%]):?%d*$') or (h.host or ''):match('^([%w.%-]+):?%d*$')
        if not hosts[hostname] then fail(conn, req, 403, 'Host is not allowed'); return end
        if h.origin and not origins[h.origin] then fail(conn, req, 403, 'Origin is not allowed'); return end
        if not authorized(h.authorization) then fail(conn, req, 401, 'Bearer authentication required'); return end
        if req.path ~= '/mcp' then fail(conn, req, 404, 'Not found'); return end
        if h['mcp-protocol-version'] and h['mcp-protocol-version'] ~= mcp.VERSION then
            fail(conn, req, 400, 'Unsupported MCP protocol version'); return
        end
        local sid = h['mcp-session-id']
        local session = sid and sessions[sid]
        if sid and not session then fail(conn, req, 404, 'Session not found'); return end
        if req.method == 'GET' then
            respond(conn, req, 405, '', { Allow = 'POST, DELETE' }); return
        elseif req.method == 'DELETE' then
            if not session then fail(conn, req, 400, 'Session required'); return end
            remove_session(sid); respond(conn, req, 200); return
        elseif req.method ~= 'POST' then respond(conn, req, 405, '', { Allow = 'POST, DELETE' }); return end
        if not (h.accept or ''):find('application/json', 1, true) or not (h.accept or ''):find('text/event-stream', 1, true) then
            fail(conn, req, 406, 'Accept must include application/json and text/event-stream'); return
        end
        local content_type = (h['content-type'] or ''):lower():match('^%s*([^;%s]+)')
        if content_type ~= 'application/json' then fail(conn, req, 415, 'Content-Type must be application/json'); return end
        local msg, decode_error = mcp.decode(req.body)
        if not msg then respond(conn, req, 400, xutils.json_pack(decode_error)); return end
        if not session then
            if msg.method ~= 'initialize' or msg.id == nil then fail(conn, req, 400, 'Initialization required'); return end
            if session_count >= 64 then fail(conn, req, 503, 'Session limit reached'); return end
            sid = xutils.sha256_hex(xutils.random_bytes(32))
            session = mcp.new(config, submit, cancel)
            sessions[sid] = session
            session_count = session_count + 1
        end
        local stream = false
        session:dispatch(msg, function(response, notification)
            if not connections[conn] then return end
            if notification then
                if not stream then
                    stream = true
                    conn:send('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\nMcp-Session-Id: ' .. sid .. '\r\n\r\n')
                end
                conn:send('data: ' .. xutils.json_pack(response) .. '\n\n')
            elseif stream then
                if response then conn:send('data: ' .. xutils.json_pack(response) .. '\n\n') end
                conn:close('stream complete')
            else
                local headers = session.initialized and { ['Mcp-Session-Id'] = sid } or {}
                if not session.initialized then remove_session(sid) end
                respond(conn, req, response and 200 or ((msg.id == nil or msg.method == nil) and 202 or 204),
                    response and xutils.json_pack(response) or '', headers)
            end
        end)
    end

    function handler.on_connect(conn)
        if connection_count >= 128 then conn:close('connection limit'); return end
        conn:set_framing({ type = 'raw', max_packet = MAX_BODY + MAX_HEADER })
        connections[conn] = { buffer = '', started = xtimer.now_ms() }
        connection_count = connection_count + 1
    end
    function handler.on_packet(conn, data)
        local state = connections[conn]
        if not state then return #data end
        if state.dispatched then conn:close('HTTP pipelining is not supported'); return #data end
        state.buffer = state.buffer .. data
        local header_end = state.buffer:find('\r\n\r\n', 1, true)
        if (header_end or #state.buffer) > MAX_HEADER or #state.buffer > MAX_BODY + MAX_HEADER then
            fail(conn, {}, 413, 'Request too large'); return #data
        end
        local req, next_pos, err = codec.parse_request(state.buffer, 1, { max_request_size = MAX_BODY + MAX_HEADER })
        if not req then
            if err ~= 'incomplete' then fail(conn, {}, err == 'request too large' and 413 or 400, err) end
            return #data
        end
        if #req.body > MAX_BODY then fail(conn, req, 413, 'Request body too large'); return #data end
        if next_pos <= #state.buffer then fail(conn, req, 400, 'HTTP pipelining is not supported'); return #data end
        state.buffer, state.dispatched = '', true
        local ok, request_error = pcall(request, conn, req)
        if not ok then
            io.stderr:write('[codeoutline] HTTP: ' .. tostring(request_error) .. '\n')
            fail(conn, req, 500, 'Internal server error')
        end
        return #data
    end
    function handler.on_close(conn)
        if connections[conn] then connection_count = connection_count - 1 end
        connections[conn] = nil
    end
    local listener = assert(xnet.listen(host, port, handler))
    return {
        tick = function()
            local now = xtimer.now_ms()
            for sid, session in pairs(sessions) do
                session:tick()
                if not next(session.pending) and now - session.used > 900000 then remove_session(sid) end
            end
            for conn, state in pairs(connections) do
                if now - state.started > (state.dispatched and 125000 or 15000) then conn:close('timeout') end
            end
        end,
        close = function()
            for sid in pairs(sessions) do remove_session(sid) end
            for conn in pairs(connections) do conn:close('shutdown') end
            listener:close('shutdown')
        end,
    }
end

return M
