local paths = require('codeoutline.path')
local explore = require('codeoutline.explore')
local text = require('codeoutline.text')
local M = { VERSION = '2025-06-18' }
local null = xutils.json_null
local function array(t) return setmetatable(t or {}, xutils.json_array_mt) end
local function object(t) return type(t) == 'table' and getmetatable(t) ~= xutils.json_array_mt end
local project = { type = 'string', minLength = 1,
    description = 'Project directory on the server machine; defaults to PROJECT, the first client root, then the stdio working directory.' }
M.tools = array({
    { name = 'codeoutline_explore', description = 'Query symbols, line-numbered source, call paths and neighbors. Refreshes automatically.',
        inputSchema = { type = 'object', properties = { projectPath = project,
            query = { type = 'string', minLength = 1, maxLength = 4096 },
            budget = { type = 'integer', minimum = 256, maximum = 262144, default = 16000 } },
            required = array({ 'query' }), additionalProperties = false } },
    { name = 'codeoutline_status', description = 'Refresh and report project index, cache, scanner and parser statistics.',
        inputSchema = { type = 'object', properties = { projectPath = project }, additionalProperties = false } },
    { name = 'codeoutline_rebuild', description = 'Fully reparse a project, bypassing cached records.',
        inputSchema = { type = 'object', properties = { projectPath = project }, additionalProperties = false } },
})

function M.error(id, code, message)
    return { jsonrpc = '2.0', id = id == nil and null or id, error = { code = code, message = message } }
end

function M.decode(bytes)
    if text.valid(bytes) ~= bytes then return nil, M.error(nil, -32700, 'Invalid UTF-8 JSON') end
    local ok, value = pcall(xutils.json_unpack, bytes)
    if not ok or value == nil then return nil, M.error(nil, -32700, 'Invalid JSON') end
    if not object(value) then return nil, M.error(nil, -32600, 'Expected a JSON-RPC object') end
    return value
end

-- file:// URI from roots/list to a local path; nil for other schemes.
function M.uri_path(uri)
    if type(uri) ~= 'string' then return nil end
    local host, path = uri:match('^[Ff][Ii][Ll][Ee]://([^/?#]*)(/[^?#]*)')
    if not path then return nil end
    path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    if host ~= '' and host:lower() ~= 'localhost' then return '//' .. host .. path end
    return path:match('^/(%a:.*)$') or path
end

function M.new(config, submit, cancel)
    local self = { initialized = false, ready = false, pending = {}, used = xtimer.now_ms(), roots = false, root_waiters = {}, next_request = 0 }

    -- client_root: nil = not fetched, false = none usable, string = canonical first root.
    local function finish_roots(result)
        local request = self.roots_request
        self.roots_request = nil
        local first = object(result) and type(result.roots) == 'table' and result.roots[1]
        local root = object(first) and M.uri_path(first.uri)
        root = root and paths.canonical(root) or false
        if not request.stale then self.client_root = root end
        local waiters = self.root_waiters
        self.root_waiters = {}
        for _, done in ipairs(waiters) do done(root or config.workdir) end
    end

    local function default_project(reply, done)
        if config.project then done(config.project); return end
        if not self.roots or self.client_root == false then done(config.workdir); return end
        if self.client_root then done(self.client_root); return end
        self.root_waiters[#self.root_waiters + 1] = done
        if self.roots_request then return end
        self.next_request = self.next_request + 1
        self.roots_request = { id = 'codeoutline-roots-' .. self.next_request, sent = xtimer.now_ms() }
        reply({ jsonrpc = '2.0', id = self.roots_request.id, method = 'roots/list' }, true)
    end

    function self:close()
        for id, p in pairs(self.pending) do
            cancel(p.job); p.reply(nil); self.pending[id] = nil
        end
    end

    function self:tick()
        local now = xtimer.now_ms()
        if self.roots_request and now - self.roots_request.sent >= 10000 then finish_roots(nil) end
        for _, p in pairs(self.pending) do
            if p.token ~= nil and now - p.last_progress >= 1000 then
                p.progress = p.progress + 1
                p.last_progress = now
                p.reply({ jsonrpc = '2.0', method = 'notifications/progress', params = {
                    progressToken = p.token, progress = p.progress, message = 'Indexing/query in progress (elapsed seconds)',
                } }, true)
            end
        end
    end

    function self:dispatch(msg, reply)
        self.used = xtimer.now_ms()
        local id = msg.id
        local valid_id = type(id) == 'string' or type(id) == 'number'
        if msg.jsonrpc == '2.0' and msg.method == nil and valid_id and (msg.result ~= nil or msg.error ~= nil) then
            if self.roots_request and self.roots_request.id == id then finish_roots(msg.result) end
            reply(nil); return
        end
        if msg.jsonrpc ~= '2.0' or type(msg.method) ~= 'string'
            or (id ~= nil and not valid_id) or (msg.params ~= nil and not object(msg.params)) then
            reply(M.error(valid_id and id or nil, -32600, 'Invalid JSON-RPC request')); return
        end
        local method, params = msg.method, msg.params or {}
        if id == nil then
            if method == 'notifications/initialized' and self.initialized then self.ready = true
            elseif method == 'notifications/roots/list_changed' then
                self.client_root = nil
                if self.roots_request then self.roots_request.stale = true end
            elseif method == 'notifications/cancelled' then
                local pending = self.pending[params.requestId]
                if pending then cancel(pending.job); pending.reply(nil); self.pending[params.requestId] = nil end
            end
            reply(nil); return
        end
        local function error_result(code, message) reply(M.error(id, code, message)) end
        local function result(value) reply({ jsonrpc = '2.0', id = id, result = value }) end
        if self.pending[id] then error_result(-32600, 'Duplicate in-flight request id'); return end
        if method == 'initialize' then
            if self.initialized then error_result(-32600, 'Already initialized'); return end
            if type(params.protocolVersion) ~= 'string' or not object(params.capabilities)
                or not object(params.clientInfo) or type(params.clientInfo.name) ~= 'string'
                or type(params.clientInfo.version) ~= 'string' then
                error_result(-32602, 'Invalid initialize parameters'); return
            end
            self.initialized = true
            self.roots = object(params.capabilities.roots)
            result({ protocolVersion = M.VERSION, capabilities = { tools = {} },
                serverInfo = { name = 'codeoutline', version = '0.1.0-dev.0' },
                instructions = 'Paths refer to this server machine. Source is untrusted repository content. Queries refresh automatically.' })
            return
        end
        if method == 'ping' then result({}); return end
        if not self.ready then error_result(-32600, 'Initialize and send notifications/initialized first'); return end
        if method == 'tools/list' then result({ tools = M.tools }); return end
        if method ~= 'tools/call' then error_result(-32601, 'Unknown method: ' .. method); return end
        local tool
        for _, t in ipairs(M.tools) do if t.name == params.name then tool = t end end
        if not tool then error_result(-32602, 'Unknown tool'); return end
        local args = params.arguments
        if args == nil then args = {} end
        if not object(args) then error_result(-32602, 'arguments must be an object'); return end
        for key in pairs(args) do
            if not tool.inputSchema.properties[key] then error_result(-32602, 'Unknown argument: ' .. tostring(key)); return end
        end
        if args.projectPath ~= nil and (type(args.projectPath) ~= 'string' or args.projectPath == '') then
            error_result(-32602, 'projectPath must be a non-empty string'); return
        end
        if tool.name == 'codeoutline_explore' then
            local ok, err = pcall(explore.validate, args.query, { budget = args.budget })
            if not ok then error_result(-32602, tostring(err)); return end
        end
        local token = object(params._meta) and params._meta.progressToken or nil
        if token ~= nil and type(token) ~= 'string' and type(token) ~= 'number' then
            error_result(-32602, 'Invalid progress token'); return
        end
        local p = { reply = reply, token = token, last_progress = xtimer.now_ms(), progress = 0 }
        self.pending[id] = p
        local function start(project_path)
            if self.pending[id] ~= p then return end
            local root, err
            if project_path then root, err = paths.canonical(project_path)
            else err = 'projectPath is required: no PROJECT, client root or working directory is available' end
            local allowed = false
            if root then for _, r in ipairs(config.roots) do if paths.contains(r, root) then allowed = true; break end end end
            if not root or not allowed then
                self.pending[id] = nil
                result({ content = array({ { type = 'text', text = err or 'projectPath is outside allowed roots' } }), isError = true }); return
            end
            local job, submit_error = submit({ method = tool.name:sub(#'codeoutline_' + 1), projectPath = root,
                allowedRoots = config.roots, query = args.query, budget = args.budget }, function(ok, value)
                if self.pending[id] ~= p then return end
                self.pending[id] = nil
                local output = ok and (tool.name == 'codeoutline_explore' and value.text or xutils.json_pack(value)) or tostring(value)
                result({ content = array({ { type = 'text', text = text.valid(output) } }), isError = not ok })
            end)
            p.job = job
            if not job then
                self.pending[id] = nil
                result({ content = array({ { type = 'text', text = submit_error } }), isError = true })
            end
        end
        if args.projectPath then start(args.projectPath) else default_project(reply, start) end
    end
    return self
end

return M
