-- graph.lua — cross-file resolution over an index: global symbol tables,
-- file dependencies (#include / import), and call edges between nodes.
--
--   local G = graph.build(idx)
--   G.nodes[id]        -> <node table> (shared with the file record)
--   G.node_file[id]    -> file index
--   G.files[f]         -> file record (path, language, nodes, refs, imports)
--   G.by_name[name]    -> { id, ... }
--   G.out[id], G.inn[id] -> { other, line, kind, other, line, kind, ... }
--
-- Edge lists are flat, EDGE values per edge, and nodes carry no wrapper
-- table: on large trees per-edge and per-node tables cost more than the
-- data they hold. Walk an edge list with `for i = 1, #list, graph.EDGE`.
--
-- Resolution is name-based with locality scoring, the same model CodeGraph
-- uses for dynamic languages: a call binds to the best-placed definition of
-- that name (same file > included/imported file > paired source of an
-- included header > same directory), never across languages. Ties keep up
-- to MAX_TIES targets instead of guessing.

local control = require('codeoutline.control')
local M = {}

M.EDGE = 3
M.MAX_TIES = 3
M.MAX_CANDIDATES = 200

-- Node kinds a call / `new` / bare reference may bind to.
local CALLABLE = {
    ['function'] = true, method = true, macro = true, constructor = true, prototype = true,
    class = true, record = true,
}
local NEWABLE = { class = true, record = true, constructor = true, enum = true }
local VALUE = { ['function'] = true, method = true }

-- C and C++ call each other (extern "C", shared headers); others don't mix.
local C_FAMILY = { c = true, cpp = true }
local HEADER_EXT = { h = true, hpp = true, hh = true, hxx = true }
local SOURCE_EXT = { c = true, cc = true, cpp = true, cxx = true }
local FAMILY = { c = 'c', cpp = 'c', javascript = 'js', typescript = 'js' }
local function family(lang) return FAMILY[lang] or lang end

local function dirname(p) return p:match('^(.*)/[^/]*$') or '' end
local function basename(p) return p:match('([^/]*)$') end
local function stem(p) return basename(p):match('^(.*)%.[^.]*$') or basename(p) end

local function push(t, k, v)
    local list = t[k]
    if not list then list = {}; t[k] = list end
    list[#list + 1] = v
end

local function push3(t, k, a, b, c)
    local list = t[k]
    if not list then list = {}; t[k] = list end
    local n = #list
    list[n + 1], list[n + 2], list[n + 3] = a, b, c
end

-- Files a file depends on, resolved from its #include / import records.
local function resolve_deps(G, f)
    local rec = G.files[f]
    local deps = {}
    local function add(g) if g and g ~= f then deps[g] = true end end
    local here = dirname(rec.path)
    for _, imp in ipairs(rec.imports) do
        local path = imp.path
        if C_FAMILY[rec.language] then
            -- "dir/x.h": files whose path ends with it, preferring the closest
            for _, g in ipairs(G.by_base[basename(path)] or {}) do
                local p = G.files[g].path
                if p == path or p:sub(-(#path + 1)) == '/' .. path then add(g) end
            end
        elseif rec.language == 'python' then
            local rel = path
            local base = here
            local dots = rel:match('^(%.+)')
            if dots then
                for _ = 2, #dots do base = dirname(base) end
                rel = rel:sub(#dots + 1)
            end
            local sub = rel:gsub('%.', '/')
            local cands = {}
            if dots then
                local b = base ~= '' and (base .. '/') or ''
                cands = { b .. sub .. '.py', b .. sub .. '/__init__.py' }
                -- `from . import x` / `from .pkg import x`: the names may be modules
                for _, name in ipairs(imp.names or {}) do
                    local s2 = (sub ~= '' and (sub .. '/') or '') .. name
                    cands[#cands + 1] = b .. s2 .. '.py'
                end
            end
            for _, c in ipairs(cands) do add(G.file_index[c]) end
            if not dots and sub ~= '' then
                -- absolute import: match by path suffix anywhere in the tree
                for _, g in ipairs(G.by_base[basename(sub) .. '.py'] or {}) do
                    local p = G.files[g].path
                    if p == sub .. '.py' or p:sub(-(#sub + 4)) == '/' .. sub .. '.py' then add(g) end
                end
                for _, g in ipairs(G.by_base['__init__.py'] or {}) do
                    local p = G.files[g].path
                    local want = sub .. '/__init__.py'
                    if p == want or p:sub(-(#want + 1)) == '/' .. want then add(g) end
                end
            end
        elseif rec.language == 'lua' then
            -- require 'a.b' -> a/b.lua or a/b/init.lua anywhere under the root
            -- (package.path prefixes like scripts/?.lua vary per project);
            -- dofile/loadfile take a path.
            local wants
            if imp.kind == 'require' then
                local sub = path:gsub('%.', '/')
                wants = { sub .. '.lua', sub .. '/init.lua' }
            else
                wants = { (path:gsub('\\', '/'):gsub('^%./', '')) }
            end
            for _, want in ipairs(wants) do
                for _, g in ipairs(G.by_base[basename(want)] or {}) do
                    local p = G.files[g].path
                    if p == want or p:sub(-(#want + 1)) == '/' .. want then add(g) end
                end
            end
        elseif rec.language == 'go' then
            -- import "github.com/org/repo/pkg/sub": the package is the directory
            -- whose path ends with the longest matching suffix of the import
            local segs = {}
            for s in path:gmatch('[^/]+') do segs[#segs + 1] = s end
            for k = 1, #segs do
                local suffix = table.concat(segs, '/', k)
                local hit = false
                for _, d in ipairs(G.dir_by_base[segs[#segs]] or {}) do
                    if d == suffix or d:sub(-(#suffix + 1)) == '/' .. suffix then
                        for _, g in ipairs(G.dir_files[d]) do add(g) end
                        hit = true
                    end
                end
                if hit then break end
            end
        elseif rec.language == 'javascript' or rec.language == 'typescript' then
            -- relative specifiers only; bare package names live in node_modules
            if path:sub(1, 1) == '.' then
                local base = here
                local rel = path
                while true do
                    if rel:sub(1, 2) == './' then rel = rel:sub(3)
                    elseif rel:sub(1, 3) == '../' then base = dirname(base); rel = rel:sub(4)
                    else break end
                end
                local stemp = (base ~= '' and (base .. '/') or '') .. rel
                stemp = stemp:gsub('%.[mc]?js$', '')        -- TS sources imported as ./x.js
                for _, ext in ipairs({ '', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts',
                    '/index.ts', '/index.tsx', '/index.js', '/index.mjs' }) do
                    add(G.file_index[stemp .. ext])
                end
            end
        elseif rec.language == 'csharp' then
            for _, g in ipairs(G.ns_files[path] or {}) do add(g) end
        elseif rec.language == 'rust' then
            if imp.kind == 'mod' then
                -- mod x;  ->  x.rs / x/mod.rs next to this file (or under its stem dir)
                local st = stem(rec.path)
                local bases = { here }
                if st ~= 'mod' and st ~= 'lib' and st ~= 'main' then bases[2] = (here ~= '' and here .. '/' or '') .. st end
                for _, b in ipairs(bases) do
                    local pre = b ~= '' and (b .. '/') or ''
                    add(G.file_index[pre .. path .. '.rs'])
                    add(G.file_index[pre .. path .. '/mod.rs'])
                end
            else
                -- use crate::a::b::{C, D}: the module file for the longest path prefix
                local segs = {}
                for s in path:gsub('{.*$', ''):gmatch('[%w_]+') do
                    if s ~= 'crate' and s ~= 'self' and s ~= 'super' and s ~= 'pub' then segs[#segs + 1] = s end
                end
                for k = #segs, 1, -1 do
                    local sub = table.concat(segs, '/', 1, k)
                    local found = false
                    for _, want in ipairs({ sub .. '.rs', sub .. '/mod.rs' }) do
                        for _, g in ipairs(G.by_base[basename(want)] or {}) do
                            local p = G.files[g].path
                            if p == want or p:sub(-(#want + 1)) == '/' .. want then add(g); found = true end
                        end
                    end
                    if found then break end
                end
            end
        elseif rec.language == 'java' then
            if path:sub(-2) == '.*' then
                for _, g in ipairs(G.pkg_files[path:sub(1, -3)] or {}) do add(g) end
            else
                for _, id in ipairs(G.by_qualified[path] or {}) do add(G.node_file[id]) end
            end
        end
    end
    -- Java: the whole package is visible without imports; Go: the whole
    -- directory is one package; C#: the file's own namespaces.
    if rec.language == 'java' and rec.package then
        for _, g in ipairs(G.pkg_files[rec.package] or {}) do add(g) end
    elseif rec.language == 'go' then
        for _, g in ipairs(G.dir_files[here] or {}) do add(g) end
    elseif rec.language == 'csharp' then
        for _, node in ipairs(rec.nodes) do
            if node.kind == 'namespace' then
                for _, g in ipairs(G.ns_files[node.qualified] or {}) do add(g) end
            end
        end
    end
    -- C: x.c usually implements what x.h declares, so a file that includes
    -- x.h also "depends on" x.c for resolution purposes.
    local paired = {}
    if C_FAMILY[rec.language] then
        for g in pairs(deps) do
            local p = G.files[g].path
            if HEADER_EXT[p:match('%.(%w+)$') or ''] then
                for _, h in ipairs(G.by_stem[stem(p)] or {}) do
                    if h ~= f and SOURCE_EXT[G.files[h].path:match('%.(%w+)$') or ''] then paired[h] = true end
                end
            end
        end
    end
    return deps, paired
end

-- Innermost class-like container of a node (for self./this. calls).
local function owner_class(G, id)
    local f = G.node_file[id]
    local rec = G.files[f]
    local p = G.nodes[id].parent
    while p do
        local pn = rec.nodes[p]
        if pn.kind == 'class' or pn.kind == 'record' or pn.kind == 'interface' or pn.kind == 'enum'
            or pn.kind == 'struct' or pn.kind == 'union' then
            return G.id_of[f][p]
        end
        p = pn.parent
    end
    return nil
end

-- Placement of a candidate in file cf relative to the ref's file f: 0 when
-- unrelated, nil when invisible (a C static of another file).
local function locality(G, f, cf, c, deps, paired)
    if cf == f then return 100 end
    if c.static then return nil end
    if deps[cf] then return 50 end
    if paired[cf] then return 40 end
    if G.file_dir[cf] == G.file_dir[f] then return 20 end
    return 0
end

-- owner: the innermost class of src_id, passed in by resolve_ref when the
-- ref kind needs it (computed once per ref, not per candidate).
local function score(G, f, src_id, ref_kind, recv, cid, deps, paired, owner)
    local c = G.nodes[cid]
    local cf = G.node_file[cid]
    if family(G.files[cf].language) ~= family(G.files[f].language) then return nil end
    local s = locality(G, f, cf, c, deps, paired)
    if not s then return nil end
    local kind = c.kind
    if kind == 'prototype' then s = s - 3 end
    if ref_kind == 'member_call' and (recv == 'self' or recv == 'this' or recv == 'cls') and src_id then
        if owner and c.parent and G.id_of[cf][c.parent] == owner then
            s = s + 80
        elseif kind ~= 'method' then
            s = s - 20
        end
    elseif ref_kind == 'member_call' and s <= 0 then
        -- obj.name() on an unknown receiver: binding it to any same-named
        -- method project-wide (str.format -> some format()) is mostly wrong,
        -- so only local candidates qualify.
        return nil
    elseif ref_kind == 'call' and G.files[f].language == 'java' and src_id then
        -- unqualified call inside a class: implicit this
        if owner and c.parent and G.id_of[cf][c.parent] == owner then s = s + 30 end
    end
    return s
end

local function is_decl(node) return node.kind == 'prototype' or node.decl end

-- Scored candidates of the current resolve_ref call, reused across calls to
-- keep the hot loop allocation-free; only the first n entries are live.
local scored_ids, scored_vals = {}, {}

local function resolve_ref(G, f, src_id, name, kind, recv, deps, paired)
    if kind == 'annotation' then return nil end
    local accept = CALLABLE
    if kind == 'new' then accept = NEWABLE elseif kind == 'ref' then accept = VALUE end
    local cands = G.by_name[name]
    if not cands then return nil end
    -- Score first: score() rejects other languages and statics of other
    -- files, so "is there a real definition?" is only asked among the
    -- candidates this call could actually reach. (Asking it over all
    -- same-named nodes let a Python `def work` hide the C prototype of
    -- `work`, after which the Python def was filtered out too.)
    local self_call = kind == 'member_call' and src_id and (recv == 'self' or recv == 'this' or recv == 'cls')
    local owner = (self_call or (kind == 'call' and src_id and G.files[f].language == 'java'))
        and owner_class(G, src_id) or nil
    -- score() rejects an unknown-receiver member call to an unrelated file;
    -- checking placement first skips most candidates of common method names.
    local local_only = kind == 'member_call' and not self_call
    local n, has_def = 0, false
    for i = 1, math.min(#cands, M.MAX_CANDIDATES) do
        local cid = cands[i]
        local node = G.nodes[cid]
        if cid ~= src_id and accept[node.kind]
            and (not local_only or (locality(G, f, G.node_file[cid], node, deps, paired) or 0) > 0) then
            local s = score(G, f, src_id, kind, recv, cid, deps, paired, owner)
            if s then
                n = n + 1
                scored_ids[n], scored_vals[n] = cid, s
                if not is_decl(node) then has_def = true end
            end
        end
    end
    -- Prefer definitions: drop prototypes / in-class declarations when a
    -- reachable definition exists.
    local best, ties = nil, {}
    for i = 1, n do
        local cid, s = scored_ids[i], scored_vals[i]
        if not (has_def and is_decl(G.nodes[cid])) then
            if not best or s > best then
                best, ties = s, { cid }
            elseif s == best and #ties < M.MAX_TIES then
                ties[#ties + 1] = cid
            end
        end
    end
    -- A lone candidate far away (score 0) is still a match for a unique
    -- name; many far candidates with nothing to separate them is a guess.
    if best and best <= 0 and #ties > 1 then return nil end
    return ties
end

function M.build(idx, opts)
    local G = {
        files = {}, file_index = {}, file_dir = {}, nodes = {}, node_file = {}, id_of = {},
        by_name = {}, by_lname = {}, by_qualified = {}, by_base = {}, by_stem = {},
        pkg_files = {}, children = {}, out = {}, inn = {}, deps = {}, dir_files = {}, ns_files = {},
        generation = idx.generation,
    }
    local paths = {}
    for rel in pairs(idx.files) do paths[#paths + 1] = rel end
    table.sort(paths)
    -- Directory ids per file: placement scoring compares numbers instead of
    -- slicing two paths per candidate.
    local dir_ids = {}
    -- Checkpoints per file: LuaJIT does not run count hooks inside compiled
    -- loops, so cancellation relies on these (as in Index:refresh).
    for f, rel in ipairs(paths) do
        control.check()
        local rec = idx.files[rel]
        G.files[f] = rec
        G.file_index[rel] = f
        local dir = dirname(rel)
        local did = dir_ids[dir]
        if not did then did = f; dir_ids[dir] = did end
        G.file_dir[f] = did
        push(G.by_base, basename(rel), f)
        push(G.by_stem, stem(rel), f)
        push(G.dir_files, dirname(rel), f)
        if rec.package then push(G.pkg_files, rec.package, f) end
        local ids = {}
        G.id_of[f] = ids
        for n, node in ipairs(rec.nodes) do
            if n % 128 == 0 then control.check() end
            local id = #G.nodes + 1
            G.nodes[id], G.node_file[id] = node, f
            ids[n] = id
            push(G.by_name, node.name, id)
            push(G.by_lname, node.name:lower(), id)
            push(G.by_qualified, node.qualified, id)
            if node.kind == 'namespace' and rec.language == 'csharp' then
                local list = G.ns_files[node.qualified]
                if not list or list[#list] ~= f then push(G.ns_files, node.qualified, f) end
            end
            if node.parent then push(G.children, ids[node.parent], id) end
        end
    end
    -- Directories indexed by their last path segment (Go import lookups).
    G.dir_by_base = {}
    for d in pairs(G.dir_files) do push(G.dir_by_base, basename(d), d) end
    for _, list in pairs(G.dir_by_base) do table.sort(list) end
    -- Step 3 keeps the eager graph as the oracle; this mode builds symbols only.
    if opts and opts.edges == false then
        G.out, G.inn, G.deps = nil, nil, nil
        G.symbols_only = true
        return G
    end
    -- Edges.
    local edges = 0
    for f, rec in ipairs(G.files) do
        control.check()
        local deps, paired = resolve_deps(G, f)
        G.deps[f] = deps
        local refs, ids = rec.refs, G.id_of[f]
        local names, froms, kinds, lines, recvs = refs.name, refs.from, refs.kind, refs.line, refs.recv
        for i = 1, #names do
            if i % 128 == 0 then control.check() end
            local from = froms[i]
            if from > 0 then
                local src, kind, line = ids[from], kinds[i], lines[i]
                local targets = resolve_ref(G, f, src, names[i], kind, recvs[i] or nil, deps, paired)
                if targets then
                    for _, dst in ipairs(targets) do
                        push3(G.out, src, dst, line, kind)
                        push3(G.inn, dst, src, line, kind)
                        edges = edges + 1
                    end
                end
            end
        end
    end
    G.edge_count = edges
    return G
end

-- Query-owned edges: never attach these caches to the resident symbol tables.
M.MAX_EXPANDED = 20000
function M.query(symbols, opts)
    opts = opts or {}
    local limit = opts.max_expanded or M.MAX_EXPANDED
    assert(type(limit) == 'number' and limit >= 1 and limit % 1 == 0 and limit < math.huge,
        'max_expanded must be a positive integer')
    local Q = setmetatable({ out = {}, inn = {},
        stats = { expanded = 0, incoming_scans = 0, resolved_refs = 0 }, incomplete = false }, { __index = symbols })
    local dependencies, references = {}, {}
    local function deps(f)
        local entry = dependencies[f]
        if not entry then
            local direct, paired = resolve_deps(symbols, f)
            entry = { direct, paired }; dependencies[f] = entry
        end
        return entry[1], entry[2]
    end
    local function targets(f, i)
        local rec, ids = symbols.files[f], symbols.id_of[f]
        local refs = rec.refs
        local direct, paired = deps(f)
        Q.stats.resolved_refs = Q.stats.resolved_refs + 1
        return resolve_ref(symbols, f, ids[refs.from[i]], refs.name[i], refs.kind[i],
            refs.recv[i] or nil, direct, paired)
    end
    setmetatable(Q.out, { __index = function(cache, id)
        control.check()
        if Q.stats.expanded >= limit then Q.incomplete = true; return nil end
        Q.stats.expanded = Q.stats.expanded + 1
        local f = assert(symbols.node_file[id], 'unknown symbol')
        local rec, ids = symbols.files[f], symbols.id_of[f]
        local grouped = references[f]
        if not grouped then
            grouped = {}
            for i, from in ipairs(rec.refs.from) do
                if i % 128 == 0 then control.check() end
                if from > 0 then push(grouped, ids[from], i) end
            end
            references[f] = grouped
        end
        local edges = {}
        for _, i in ipairs(grouped[id] or {}) do
            control.check()
            for _, dst in ipairs(targets(f, i) or {}) do
                edges[#edges + 1] = dst
                edges[#edges + 1] = rec.refs.line[i]
                edges[#edges + 1] = rec.refs.kind[i]
            end
        end
        rawset(cache, id, edges)
        return edges
    end })
    -- Resolve all requested callers with a single ordered multi-name scan.
    function Q:load_incoming(ids)
        local wanted, names, found = {}, {}, false
        for _, id in ipairs(ids) do
            if rawget(self.inn, id) == nil then
                wanted[id], names[symbols.nodes[id].name], found = true, true, true
            end
        end
        if not found then return end
        local incoming = {}
        for id in pairs(wanted) do incoming[id] = {} end
        self.stats.incoming_scans = self.stats.incoming_scans + 1
        -- Hot loop over every reference: numeric loops, hoisted fields, and the
        -- selective name test first. Checkpoints run per file and per chunk.
        local files = symbols.files
        for f = 1, #files do
            control.check()
            local refs = files[f].refs
            local ref_names, froms = refs.name, refs.from
            local count = #ref_names
            for first = 1, count, 4096 do
                if first > 1 then control.check() end
                for i = first, math.min(count, first + 4095) do
                    if names[ref_names[i]] and froms[i] > 0 then
                        for _, dst in ipairs(targets(f, i) or {}) do
                            if wanted[dst] then
                                push3(incoming, dst, symbols.id_of[f][froms[i]], refs.line[i], refs.kind[i])
                            end
                        end
                    end
                end
            end
        end
        -- Interrupted scans never publish partial caller lists.
        for id, edges in pairs(incoming) do rawset(self.inn, id, edges) end
    end
    setmetatable(Q.inn, { __index = function(cache, id)
        Q:load_incoming({ id })
        return rawget(cache, id)
    end })
    return Q
end

-- Location string for a node: "path:line".
function M.where(G, id)
    return G.files[G.node_file[id]].path .. ':' .. G.nodes[id].line
end

return M
