-- Explicit unknown-suffix files live in a bounded query overlay, never in idx.
local M = { MAX_FILES = 4, MAX_BYTES = 2 * 1048576, MAX_PROBES = 16 }
local graph = require('codeoutline.graph')
local parse = require('codeoutline.parse')
local documents = require('codeoutline.documents')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')

local function fork(G)
    local V = setmetatable({}, { __index = G })
    for _, key in ipairs({ 'files', 'file_index', 'file_dir', 'dir_ids', 'nodes', 'node_file', 'id_of', 'children' }) do
        V[key] = setmetatable({}, { __index = G[key] })
    end
    for _, key in ipairs({ 'by_name', 'by_lname', 'by_qualified', 'by_owner', 'by_base', 'by_stem',
        'pkg_files', 'dir_files', 'dir_by_base', 'ns_files' }) do
        local base = G[key]
        V[key] = setmetatable({}, { __index = function(t, name)
            local old = base[name]
            if not old then return nil end
            local list = {}; for i, value in ipairs(old) do list[i] = value end
            rawset(t, name, list); return list
        end })
    end
    V.file_order = {}
    for i, f in ipairs(G.file_order) do
        if i % 4096 == 0 then control.check() end
        V.file_order[i] = f
    end
    V.query_base_names = G.by_name
    return V
end

function M.open(G, idx, query)
    local result = { files = {}, rejected = {}, truncated = false }
    local candidates, seen = {}, {}
    local function add(value)
        value = value:gsub('^path:', ''):gsub('[,;?]+$', ''):gsub('\\', '/')
        if value:match('%.[%w_]+$') and not parse.language(value) and not seen[value] then
            seen[value] = true; candidates[#candidates + 1] = value
        end
    end
    for value in query:gmatch('"([^"]+)"') do add(value) end
    for value in query:gsub('"[^"]+"', ''):gmatch('%S+') do add(value) end
    local records, sources, V, bytes = {}, {}, nil, 0
    for i, written in ipairs(candidates) do
        if i > M.MAX_PROBES then result.truncated = true; break end
        control.check()
        local full = written:match('^%a:/') or written:sub(1, 1) == '/' and written
        full = full and written or idx.root .. '/' .. written
        local real = xutils.realpath(full)
        real = real and paths.normalize(real)
        if real and paths.contains(idx.root, real) then
            local rel = real:sub(#idx.root + 2)
            local stat = xutils.stat(real)
            if not G.file_index[rel] and not records[rel] and stat and stat.type == 'file' then
                if #result.files >= M.MAX_FILES or stat.size > 1048576 or bytes + stat.size > M.MAX_BYTES then
                    result.truncated = true
                else
                    local doc = documents.read(real)
                    local filters = require('codeoutline.query_filters').parse(query)
                    local hint = #filters.languages == 1 and filters.languages[1] or nil
                    local rec = doc and parse.parse(rel, doc.source, { detect = true, language = hint, ordinary_bindings = true })
                    if rec then
                        -- Validate the raw file when the result is rendered too.
                        local file = assert(io.open(real, 'rb')); local raw = file:read(1048577); file:close()
                        assert(#raw <= 1048576 and bytes + #raw <= M.MAX_BYTES, 'source grew beyond query limits: ' .. rel)
                        local current = assert(documents.read(real))
                        assert(current.source == doc.source, 'source changed during query; retry: ' .. rel)
                        rec.size = #raw
                        if rec.language_source == 'editor' then rec.language_source = 'query' end
                        rec.crc = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
                        records[rel], sources[rel], bytes = rec, doc.source, bytes + #raw
                        V = V or fork(G)
                        graph.add_file(V, rel, rec)
                        result.files[#result.files + 1] = { path = rel, language = rec.language, basis = rec.language_source }
                    else result.rejected[#result.rejected + 1] = { path = rel, reason = 'language not confidently identified' } end
                end
            end
        end
    end
    if not V then return G, idx, result end
    local transient = setmetatable({ root = idx.root }, { __index = idx })
    function transient:query_source(rel)
        if records[rel] then
            assert(documents.read(idx.root .. '/' .. rel, records[rel]), 'cannot read source: ' .. rel)
            return sources[rel], false
        end
        return idx:query_source(rel)
    end
    return V, transient, result
end

return M
