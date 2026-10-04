local documents = require('codeoutline.documents')
local paths = require('codeoutline.path')
local text = require('codeoutline.text')
local M = {}
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
                assert((stop or #self.buffer) <= 16384, 'LSP header too large')
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
                assert(length and length <= 4194304, 'missing or excessive Content-Length')
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

function M.new(config, emit, scan, stop)
    config = config or {}
    local self = { state = 'new', documents = {}, roots = {}, document_bytes = 0, document_count = 0 }
    local progress, server_pending, next_id = {}, {}, 0
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
    local function set_roots(folders)
        local roots = {}
        assert(type(folders) == 'table' and #folders <= 16, 'too many workspace folders')
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
        for _, root in ipairs(self.roots) do scan(root) end
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
    -- Open documents only; project symbols move to the index worker.
    local function workspace_symbols(query)
        assert(type(query) == 'string' and #query <= 4096, 'invalid symbol query')
        local drafts = {}
        for _, doc in pairs(self.documents) do
            if doc.path and root_for(doc.path) then drafts[#drafts + 1] = doc end
        end
        table.sort(drafts, function(a, b) return a.uri < b.uri end)
        local result = array()
        local needle = query:lower()
        for _, doc in ipairs(drafts) do
            for _, node in ipairs(doc:parse().nodes) do
                if #result >= 200 then return result end
                if node.qualified:lower():find(needle, 1, true) then
                    result[#result + 1] = { name = node.name, kind = kind(node), location = location(doc, node),
                        containerName = node.qualified ~= node.name and node.qualified or nil }
                end
            end
        end
        return result
    end
    local function dispatch(msg)
        local id, method, params = msg.id, msg.method, msg.params or {}
        if method == 'exit' then stop(self.state == 'shutdown' and 0 or 1); return end
        -- Requests are answered as they arrive, so none is left to cancel.
        if method == '$/cancelRequest' then return end
        if method == 'initialize' then
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
            return
        end
        if self.state == 'new' then if id ~= nil then error_response(id, -32002, 'Server not initialized') end; return end
        if method == 'initialized' then
            if self.state == 'initialized' then self.state = 'ready' end
            return
        end
        if method == 'shutdown' then self.state = 'shutdown'; reply(id, nil); return end
        if self.state == 'shutdown' then if id ~= nil then error_response(id, -32600, 'Server is shutting down') end; return end
        if self.state ~= 'ready' then if id ~= nil then error_response(id, -32002, 'Initialization is incomplete') end; return end
        if method == 'textDocument/didOpen' then
            local td = assert(params.textDocument, 'textDocument required')
            assert(type(td.version) == 'number' and td.version % 1 == 0, 'invalid document version')
            assert(not self.documents[td.uri], 'document already open')
            local doc = documents.new(td.uri, td.text, td.version, td.languageId)
            assert(self.document_count < 128 and self.document_bytes + #doc.source <= 33554432, 'open document limit reached')
            self.documents[td.uri] = doc
            self.document_count, self.document_bytes = self.document_count + 1, self.document_bytes + #doc.source
        elseif method == 'textDocument/didChange' then
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
            assert(self.document_bytes - #doc.source + #source <= 33554432, 'open document limit reached')
            self.documents[td.uri] = updated
            self.document_bytes = self.document_bytes - #doc.source + #source
        elseif method == 'textDocument/didClose' then
            local uri = params.textDocument.uri
            local doc = self.documents[uri]
            if doc then
                self.document_count, self.document_bytes = self.document_count - 1, self.document_bytes - #doc.source
                self.documents[uri] = nil
            end
        elseif method == 'textDocument/didSave' then
            local path = documents.path(params.textDocument.uri)
            local root = path and root_for(path)
            if root then scan(root) end
        elseif method == 'workspace/didChangeWatchedFiles' then
            for _, root in ipairs(self.roots) do scan(root) end
        elseif method == 'workspace/didChangeWorkspaceFolders' then
            local folders, removed = {}, {}
            for _, folder in ipairs(params.event.removed) do removed[folder.uri] = true end
            for _, folder in ipairs(self.folders) do if not removed[folder.uri] then folders[#folders + 1] = folder end end
            for _, folder in ipairs(params.event.added) do folders[#folders + 1] = folder end
            set_roots(folders)
        elseif method == 'textDocument/documentSymbol' then
            assert(id ~= nil, 'symbol query must be a request')
            local doc = document(params)
            reply(id, doc and M.document_symbols(doc, self.hierarchical) or array())
        elseif method == 'workspace/symbol' then
            assert(id ~= nil, 'symbol query must be a request')
            reply(id, workspace_symbols(params.query))
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
