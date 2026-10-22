-- Rust crate/module evidence is produced only for queries, never serialized.
local M = { MAX_DEPTH = 16, MAX_RESULTS = 128, MAX_ALIAS_FILES = 64, MAX_NODES = 8192 }
local cargo, control = require('codeoutline.rust_packages'), require('codeoutline.control')
local function join(a, b) return a == '' and b or b == '' and a or a .. '::' .. b end
local function text(T, i) return i >= 1 and i <= T.n and T:text(i) or '' end

function M.collect(r, T)
    r.rust_imports, r.rust_public, r.has_bindings = {}, {}, true
    for n, node in ipairs(r.nodes) do
        r.rust_public[n] = text(T, node.ti) == 'pub' and text(T, node.ti + 1) ~= '('
    end
    for i = 1, T.n do
        if text(T, i) == 'use' then
            local parent, in_function, last, j = nil, false, i + 1, i + 1
            for n, node in ipairs(r.nodes) do
                if node.ti <= i and i <= node.tj then
                    if node.kind == 'namespace' then parent = n
                    elseif node.kind == 'function' or node.kind == 'method' then in_function = true end
                end
            end
            while j <= T.n and text(T, j) ~= ';' do
                if T.m[j] and T.m[j] > j then j = T.m[j] end
                j = j + 1
            end
            last = j - 1
            local cursor, count = i + 1, 0
            if text(T, cursor) == '::' then cursor = cursor + 1 end
            local branch
            branch = function(prefix, depth)
                if depth > M.MAX_DEPTH then error('Rust use nesting limit reached', 0) end
                local path = prefix
                while cursor <= last do
                    local token = text(T, cursor)
                    if token == '{' then
                        cursor = cursor + 1
                        while cursor <= last and text(T, cursor) ~= '}' do
                            branch(path, depth + 1)
                            if text(T, cursor) == ',' then cursor = cursor + 1 else break end
                        end
                        if text(T, cursor) ~= '}' then error('unsupported Rust use group', 0) end
                        cursor = cursor + 1; return
                    end
                    if token == '' or token == ',' or token == '}' then break end
                    if token ~= 'self' or path == '' then path = join(path, token) end
                    cursor = cursor + 1
                    if text(T, cursor) == '::' then cursor = cursor + 1 else break end
                end
                local alias = path:match('([^:]+)$')
                if text(T, cursor) == 'as' then alias = text(T, cursor + 1); cursor = cursor + 2 end
                count = count + 1
                if count > M.MAX_RESULTS then error('Rust use binding limit reached', 0) end
                if not in_function then r.rust_imports[#r.rust_imports + 1] = { path = path, alias = alias,
                    parent = parent, public = text(T, i - 1) == 'pub', line = T:line(i) } end
            end
            branch('', 0)
        end
    end
    for _, ref in ipairs(r.refs) do
        local i, path = ref.tok, ref.name
        if text(T, i - 1) == '.' then ref.binding = 'rust:member'
        else
            while text(T, i - 1) == '::' and (T.k[i - 2] == 'id' or T.k[i - 2] == 'kw') do
                path, i = text(T, i - 2) .. '::' .. path, i - 2
            end
            ref.binding = 'rust:path:' .. path
        end
    end
end

local function data(G, f, ctx)
    local rec = G.files[f]
    if rec.rust_imports then return rec end
    return ctx.ordinary and cargo.guard(ctx, function() return ctx.ordinary.data(f) end) or rec
end
local function scope_of(G, f, src)
    local node = src and G.nodes[src]
    local p = node and node.parent
    while p do
        local owner = G.files[f].nodes[p]
        if owner.kind == 'namespace' then return owner.qualified end
        p = owner.parent
    end
    return ''
end
local function parent_scope(G, f, p) return p and G.files[f].nodes[p].qualified or '' end
local function nodes(G, f, ctx)
    local list = G.files[f].nodes
    if #list > M.MAX_NODES then
        ctx.rust_incomplete, ctx.rust_error = true, 'Rust module node limit reached'
        return {}
    end
    return list
end
local function child(G, entry, name, ctx)
    local wanted, found = join(entry.scope, name), nil
    local rec, detail = G.files[entry.file], data(G, entry.file, ctx)
    for n, node in ipairs(nodes(G, entry.file, ctx)) do
        if node.kind == 'namespace' and node.qualified == wanted then
            if entry.external and not (detail.rust_public or {})[n] then return nil end
            local external = false
            for _, imp in ipairs(rec.imports) do if imp.kind == 'mod' and imp.path == name then external = true; break end end
            if not external then return { file = entry.file, scope = wanted, external = entry.external, root = entry.root } end
            local path = rec.path
            local directory, stem = cargo.dir(path), path:match('([^/]+)%.rs$')
            if not entry.root and stem ~= 'lib' and stem ~= 'main' and stem ~= 'mod' then directory = cargo.join(directory, stem) end
            if entry.scope ~= '' then directory = cargo.join(directory, entry.scope:gsub('::', '/')) end
            for _, candidate in ipairs({ cargo.join(directory, name .. '.rs'), cargo.join(directory, name .. '/mod.rs') }) do
                local id = G.file_index[candidate]
                if id then
                    if found then return nil end
                    if cargo.owner(G, id, ctx) ~= cargo.owner(G, entry.file, ctx) then return nil end
                    found = { file = id, scope = '', external = entry.external }
                end
            end
            return found
        end
    end
end

local walk
local function terminal(G, entry, name, ctx, seen, depth)
    local result, rec, detail = {}, G.files[entry.file], data(G, entry.file, ctx)
    local wanted = join(entry.scope, name)
    for n, node in ipairs(nodes(G, entry.file, ctx)) do
        if node.qualified == wanted and node.kind ~= 'namespace'
            and (not entry.external or (detail.rust_public or {})[n]) then
            result[#result + 1] = G.id_of[entry.file][n]
        end
    end
    if #result > 0 then return { ids = result } end
    for _, imp in ipairs(detail.rust_imports or {}) do
        if imp.alias == name and parent_scope(G, entry.file, imp.parent) == entry.scope
            and (not entry.external or imp.public) then
            local found = walk(G, entry.file, imp.path, ctx, entry.scope, seen, depth + 1)
            if entry.external and found and found.ids then
                local visible = {}
                for _, id in ipairs(found.ids) do
                    local f = G.node_file[id]
                    for n, local_id in ipairs(G.id_of[f]) do
                        if local_id == id and (data(G, f, ctx).rust_public or {})[n] then visible[#visible + 1] = id end
                    end
                end
                found.ids = visible
            end
            return found
        end
    end
end
walk = function(G, f, path, ctx, scope, seen, depth)
    control.check()
    if depth > M.MAX_DEPTH then error('Rust module resolution depth limit reached', 0) end
    local key = G.files[f].path .. '\0' .. scope .. '\0' .. path
    if seen[key] then return nil end
    seen[key] = true
    local parts = {}; for name in path:gmatch('[^:]+') do parts[#parts + 1] = name end
    if #parts == 0 then return nil end
    local owner = cargo.owner(G, f, ctx)
    if not owner then return nil end
    local first, index, entry = parts[1], 2, nil
    if first == 'crate' then
        local id = cargo.entry(G, owner, ctx, f)
        if id then entry = { file = id, scope = '', root = true } end
    elseif first == 'self' then entry = { file = f, scope = scope, root = cargo.entry(G, owner, ctx, f) == f }
    elseif first == 'super' then
        if scope ~= '' then entry = { file = f, scope = scope:match('^(.*)::[^:]+$') or '', root = cargo.entry(G, owner, ctx, f) == f }
        else
            local root = cargo.entry(G, owner, ctx, f)
            if root and root ~= f then
                local directory = cargo.dir(G.files[f].path)
                if G.files[f].path:match('/mod%.rs$') then directory = cargo.dir(directory) end
                local candidates = directory == cargo.dir(G.files[root].path) and { G.files[root].path }
                    or { directory .. '.rs', cargo.join(directory, 'mod.rs') }
                for _, candidate in ipairs(candidates) do
                    local id = G.file_index[candidate]
                    if id and cargo.owner(G, id, ctx) == owner then
                        if entry then return nil end
                        entry = { file = id, scope = '', root = id == root }
                    end
                end
            end
        end
    else
        for _, imp in ipairs(data(G, f, ctx).rust_imports or {}) do
            if imp.alias == first and parent_scope(G, f, imp.parent) == scope then
                local replacement = imp.path
                if #parts > 1 then replacement = replacement .. '::' .. table.concat(parts, '::', 2) end
                if replacement ~= path then return walk(G, f, replacement, ctx, scope, seen, depth + 1) end
            end
        end
        local id = cargo.crates(G, f, ctx)[first]
        if id then entry = { file = id, scope = '', external = cargo.owner(G, id, ctx) ~= owner, root = true }
        else entry, index = { file = f, scope = scope }, 1 end
    end
    if not entry then return nil end
    if first == 'super' and parts[2] == 'super' then
        return walk(G, entry.file, table.concat(parts, '::', 2), ctx, entry.scope, seen, depth + 1)
    end
    while index <= #parts do
        local next_entry = child(G, entry, parts[index], ctx)
        if next_entry then entry = next_entry
        else
            local found = terminal(G, entry, parts[index], ctx, seen, depth)
            if index == #parts then return found end
            if found and found.module then
                found.module.external = entry.external; entry = found.module
            elseif found and found.ids and index + 1 == #parts then
                local ids = {}
                for _, type_id in ipairs(found.ids) do
                    local ty, tf = G.nodes[type_id], G.node_file[type_id]
                    for _, id in ipairs(G.by_name[parts[index + 1]] or {}) do
                        local method, mf = G.nodes[id], G.node_file[id]
                        if mf == tf and method.kind == 'method' and method.qualified == ty.qualified .. '::' .. parts[index + 1] then
                            for n, local_id in ipairs(G.id_of[mf]) do
                                if local_id == id and (not entry.external or (data(G, mf, ctx).rust_public or {})[n]) then ids[#ids + 1] = id end
                            end
                        end
                    end
                end
                return { ids = ids }
            else return nil end
        end
        index = index + 1
    end
    return { module = entry }
end

function M.path(G, f, path, ctx, scope)
    return cargo.guard(ctx, walk, G, f, path, ctx, scope or '', {}, 0)
end
function M.resolve(G, f, src, name, recv, evidence, ctx)
    if not cargo.owner(G, f, ctx) then return ctx.rust_incomplete and {} or nil, ctx.rust_error end
    if evidence == 'rust:member' then return nil end
    local path = evidence and evidence:match('^rust:path:(.*)$') or (recv and recv .. '::' .. name or name)
    local found, reason = M.path(G, f, path, ctx, scope_of(G, f, src))
    return found and found.ids or {}, reason or 'Cargo crate/module target is not indexed or visible'
end
function M.imports(G, f, imp, ctx)
    if not cargo.owner(G, f, ctx) then return ctx.rust_incomplete and {} or nil end
    local result, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; result[#result + 1] = id end end
    if imp.kind == 'mod' then
        local entry = child(G, { file = f, scope = '' }, imp.path, ctx)
        if entry then add(entry.file) end
    else
        for _, binding in ipairs(data(G, f, ctx).rust_imports or {}) do
            if binding.line == imp.line then
                local found = M.path(G, f, binding.path, ctx, parent_scope(G, f, binding.parent))
                if found then
                    if found.module then add(found.module.file) end
                    for _, id in ipairs(found.ids or {}) do add(G.node_file[id]) end
                end
            end
        end
    end
    return result
end
function M.members(G, entry, ctx)
    return cargo.guard(ctx, function()
        local result, names, detail = {}, {}, data(G, entry.file, ctx)
        for n, node in ipairs(nodes(G, entry.file, ctx)) do
            if node.kind ~= 'impl' and parent_scope(G, entry.file, node.parent) == entry.scope
                and (not entry.external or (detail.rust_public or {})[n]) then
                names[node.name] = true
                result[#result + 1] = { name = node.name, node = node, file = entry.file, kind = node.kind }
            end
        end
        for _, imp in ipairs(detail.rust_imports or {}) do
            if imp.public and imp.alias ~= '*' and not names[imp.alias]
                and parent_scope(G, entry.file, imp.parent) == entry.scope then
                local found = M.path(G, entry.file, imp.path, ctx, entry.scope)
                for _, id in ipairs(found and found.ids or {}) do
                    result[#result + 1] = { name = imp.alias, node = G.nodes[id], file = G.node_file[id], kind = G.nodes[id].kind }
                end
            end
        end
        if #result > M.MAX_RESULTS then error('Rust module member limit reached', 0) end
        return result
    end) or {}
end

function M.alias_refs(G, f, wanted, ctx)
    local rec = G.files[f]
    if rec.language ~= 'rust' or #rec.imports == 0 or not cargo.owner(G, f, ctx) then return {} end
    local relevant = false
    for id in pairs(wanted) do
        local target = cargo.owner(G, G.node_file[id], ctx)
        if cargo.reaches(G, f, target, ctx) then relevant = true end
    end
    if not relevant then return {} end
    ctx.rust_alias_files = ctx.rust_alias_files or {}
    if not ctx.rust_alias_files[f] then
        ctx.rust_alias_count = (ctx.rust_alias_count or 0) + 1
        if ctx.rust_alias_count > M.MAX_ALIAS_FILES then ctx.rust_incomplete = true; return {} end
        ctx.rust_alias_files[f] = true
    end
    local refs, result = data(G, f, ctx).refs, {}
    for i, binding in ipairs(refs.binding or {}) do if binding:match('^rust:path:') then result[i] = true end end
    return result
end
M.scope = scope_of
return M
