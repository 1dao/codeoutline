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
local parse = require('codeoutline.parse')
-- Reference scans stop at a result count or time budget and report truncation.
local M = { MAX_RESULTS = 1000, MAX_HOVER = 3, SCAN_SECONDS = 3, POSITION_SECONDS = 2, MAX_INCLUDES = 2000,
    MAX_FILE_BYTES = 1048576, CACHE_FILES = 64 }

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
local PROTOTYPE = { prototype = true }
local C_FAMILY = { c = true, cpp = true }

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
    V.js_context = require('codeoutline.js_resolution').context(V)
    V.js_context.lua = require('codeoutline.lua_bindings').context(V)
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
            for _, alias in ipairs(require('codeoutline.lua_bindings').aliases(node, V.lua_global_export_tables)) do
                added[alias] = added[alias] or {}
                added[alias][#added[alias] + 1] = id
            end
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

-- Dependencies of file f. C and C++ see everything their includes include,
-- so headers are followed transitively (bounded), with the sources paired to
-- any of them.
local function deps(V, f)
    local entry = V.dep_cache[f]
    if not entry then
        local direct, paired = graph.dependencies(V, f, V.js_context)
        if C_FAMILY[V.files[f].language] then
            local queue = {}
            for g in pairs(direct) do queue[#queue + 1] = g end
            local i = 1
            while i <= #queue and #queue < M.MAX_INCLUDES do
                local more, sources = graph.dependencies(V, queue[i])
                for h in pairs(sources) do paired[h] = true end
                for h in pairs(more) do
                    if not direct[h] and h ~= f then direct[h] = true; queue[#queue + 1] = h end
                end
                i = i + 1
            end
        end
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
local function resolve_site(V, f, from, name, kind, recv, evidence, offset)
    local src = from > 0 and V.id_of[f][from] or nil
    local direct, paired = deps(V, f)
    local rkind, accept = kind, nil
    if kind == 'symbol' then rkind, accept = 'call', ANY
    elseif kind == 'member_symbol' then rkind, accept = 'member_call', ANY end
    local targets = graph.resolve(V, f, src, name, rkind, recv or nil, direct, paired, accept, evidence, V.js_context) or {}
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
    -- Definitions too far apart to choose between: a visible prototype still
    -- names the function, and going to its definition lists them all.
    if #targets == 0 and (kind == 'call' or kind == 'ref') then
        targets = graph.resolve(V, f, src, name, kind, recv or nil, direct, paired, PROTOTYPE, evidence, V.js_context) or {}
    end
    -- A native object: the local's initializer chain names the metatable whose
    -- methods the C side registers (`local pool = mod.open()`, then `pool:read()`).
    if #targets == 0 and recv and (kind == 'member_call' or kind == 'member_symbol')
        and V.files[f].language == 'lua' then
        local bindings = require('codeoutline.lua_bindings')
        local ctx = V.js_context.lua
        local rec, T
        if offset and require('codeoutline.foreign').has_candidates(V, ctx) then rec, T = M.full(V, f) end
        if T then
            local target = bindings.receiver(V, rec, T, recv, offset, V.js_context.lua)
            for _, entry in ipairs(bindings.member(V, target, name)) do
                local id = V.id_of[entry.file] and V.id_of[entry.file][entry.index]
                if id then targets[#targets + 1] = id end
            end
        end
    end
    if C_FAMILY[V.files[f].language] then
        -- C binds only what its includes make visible; a lone far definition
        -- (another library's macro) is not the one a system header declares.
        local kept = {}
        for _, id in ipairs(targets) do
            if id == src or (graph.placement(V, f, V.node_file[id], V.nodes[id], direct, paired) or 0) > 0 then
                kept[#kept + 1] = id
            end
        end
        targets = kept
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
                    evidence = refs.lua_binding and refs.lua_binding[i] or refs.js_receiver and refs.js_receiver[i],
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
    if V.drafts and V.drafts[f] then return V.drafts[f] end
    local rec = V.files[f]
    local indexed = rec.crc ~= nil and rec or nil
    if not V.disk then return V.root and documents.read(V.root .. '/' .. rec.path, indexed) end
    local doc = V.disk[f]
    if doc == nil then
        doc = documents.read(V.idx:abs(rec.path), indexed) or false
        V.disk[f] = doc
    end
    return doc or nil
end

-- Full parse (record plus tokens) of one file, cached per record. Shared with
-- completion, which needs tokens for types this index does not store.
local full_cache, full_order = setmetatable({}, { __mode = 'k' }), {}
function M.full(V, f, native)
    local draft = V.drafts and V.drafts[f]
    if draft then
        draft.full = draft.full or {}
        local entry = draft.full
        if not entry.rec or native and not entry.foreign then
            entry.rec, entry.tokens = parse.parse_tokens(draft.path or V.files[f].path, draft.source, { foreign = native })
            entry.foreign = native
        end
        return entry.rec, entry.tokens, draft
    end
    local key = V.files[f]
    local entry = full_cache[key]
    if entry == nil or native and not entry.foreign then
        local fresh = entry == nil
        if (key.size or 0) > M.MAX_FILE_BYTES then return nil end
        local doc = source_doc(V, f)
        -- Read/parse failures are transient, unlike a successful empty result.
        if not doc then return nil end
        local rec, tokens = parse.parse_tokens(key.path, doc.source, { foreign = native })
        if not rec then return nil end
        entry = { rec = rec, tokens = tokens, foreign = native }
        full_cache[key] = entry
        if fresh then full_order[#full_order + 1] = key end
        if #full_order > M.CACHE_FILES then full_cache[table.remove(full_order, 1)] = nil end
    end
    if not entry then return nil end
    return entry.rec, entry.tokens
end

-- Restore display/type details without attaching them to resident index nodes.
function M.detail(V, f, node)
    if node.sig then return node end
    local rec = M.full(V, f)
    if not rec then return node end
    if not rec.detail_nodes then
        local map = {}
        for n, original in ipairs(V.files[f].nodes) do
            local current = rec.nodes[n]
            if current and current.name == original.name and current.qualified == original.qualified
                and current.line == original.line and current.kind == original.kind then map[original] = current end
        end
        rec.detail_nodes = map
    end
    return rec.detail_nodes[node] or node
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
    return { name = node.name, kind = lsp.symbol_kind(node), detail = (hit and hit.sig) or node.sig or node.qualified, uri = loc.uri,
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
    local wanted = { [name] = true }
    for id in pairs(targets) do
        for _, alias in ipairs(require('codeoutline.lua_bindings').aliases(V.nodes[id], V.lua_global_export_tables)) do wanted[alias] = true end
    end
    local files = {}
    for i, f in ipairs(V.file_order) do files[i] = f end
    for _, f in ipairs(V.new_files) do files[#files + 1] = f end
    for _, f in ipairs(files) do
        control.check()
        local refs = V.files[f].refs
        local names = refs.name
        local aliases = {}
        for _, binding in ipairs(V.files[f].js_imports or {}) do aliases[binding.local_name] = true end
        if V.files[f].language == 'kotlin' then
            for _, imp in ipairs(V.files[f].imports) do
                if imp.alias and imp.path:match('([^.]+)$') == name then aliases[imp.alias] = true end
            end
        end
        for i = 1, #names do
            if i % 4096 == 0 then control.check() end
            if wanted[names[i]] or aliases[names[i]] or aliases[refs.recv[i]] or (refs.lua_binding and refs.lua_binding[i] ~= '') then
                if os.clock() > deadline then return hits, true end
                for _, dst in ipairs(resolve_site(V, f, refs.from[i], names[i], refs.kind[i], refs.recv[i], refs.lua_binding and refs.lua_binding[i] or refs.js_receiver and refs.js_receiver[i], refs.start and refs.start[i] or nil)) do
                    if targets[dst] then hits[#hits + 1] = { f, i }; break end
                end
                if #hits >= M.MAX_RESULTS then return hits, true end
            end
        end
    end
    return hits, false
end

-- Files one import record resolves to, through the graph's dependency
-- rules: a temporary record holding only that import.
function M.import_files(V, f, imp)
    local rec = V.files[f]
    local fake = { path = rec.language == 'go' and '\0/import.go' or rec.path, language = rec.language,
        nodes = {}, imports = { imp } }
    rawset(V.files, -1, fake)
    local ok, direct = pcall(graph.dependencies, V, -1)
    rawset(V.files, -1, nil)
    local files = {}
    if ok then for g in pairs(direct) do files[#files + 1] = g end end
    table.sort(files, function(x, y) return V.files[x].path < V.files[y].path end)
    return files
end

-- System include directories: client includePaths, INCLUDE/CPATH-style
-- variables, then the compiler's own list (cc -E -v) or, on Windows, the
-- newest Windows Kits and the MSVC found by vswhere. Probed once.
local probed_includes
local function existing(dir)
    local st = dir and xutils.stat(dir)
    return st and st.type == 'directory'
end
local function newest(dir)
    local entries = existing(dir) and xutils.list_dir(dir, nil, true) or {}
    local best
    for _, e in ipairs(entries) do
        local name = e.name or e
        if name:match('^%d') and (not best or name > best) then best = name end
    end
    return best and (dir .. '/' .. best)
end
local function probe_includes()
    if probed_includes then return probed_includes end
    local dirs = {}
    local function add(dir)
        dir = dir and paths.normalize(dir)
        if existing(dir) then dirs[#dirs + 1] = dir end
    end
    local windows = paths.windows
    for _, name in ipairs({ 'INCLUDE', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH' }) do
        for dir in (os.getenv(name) or ''):gmatch(windows and '[^;]+' or '[^:]+') do add(dir) end
    end
    if windows then
        local kits = newest('C:/Program Files (x86)/Windows Kits/10/Include')
        if kits then
            for _, sub in ipairs({ 'ucrt', 'um', 'shared', 'winrt' }) do add(kits .. '/' .. sub) end
        end
        local vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
        if xutils.stat(vswhere) and io.popen then
            -- cmd strips one pair of quotes around a command with `(x86)` in it.
            local command = '""' .. vswhere:gsub('/', '\\') .. '" -latest -products * -property installationPath 2>nul"'
            local ok, pipe = pcall(io.popen, command)
            local install = ok and pipe and pipe:read('*l')
            if ok and pipe then pipe:close() end
            local msvc = install and newest(paths.normalize(install) .. '/VC/Tools/MSVC')
            if msvc then add(msvc .. '/include') end
        end
    elseif io.popen then
        local ok, pipe = pcall(io.popen, 'cc -xc++ -E -v - </dev/null 2>&1')
        local output = ok and pipe and pipe:read('*a') or ''
        if ok and pipe then pipe:close() end
        local list = output:match('#include <%.%.%.> search starts here:(.-)End of search list') or ''
        for line in list:gmatch('[^\n]+') do add((line:gsub('^%s+', ''):gsub('%s+%(framework directory%)$', ''))) end
        add('/usr/local/include'); add('/usr/include')
    end
    local seen, unique = {}, {}
    for _, dir in ipairs(dirs) do
        local key = paths.key(dir)
        if not seen[key] then seen[key] = true; unique[#unique + 1] = dir end
    end
    probed_includes = unique
    return unique
end

-- Locations of the files an import on this line names: project files by the
-- dependency rules, and C/C++ headers found in the include directories.
local function import_targets(V, f, line, include_paths)
    local rec, result, seen = V.files[f], {}, {}
    local function add(uri)
        if not seen[uri] then seen[uri] = true; result[#result + 1] = { uri = uri, range = line_range(1) } end
    end
    for _, imp in ipairs(rec.imports or {}) do
        if imp.line == line then
            local files = imp.system and {} or M.import_files(V, f, imp)
            for _, g in ipairs(files) do add(uri_of(V, g)) end
            if #files == 0 and C_FAMILY[rec.language] then
                local dirs = {}
                if not imp.system then dirs[1] = (V.idx:abs(rec.path):match('^(.*)/[^/]*$')) end
                for _, dir in ipairs(include_paths or {}) do dirs[#dirs + 1] = paths.normalize(dir) end
                for _, dir in ipairs(probe_includes()) do dirs[#dirs + 1] = dir end
                for _, dir in ipairs(dirs) do
                    local file = dir .. '/' .. imp.path:gsub('\\', '/')
                    local st = xutils.stat(file)
                    if st and st.type == 'file' then add(documents.uri(file)); break end
                end
            end
        end
    end
    return result
end

-- Project-local declarative rules; read per request so configuration edits are live.
local function definition_rules(root)
    return require('codeoutline.rules').load(root).definitions
end

-- Decode literals without running source code. Lua long strings and quoted escapes.
local string_value = require('codeoutline.lua_literal').decode

local function call_name(T, i)
    if T.k[i] ~= 'id' or T:text(i + 1) ~= '(' then return nil end
    local name, first = T:text(i), i
    while T.k[first - 2] == 'id' and (T:text(first - 1) == '.' or T:text(first - 1) == ':') do
        name = T:text(first - 2) .. T:text(first - 1) .. name
        first = first - 2
    end
    if T:text(first - 1) == 'function' then return nil end
    return name
end

-- Find a single literal argument, skipping nested brackets and anonymous functions.
local function literal_argument(T, call, argument)
    local open, number, first = call + 1, 1, call + 2
    local close = T.m[open]
    if not close then return nil end
    local i = first
    while i <= close do
        local token = T:text(i)
        if i == close or token == ',' then
            if number == argument then
                if i == first + 1 and T.k[first] == 'str' then
                    return string_value(T:text(first)), T.s[first] - 1, T.e[first]
                end
                return nil
            end
            number, first = number + 1, i + 1
        elseif token == '(' or token == '[' or token == '{' then
            if not T.m[i] then return nil end
            i = T.m[i]
        elseif T.k[i] == 'kw' and token == 'function' then
            local depth = 1
            while depth > 0 and i < close do
                i = i + 1
                local kw = T.k[i] == 'kw' and T:text(i)
                if kw == 'function' or kw == 'if' or kw == 'do' or kw == 'repeat' then depth = depth + 1
                elseif kw == 'end' or kw == 'until' then depth = depth - 1 end
            end
            if depth > 0 then return nil end
        end
        i = i + 1
    end
end

local DECLARABLE = { ['function'] = true, method = true }

-- A string literal being written as a table key: t["name"] = ... or { ["name"] = ... }.
-- Returns the decoded value and the owner identifier for assignments (nil in constructors).
local function key_literal(T, i)
    if i < 3 or i + 2 > T.n or T.k[i] ~= 'str' then return nil end
    if T:text(i - 1) ~= '[' or T:text(i + 1) ~= ']' or T:text(i + 2) ~= '=' then return nil end
    local value = string_value(T:text(i))
    if not value then return nil end
    local owner
    if T.k[i - 2] == 'id' and T:text(i - 3) ~= '.' and T:text(i - 3) ~= ':' then
        owner = T:text(i - 2)
    end
    return value, owner
end

local function qualifier_matches(rule, owner)
    return not rule.qualifiers or (owner ~= nil and rule.qualifiers[owner])
end

-- A rule name also binds colon calls by their method segment: self:callCluster matches callCluster.
local function call_matches(name, rule_name)
    if not name then return false end
    if name == rule_name then return true end
    return name:find(':') ~= nil and name:match('([%w_]+)$') == rule_name
end

local function service_argument(rule)
    if rule.serviceArgument then return rule.serviceArgument end
    if rule.call == 'skynet.call' or rule.call == 'skynet.send' then return 1 end
    return rule.argument - 1
end

-- Service filenames are candidate locations, not proof of a runtime RPC edge.
-- Keep every exact suffix match if several indexed service roots use the name.
local function service_files(V, site, rule)
    local arg = site.args[service_argument(rule)]
    if not arg then return nil end
    local name = arg.service
    if not name and (rule.serviceArgument or rule.call:match('^dservice%.')
        or rule.call == 'skynet.call' or rule.call == 'skynet.send'
        or rule.call == 'cluster.call' or rule.call == 'cluster.send') then name = arg.literal end
    if not name or not name:match('^[%w_][%w_/-]*$') then return nil end
    local suffix, result = name .. '.lua', {}
    local function add(file)
        local rec = V.files[file]
        if rec.language == 'lua' and (rec.path == suffix or rec.path:sub(-#suffix - 1) == '/' .. suffix) then result[file] = true end
    end
    for _, file in ipairs(V.file_order) do control.check(); add(file) end
    for _, file in ipairs(V.new_files) do control.check(); add(file) end
    return next(result) and result or nil
end

-- Shared rules reuse graph sites and aliases. String targets navigate to project
-- declarations: remote services need not be lexical dependencies of the caller.
local function shared_definition(V, doc, offset, rules)
    local record = doc:parse()
    local language = record.language
    local names, applicable, literals = {}, {}, {}
    local function literal_position(name, argument)
        literals[name] = literals[name] or {}
        literals[name][argument] = true
    end
    for _, rule in ipairs(rules) do
        if rule.shared and (not rule.language or rule.language == language)
            and require('codeoutline.indirect').candidate(record, rule.call) then
            applicable[#applicable + 1] = rule
            names[rule.call] = true
            if rule.register then names[rule.register] = true end
            if rule.kind == 'target' or rule.kind == 'event' then literal_position(rule.call, rule.argument) end
            if rule.kind == 'target' and service_argument(rule) > 0 then literal_position(rule.call, service_argument(rule)) end
            if rule.kind == 'event' then literal_position(rule.register, rule.keyArgument) end
        end
    end
    if #applicable == 0 then return nil end
    local parsed = {}
    local function sites(source)
        if not parsed[source] then
            local record = source:dispatch(names)
            parsed[source] = record and record.dispatch_sites or {}
            -- Preserve the explicit Lua literal contract even when conservative
            -- alias analysis cannot prove a receiver's identity. These sites
            -- belong only to navigation, never to the relationship resolver.
            if language == 'lua' then
                local T = source:tokens()
                local known = {}
                for _, site in ipairs(parsed[source]) do
                    for argument in pairs(literals[site.call] or {}) do
                        local arg, range = site.args[argument], site.ranges[argument]
                        if arg and arg.literal and range then
                            known[site.call .. ':' .. argument .. ':' .. range[1]] = true
                        end
                    end
                end
                for i = 1, T.n do
                    if i % 128 == 0 then control.check() end
                    local name = call_name(T, i)
                    if literals[name] then
                        local site = { call = name, args = {}, ranges = {} }
                        for argument in pairs(literals[name]) do
                            local value, first, last = literal_argument(T, i, argument)
                            if value and not known[name .. ':' .. argument .. ':' .. first] then
                                site.args[argument] = { literal = value }
                                site.ranges[argument] = { first, last }
                            end
                        end
                        if next(site.args) then parsed[source][#parsed[source] + 1] = site end
                    end
                end
            end
        end
        return parsed[source]
    end
    local matched = {}
    for _, site in ipairs(sites(doc)) do
        for _, rule in ipairs(applicable) do
            local range, arg = site.ranges[rule.argument], site.args[rule.argument]
            if (site.call == rule.call or site.api == rule.call) and arg and range
                and range[1] <= offset and offset < range[2]
                and (rule.kind == 'callback' and arg.symbol or rule.kind ~= 'callback' and arg.literal) then
                matched[#matched + 1] = { rule = rule, site = site, arg = arg }
            end
        end
    end
    if #matched == 0 then return nil end
    local result, seen, events = {}, {}, {}
    local deadline = os.clock() + M.SCAN_SECONDS
    local function add(loc)
        local key = loc.uri .. ':' .. loc.range.start.line .. ':' .. loc.range.start.character
        if not seen[key] then result[#result + 1] = loc; seen[key] = true end
        return #result >= M.MAX_RESULTS
    end
    local f = V.add(doc)
    local resolver
    for _, match in ipairs(matched) do
        local rule = match.rule
        if rule.kind == 'event' then events[#events + 1] = match
        elseif rule.kind == 'target' then
            local name = match.arg.literal
            local services = language == 'lua' and service_files(V, match.site, rule)
            local short = name:match('([%w_]+)$')
            if short and name:match('^[%a_][%w_%.:>%-]*$') then
                for _, id in ipairs(V.by_name[short]) do
                    control.check()
                    if os.clock() > deadline then return result, true end
                    local node = V.nodes[id]
                    if DECLARABLE[node.kind] and V.files[V.node_file[id]].language == language
                        and (name == short or node.qualified == name)
                        and (not services or services[V.node_file[id]])
                        and qualifier_matches(rule, graph.owner(node.qualified or node.name)) then
                        if add(location(V, id)) then return result, true end
                    end
                end
            end
        else
            resolver = resolver or require('codeoutline.indirect').query(V, { rule }).resolve_targets
            for _, id in ipairs(resolver(f, match.site, match.arg, rule.kind == 'target')) do
                control.check()
                if os.clock() > deadline then return result, true end
                if add(location(V, id)) then return result, true end
            end
        end
    end
    if #events == 0 then return result, false end
    local files = {}
    for _, file in ipairs(V.file_order) do files[#files + 1] = file end
    for _, file in ipairs(V.new_files) do files[#files + 1] = file end
    table.sort(files, function(a, b) return V.files[a].path < V.files[b].path end)
    for _, file in ipairs(files) do
        control.check()
        if os.clock() > deadline then return result, true end
        local candidate = false
        if V.files[file].language == language then
            for _, match in ipairs(events) do
                if require('codeoutline.indirect').candidate(V.files[file], match.rule.register) then candidate = true; break end
            end
        end
        if candidate then
            local source = source_doc(V, file)
            if source then
                for _, site in ipairs(sites(source)) do
                    for _, match in ipairs(events) do
                        local rule = match.rule
                        local arg, range = site.args[rule.keyArgument], site.ranges[rule.keyArgument]
                        if (site.call == rule.register or site.api == rule.register) and arg and range
                            and arg.literal == match.arg.literal then
                            if add({ uri = source.uri, range = source:range(range[1], range[2]) }) then return result, true end
                        end
                    end
                end
            end
        end
    end
    return result, false
end

local function legacy_definition(V, doc, offset, rules)
    if doc:parse().language ~= 'lua' then return nil end
    local legacy = {}
    for _, rule in ipairs(rules) do
        if (not rule.shared or rule.legacy)
            and (not rule.language or rule.language == 'lua') then legacy[#legacy + 1] = rule end
    end
    rules = legacy
    if #rules == 0 then return nil end
    local tokens = doc:tokens()
    local matched = {}
    for i = 1, tokens.n do
        if i % 128 == 0 then control.check() end
        local name = call_name(tokens, i)
        for _, rule in ipairs(rules) do
            if call_matches(name, rule.call) then
                local value, first, last = literal_argument(tokens, i, rule.argument)
                if value and first <= offset and offset < last then matched[#matched + 1] = { rule, value } end
            end
        end
    end
    if #matched == 0 then return nil end
    local result, seen, files = {}, {}, {}
    local function add(loc)
        local start = loc.range.start
        local key = loc.uri .. ':' .. start.line .. ':' .. start.character
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = loc
        end
        return #result >= M.MAX_RESULTS
    end
    local calls, keys = {}, {}
    local deadline = os.clock() + M.SCAN_SECONDS
    for _, match in ipairs(matched) do
        if match[1].targetKind == 'declaration' then
            for _, id in ipairs(V.by_name[match[2]]) do
                control.check()
                if os.clock() > deadline then return result, true end
                local node = V.nodes[id]
                if DECLARABLE[node.kind] and V.files[V.node_file[id]].language == 'lua' then
                    local owner = graph.owner(node.qualified or node.name)
                    if qualifier_matches(match[1], owner) and add(location(V, id)) then
                        return result, true
                    end
                end
            end
        elseif match[1].targetKind == 'key' then
            keys[#keys + 1] = match
        else
            calls[#calls + 1] = match
        end
    end
    if #calls == 0 and #keys == 0 then return result, false end
    for _, f in ipairs(V.file_order) do files[#files + 1] = f end
    for _, f in ipairs(V.new_files) do files[#files + 1] = f end
    table.sort(files, function(a, b) return V.files[a].path < V.files[b].path end)
    for _, f in ipairs(files) do
        control.check()
        if os.clock() > deadline then return result, true end
        if V.files[f].language == 'lua' then
            local target = source_doc(V, f)
            if target then
                local candidate = #keys > 0
                for _, match in ipairs(calls) do
                    local tail = match[1].target:match('([%w_]+)$')
                    if target.source:find(tail, 1, true) then candidate = true; break end
                end
                if candidate then
                    local T = target:tokens()
                    for i = 1, T.n do
                        if i % 128 == 0 then
                            control.check()
                            if os.clock() > deadline then return result, true end
                        end
                        local name = call_name(T, i)
                        for _, match in ipairs(calls) do
                            if call_matches(name, match[1].target) then
                                local value, first, last = literal_argument(T, i, match[1].targetArgument)
                                if value == match[2] then
                                    if add({ uri = target.uri, range = target:range(first, last) }) then
                                        return result, true
                                    end
                                end
                            end
                        end
                        if #keys > 0 then
                            local value, owner = key_literal(T, i)
                            if value then
                                for _, match in ipairs(keys) do
                                    if value == match[2] and qualifier_matches(match[1], owner)
                                        and add({ uri = target.uri, range = target:range(T.s[i] - 1, T.e[i]) }) then
                                        return result, true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return result, false
end

local function configured_definition(V, doc, offset)
    local rules = definition_rules(V.root)
    if #rules == 0 then return nil end
    local shared, incomplete = shared_definition(V, doc, offset, rules)
    local legacy, legacy_incomplete = legacy_definition(V, doc, offset, rules)
    if shared == nil then return legacy, legacy_incomplete end
    local seen = {}
    local function key(loc)
        return loc.uri .. ':' .. loc.range.start.line .. ':' .. loc.range.start.character
    end
    for _, loc in ipairs(shared) do seen[key(loc)] = true end
    for _, loc in ipairs(legacy or {}) do
        if not seen[key(loc)] then
            if #shared >= M.MAX_RESULTS then return shared, true end
            seen[key(loc)] = true
            shared[#shared + 1] = loc
        end
    end
    return shared, incomplete or legacy_incomplete or false
end

local function at(req)
    local doc = request_doc(req)
    if not doc then return nil end
    local V = view(req.session, req.root)
    local f = V.add(doc)
    if not f then return nil end
    local offset = doc:offset(req.position)
    local c = cursor(doc, offset)
    local targets = {}
    if c and c.decl then targets = { V.id_of[f][c.decl] }
    elseif c then targets = resolve_site(V, f, c.from, c.name, c.kind, c.recv, c.evidence, c.first) end
    return V, doc, c, targets, f, offset
end

local handlers = {}

function handlers.lsp_definition(req)
    local V, doc, c, targets, f, offset = at(req)
    if not V then return false end
    local configured, incomplete
    -- Rule arguments are strings or referenced values, never the name of a
    -- call/declaration itself. Avoid collecting dispatch sites for ordinary F12.
    if not c or not c.decl and c.kind ~= 'call' and c.kind ~= 'member_call' and c.kind ~= 'new' then
        configured, incomplete = configured_definition(V, doc, offset)
    end
    if configured then return configured, incomplete end
    local line = doc:position(offset).line + 1
    local importer = false
    if c and not c.decl then
        -- `require`/`dofile` themselves name the file they load, not a same-named project function.
        for _, imp in ipairs(V.files[f].imports or {}) do
            if imp.line == line and imp.kind == c.name then importer = true end
        end
    end
    if #targets == 0 or importer then
        -- An import line: `require "a.b"`, `dofile("x.lua")`, `#include <x.h>`, `from . import m`.
        local files = import_targets(V, f, line, req.includePaths)
        if #files > 0 or #targets == 0 then return files end
    end
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

-- Follow unmatched delimiters up to the cursor. Commas in nested calls,
-- literals and indexing expressions do not advance the enclosing argument.
function handlers.lsp_signature(req)
    local doc = request_doc(req)
    if not doc then return false end
    local T, offset = doc:tokens(), doc:offset(req.position)
    if not T then return false end
    local language = doc:parse().language
    local stack = {}
    local close = { [')'] = '(', [']'] = '[', ['}'] = '{' }
    local lua_blocks = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
    for i = 1, T.n do
        if T.s[i] - 1 >= offset then break end
        if i % 128 == 0 then control.check() end
        if language == 'lua' and T.k[i] == 'kw' then
            local s = T:text(i)
            if lua_blocks[s] then
                stack[#stack + 1] = { token = i, delimiter = s, block = true, argument = 0 }
            elseif s == 'end' or s == 'until' then
                while #stack > 0 do if table.remove(stack).block then break end end
            end
        elseif T.k[i] == 'op' then
            local s = T:text(i)
            if s == '(' or s == '[' or s == '{' then
                stack[#stack + 1] = { token = i, delimiter = s, argument = 0 }
            elseif close[s] then
                if stack[#stack] and stack[#stack].delimiter == close[s] then table.remove(stack) end
            elseif s == ',' and stack[#stack] then
                stack[#stack].argument = stack[#stack].argument + 1
            end
        end
    end
    local call
    local kotlin = language == 'kotlin'
    for i = #stack, 1, -1 do
        local entry = stack[i]
        -- A callback body is not an argument-editing context for its caller.
        -- Inner calls can still supply help; after `end` the outer call resumes.
        if entry.delimiter == 'function' then break end
        local name_token = entry.token - 1
        if kotlin and entry.delimiter == '(' and T:text(name_token) == '>' then
            local depth, k = 1, name_token - 1
            while k > 1 and depth > 0 do
                local s = T:text(k)
                if s == '>' then depth = depth + 1 elseif s == '<' then depth = depth - 1 end
                k = k - 1
            end
            if depth == 0 then name_token = k end
        end
        if entry.delimiter == '(' and T.k[name_token] == 'id' then
            call = entry; call.name_token = name_token; break
        end
    end
    if not call then return false end
    local name_token = call.name_token
    local query = {}
    for key, value in pairs(req) do query[key] = value end
    query.position = doc:position(T.s[name_token] - 1)
    local V, _, c, targets = at(query)
    if not V or not c or c.decl then return false end
    local signatures, seen = {}, {}
    for _, id in ipairs(targets) do
        local node = V.nodes[id]
        local foreign = require('codeoutline.foreign').signature(node, doc:parse().language, T:text(name_token))
        local label = M.detail(V, V.node_file[id], node).sig
        if foreign and not seen[foreign.label] then
            foreign.activeParameter = #foreign.parameters > 0 and math.min(call.argument, #foreign.parameters - 1) or nil
            signatures[#signatures + 1] = foreign
            seen[foreign.label] = true
        elseif not foreign and REFERENCE[node.kind] and label and not seen[label] then
            local sig_doc = documents.new(uri_of(V, V.node_file[id]), label, 0)
            local S = sig_doc:tokens()
            local opening
            for i = 1, S and S.n - 1 or 0 do
                if S:text(i) == node.name and S:text(i + 1) == '(' then opening = i + 1; break end
            end
            local ending = opening and S.m[opening]
            if ending then
                local parameters, start, i, angle_depth = {}, S.e[opening] + 1, opening + 1, 0
                while i <= ending do
                    local s = S:text(i)
                    if kotlin and S.k[i] == 'op' then
                        if s == '<' then angle_depth = angle_depth + 1
                        elseif s == '>' then angle_depth = math.max(0, angle_depth - 1) end
                    end
                    if i == ending or (s == ',' and angle_depth == 0) then
                        local parameter = label:sub(start, S.s[i] - 1):match('^%s*(.-)%s*$')
                        if parameter ~= '' and parameter ~= 'void' then parameters[#parameters + 1] = { label = parameter } end
                        start = S.e[i] + 1
                    elseif S.m[i] and S.m[i] > i then i = S.m[i] end
                    i = i + 1
                end
                signatures[#signatures + 1] = { label = label, parameters = parameters,
                    activeParameter = #parameters > 0 and math.min(call.argument, #parameters - 1) or nil }
                seen[label] = true
            end
        end
    end
    if #signatures == 0 then return false end
    return { signatures = signatures, activeSignature = 0, activeParameter = signatures[1].activeParameter }
end

function handlers.lsp_hover(req)
    local V, doc, c, targets = at(req)
    if not V or #targets == 0 then return false end
    local parts = {}
    for k, id in ipairs(targets) do
        if k > M.MAX_HOVER then break end
        local node, rec = V.nodes[id], V.files[V.node_file[id]]
        local foreign = require('codeoutline.foreign').signature(node, doc:parse().language, doc.source:sub(c.first + 1, c.last))
        parts[#parts + 1] = '```' .. (foreign and doc:parse().language or rec.language or '') .. '\n'
            .. (foreign and foreign.label or M.detail(V, V.node_file[id], node).sig or node.qualified) .. '\n```'
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
            for _, dst in ipairs(resolve_site(V, f, from, refs.name[i], refs.kind[i], refs.recv[i], refs.lua_binding and refs.lua_binding[i] or refs.js_receiver and refs.js_receiver[i], refs.start and refs.start[i] or nil)) do
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
    local name = V.files[V.node_file[targets[1]]].language == 'kotlin' and V.nodes[targets[1]].name or c.name
    local hits, incomplete = scan(V, set, name)
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

-- Shared with completion.lua, which registers its own handler.
M.view, M.request_doc, M.deps, M.source_doc = view, request_doc, deps, source_doc
function M.register(method, handler) handlers[method] = handler end

function M.handles(method) return handlers[method] ~= nil end

-- Returns { result = value (false for null), incomplete = bool } or { error = message }.
function M.execute(req)
    local result, incomplete = handlers[req.method](req)
    if type(result) == 'table' and result.error then return result end
    return { result = result, incomplete = incomplete or false }
end

return M
