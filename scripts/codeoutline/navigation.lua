-- navigation.lua — LSP navigation inside the INDEX worker.
--
-- Resolution reuses the graph resolver over the resident symbol tables of one
-- workspace root, overlaid with the session's open documents (and the queried
-- file itself), so drafts hide the disk records of their files. Nothing here
-- is persisted: exact positions come from reparsing only the files a result
-- names, and callers are found by one scan of reference names per request.
local graph = require('codeoutline.graph')
local service = require('codeoutline.service')
local documents = require('codeoutline.documents')
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local lsp = require('codeoutline.lsp')
-- Reference scans stop at a result count or time budget and report truncation.
local M = { MAX_RESULTS = 1000, MAX_HOVER = 3, SCAN_SECONDS = 3, POSITION_SECONDS = 2 }

local sessions = {}
local ANY = setmetatable({}, { __index = function() return true end })
-- Bare identifiers bind only nearby, except type names used across files.
local TYPES = { class = true, struct = true, union = true, interface = true, enum = true, record = true,
    typedef = true, namespace = true, annotation_type = true }
-- references and call hierarchy cover callables; types need complete reference semantics.
local REFERENCE = { ['function'] = true, method = true, macro = true, constructor = true,
    prototype = true, destructor = true }
local CALLS = { ['function'] = true, method = true, macro = true, constructor = true,
    prototype = true, destructor = true, class = true, record = true }
local MEMBER = { ['.'] = true, ['->'] = true, ['::'] = true, ['?.'] = true }
local LUA_MEMBER = { ['.'] = true, [':'] = true }
local SELF = { self = true, this = true, cls = true }

-- Session drafts arrive with each navigation request: the open set always,
-- text only for versions this worker has not seen.
function M.sync(req)
    local store = sessions[req.session] or {}
    sessions[req.session] = store
    for uri in pairs(store) do
        if not req.open[uri] then store[uri] = nil end
    end
    for uri, draft in pairs(req.changed or {}) do
        store[uri] = documents.new(uri, draft.source, draft.version, draft.language)
    end
end

function M.close(session) sessions[session] = nil end

local function relative(root, path)
    local real = xutils.realpath(path)
    local full = real and paths.normalize(real) or path
    if not paths.contains(root, full) or paths.key(full) == paths.key(root) then return nil end
    return full:sub(#root + 2)
end

-- The request's document: the session draft, else the file on disk.
local function request_doc(req)
    local doc = (sessions[req.session] or {})[req.uri]
    if doc then return doc end
    local path = documents.path(req.uri)
    local real = path and xutils.realpath(path)
    if not real or not paths.contains(req.root, paths.normalize(real)) then return nil end
    doc = documents.read(paths.normalize(real))
    if doc then doc.uri = req.uri end
    return doc
end

-- The index's maintained symbol tables with documents layered over their
-- files. Overlay files and nodes take ids after every resident one; masked
-- resident nodes drop out of name lists, which keep path and node order.
-- Nothing is written to the resident tables.
local function view(session, root)
    local idx = service.resident(root)
    local G = idx:symbols()
    local V = setmetatable({ root = root, idx = idx, drafts = {}, disk = {}, dep_cache = {}, new_files = {},
        next_file = G.next_file, next_node = G.next_node, next_dir = G.next_dir }, { __index = G })
    for _, name in ipairs({ 'files', 'nodes', 'node_file', 'id_of', 'file_index', 'file_dir' }) do
        V[name] = setmetatable({}, { __index = G[name] })
    end
    local masked, added = {}, {}
    function V.add(doc)
        local rel = doc.path and relative(root, doc.path)
        local f = rel and V.file_index[rel]
        if not rel or (f and V.drafts[f]) then return f end
        local rec = doc:parse()
        if not rec.language then return nil end
        if f then masked[f] = true
        else
            -- An unsaved file resolves against others; no resident file depends on it.
            V.next_file = V.next_file + 1
            f = V.next_file
            V.file_index[rel] = f
            V.new_files[#V.new_files + 1] = f
            local same = G.dir_ids[rel:match('^(.*)/[^/]*$') or '']
            if not same then V.next_dir = V.next_dir + 1; same = V.next_dir end
            V.file_dir[f] = same
        end
        local copy = {}
        for key, value in pairs(rec) do copy[key] = value end
        copy.path = rel
        V.files[f], V.drafts[f] = copy, doc
        local ids = {}
        V.id_of[f] = ids
        for n, node in ipairs(rec.nodes) do
            V.next_node = V.next_node + 1
            local id = V.next_node
            V.nodes[id], V.node_file[id], ids[n] = node, f, id
            local list = added[node.name]
            if not list then list = {}; added[node.name] = list end
            list[#list + 1] = id
        end
        return f
    end
    V.by_name = setmetatable({}, { __index = function(cache, name)
        local list, extra = G.by_name[name] or {}, added[name]
        if next(masked) then
            local kept = {}
            for _, id in ipairs(list) do
                if not masked[G.node_file[id]] then kept[#kept + 1] = id end
            end
            list = kept
        end
        if extra then
            local merged = {}
            for _, id in ipairs(list) do merged[#merged + 1] = id end
            for _, id in ipairs(extra) do merged[#merged + 1] = id end
            table.sort(merged, function(a, b) return graph.before(V, a, b) end)
            list = merged
        end
        rawset(cache, name, list)
        return list
    end })
    local drafts = {}
    for _, doc in pairs(sessions[session] or {}) do drafts[#drafts + 1] = doc end
    table.sort(drafts, function(a, b) return a.uri < b.uri end)
    for _, doc in ipairs(drafts) do V.add(doc) end
    return V
end

local function deps(V, f)
    local entry = V.dep_cache[f]
    if not entry then
        local direct, paired = graph.dependencies(V, f)
        entry = { direct, paired }
        V.dep_cache[f] = entry
    end
    return entry[1], entry[2]
end

local function index_of(V, id)
    local f = V.node_file[id]
    return id - V.id_of[f][1] + 1, f
end

-- self.f() inside f, or M.f() inside M.f / Box::f() inside Box::f.
local function recursive(node, recv)
    if not recv then return false end
    if SELF[recv] then return true end
    local q = node.qualified
    for _, sep in ipairs({ '.', ':', '::' }) do
        local tail = recv .. sep .. node.name
        if q == tail or q:sub(-(#tail + 1)) == '.' .. tail then return true end
    end
    return false
end

-- Targets of one occurrence of name in file f, enclosed by node index from.
local function resolve_site(V, f, from, name, kind, recv)
    local src = from > 0 and V.id_of[f][from] or nil
    local direct, paired = deps(V, f)
    local rkind, accept = kind, nil
    if kind == 'symbol' then rkind, accept = 'call', ANY
    elseif kind == 'member_symbol' then rkind, accept = 'member_call', ANY end
    local targets = graph.resolve(V, f, src, name, rkind, recv or nil, direct, paired, accept) or {}
    if kind == 'symbol' then
        local kept = {}
        for _, id in ipairs(targets) do
            local node = V.nodes[id]
            if TYPES[node.kind] or (graph.placement(V, f, V.node_file[id], node, direct, paired) or 0) > 0 then
                kept[#kept + 1] = id
            end
        end
        targets = kept
    end
    -- The resolver never binds a ref to its enclosing node, which hides recursion.
    if #targets == 0 and src and V.nodes[src].name == name and (kind == 'call' or recursive(V.nodes[src], recv)) then
        targets = { src }
    end
    return targets
end

-- What the cursor names: a declaration, an indexed reference, or another identifier.
local function find_cursor(doc, offset, strict)
    local rec = doc:parse()
    local function inside(a, b) return a <= offset and (offset < b or (not strict and offset == b)) end
    for n, node in ipairs(rec.nodes) do
        if node.name_start and inside(node.name_start, node.name_end) then
            return { decl = n, name = node.name, first = node.name_start, last = node.name_end }
        end
    end
    local refs = rec.refs
    if refs and refs.start then
        for i = 1, #refs.name do
            local a = refs.start[i]
            if a and inside(a, refs.stop[i]) then
                return { from = refs.from[i], name = refs.name[i], kind = refs.kind[i], recv = refs.recv[i],
                    first = a, last = refs.stop[i] }
            end
        end
    end
end

local function cursor(doc, offset)
    local found = find_cursor(doc, offset, true) or find_cursor(doc, offset, false)
    if found then return found end
    local rec, T = doc:parse(), doc:tokens()
    if not T then return nil end
    local t
    for i = 1, T.n do
        local a = T.s[i] - 1
        if a > offset then break end
        if T.k[i] == 'id' and offset <= T.e[i] then t = i end
    end
    if not t then return nil end
    local kind, recv = 'symbol', nil
    local member = rec.language == 'lua' and LUA_MEMBER or MEMBER
    if T.k[t + 1] == 'op' and T:text(t + 1) == '(' then kind = 'call' end
    local p = t - 1
    if p >= 1 and T.k[p] == 'op' and member[T:text(p)] then
        kind = kind == 'call' and 'member_call' or 'member_symbol'
        if T.k[p - 1] == 'id' or T.k[p - 1] == 'kw' then recv = T:text(p - 1) end
    elseif p >= 1 and T.k[p] == 'kw' and T:text(p) == 'new' then
        kind = 'new'
    end
    local from, span = 0, math.huge
    for n, node in ipairs(rec.nodes) do
        if node.start_byte and node.start_byte <= offset and offset < node.end_byte
            and node.end_byte - node.start_byte < span then
            from, span = n, node.end_byte - node.start_byte
        end
    end
    return { from = from, name = T:text(t), kind = kind, recv = recv, first = T.s[t] - 1, last = T.e[t] }
end

-- Source document for file f: its overlay, else the disk file read once per request.
local function source_doc(V, f)
    if V.drafts[f] then return V.drafts[f] end
    local doc = V.disk[f]
    if doc == nil then
        doc = documents.read(V.idx:abs(V.files[f].path)) or false
        V.disk[f] = doc
    end
    return doc or nil
end

local function uri_of(V, f)
    local doc = source_doc(V, f)
    return doc and doc.uri or documents.uri(V.idx:abs(V.files[f].path))
end

local function line_range(line)
    local at = { line = math.max(line - 1, 0), character = 0 }
    return { start = at, ['end'] = at }
end

-- Reparsed node for id, matched by index and verified by name, else by qualified name.
local function locate(V, id)
    local n, f = index_of(V, id)
    local node, doc = V.nodes[id], source_doc(V, f)
    if not doc then return nil end
    local nodes = doc:parse().nodes
    local hit = nodes[n]
    if hit and hit.name == node.name and hit.qualified == node.qualified and hit.name_start then return doc, hit end
    hit = nil
    for _, c in ipairs(nodes) do
        if c.qualified == node.qualified and c.name_start
            and (not hit or math.abs(c.line - node.line) < math.abs(hit.line - node.line)) then hit = c end
    end
    return doc, hit
end

local function location(V, id)
    local doc, hit = locate(V, id)
    local f = V.node_file[id]
    if hit then return { uri = doc.uri, range = doc:range(hit.name_start, hit.name_end) }, doc, hit end
    return { uri = uri_of(V, f), range = line_range(V.nodes[id].line) }
end

local function item(V, id)
    local loc, doc, hit = location(V, id)
    local node = V.nodes[id]
    local n, f = index_of(V, id)
    return { name = node.name, kind = lsp.symbol_kind(node), detail = node.sig or node.qualified, uri = loc.uri,
        range = hit and doc:range(hit.start_byte, hit.end_byte) or loc.range, selectionRange = loc.range,
        data = { root = V.root, path = V.files[f].path, index = n, name = node.name, qualified = node.qualified } }
end

-- File-scope code (Lua chunks, Python modules, JS top level) calls from the file itself.
local function file_item(V, f)
    local rel = V.files[f].path
    local start = line_range(1)
    return { name = rel:match('[^/]*$'), kind = 1, detail = rel, uri = uri_of(V, f), range = start,
        selectionRange = start, data = { root = V.root, path = rel, index = 0 } }
end

-- Item data to a node id (nil for a file item) and file index.
local function relocate(V, data)
    local f = type(data) == 'table' and type(data.path) == 'string' and V.file_index[data.path]
    if not f then return nil end
    if data.index == 0 then return nil, f end
    local ids = V.id_of[f]
    local id = type(data.index) == 'number' and ids[data.index]
    if id and V.nodes[id].name == data.name and V.nodes[id].qualified == data.qualified then return id, f end
    for _, cid in ipairs(ids) do
        if V.nodes[cid].qualified == data.qualified and V.nodes[cid].name == data.name then return cid, f end
    end
end

-- Exact range of reference i of file f, from the overlay or a reparse of the
-- disk file. A file edited since indexing is matched by name and line.
local function site_range(V, f, i)
    local doc = source_doc(V, f)
    if not doc then return nil end
    local refs, indexed = doc:parse().refs, V.files[f].refs
    if not refs or not refs.start then return nil end
    local j = i
    if refs.name[i] ~= indexed.name[i] or refs.line[i] ~= indexed.line[i] then
        j = nil
        for k = 1, #refs.name do
            if refs.name[k] == indexed.name[i] and refs.line[k] == indexed.line[i] then j = k; break end
        end
        if not j then return nil end
    end
    local a, b = refs.start[j], refs.stop[j]
    if not a then
        -- Macro bodies record the directive token; find the name on its line.
        local line = refs.line[j]
        local first = doc.lines[line]
        if not first then return nil end
        local last = doc.lines[line + 1] or #doc.source
        local s = doc.source:find(refs.name[j], first + 1, true)
        if not s or s > last then return nil end
        a, b = s - 1, s - 1 + #refs.name[j]
    end
    return doc:range(a, b)
end

local function is_decl(node) return not not graph.is_decl(node) end

-- A declaration and its definitions (prototypes, in-class declarations) as one target.
local function expand(V, set)
    local out = {}
    for id in pairs(set) do
        out[id] = true
        local node = V.nodes[id]
        local family = graph.family(V.files[V.node_file[id]].language)
        for _, cid in ipairs(V.by_name[node.name]) do
            local c = V.nodes[cid]
            if c.qualified == node.qualified and is_decl(c) ~= is_decl(node)
                and graph.family(V.files[V.node_file[cid]].language) == family then out[cid] = true end
        end
    end
    return out
end

local function sorted(set)
    local list = {}
    for id in pairs(set) do list[#list + 1] = id end
    table.sort(list)
    return list
end

-- References to name that resolve into targets, as { f, i } in file order.
-- Hot names can match thousands of files; past the budget the scan stops.
local function scan(V, targets, name)
    local hits, deadline = {}, os.clock() + M.SCAN_SECONDS
    local files = {}
    for i, f in ipairs(V.file_order) do files[i] = f end
    for _, f in ipairs(V.new_files) do files[#files + 1] = f end
    for _, f in ipairs(files) do
        control.check()
        local refs = V.files[f].refs
        local names = refs.name
        for i = 1, #names do
            if i % 4096 == 0 then control.check() end
            if names[i] == name then
                if os.clock() > deadline then return hits, true end
                for _, dst in ipairs(resolve_site(V, f, refs.from[i], name, refs.kind[i], refs.recv[i])) do
                    if targets[dst] then hits[#hits + 1] = { f, i }; break end
                end
                if #hits >= M.MAX_RESULTS then return hits, true end
            end
        end
    end
    return hits, false
end

local function at(req)
    local doc = request_doc(req)
    if not doc then return nil end
    local V = view(req.session, req.root)
    local f = V.add(doc)
    if not f then return nil end
    local c = cursor(doc, doc:offset(req.position))
    if not c then return nil end
    local targets
    if c.decl then targets = { V.id_of[f][c.decl] }
    else targets = resolve_site(V, f, c.from, c.name, c.kind, c.recv) end
    return V, doc, c, targets
end

local handlers = {}

function handlers.lsp_definition(req)
    local V, _, c, targets = at(req)
    if not V then return false end
    if c.decl and is_decl(V.nodes[targets[1]]) then
        -- From a declaration, go to its definitions.
        local defs = {}
        for _, id in ipairs(sorted(expand(V, { [targets[1]] = true }))) do
            if not is_decl(V.nodes[id]) then defs[#defs + 1] = id end
        end
        if #defs > 0 then targets = defs end
    end
    local result = {}
    for _, id in ipairs(targets) do result[#result + 1] = (location(V, id)) end
    return result
end

function handlers.lsp_hover(req)
    local V, doc, c, targets = at(req)
    if not V or #targets == 0 then return false end
    local parts = {}
    for k, id in ipairs(targets) do
        if k > M.MAX_HOVER then break end
        local node, rec = V.nodes[id], V.files[V.node_file[id]]
        parts[#parts + 1] = '```' .. (rec.language or '') .. '\n' .. (node.sig or node.qualified) .. '\n```'
        parts[#parts + 1] = node.kind .. ' `' .. node.qualified .. '` — ' .. rec.path .. ':' .. node.line
    end
    return { contents = { kind = 'markdown', value = table.concat(parts, '\n\n') }, range = doc:range(c.first, c.last) }
end

function handlers.lsp_prepare_calls(req)
    local V, _, _, targets = at(req)
    if not V then return false end
    local result = {}
    for _, id in ipairs(targets) do
        if CALLS[V.nodes[id].kind] then result[#result + 1] = item(V, id) end
    end
    return #result > 0 and result or false
end

local function positions_left(t0, incomplete)
    return not incomplete and os.clock() - t0 <= M.POSITION_SECONDS
end

function handlers.lsp_incoming(req)
    local V = view(req.session, req.root)
    local id = relocate(V, req.data)
    if not id then return {} end
    local name = V.nodes[id].name
    local hits, incomplete = scan(V, expand(V, { [id] = true }), name)
    local result, groups, t0 = {}, {}, os.clock()
    for _, hit in ipairs(hits) do
        if not positions_left(t0, false) then incomplete = true; break end
        local f, i = hit[1], hit[2]
        local from = V.files[f].refs.from[i]
        local key = f .. ':' .. from
        local group = groups[key]
        if not group then
            group = { from = from > 0 and item(V, V.id_of[f][from]) or file_item(V, f), fromRanges = {} }
            groups[key] = group
            result[#result + 1] = group
        end
        local range = site_range(V, f, i)
        if range then group.fromRanges[#group.fromRanges + 1] = range end
    end
    return result, incomplete
end

function handlers.lsp_outgoing(req)
    local V = view(req.session, req.root)
    local f = type(req.data) == 'table' and type(req.data.path) == 'string' and V.file_index[req.data.path]
    if not f then return {} end
    if not V.drafts[f] then
        -- Reference positions of the calling file come from one exact reparse.
        local doc = source_doc(V, f)
        if doc then V.add(doc) end
    end
    local id
    id, f = relocate(V, req.data)
    if not f or (req.data.index ~= 0 and not id) then return {} end
    local from = id and index_of(V, id) or 0
    local refs = V.files[f].refs
    local result, groups = {}, {}
    for i = 1, #refs.name do
        if i % 128 == 0 then control.check() end
        if refs.from[i] == from then
            for _, dst in ipairs(resolve_site(V, f, from, refs.name[i], refs.kind[i], refs.recv[i])) do
                local group = groups[dst]
                if not group then
                    group = { to = item(V, dst), fromRanges = {} }
                    groups[dst] = group
                    result[#result + 1] = group
                end
                local range = site_range(V, f, i)
                if range then group.fromRanges[#group.fromRanges + 1] = range end
            end
        end
    end
    return result
end

function handlers.lsp_references(req)
    local V, _, c, targets = at(req)
    if not V or #targets == 0 then return {} end
    local set = {}
    for _, id in ipairs(targets) do
        if not REFERENCE[V.nodes[id].kind] then
            return { error = 'References currently support functions, methods, constructors and macros only' }
        end
        set[id] = true
    end
    set = expand(V, set)
    local hits, incomplete = scan(V, set, c.name)
    local result, t0 = {}, os.clock()
    if req.includeDeclaration then
        for _, id in ipairs(sorted(set)) do result[#result + 1] = (location(V, id)) end
    end
    for _, hit in ipairs(hits) do
        if not positions_left(t0, false) then incomplete = true; break end
        local range = site_range(V, hit[1], hit[2])
        if range then result[#result + 1] = { uri = uri_of(V, hit[1]), range = range } end
    end
    return result, incomplete
end

function M.handles(method) return handlers[method] ~= nil end

-- Returns { result = value (false for null), incomplete = bool } or { error = message }.
function M.execute(req)
    local result, incomplete = handlers[req.method](req)
    if type(result) == 'table' and result.error then return result end
    return { result = result, incomplete = incomplete or false }
end

return M
