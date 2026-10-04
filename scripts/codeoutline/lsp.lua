local documents = require('codeoutline.documents')
local paths = require('codeoutline.path')
local text = require('codeoutline.text')
local M = { MAX_HEADER = 16384, MAX_MESSAGE = 4194304, MAX_ROOTS = 16,
    MAX_DOCUMENTS = 128, MAX_DRAFT_BYTES = 33554432, MAX_PENDING = 64,
    MAX_QUERY = 4096, MAX_SYMBOLS = 200, POLL_MS = 1000 }
local null = xutils.json_null
local function array(t) return setmetatable(t or {}, xutils.json_array_mt) end
local function object(t) return type(t) == 'table' and getmetatable(t) ~= xutils.json_array_mt end
local function valid_id(id) return type(id) == 'string' or (type(id) == 'number' and id % 1 == 0) end
local kinds = { namespace = 3, impl = 3, class = 5, method = 6, property = 7, field = 8,
    constructor = 9, destructor = 9, enum = 10, interface = 11, ['function'] = 12, prototype = 12,
    variable = 13, constant = 14, enum_member = 22, struct = 23, union = 23, record = 23,
    typedef = 13, macro = 12, annotation_type = 11 }

function M.frame(message)
    local body = xutils.json_pack(message)
    return 'Content-Length: ' .. #body .. '\r\n\r\n' .. body
end

function M.reader()
    local self = { buffer = '', length = nil }
    function self:feed(data, accept)
        self.buffer = self.buffer .. data
        while true do
            if not self.length then
                local stop = self.buffer:find('\r\n\r\n', 1, true)
                assert((stop or #self.buffer) <= M.MAX_HEADER, 'LSP header too large')
                if not stop then return end
                local header = self.buffer:sub(1, stop - 1)
                local length
                for line in (header .. '\r\n'):gmatch('(.-)\r\n') do
                    local name, value = line:match('^([%w%-]+):%s*(.-)%s*$')
                    assert(name, 'invalid LSP header')
                    if name:lower() == 'content-length' then
                        assert(not length and value:match('^%d+$'), 'invalid Content-Length')
                        length = tonumber(value)
                    elseif name:lower() == 'content-type' then
                        local charset = value:lower():match('charset%s*=%s*([^;%s]+)')
                        assert(not charset or charset == 'utf-8' or charset == 'utf8', 'unsupported LSP charset')
                    end
                end
                assert(length and length <= M.MAX_MESSAGE, 'missing or excessive Content-Length')
                self.length, self.buffer = length, self.buffer:sub(stop + 4)
            end
            if #self.buffer < self.length then return end
            local body = self.buffer:sub(1, self.length)
            self.buffer, self.length = self.buffer:sub(self.length + 1), nil
            accept(body)
        end
    end
    function self:complete() return self.length == nil and self.buffer == '' end
    return self
end

local function kind(node) return kinds[node.kind] or 13 end
local function location(doc, node) return { uri = doc.uri, range = doc:range(node.name_start, node.name_end) } end

function M.document_symbols(doc, hierarchical)
    local rec, result, entries = doc:parse(), array(), {}
    for i, node in ipairs(rec.nodes) do
        local item
        if hierarchical then
            item = { name = node.name, detail = node.sig, kind = kind(node),
                range = doc:range(node.start_byte, node.end_byte), selectionRange = doc:range(node.name_start, node.name_end) }
        else item = { name = node.name, kind = kind(node), location = location(doc, node),
            containerName = node.parent and rec.nodes[node.parent].qualified or nil } end
        entries[i] = item
        local pn = node.parent and rec.nodes[node.parent]
        if hierarchical and pn and entries[node.parent]
            and pn.start_byte <= node.start_byte and node.end_byte <= pn.end_byte then
            local parent = entries[node.parent]
            parent.children = parent.children or array()
            parent.children[#parent.children + 1] = item
            -- Logical parents of out-of-line methods are not lexical containers.
        else result[#result + 1] = item end
    end
    return result
end

function M.new(config, emit, submit, cancel, stop)
    config = config or {}
    local self = { state = 'new', documents = {}, roots = {}, pending = {}, scans = {}, ready = {},
        document_bytes = 0, document_count = 0 }
    local progress, server_pending, next_id, next_poll = {}, {}, 0, 0
    local handlers = {}
    local function error_response(id, code, message)
        emit({ jsonrpc = '2.0', id = id == nil and null or id, error = { code = code, message = message } })
    end
    local function reply(id, value) emit({ jsonrpc = '2.0', id = id, result = value == nil and null or value }) end
    local function progress_value(job, value)
        emit({ jsonrpc = '2.0', method = '$/progress', params = { token = job.token, value = value } })
    end
    function self:begin_index(root)
        if not self.work_done or self.state ~= 'ready' or progress[root] then return end
        next_id = next_id + 1
        local id = 'codeoutline-progress-' .. next_id
        local job = { token = id, root = root }
        progress[root], server_pending[id] = job, job
        emit({ jsonrpc = '2.0', id = id, method = 'window/workDoneProgress/create', params = { token = id } })
    end
    function self:end_index(root, message)
        local job = progress[root]
        if not job then return end
        job.done, job.message = true, message
        if job.started then
            progress_value(job, { kind = 'end', message = message })
            progress[root] = nil
        end
    end
    local function root_for(path)
        for _, root in ipairs(self.roots) do if paths.contains(root, path) then return root end end
    end
    local function scan(root, hints)
        local existing = self.scans[root]
        if existing then
            for _, path in ipairs(hints or {}) do existing.hints[path] = true end
            return
        end
        local job = { hints = {} }
        self.scans[root] = job
        if not self.ready[root] then self:begin_index(root) end
        local id, err = submit({ method = 'lsp_refresh', projectPath = root, allowedRoots = self.roots,
            paths = hints }, function(ok, result)
            if self.scans[root] ~= job then return end
            self.scans[root] = nil
            self.ready[root] = ok or nil
            self:end_index(root, ok and 'Ready' or tostring(result))
            if not ok then
                emit({ jsonrpc = '2.0', method = 'window/logMessage', params = { type = 1, message = tostring(result) } })
            end
            local pending = {}
            for path in pairs(job.hints) do pending[#pending + 1] = path end
            if #pending > 0 and self.state == 'ready' then scan(root, pending) end
        end)
        job.id = id
        if not id then self.scans[root] = nil; self:end_index(root, err) end
    end
    function self:poll()
        if self.state ~= 'ready' or xtimer.now_ms() < next_poll then return end
        next_poll = xtimer.now_ms() + M.POLL_MS
        for _, root in ipairs(self.roots) do scan(root) end
    end
    local function set_roots(folders)
        local roots = {}
        assert(type(folders) == 'table' and #folders <= M.MAX_ROOTS, 'too many workspace folders')
        for _, folder in ipairs(folders) do
            local path = documents.path(folder.uri)
            local root = path and paths.canonical(path)
            assert(root, 'workspace folder must be an existing local directory')
            roots[#roots + 1] = root
        end
        table.sort(roots, function(a, b) return #a < #b or (#a == #b and a < b) end)
        self.roots = {}
        for _, root in ipairs(roots) do
            if not root_for(root) then self.roots[#self.roots + 1] = root end
        end
        self.folders = folders
        local retained = {}
        for _, root in ipairs(self.roots) do retained[root] = true end
        for root, job in pairs(self.scans) do
            if not retained[root] then cancel(job.id); self.scans[root] = nil; self:end_index(root, 'Workspace removed') end
        end
        for root in pairs(self.ready) do if not retained[root] then self.ready[root] = nil end end
        if self.state == 'ready' then next_poll = 0; self:poll() end
    end
    local function document(params)
        assert(object(params.textDocument) and type(params.textDocument.uri) == 'string', 'document URI required')
        local uri = params.textDocument.uri
        local doc = self.documents[uri]
        if doc then return doc end
        local path = documents.path(uri)
        assert(path and root_for(path), 'document is outside the workspace')
        local canonical = xutils.realpath(path)
        assert(canonical and root_for(paths.normalize(canonical)), 'document is outside the workspace')
        return documents.read(canonical)
    end
    local function cancel_pending(id)
        local job = self.pending[id]
        if job then
            self.pending[id] = nil
            cancel(job.id)
            error_response(id, -32800, 'Request cancelled')
        end
    end
    function self:close()
        if self.state == 'closed' then return end
        self.state = 'closed'
        for id in pairs(self.pending) do cancel_pending(id) end
        for _, job in pairs(self.scans) do cancel(job.id) end
        self.scans, self.documents, self.ready = {}, {}, {}
        progress, server_pending = {}, {}
    end
    handlers.initialize = function(id, params)
        assert(self.state == 'new', 'server already initialized')
        local folders = params.workspaceFolders
        if folders == null or folders == nil then
            local uri = params.rootUri
            if uri == null or uri == nil then
                local root = params.rootPath ~= null and params.rootPath or config.project
                uri = root and documents.uri(assert(paths.canonical(root)))
            end
            folders = uri and { { uri = uri } } or {}
        end
        set_roots(folders)
        local td = (params.capabilities or {}).textDocument or {}
        local window = (params.capabilities or {}).window or {}
        self.work_done = window.workDoneProgress == true
        self.hierarchical = td.documentSymbol and td.documentSymbol.hierarchicalDocumentSymbolSupport == true
        self.state = 'initialized'
        reply(id, { capabilities = { positionEncoding = 'utf-16',
            textDocumentSync = { openClose = true, change = 1, save = { includeText = false } },
            documentSymbolProvider = true, workspaceSymbolProvider = true,
            workspace = { workspaceFolders = { supported = true, changeNotifications = true } } },
            serverInfo = { name = 'codeoutline', version = require('codeoutline.version') } })
    end
    handlers.initialized = function()
        if self.state == 'initialized' then self.state = 'ready'; self:poll() end
    end
    handlers.shutdown = function(id)
        self.state = 'shutdown'
        for request_id in pairs(self.pending) do cancel_pending(request_id) end
        for _, job in pairs(self.scans) do cancel(job.id) end
        self.scans = {}
        reply(id, nil)
    end
    handlers['textDocument/didOpen'] = function(_, params)
        local td = assert(params.textDocument, 'textDocument required')
        assert(type(td.version) == 'number' and td.version % 1 == 0, 'invalid document version')
        assert(not self.documents[td.uri], 'document already open')
        local doc = documents.new(td.uri, td.text, td.version, td.languageId)
        assert(self.document_count < M.MAX_DOCUMENTS and self.document_bytes + #doc.source <= M.MAX_DRAFT_BYTES, 'open document limit reached')
        self.documents[td.uri] = doc
        self.document_count, self.document_bytes = self.document_count + 1, self.document_bytes + #doc.source
    end
    handlers['textDocument/didChange'] = function(_, params)
        local td = assert(params.textDocument, 'textDocument required')
        local doc = assert(self.documents[td.uri], 'document is not open')
        assert(type(td.version) == 'number' and td.version % 1 == 0 and td.version > doc.version, 'stale document version')
        local source = doc.source
        assert(type(params.contentChanges) == 'table' and #params.contentChanges > 0, 'contentChanges required')
        for _, change in ipairs(params.contentChanges) do
            assert(change.range == nil and type(change.text) == 'string', 'server requires full document synchronization')
            source = change.text
        end
        local updated = documents.new(td.uri, source, td.version, doc.language)
        assert(self.document_bytes - #doc.source + #updated.source <= M.MAX_DRAFT_BYTES, 'open document limit reached')
        self.documents[td.uri] = updated
        self.document_bytes = self.document_bytes - #doc.source + #updated.source
    end
    handlers['textDocument/didClose'] = function(_, params)
        local uri = params.textDocument.uri
        local doc = self.documents[uri]
        if doc then
            self.document_count, self.document_bytes = self.document_count - 1, self.document_bytes - #doc.source
            self.documents[uri] = nil
        end
    end
    local function hint(uri)
        local path = documents.path(uri)
        local root = path and root_for(path)
        if root then scan(root, { path }) end
    end
    handlers['textDocument/didSave'] = function(_, params) hint(params.textDocument.uri) end
    handlers['workspace/didChangeWatchedFiles'] = function(_, params)
        assert(type(params.changes) == 'table', 'changes required')
        for _, change in ipairs(params.changes) do hint(change.uri) end
    end
    handlers['workspace/didChangeWorkspaceFolders'] = function(_, params)
        local folders, removed = {}, {}
        for _, folder in ipairs(params.event.removed) do removed[folder.uri] = true end
        for _, folder in ipairs(self.folders) do if not removed[folder.uri] then folders[#folders + 1] = folder end end
        for _, folder in ipairs(params.event.added) do folders[#folders + 1] = folder end
        set_roots(folders)
    end
    handlers['textDocument/documentSymbol'] = function(id, params)
        assert(id ~= nil, 'symbol query must be a request')
        local doc = document(params)
        reply(id, doc and M.document_symbols(doc, self.hierarchical) or array())
    end
    handlers['workspace/symbol'] = function(id, params)
        assert(id ~= nil, 'symbol query must be a request')
        assert(type(params.query) == 'string' and #params.query <= M.MAX_QUERY, 'invalid symbol query')
        local count = 0
        for _ in pairs(self.pending) do count = count + 1 end
        assert(count < M.MAX_PENDING, 'too many pending requests')
        local drafts, exclude, result = {}, {}, array()
        for _, doc in pairs(self.documents) do
            if doc.path and root_for(doc.path) then
                drafts[#drafts + 1] = doc
                exclude[paths.key(doc.path)] = true
            end
        end
        table.sort(drafts, function(a, b) return a.uri < b.uri end)
        local needle = params.query:lower()
        for _, doc in ipairs(drafts) do
            for _, node in ipairs(doc:parse().nodes) do
                if #result < M.MAX_SYMBOLS and node.qualified:lower():find(needle, 1, true) then
                    result[#result + 1] = { name = node.name, kind = kind(node), location = location(doc, node),
                        containerName = node.qualified ~= node.name and node.qualified or nil }
                end
            end
        end
        for _, root in ipairs(self.roots) do
            if not self.ready[root] then reply(id, result); return end
        end
        local job = {}
        self.pending[id] = job
        local job_id, err = submit({ method = 'lsp_symbols', roots = self.roots, exclude = exclude,
            query = params.query, limit = M.MAX_SYMBOLS - #result }, function(ok, symbols)
            if self.pending[id] ~= job then return end
            self.pending[id] = nil
            if not ok then error_response(id, -32603, tostring(symbols)); return end
            for _, symbol in ipairs(symbols) do result[#result + 1] = symbol end
            reply(id, result)
        end)
        job.id = job_id
        if not job_id and self.pending[id] == job then
            self.pending[id] = nil; error_response(id, -32603, err)
        end
    end
    local navigation = { ['textDocument/definition'] = true, ['textDocument/hover'] = true,
        ['textDocument/references'] = true, ['textDocument/prepareCallHierarchy'] = true,
        ['callHierarchy/incomingCalls'] = true, ['callHierarchy/outgoingCalls'] = true }
    local function dispatch(msg)
        local id, method, params = msg.id, msg.method, msg.params or {}
        if method == 'exit' then
            local code = self.state == 'shutdown' and 0 or 1
            self:close(); stop(code); return
        end
        if self.state == 'closed' then return end
        if method == '$/cancelRequest' then cancel_pending(params.id); return end
        if self.pending[id] then error_response(id, -32600, 'Request ID is already pending'); return end
        if method == 'initialize' then handlers.initialize(id, params); return end
        if self.state == 'new' then if id ~= nil then error_response(id, -32002, 'Server not initialized') end; return end
        if method == 'initialized' then handlers.initialized(); return end
        if self.state == 'shutdown' then if id ~= nil then error_response(id, -32600, 'Server is shutting down') end; return end
        if method == 'shutdown' then handlers.shutdown(id); return end
        if self.state ~= 'ready' then if id ~= nil then error_response(id, -32002, 'Initialization is incomplete') end; return end
        if navigation[method] or method == 'textDocument/completion' then
            for _, root in ipairs(self.roots) do
                if not self.ready[root] then
                    if id ~= nil then
                        if method == 'textDocument/completion' then reply(id, { isIncomplete = true, items = array() })
                        else error_response(id, -32803, 'Project is indexing; retry when indexing completes') end
                    end
                    return
                end
            end
        end
        local handler = handlers[method]
        if handler then handler(id, params)
        elseif id ~= nil then error_response(id, -32601, 'Method not found: ' .. method) end
    end
    function self:accept(body)
        local ok, msg = pcall(xutils.json_unpack, body)
        if not ok or text.valid(body) ~= body then error_response(nil, -32700, 'Invalid JSON'); return end
        if object(msg) and msg.jsonrpc == '2.0' and msg.method == nil and valid_id(msg.id)
            and ((msg.result ~= nil and msg.error == nil) or (msg.result == nil and object(msg.error))) then
            local job = server_pending[msg.id]
            if not job then return end
            server_pending[msg.id] = nil
            if msg.error or self.state ~= 'ready' then progress[job.root] = nil; return end
            job.started = true
            progress_value(job, { kind = 'begin', title = 'CodeOutline indexing', message = job.root, cancellable = false })
            if job.done then self:end_index(job.root, job.message) end
            return
        end
        if not object(msg) or msg.jsonrpc ~= '2.0' or type(msg.method) ~= 'string'
            or (msg.id ~= nil and not valid_id(msg.id)) or (msg.params ~= nil and not object(msg.params)) then
            error_response(nil, -32600, 'Invalid JSON-RPC request'); return
        end
        if (msg.method == 'initialize' or msg.method == 'shutdown') and msg.id == nil then return end
        local dispatched, err = pcall(dispatch, msg)
        if not dispatched then
            if msg.id ~= nil then error_response(msg.id, -32602, tostring(err))
            else io.stderr:write('[codeoutline lsp] ', tostring(err), '\n') end
        end
    end
    return self
end

return M
