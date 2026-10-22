-- graph.lua — cross-file resolution over an index: global symbol tables,
-- file dependencies (#include / import), and call edges resolved per query.
--
--   local G = graph.build(idx)       -- symbol and path tables, kept per file
--   G.nodes[id]        -> <node table> (shared with the file record)
--   G.node_file[id]    -> file index
--   G.files[f]         -> file record (path, language, nodes, refs, imports)
--   G.file_order       -> { f, ... } in path order
--   G.by_name[name]    -> { id, ... } in path, then node order
--   G.by_owner[q]      -> members of qualifier q (`Box` for `Box::area`)
--   local Q = graph.query(G)
--   Q.out[id], Q.inn[id] -> { other, line, kind, other, line, kind, ... }
--
-- Tables change one file at a time (add_file / remove_file). File and node
-- ids are never reused while the tables live, so removed files leave holes:
-- iterate file_order, and compare nodes with graph.before rather than by id.
-- Every ordered list matches what a fresh build of the same records gives.
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
local js_resolution = require('codeoutline.js_resolution')
local lua_bindings = require('codeoutline.lua_bindings')
local M = {}

M.EDGE = 3
M.MAX_TIES = 3
M.MAX_CANDIDATES = 200
M.MAX_INCLUDES = 2000

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
local FAMILY = { c = 'c', cpp = 'c', javascript = 'js', typescript = 'js', arkts = 'js' }
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
local function resolve_deps(G, f, js_context)
    local rec = G.files[f]
    local deps = {}
    local function add(g) if g and g ~= f then deps[g] = true end end
    local here = dirname(rec.path)
    for _, imp in ipairs(rec.imports) do
        local path = imp.path
        if C_FAMILY[rec.language] then
            path = path:gsub('\\', '/')
            local parts = {}
            for segment in ((here ~= '' and here .. '/' or '') .. path):gmatch('[^/]+') do
                if segment == '..' then parts[#parts] = nil
                elseif segment ~= '.' then parts[#parts + 1] = segment end
            end
            local relative = G.file_index[table.concat(parts, '/')]
            if relative and not imp.system then
                add(relative)
                goto next_import
            end
            -- Fall back to suffix candidates when the local quoted path is absent.
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
            for _, g in ipairs(lua_bindings.modules(G, imp, js_context and js_context.lua)) do add(g) end
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
        elseif rec.language == 'javascript' or rec.language == 'typescript' or rec.language == 'arkts' then
            add(js_resolution.module(G, f, path, js_context, imp.kind))
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
        elseif rec.language == 'java' or rec.language == 'kotlin' then
            if path:sub(-2) == '.*' then
                for _, g in ipairs(G.pkg_files[path:sub(1, -3)] or {}) do add(g) end
                if rec.language == 'kotlin' then
                    for _, id in ipairs(G.by_owner[path:sub(1, -3)] or {}) do add(G.node_file[id]) end
                end
            else
                for _, id in ipairs(G.by_qualified[path] or {}) do add(G.node_file[id]) end
            end
        end
        ::next_import::
    end
    -- Java: the whole package is visible without imports; Go: the whole
    -- directory is one package; C#: the file's own namespaces.
    if (rec.language == 'java' or rec.language == 'kotlin') and rec.package then
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

-- One bounded include closure for graph queries, navigation and type lookup.
-- Paired implementations may supply definitions, never declarations/imports.
function M.visible_dependencies(G, f, ctx)
    local cache = ctx and ctx.include_dependencies
    if not cache and ctx then cache = {}; ctx.include_dependencies = cache end
    local old = cache and cache[f]
    if old then return old[1], old[2], old[3] end
    local direct, paired = resolve_deps(G, f, ctx)
    local incomplete = false
    if C_FAMILY[G.files[f].language] then
        local visible, queue = {}, {}
        local function add(files)
            local ordered = {}
            for g in pairs(files) do ordered[#ordered + 1] = g end
            table.sort(ordered, function(a, b) return G.files[a].path < G.files[b].path end)
            for _, g in ipairs(ordered) do
                if g ~= f and not visible[g] then
                    if #queue >= M.MAX_INCLUDES then incomplete = true
                    else visible[g] = true; queue[#queue + 1] = g end
                end
            end
        end
        add(direct)
        local i = 1
        while i <= #queue do
            control.check()
            local more, sources = resolve_deps(G, queue[i], ctx)
            for g in pairs(sources) do if g ~= f then paired[g] = true end end
            add(more); i = i + 1
        end
        direct = visible
    end
    if cache then cache[f] = { direct, paired, incomplete } end
    if incomplete and ctx then ctx.include_incomplete = true end
    return direct, paired, incomplete
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
    if c.static then
        -- `static inline` helpers in an included header serve every includer.
        if deps[cf] and HEADER_EXT[G.files[cf].path:match('%.(%w+)$') or ''] then return 50 end
        return nil
    end
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
    elseif ref_kind == 'call' and (G.files[f].language == 'java' or G.files[f].language == 'kotlin') and src_id then
        -- unqualified call inside a class: implicit this
        if owner and c.parent and G.id_of[cf][c.parent] == owner then s = s + 30 end
    end
    return s
end

local function is_decl(node) return node.kind == 'prototype' or node.decl end

-- Scored candidates of the current resolve_ref call, reused across calls to
-- keep the hot loop allocation-free; only the first n entries are live.
local scored_ids, scored_vals = {}, {}

-- accept overrides the node kinds the ref kind may bind to (navigation only).
local function resolve_ref(G, f, src_id, name, kind, recv, deps, paired, accept, evidence, js_context)
    if kind == 'annotation' then return nil end
    if evidence and evidence:sub(1, 7) == 'cs:new:' then kind = 'new' end
    accept = accept or (kind == 'new' and NEWABLE) or (kind == 'ref' and VALUE) or CALLABLE
    if evidence == '' then evidence = nil end
    local strategy = 'js/ts binding'
    local exact, binding_reason = js_resolution.resolve(G, f, name, kind, recv, evidence, js_context)
    if exact == nil and G.files[f].language == 'python' then
        strategy = 'python binding'
        exact = require('codeoutline.python_bindings').resolve(G, f, evidence, js_context)
    end
    if exact == nil and G.files[f].language == 'cpp' then
        strategy = evidence and evidence:match('^cpp:name:') and 'c++ namespace/import' or 'c++ declared receiver'
        exact = require('codeoutline.cpp_bindings').resolve(G, f, src_id, name, evidence, deps, js_context, accept)
    end
    if exact == nil and G.files[f].language == 'csharp' then
        strategy = 'c# binding'
        exact = require('codeoutline.csharp_bindings').resolve(G, f, src_id, name, kind, recv, evidence, js_context)
    end
    if exact == nil and (G.files[f].language == 'java' or G.files[f].language == 'kotlin') then
        strategy = 'declared JVM receiver'
        exact = require('codeoutline.implementations').resolve(G, f, src_id, name, evidence, js_context)
    end
    if exact == nil then
        strategy = 'lua binding'
        exact = lua_bindings.resolve(G, f, name, evidence, js_context and js_context.lua, recv)
    end
    if exact ~= nil then
        local result = {}
        for _, id in ipairs(exact) do if accept[G.nodes[id].kind] then result[#result + 1] = id end end
        return result, #result == 0 and (binding_reason or 'binding target unresolved') or strategy
    end
    local cands = G.by_name[name]
    if G.files[f].language == 'kotlin' and not recv then
        for _, imp in ipairs(G.files[f].imports) do
            if (imp.alias or imp.path:match('([^.]+)$')) == name then
                cands = {}
                -- by_name also includes unsaved LSP overlays; by_qualified is
                -- a resident index and may still name the masked disk nodes.
                for _, id in ipairs(G.by_name[imp.path:match('([^.]+)$')] or {}) do
                    if G.nodes[id].qualified == imp.path then cands[#cands + 1] = id end
                end
                break
            end
        end
    end
    if not cands then return nil, 'no indexed target' end
    -- Score first: score() rejects other languages and statics of other
    -- files, so "is there a real definition?" is only asked among the
    -- candidates this call could actually reach. (Asking it over all
    -- same-named nodes let a Python `def work` hide the C prototype of
    -- `work`, after which the Python def was filtered out too.)
    local self_call = kind == 'member_call' and src_id and (recv == 'self' or recv == 'this' or recv == 'cls')
    local owner = (self_call or (kind == 'call' and src_id and (G.files[f].language == 'java' or G.files[f].language == 'kotlin')))
        and owner_class(G, src_id) or nil
    -- score() rejects an unknown-receiver member call to an unrelated file;
    -- checking placement first skips most candidates of common method names.
    local local_only = kind == 'member_call' and not self_call
    local n, has_def, has_name = 0, false, false
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
                if node.name == name then has_name = true end
            end
        end
    end
    -- Prefer real names over export aliases (which may be platform stubs),
    -- then definitions over prototypes / in-class declarations.
    local best, ties, tie_count = nil, {}, 0
    for i = 1, n do
        local cid, s = scored_ids[i], scored_vals[i]
        if not (has_def and is_decl(G.nodes[cid])) and (not has_name or G.nodes[cid].name == name) then
            if not best or s > best then
                best, ties, tie_count = s, { cid }, 1
            elseif s == best then
                tie_count = tie_count + 1
                if #ties < M.MAX_TIES then ties[#ties + 1] = cid end
            end
        end
    end
    -- A lone candidate far away (score 0) is still a match for a unique
    -- name; many far candidates with nothing to separate them is a guess.
    if best and best <= 0 and #ties > 1 then
        return nil, 'ambiguous name candidates' .. (#cands > M.MAX_CANDIDATES and '; candidate scan limit reached' or '')
    end
    local reason = #ties == 0 and 'no eligible target' or #ties > 1 and 'multiple name/locality candidates' or 'name/locality match'
    if #cands > M.MAX_CANDIDATES then reason = reason .. '; candidate scan limit reached' end
    if tie_count > M.MAX_TIES then reason = reason .. '; tied candidate limit reached' end
    return ties, reason
end

-- Files compare by path; nodes by file path, then node order (ids ascend
-- within a file). Both are strict total orders over live entries.
local function file_before(G, a, b) return G.files[a].path < G.files[b].path end
local function node_before(G, a, b)
    local fa, fb = G.node_file[a], G.node_file[b]
    if fa == fb then return a < b end
    return G.files[fa].path < G.files[fb].path
end
local function string_before(_, a, b) return a < b end
M.before = node_before

-- Position of v (or where it belongs) in an ordered list.
local function search(G, list, v, before)
    local lo, hi = 1, #list + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if before(G, list[mid], v) then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- Ordered insert; a build in path order appends after one comparison.
local function insert(G, t, key, v, before)
    local list = t[key]
    if not list then t[key] = { v }; return end
    local n = #list
    if before(G, list[n], v) then list[n + 1] = v; return end
    table.insert(list, search(G, list, v, before), v)
end

local function remove(G, t, key, v, before)
    local list = t[key]
    if not list then return end
    local i = search(G, list, v, before)
    if list[i] ~= v then return end
    table.remove(list, i)
    if #list == 0 then t[key] = nil end
end

function M.new()
    return { files = {}, file_index = {}, file_order = {}, file_dir = {}, dir_ids = {}, nodes = {}, node_file = {},
        id_of = {}, by_name = {}, by_lname = {}, by_qualified = {}, by_owner = {}, by_base = {}, by_stem = {}, pkg_files = {},
        lua_global_export_tables = { 'g_exports' },
        children = {}, dir_files = {}, dir_by_base = {}, ns_files = {},
        next_file = 0, next_node = 0, next_dir = 0, file_count = 0, node_count = 0 }
end

local function namespaces(rec)
    local seen = {}
    if rec.language == 'csharp' then
        for _, node in ipairs(rec.nodes) do
            if node.kind == 'namespace' then seen[node.qualified] = true end
        end
    end
    return seen
end

-- Qualifier of a qualified name: `Box` for `Box::area`, `M` for `M:split` or `M.trim`.
-- by_owner lists members wherever they are defined (out-of-line, other files).
function M.owner(qualified)
    return qualified:match('^(.+)::[^:]+$') or qualified:match('^(.+)[%.:][^%.:]+$')
end

-- Add a record under rel. No cancellation checkpoints: index commits call
-- this and must not stop halfway.
function M.add_file(G, rel, rec)
    assert(not G.file_index[rel], 'file already in symbol tables: ' .. rel)
    local f = G.next_file + 1
    G.next_file = f
    G.files[f], G.file_index[rel] = rec, f
    G.file_order[#G.file_order + 1] = f
    local order = G.file_order
    if #order > 1 and not file_before(G, order[#order - 1], f) then
        table.remove(order)
        table.insert(order, search(G, order, f, file_before), f)
    end
    local dir = dirname(rel)
    local did = G.dir_ids[dir]
    if not did then G.next_dir = G.next_dir + 1; did = G.next_dir; G.dir_ids[dir] = did end
    G.file_dir[f] = did
    insert(G, G.by_base, basename(rel), f, file_before)
    insert(G, G.by_stem, stem(rel), f, file_before)
    if not G.dir_files[dir] then insert(G, G.dir_by_base, basename(dir), dir, string_before) end
    insert(G, G.dir_files, dir, f, file_before)
    if rec.package then insert(G, G.pkg_files, rec.package, f, file_before) end
    for qualified in pairs(namespaces(rec)) do insert(G, G.ns_files, qualified, f, file_before) end
    local ids = {}
    G.id_of[f] = ids
    for n, node in ipairs(rec.nodes) do
        local id = G.next_node + 1
        G.next_node = id
        G.nodes[id], G.node_file[id] = node, f
        ids[n] = id
        insert(G, G.by_name, node.name, id, node_before)
        for _, alias in ipairs(lua_bindings.aliases(node, G.lua_global_export_tables)) do insert(G, G.by_name, alias, id, node_before) end
        insert(G, G.by_lname, node.name:lower(), id, node_before)
        insert(G, G.by_qualified, node.qualified, id, node_before)
        local owner = M.owner(node.qualified)
        if owner then insert(G, G.by_owner, owner, id, node_before) end
        if node.parent then push(G.children, ids[node.parent], id) end
    end
    G.file_count, G.node_count = G.file_count + 1, G.node_count + #rec.nodes
    return f
end

function M.remove_file(G, rel)
    local f = G.file_index[rel]
    if not f then return end
    local rec, ids = G.files[f], G.id_of[f]
    for _, id in ipairs(ids) do
        local node = G.nodes[id]
        remove(G, G.by_name, node.name, id, node_before)
        for _, alias in ipairs(lua_bindings.aliases(node, G.lua_global_export_tables)) do remove(G, G.by_name, alias, id, node_before) end
        remove(G, G.by_lname, node.name:lower(), id, node_before)
        remove(G, G.by_qualified, node.qualified, id, node_before)
        local owner = M.owner(node.qualified)
        if owner then remove(G, G.by_owner, owner, id, node_before) end
        G.children[id] = nil
    end
    for _, id in ipairs(ids) do G.nodes[id], G.node_file[id] = nil, nil end
    local dir = dirname(rel)
    remove(G, G.by_base, basename(rel), f, file_before)
    remove(G, G.by_stem, stem(rel), f, file_before)
    remove(G, G.dir_files, dir, f, file_before)
    if not G.dir_files[dir] then remove(G, G.dir_by_base, basename(dir), dir, string_before) end
    if rec.package then remove(G, G.pkg_files, rec.package, f, file_before) end
    for qualified in pairs(namespaces(rec)) do remove(G, G.ns_files, qualified, f, file_before) end
    local order = G.file_order
    table.remove(order, search(G, order, f, file_before))
    G.files[f], G.file_index[rel], G.id_of[f], G.file_dir[f] = nil, nil, nil, nil
    G.file_count, G.node_count = G.file_count - 1, G.node_count - #ids
end

-- Symbol tables for every record of idx. Checkpoints per file: a cancelled
-- build is simply discarded.
function M.build(idx, lua_context)
    local G = M.new()
    G.root = idx.root
    G.lua_global_export_tables = (lua_context or lua_bindings.context(G)).global_export_tables
    local paths = {}
    for rel in pairs(idx.files) do paths[#paths + 1] = rel end
    table.sort(paths)
    for _, rel in ipairs(paths) do
        control.check()
        M.add_file(G, rel, idx.files[rel])
    end
    G.generation = idx.generation
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
    local js_context = js_resolution.context(symbols)
    js_context.lua = lua_bindings.context(symbols)
    js_context.ordinary = require('codeoutline.ordinary_bindings').context(symbols, js_context)
    Q.stats.ordinary = js_context.ordinary.stats
    Q.stats.workspace = js_context.workspace_stats
    local report = opts.explain and require('codeoutline.query_report').new() or nil
    Q.report = report
    local indirect = require('codeoutline.indirect').query(symbols, opts.dispatch_rules, report)
    local static_dispatch = require('codeoutline.static_dispatch').query(symbols, report)
    local implementations = require('codeoutline.implementations').context(symbols, js_context, report)
    Q.stats.implementations = implementations.stats
    local function deps(f)
        local entry = dependencies[f]
        if not entry then
            local direct, paired, incomplete = M.visible_dependencies(symbols, f, js_context)
            if incomplete then Q.incomplete = true end
            entry = { direct, paired }; dependencies[f] = entry
        end
        return entry[1], entry[2]
    end
    local function targets(f, i, explain)
        if static_dispatch.handles(f, i) then return {} end
        local rec, ids = symbols.files[f], symbols.id_of[f]
        local refs = rec.refs
        local direct, paired = deps(f)
        Q.stats.resolved_refs = Q.stats.resolved_refs + 1
        local found, reason = resolve_ref(symbols, f, ids[refs.from[i]], refs.name[i], refs.kind[i],
            refs.recv[i] or nil, direct, paired, nil, js_context.ordinary.evidence(f, i), js_context)
        if js_context.workspace_incomplete then Q.incomplete = true end
        if report and explain and (refs.kind[i] == 'call' or refs.kind[i] == 'member_call') then
            if (not found or #found == 0) and explain == true then
                report:add({ source = ids[refs.from[i]], line = refs.line[i], call = refs.name[i], reason = reason or 'unresolved reference' })
            else
                for _, dst in ipairs(found or {}) do
                    if explain == true or explain[dst] then
                        report:add({ source = ids[refs.from[i]], target = dst, line = refs.line[i], kind = reason })
                    end
                end
            end
        end
        return found
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
        for _, dst in ipairs(implementations.outgoing(id)) do
            edges[#edges + 1] = dst
            edges[#edges + 1] = symbols.nodes[id].line
            edges[#edges + 1] = 'implementation'
        end
        if implementations.incomplete then Q.incomplete = true end
        for _, edge in ipairs(indirect.outgoing(id)) do
            edges[#edges + 1] = edge.target
            edges[#edges + 1] = edge.line
            edges[#edges + 1] = edge.kind
        end
        for _, edge in ipairs(static_dispatch.outgoing(id)) do
            edges[#edges + 1] = edge.target
            edges[#edges + 1] = edge.line
            edges[#edges + 1] = edge.kind
        end
        for _, i in ipairs(grouped[id] or {}) do
            control.check()
            for _, dst in ipairs(targets(f, i, true) or {}) do
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
                for _, alias in ipairs(lua_bindings.aliases(symbols.nodes[id], symbols.lua_global_export_tables)) do names[alias] = true end
            end
        end
        if not found then return end
        local incoming = {}
        for id in pairs(wanted) do
            incoming[id] = {}
            for _, source in ipairs(implementations.incoming(id)) do
                push3(incoming, id, source, symbols.nodes[source].line, 'implementation')
            end
        end
        if implementations.incomplete then Q.incomplete = true end
        local indirect_incoming = indirect.incoming(wanted)
        for src, edges in pairs(static_dispatch.incoming(wanted)) do
            for _, edge in ipairs(edges) do push3(incoming, edge.target, src, edge.line, edge.kind) end
        end
        for _, f in ipairs(symbols.file_order) do
            for _, src in ipairs(symbols.id_of[f]) do
                for _, edge in ipairs(indirect_incoming[src] or {}) do
                    if wanted[edge.target] then push3(incoming, edge.target, src, edge.line, edge.kind) end
                end
            end
        end
        self.stats.incoming_scans = self.stats.incoming_scans + 1
        -- Hot loop over every reference: numeric loops, hoisted fields, and the
        -- selective name test first. Checkpoints run per file and per chunk.
        local files = symbols.files
        local candidates = js_context.ordinary.candidates(wanted)
        if js_context.workspace_incomplete then Q.incomplete = true end
        for _, f in ipairs(symbols.file_order) do
            control.check()
            local alias_refs = js_context.ordinary.aliases(f, wanted, candidates)
            local aliases = {}
            if files[f].language == 'kotlin' then
                for _, imp in ipairs(files[f].imports) do
                    if imp.alias and names[imp.path:match('([^.]+)$')] then aliases[imp.alias] = true end
                end
            end
            local refs = files[f].refs
            local ref_names, froms = refs.name, refs.from
            local count = #ref_names
            for first = 1, count, 4096 do
                if first > 1 then control.check() end
                for i = first, math.min(count, first + 4095) do
                    if (names[ref_names[i]] or aliases[ref_names[i]] or aliases[refs.recv[i]]
                        or alias_refs[i]
                        or (refs.lua_binding and refs.lua_binding[i] ~= '')) and froms[i] > 0 then
                        for _, dst in ipairs(targets(f, i, wanted) or {}) do
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

-- Navigation reuses the resolver over symbol tables or overlays of them.
M.CALLABLE = CALLABLE
M.dependencies = resolve_deps
M.resolve = resolve_ref
M.placement = locality
M.is_decl = is_decl
M.family = family

-- Location string for a node: "path:line".
function M.where(G, id)
    return G.files[G.node_file[id]].path .. ':' .. G.nodes[id].line
end

return M
