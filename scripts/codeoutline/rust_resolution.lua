-- Rust crate/module evidence is produced only for queries, never serialized.
local M = { MAX_DEPTH = 16, MAX_RESULTS = 128, MAX_ALIAS_FILES = 64, MAX_NODES = 8192 }
local cargo, control = require('codeoutline.rust_packages'), require('codeoutline.control')
local function join(a, b) return a == '' and b or b == '' and a or a .. '::' .. b end
local function text(T, i) return i >= 1 and i <= T.n and T:text(i) or '' end

-- Keep complete impl targets in query evidence; compact declaration names omit
-- module prefixes and generic arguments and cannot identify an impl's type.
local function impl_header(T, node)
    local i = node.ti
    while i < node.tj and text(T, i) ~= 'impl' do i = i + 1 end
    i = i + 1
    local function angle_end(at)
        local depth = 0
        for j = at, node.tj do
            local token = text(T, j)
            if token == '<' then depth = depth + 1
            elseif token == '>' then depth = depth - 1
            elseif token == '>>' then depth = depth - 2 end
            if depth <= 0 then return j + 1 end
        end
        return node.tj
    end
    local generics, constrained = {}, false
    if text(T, i) == '<' then
        local finish = angle_end(i)
        for j = i + 1, finish - 2 do
            if T.k[j] == 'id' and (text(T, j - 1) == '<' or text(T, j - 1) == ',') then generics[text(T, j)] = true
            elseif text(T, j) ~= ',' then constrained = true end
        end
        i = finish
    end
    local first, trait, depth, last = i, nil, 0, i - 1
    for j = i, node.tj do
        local token = text(T, j)
        if depth == 0 and (token == 'where' or token == '{') then
            if token == 'where' then constrained = true end
            break
        end
        if token == 'for' and depth == 0 then
            local parts = {}; for k = first, j - 1 do parts[#parts + 1] = text(T, k) end
            trait, first = table.concat(parts), j + 1
        end
        if token == '<' then depth = depth + 1
        elseif token == '>' then depth = depth - 1
        elseif token == '>>' then depth = depth - 2 end
        last = j
    end
    local path, args, target = {}, {}, {}
    local j = first
    while j <= last do
        local token = text(T, j); target[#target + 1] = token
        if token == '<' then
            local finish = angle_end(j)
            for k = j, finish - 1 do args[#args + 1] = text(T, k) end
            j = finish
        elseif T.k[j] == 'id' or T.k[j] == 'kw' or token == '::' then
            path[#path + 1] = token; j = j + 1
        else return { target = table.concat(target), trait = trait } end
    end
    return { path = table.concat(path), args = table.concat(args), trait = trait, generics = generics, constrained = constrained }
end

local function compatible_args(candidate, current)
    if candidate.args == current.args then
        if candidate.constrained and candidate ~= current then return nil end
        return true
    end
    if not candidate.args or not current.args then return false end
    local pattern = candidate.args:match('^<([%w_,]+)>$')
    if not pattern then return false end
    local args, first, depth = {}, 2, 0
    for i = 2, #current.args do
        local c = current.args:sub(i, i)
        if c == ',' and depth == 0 or i == #current.args then args[#args + 1] = current.args:sub(first, i - 1); first = i + 1
        elseif c == '<' or c == '(' or c == '[' then depth = depth + 1
        elseif c == '>' or c == ')' or c == ']' then depth = depth - 1 end
    end
    local at, bindings = 0, {}
    for name in pattern:gmatch('[^,]+') do
        at = at + 1
        if not args[at] then return false end
        if candidate.generics[name] then
            if bindings[name] and bindings[name] ~= args[at] then return false end
            bindings[name] = args[at]
        elseif name ~= args[at] then return false end
    end
    if at ~= #args then return false end
    if candidate.constrained then return nil end
    return true
end

function M.collect(r, T)
    r.rust_imports, r.rust_public, r.rust_impls, r.rust_instance, r.has_bindings = {}, {}, {}, {}, true
    for n, node in ipairs(r.nodes) do
        r.rust_public[n] = text(T, node.ti) == 'pub' and text(T, node.ti + 1) ~= '('
        if node.kind == 'impl' then r.rust_impls[n] = impl_header(T, node) end
        if node.kind == 'method' then
            local p = node.ti
            while p < node.tj and text(T, p) ~= '(' do p = p + 1 end
            for i = p + 1, (T.m[p] or p) - 1 do
                if text(T, i) == ',' then break end
                if text(T, i) == 'self' then r.rust_instance[n] = true; break end
            end
        end
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

local function type_id(G, f, path, scope, ctx, kind)
    if not path or path == '' then return nil end
    if cargo.owner(G, f, ctx) then
        local found = M.path(G, f, path, ctx, scope)
        local id
        for _, candidate in ipairs(found and found.ids or {}) do
            local node = G.nodes[candidate]
            if kind and node.kind == kind or not kind and (node.kind == 'struct' or node.kind == 'enum') then
                if id then return nil end
                id = candidate
            end
        end
        return id
    end
    -- Standalone files have no Cargo module graph. Stay inside their lexical
    -- namespaces instead of matching a same-named type in another file.
    if path:match('^crate::') then path, scope = path:sub(8), ''
    elseif path:match('^self::') then path = path:sub(7)
    else
        while path:match('^super::') do
            path, scope = path:sub(8), scope:match('^(.*)::[^:]+$') or ''
        end
    end
    local wanted, found = join(scope, path), nil
    for n, node in ipairs(nodes(G, f, ctx)) do
        if node.qualified == wanted and (kind and node.kind == kind
            or not kind and (node.kind == 'struct' or node.kind == 'enum')) then
            if found then return nil end
            found = G.id_of[f][n]
        end
    end
    return found
end

local function self_targets(G, f, src, member, ctx)
    local parent = src and G.nodes[src] and G.nodes[src].parent
    local rec = G.files[f]
    while parent do
        local owner = rec.nodes[parent]
        if owner.kind == 'impl' or owner.kind == 'interface' then
            local own = {}
            for n, candidate in ipairs(nodes(G, f, ctx)) do
                if candidate.parent == parent and candidate.name == member
                    and (candidate.kind == 'method' or candidate.kind == 'constant') then own[#own + 1] = G.id_of[f][n] end
            end
            if owner.kind == 'interface' then return own, 'Rust trait Self binding' end
            local header = (data(G, f, ctx).rust_impls or {})[parent]
            local scope = scope_of(G, f, src)
            local target = header and type_id(G, f, header.path, scope, ctx)
            if target then
                local inherent, files, count, candidates, truncated, constrained = {}, {}, 0, 0, false, false
                for i, id in ipairs(G.by_name[member] or {}) do
                    if i > M.MAX_NODES then ctx.rust_incomplete, truncated = true, true; break end
                    control.check()
                    local mf, method = G.node_file[id], G.nodes[id]
                    local impl = method.parent and G.files[mf].nodes[method.parent]
                    local plausible = impl and (impl.name == owner.name or impl.name == G.nodes[target].name)
                    if impl and not plausible then
                        for _, imp in ipairs(G.files[mf].imports or {}) do
                            for _, alias in ipairs(imp.type_aliases or {}) do
                                if alias.alias == impl.name and alias.name == G.nodes[target].name then plausible = true end
                            end
                        end
                    end
                    -- Names only narrow discovery; query-only target paths and
                    -- generic arguments below establish the actual type identity.
                    if impl and impl.kind == 'impl' and not impl.trait
                        and plausible
                        and (method.kind == 'method' or method.kind == 'constant')
                        and (mf == f or cargo.owner(G, mf, ctx) == cargo.owner(G, f, ctx) and cargo.owner(G, f, ctx)) then
                        candidates = candidates + 1
                        if candidates > M.MAX_RESULTS then ctx.rust_incomplete, truncated = true, true; break end
                        if not files[mf] then files[mf] = true; count = count + 1 end
                        if count > M.MAX_ALIAS_FILES then ctx.rust_incomplete, truncated = true, true; break end
                        local other = (data(G, mf, ctx).rust_impls or {})[method.parent]
                        if other and type_id(G, mf, other.path, parent_scope(G, mf, impl.parent), ctx) == target then
                            local compatible = compatible_args(other, header)
                            if compatible then inherent[#inherent + 1] = id
                            elseif compatible == nil then constrained = true end
                        end
                    end
                end
                if #inherent > 0 then return inherent, 'Rust inherent Self binding' end
                if truncated then return {}, 'Rust Self candidate scan limit reached' end
                if constrained then return {}, 'Rust Self generic constraints are not proven' end
            end
            if #own > 0 then return own, 'Rust lexical impl binding' end
            local trait = header and header.trait and type_id(G, f, header.trait:gsub('%b<>', ''), scope, ctx, 'interface')
            if trait then
                local tf, index = G.node_file[trait], trait - G.id_of[G.node_file[trait]][1] + 1
                local result = {}
                for n, candidate in ipairs(nodes(G, tf, ctx)) do
                    if candidate.parent == index and candidate.name == member
                        and (candidate.kind == 'method' or candidate.kind == 'constant') then result[#result + 1] = G.id_of[tf][n] end
                end
                return result, 'Rust trait default Self binding'
            end
            return {}, 'Self member is not declared in a resolved impl or trait'
        end
        parent = owner.parent
    end
    return {}, 'Self has no enclosing impl or trait'
end

function M.resolve(G, f, src, name, recv, evidence, ctx)
    if evidence == 'rust:member' then return nil end
    local path = evidence and evidence:match('^rust:path:(.*)$') or (recv and recv .. '::' .. name or name)
    if path:match('^Self::') then
        local member = path:match('^Self::([%w_]+)$')
        if not member then return {}, 'unsupported Self path' end
        local key = tostring(src) .. '\0' .. member
        local cache = ctx.rust_self_cache or {}; ctx.rust_self_cache = cache
        if cache[key] then return cache[key][1], cache[key][2] end
        local ids, reason = self_targets(G, f, src, member, ctx)
        if (ctx.rust_self_count or 0) < M.MAX_RESULTS then
            cache[key] = { ids, reason }; ctx.rust_self_count = (ctx.rust_self_count or 0) + 1
        end
        return ids, reason
    end
    if not cargo.owner(G, f, ctx) then return ctx.rust_incomplete and {} or nil, ctx.rust_error end
    local found, reason = M.path(G, f, path, ctx, scope_of(G, f, src))
    return found and found.ids or {}, reason or 'Cargo crate/module target is not indexed or visible'
end

function M.self_members(G, f, src, ctx, expired)
    local parent = src and G.nodes[src] and G.nodes[src].parent
    while parent do
        local owner = G.files[f].nodes[parent]
        if owner.kind == 'impl' or owner.kind == 'interface' then
            local names, result, count = {}, {}, 0
            local function collect(file, index)
                for _, candidate in ipairs(nodes(G, file, ctx)) do
                    if candidate.parent == index and (candidate.kind == 'method' or candidate.kind == 'constant') then
                        names[candidate.name] = true
                    end
                end
            end
            collect(f, parent)
            local function owned(name)
                for i, id in ipairs(G.by_owner[name] or {}) do
                    if i > M.MAX_NODES then ctx.rust_incomplete = true; break end
                    names[G.nodes[id].name] = true
                end
            end
            owned(owner.name)
            local header = owner.kind == 'impl' and (data(G, f, ctx).rust_impls or {})[parent]
            local target = header and type_id(G, f, header.path, scope_of(G, f, src), ctx)
            if target then owned(G.nodes[target].name) end
            local trait = header and header.trait and type_id(G, f, header.trait:gsub('%b<>', ''), scope_of(G, f, src), ctx, 'interface')
            if trait then collect(G.node_file[trait], trait - G.id_of[G.node_file[trait]][1] + 1) end
            local ordered = {}; for name in pairs(names) do ordered[#ordered + 1] = name end; table.sort(ordered)
            for _, name in ipairs(ordered) do
                if expired and expired() then ctx.rust_incomplete = true; break end
                count = count + 1
                if count > M.MAX_RESULTS then ctx.rust_incomplete = true; break end
                for _, id in ipairs(M.resolve(G, f, src, name, 'Self', 'rust:path:Self::' .. name, ctx)) do
                    result[#result + 1] = { name = name, node = G.nodes[id], file = G.node_file[id], kind = G.nodes[id].kind, id = id }
                end
            end
            return result
        end
        parent = owner.parent
    end
    return {}
end

local function receiver_fields(G, f, src, ctx)
    local parent = src and G.nodes[src] and G.nodes[src].parent
    while parent do
        local owner = G.files[f].nodes[parent]
        if owner.kind == 'impl' then
            local header = (data(G, f, ctx).rust_impls or {})[parent]
            local target = header and type_id(G, f, header.path, scope_of(G, f, src), ctx)
            local result = {}
            if target then
                local tf = G.node_file[target]
                for n, node in ipairs(nodes(G, tf, ctx)) do
                    if node.kind == 'field' and node.parent and G.id_of[tf][node.parent] == target then
                        result[#result + 1] = G.id_of[tf][n]
                    end
                end
            end
            return result
        end
        parent = owner.parent
    end
    return {}
end

function M.receiver_targets(G, f, src, name, instance, ctx, accept)
    if instance and (not src or not (data(G, f, ctx).rust_instance or {})[src - G.id_of[f][1] + 1]) then return {} end
    local ids = M.resolve(G, f, src, name, 'Self', 'rust:path:Self::' .. name, ctx)
    if not instance then return ids end
    local result = {}
    for _, id in ipairs(ids) do
        local tf = G.node_file[id]
        local index = id - G.id_of[tf][1] + 1
        if (data(G, tf, ctx).rust_instance or {})[index] then result[#result + 1] = id end
    end
    if not accept or accept.field then
        for _, id in ipairs(receiver_fields(G, f, src, ctx)) do if G.nodes[id].name == name then result[#result + 1] = id end end
    end
    return result
end

function M.receiver_members(G, f, src, instance, ctx, expired)
    if instance and (not src or not (data(G, f, ctx).rust_instance or {})[src - G.id_of[f][1] + 1]) then return {} end
    local result = M.self_members(G, f, src, ctx, expired)
    if not instance then return result end
    local filtered = {}
    for _, entry in ipairs(result) do
        local index = entry.id - G.id_of[entry.file][1] + 1
        if (data(G, entry.file, ctx).rust_instance or {})[index] then filtered[#filtered + 1] = entry end
    end
    for _, id in ipairs(receiver_fields(G, f, src, ctx)) do
        filtered[#filtered + 1] = { name = G.nodes[id].name, node = G.nodes[id], kind = 'field', file = G.node_file[id] }
    end
    return filtered
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
