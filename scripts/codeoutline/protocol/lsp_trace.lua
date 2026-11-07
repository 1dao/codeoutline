-- Opt-in local protocol metadata; document text and result bodies are omitted.
local M = {}

function M.open(path, session)
    if not path or path == '' then return nil end
    local file, err = io.open(path, 'ab')
    if not file then
        io.stderr:write('[codeoutline lsp trace] cannot open trace: ', tostring(err), '\n')
        return nil
    end
    local self, sequence = {}, 0
    function self:record(event, fields)
        if not file then return end
        sequence = sequence + 1
        local row = { event = event, session = session, sequence = sequence,
            utc = os.date('!%Y-%m-%dT%H:%M:%SZ'), ms = xtimer.now_ms(), fields = fields or {} }
        local ok, failure = file:write(xutils.json_pack(row), '\n')
        if ok then ok, failure = file:flush() end
        if not ok then
            io.stderr:write('[codeoutline lsp trace] write failed: ', tostring(failure), '\n')
            file:close(); file = nil
        end
    end
    function self:message(direction, msg)
        local fields = { id = msg.id, method = msg.method }
        local params = type(msg.params) == 'table' and msg.params or {}
        local doc = type(params.textDocument) == 'table' and params.textDocument or {}
        fields.uri, fields.version, fields.language = doc.uri, doc.version, doc.languageId
        if type(params.position) == 'table' then
            fields.position = { line = params.position.line, character = params.position.character }
        end
        if type(doc.text) == 'string' then fields.text_bytes = #doc.text end
        if type(params.contentChanges) == 'table' then fields.changes = #params.contentChanges end
        if msg.method == '$/cancelRequest' then fields.cancel_id = params.id end
        if msg.method == 'initialize' then
            fields.client = type(params.clientInfo) == 'table' and params.clientInfo.name or nil
            fields.root_uri = params.rootUri
        end
        if msg.method == 'window/showMessage' or msg.method == 'window/logMessage' then
            fields.message, fields.type = params.message, params.type
        end
        if type(msg.error) == 'table' then fields.error_code = msg.error.code end
        if type(msg.result) == 'table' then
            fields.result_count = #msg.result
            fields.incomplete = msg.result.isIncomplete
            local first = msg.result[1]
            if type(first) == 'table' then fields.target_uri = first.uri or first.targetUri end
        end
        self:record(direction, fields)
    end
    function self:close()
        if file then file:close(); file = nil end
    end
    return self
end

return M
