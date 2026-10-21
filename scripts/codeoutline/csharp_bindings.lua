-- C# using/receiver evidence shared by LSP and graph queries. No compiler execution.
local M = {}
local control = require('codeoutline.control')
local types = { class = true, struct = true, interface = true, record = true, enum = true }
local callable = { method = true, constructor = true, ['function'] = true, prototype = true }
local function clean(s) return s and s:gsub('^@', '') end

function M.name(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('%s+', ''):gsub('@([%a_][%w_]*)', '%1')
    local prefix, rest = text:match('^([%w_]+)::(.*)$')
    rest = rest or text
    local parts = {}
    for part in rest:gmatch('[^.]+') do
        if not part:match('^[%a_][%w_]*$') then return nil end
        parts[#parts + 1] = part
    end
    if #parts == 0 or table.concat(parts, '.') ~= rest then return nil end
    return (prefix and prefix .. '::' or '') .. rest
end

local function token_name(T, first, last)
    if first > last then return nil end
    return M.name(T.src:sub(T.s[first], T.e[last]))
end

function M.collect(r, T)
    r.csharp_usings = r.csharp_usings or {}
    r.csharp_scopes, r.csharp_statics, r.csharp_access, r.has_bindings = {}, {}, {}, true
    r.csharp_parameters = {}
    for index, n in ipairs(r.nodes) do
        if types[n.kind] or n.kind == 'namespace' then
            r.csharp_scopes[#r.csharp_scopes + 1] = { scope = n.qualified, first = T.s[n.ti] - 1, last = T.e[n.tj] }
        end
        local header = (n.sig or ''):match('^(.-)%(') or n.sig or ''
        if header:find('%f[%w]static%f[^%w]') then r.csharp_statics[index] = true end
        local access = header:match('%f[%w](public)%f[^%w]') or header:match('%f[%w](internal)%f[^%w]')
            or header:match('%f[%w](protected)%f[^%w]') or header:match('%f[%w](private)%f[^%w]')
        r.csharp_access[index] = access or (n.parent and r.nodes[n.parent].kind == 'interface' and 'public') or 'private'
        if types[n.kind] or callable[n.kind] then
            for i = n.ti, n.tj do
                local word = T:text(i)
                if word == '(' or word == '{' then break end
                if clean(word) == clean(n.name) and T:text(i + 1) == '<' then
                    local j, depth = i + 2, 1
                    while j <= n.tj and depth > 0 do
                        local s = T:text(j)
                        if depth == 1 and T.k[j] == 'id' and (T:text(j - 1) == '<' or T:text(j - 1) == ',') then
                            r.csharp_parameters[#r.csharp_parameters + 1] = { name = clean(s), first = T.s[n.ti] - 1, last = T.e[n.tj] }
                        end
                        if s == '<' then depth = depth + 1 elseif s == '>' then depth = depth - 1 elseif s == '>>' then depth = depth - 2 end
                        j = j + 1
                    end
                    break
                end
            end
        end
    end
    local wanted, scopes, stack = {}, {}, {}
    for _, ref in ipairs(r.refs) do if ref.recv then wanted[clean(ref.recv)] = true end end
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    local bindings = {}
    local endings = { [')'] = true, [','] = true, [';'] = true, ['='] = true, ['{'] = true }
    local forbidden = { ['return'] = true, ['new'] = true, ['throw'] = true, ['using'] = true, ['namespace'] = true }
    for i = 2, T.n do
        if i % 4096 == 0 then control.check() end
        local name, prev = clean(T:text(i)), T:text(i - 1)
        if T.k[i] == 'id' and wanted[name] and endings[T:text(i + 1)] and not forbidden[prev]
            and (T.k[i - 1] == 'id' or T.k[i - 1] == 'kw' or prev == '>' or prev == '>>' or prev == ']' or prev == '?') then
            local first = i - 1
            while (T:text(first - 1) == '.' or T:text(first - 1) == '::') and T.k[first - 2] == 'id' do first = first - 2 end
            local ty = token_name(T, first, i - 1)
            if ty == 'var' then
                ty = nil
                if T:text(i + 1) == '=' and T:text(i + 2) == 'new' then
                    local last = i + 3
                    while T:text(last + 1) == '.' or T:text(last + 1) == '::' do last = last + 2 end
                    if T:text(last + 1) == '(' then ty = token_name(T, i + 3, last) end
                end
            end
            local a = scopes[i]
            local b = a > 0 and T.m[a] or T.n
            for _, n in ipairs(r.nodes) do
                if callable[n.kind] and n.ti <= i and i <= n.tj and n.ti > a then a, b = n.ti, n.tj end
            end
            bindings[name] = bindings[name] or {}
            bindings[name][#bindings[name] + 1] = { type = ty or false, token = i, first = a, last = b }
        end
    end
    for _, ref in ipairs(r.refs) do
        local first = ref.tok
        while (T:text(first - 1) == '.' or T:text(first - 1) == '?.' or T:text(first - 1) == '::')
            and (T.k[first - 2] == 'id' or T.k[first - 2] == 'kw') do first = first - 2 end
        if T:text(first - 1) == 'new' then
            ref.binding = 'cs:new:' .. (token_name(T, first, ref.tok) or '?') .. '\0' .. (T.s[first] - 1)
        elseif ref.kind == 'member_call' then
            local root, best = clean(T:text(first))
            for _, b in ipairs(bindings[root] or {}) do
                if b.first <= ref.tok and ref.tok <= b.last and b.token <= ref.tok
                    and (not best or b.first > best.first or b.first == best.first and b.token > best.token) then best = b end
            end
            if best then
                ref.binding = best.type and first == ref.tok - 2 and 'cs:type:' .. best.type .. '\0' .. (T.s[best.token] - 1) or 'cs:?'
            elseif root == 'this' or root == 'base' then ref.binding = 'cs:self:' .. root .. '\0' .. (T.s[first] - 1)
            else ref.binding = 'cs:owner:' .. (token_name(T, first, ref.tok - 2) or '?') .. '\0' .. (T.s[first] - 1) end
        elseif ref.kind == 'call' then ref.binding = 'cs:call:\0' .. (T.s[ref.tok] - 1) end
    end
end

local function context(G, ctx)
    ctx = ctx or {}
    if ctx.csharp then return ctx.csharp end
    local C = {}
    ctx.csharp = C
    function C.data(f) return ctx.ordinary and ctx.ordinary.data(f) or G.files[f] end
    local directories, groups = {}, {}
    local function directory_group(dir)
        if directories[dir] ~= nil then return directories[dir] end
        local found
        if G.root then
            local entries, truncated = xutils.list_dir(G.root .. (dir ~= '' and '/' .. dir or ''), 8192, true)
            if truncated then directories[dir] = '!'; return '!' end
            for _, entry in ipairs(entries or {}) do
                if not entry.dir and entry.name:lower():match('%.csproj$') then
                    if found then directories[dir] = '!'; return '!' end
                    found = dir .. '/' .. entry.name
                end
            end
        end
        if not found and dir ~= '' then found = directory_group(dir:match('^(.*)/[^/]+$') or '') end
        directories[dir] = found or '@workspace'
        return directories[dir]
    end
    function C.group(f)
        if not groups[f] then
            local group = directory_group(G.files[f].path:match('^(.*)/[^/]+$') or '')
            groups[f] = group == '!' and '!file:' .. f or group
        end
        return groups[f]
    end
    function C.same(f, g) return C.group(f) == C.group(g) end
    local files = {}
    for _, f in ipairs(G.file_order) do files[#files + 1] = f end
    for _, f in ipairs(G.new_files or {}) do files[#files + 1] = f end
    local global_candidates, namespaces = {}, {}
    for _, f in ipairs(files) do
        local rec = G.files[f]
        if rec.language == 'csharp' then
            control.check()
            local group = C.group(f)
            namespaces[group] = namespaces[group] or {}
            for _, n in ipairs(rec.nodes) do
                if n.kind == 'namespace' then
                    local scope = n.qualified
                    while scope and scope ~= '' do
                        namespaces[group][scope] = true; scope = scope:match('^(.*)%.[^.]+$')
                    end
                end
            end
            local candidate = rec.ordinary_bindings
            for _, imp in ipairs(rec.imports) do if imp.global then candidate = true; break end end
            if candidate then
                global_candidates[group] = global_candidates[group] or {}
                global_candidates[group][#global_candidates[group] + 1] = f
            end
        end
    end
    function C.scope(f, at)
        local scope, first = '', -1
        for _, n in ipairs(C.data(f).csharp_scopes or {}) do
            if n.first <= at and at <= n.last and n.first > first then scope, first = n.scope, n.first end
        end
        return scope
    end
    function C.active(f, at, exclude, no_global)
        local out = {}
        for _, d in ipairs(C.data(f).csharp_usings or {}) do
            if not d.global and d.first <= at and at <= d.last and d.first ~= exclude then out[#out + 1] = { file = f, directive = d } end
        end
        if not no_global then
            for _, g in ipairs(global_candidates[C.group(f)] or {}) do
                for _, d in ipairs(C.data(g).csharp_usings or {}) do
                    if d.global and d.scope == '' then out[#out + 1] = { file = g, directive = d } end
                end
            end
        end
        return out
    end
    function C.exact(f, name)
        local ids = {}
        for _, id in ipairs(G.by_name[name:match('([^.]+)$')] or {}) do
            local n, g = G.nodes[id], G.node_file[id]
            if n.qualified == name and types[n.kind] and G.files[g].language == 'csharp' and C.same(f, g) then ids[#ids + 1] = id end
        end
        return ids
    end
    function C.namespace(f, name)
        return namespaces[C.group(f)] and namespaces[C.group(f)][name] or false
    end
    function C.namespace_children(f, namespace)
        local result = {}
        local prefix = namespace ~= '' and namespace .. '.' or ''
        for name in pairs(namespaces[C.group(f)] or {}) do
            if name:sub(1, #prefix) == prefix then
                local suffix = name:sub(#prefix + 1)
                if not suffix:find('.', 1, true) and suffix ~= '' then result[#result + 1] = suffix end
            end
        end
        table.sort(result)
        return result
    end
    return C
end

-- Result: type ids, resolved namespace (if any), and whether a binding was known.
function M.types(G, f, name, at, ctx, options)
    local C = context(G, ctx)
    options = options or {}
    name = M.name(name)
    if not name then return {}, nil, true end
    at = at or 0
    local active = C.active(f, at, options.exclude, options.no_global)
    local qualifier, rest = name:match('^([%w_]+)::(.*)$')
    if qualifier == 'global' then
        return C.exact(f, rest), C.namespace(f, rest) and rest or nil, true
    end
    local head, tail = (rest or name):match('^([^.]+)%.(.*)$')
    head = qualifier or head or name
    if qualifier then tail = rest end
    if not qualifier then
        for _, parameter in ipairs(C.data(f).csharp_parameters or {}) do
            if parameter.name == head and parameter.first <= at and at <= parameter.last then return {}, nil, true end
        end
    end
    local aliases, priority = {}, -2
    for _, entry in ipairs(active) do
        local d = entry.directive
        if clean(d.alias) == head then
            local rank = d.global and -1 or d.first
            if rank > priority then aliases, priority = {}, rank end
            if rank == priority then aliases[#aliases + 1] = entry end
        end
    end
    if #aliases > 0 then
        if #aliases ~= 1 or (options.depth or 0) >= 8 then return {}, nil, true end
        local entry = aliases[1]
        local d = entry.directive
        if not d.global and d.scope == '' then
            for _, other in ipairs(active) do
                if other.directive.global and clean(other.directive.alias) == head then return {}, nil, true end
            end
        end
        -- A nested type is looked up before a using alias from an enclosing
        -- namespace/file. The explicit alias:: form still selects the alias.
        if not qualifier then
            local scope = options.scope or C.scope(f, at)
            while scope ~= '' and scope ~= d.scope do
                local q = scope .. '.' .. name
                local ids, namespace = C.exact(f, q), C.namespace(f, q)
                if #ids > 0 or namespace then return ids, namespace and q or nil, true end
                if #C.exact(f, scope .. '.' .. head) > 0 then return {}, nil, true end
                scope = scope:match('^(.*)%.[^.]+$') or ''
            end
        end
        local ids, namespace = M.types(G, entry.file, d.path, d.first, ctx,
            { exclude = d.first, no_global = true, scope = d.scope, depth = (options.depth or 0) + 1 })
        local target = namespace or (#ids > 0 and G.nodes[ids[1]].qualified)
        if not target or qualifier and not namespace then return {}, nil, true end
        if tail then target = target .. '.' .. tail end
        return C.exact(f, target), C.namespace(f, target) and target or nil, true
    end
    if qualifier then return {}, nil, true end -- extern aliases require assembly identity
    local scope = options.scope or C.scope(f, at)
    while true do
        local q = (scope ~= '' and scope .. '.' or '') .. name
        local ids = C.exact(f, q)
        if #ids > 0 or C.namespace(f, q) then return ids, C.namespace(f, q) and q or nil, true end
        if scope == '' then break end
        scope = scope:match('^(.*)%.[^.]+$') or ''
    end
    local ids, seen = {}, {}
    for _, entry in ipairs(active) do
        local d = entry.directive
        if not d.alias then
            if (options.depth or 0) < 8 then
                local owners, path = M.types(G, entry.file, d.path, d.first, ctx,
                    { exclude = d.first, no_global = true, scope = d.scope, depth = (options.depth or 0) + 1 })
                if d.static then
                    for _, owner in ipairs(owners) do
                        for _, id in ipairs(C.exact(f, G.nodes[owner].qualified .. '.' .. name)) do
                            if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
                        end
                    end
                elseif path then
                    for _, id in ipairs(C.exact(f, path .. '.' .. name)) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
                end
            end
        end
    end
    return ids, nil, #ids > 0
end

function M.members(G, f, ids, name, static, ctx, depth, seen, access_scope)
    depth, seen = depth or 0, seen or {}
    local C, out, emitted = context(G, ctx), {}, {}
    for _, cls in ipairs(ids) do
        if not seen[cls] and depth <= 8 then
            seen[cls] = true
            local found = false
            for _, id in ipairs(G.by_name[name] or {}) do
                local n, g = G.nodes[id], G.node_file[id]
                if callable[n.kind] and n.qualified == G.nodes[cls].qualified .. '.' .. name
                    and G.files[g].language == 'csharp' and C.same(f, g) then
                    local data, index = C.data(g), id - G.id_of[g][1] + 1
                    local is_static, access = (data.csharp_statics or {})[index] or false, (data.csharp_access or {})[index]
                    local owner = G.nodes[cls].qualified
                    local own = access_scope and (access_scope == owner or access_scope:sub(1, #owner + 1) == owner .. '.')
                    if (static == nil or is_static == static) and (access == 'public' or access == 'internal' or own) then
                        if not emitted[id] then emitted[id] = true; out[#out + 1] = id end
                        found = true
                    end
                end
            end
            if not found and static ~= true then
                for _, base in ipairs(G.nodes[cls].bases or {}) do
                    local g = G.node_file[cls]
                    local at = 0
                    for _, scope in ipairs(C.data(g).csharp_scopes or {}) do if scope.scope == G.nodes[cls].qualified then at = scope.first; break end end
                    local more = M.types(G, g, base, at, ctx, { scope = G.nodes[cls].qualified:match('^(.*)%.[^.]+$') or '' })
                    for _, id in ipairs(M.members(G, f, more, name, static, ctx, depth + 1, seen, access_scope)) do
                        if not emitted[id] then emitted[id] = true; out[#out + 1] = id end
                    end
                end
            end
        end
    end
    return out
end

function M.resolve(G, f, src, name, kind, recv, evidence, ctx)
    if not evidence or evidence:sub(1, 3) ~= 'cs:' then return nil end
    local tag, value, offset = evidence:match('^cs:(%w+):(.-)%z(%d+)$')
    if not tag then return {} end
    local at, C = tonumber(offset), context(G, ctx)
    local access_scope = C.scope(f, at)
    if tag == 'new' then
        local result = {}
        for _, cls in ipairs(M.types(G, f, value, at, ctx)) do
            local n, explicit = G.nodes[cls], false
            for _, id in ipairs(G.by_name[n.name] or {}) do
                if G.nodes[id].kind == 'constructor' and G.nodes[id].qualified == n.qualified .. '.' .. n.name
                    and C.same(f, G.node_file[id]) then explicit = true; break end
            end
            if explicit then
                for _, id in ipairs(M.members(G, f, { cls }, n.name, false, ctx, nil, nil, access_scope)) do result[#result + 1] = id end
            else result[#result + 1] = cls end
        end
        return result
    end
    if tag == 'name' then
        local ids, namespace, known = M.types(G, f, value, at, ctx)
        if namespace then
            for _, id in ipairs(G.by_name[namespace:match('([^.]+)$')] or {}) do
                if G.nodes[id].kind == 'namespace' and G.nodes[id].qualified == namespace and C.same(f, G.node_file[id]) then ids[#ids + 1] = id end
            end
        end
        if known then return ids end
        return nil
    end
    if tag == 'self' then
        local scope = src and G.nodes[src].qualified:match('^(.*)%.[^.]+$') or C.scope(f, at)
        local owners = C.exact(f, scope)
        if value == 'base' then
            local bases = {}
            for _, id in ipairs(owners) do
                for _, base in ipairs(G.nodes[id].bases or {}) do
                    for _, target in ipairs(M.types(G, f, base, at, ctx)) do bases[#bases + 1] = target end
                end
            end
            owners = bases
        end
        return M.members(G, f, owners, name, false, ctx, nil, nil, access_scope)
    end
    if tag == 'type' or tag == 'owner' then
        local ids, _, known = M.types(G, f, value, at, ctx)
        if tag == 'type' or known then return M.members(G, f, ids, name, tag == 'owner', ctx, nil, nil, access_scope) end
        return nil
    end
    if tag == 'call' then
        local owner = src and G.nodes[src].qualified:match('^(.*)%.[^.]+$')
        if owner then
            local own = M.members(G, f, C.exact(f, owner), name, nil, ctx, nil, nil, access_scope)
            if #own > 0 then return own end
        end
        local out, known, seen = {}, false, {}
        for _, entry in ipairs(C.active(f, at)) do
            local d = entry.directive
            if d.static then
                known = true
                local ids = M.types(G, entry.file, d.path, d.first, ctx, { exclude = d.first, no_global = true, scope = d.scope })
                for _, id in ipairs(M.members(G, f, ids, name, true, ctx, nil, nil, access_scope)) do
                    if not seen[id] then seen[id] = true; out[#out + 1] = id end
                end
            end
        end
        if known then return out end
    end
end

function M.incoming_aliases(G, f, wanted, ctx)
    local hits, possible = {}, false
    for id in pairs(wanted) do
        if G.files[G.node_file[id]].language == 'csharp' and (types[G.nodes[id].kind] or G.nodes[id].kind == 'constructor') then possible = true; break end
    end
    if not possible then return hits end
    local C, relevant = context(G, ctx), false
    for id in pairs(wanted) do
        local kind = G.nodes[id].kind
        if G.files[G.node_file[id]].language == 'csharp' and (types[kind] or kind == 'constructor') and C.same(f, G.node_file[id]) then relevant = true; break end
    end
    if not relevant then return hits end
    local refs = G.files[f].refs
    for i, kind in ipairs(refs.kind) do
        if kind == 'new' then
            control.check()
            local value = ctx.ordinary.evidence(f, i)
            for _, id in ipairs(M.resolve(G, f, nil, refs.name[i], kind, refs.recv[i], value, ctx) or {}) do
                if wanted[id] then hits[i] = true; break end
            end
        end
    end
    return hits
end

function M.usings(G, f, at, ctx)
    return context(G, ctx).active(f, at)
end

function M.is_static(G, id, ctx)
    local g, C = G.node_file[id], context(G, ctx)
    return (C.data(g).csharp_statics or {})[id - G.id_of[g][1] + 1] or false
end

function M.static_node(G, f, node, ctx)
    for _, id in ipairs(G.by_name[node.name] or {}) do
        local n = G.nodes[id]
        if G.node_file[id] == f and n.qualified == node.qualified and n.line == node.line and n.kind == node.kind then
            return M.is_static(G, id, ctx)
        end
    end
    return false
end

function M.visible_node(G, caller, f, node, at, ctx)
    local C = context(G, ctx)
    for _, id in ipairs(G.by_name[node.name] or {}) do
        local n = G.nodes[id]
        if G.node_file[id] == f and n.qualified == node.qualified and n.line == node.line and n.kind == node.kind then
            local access = (C.data(f).csharp_access or {})[id - G.id_of[f][1] + 1]
            local owner, scope = n.qualified:match('^(.*)%.[^.]+$'), C.scope(caller, at)
            return access == 'public' or access == 'internal' or owner and (scope == owner or scope:sub(1, #owner + 1) == owner .. '.')
        end
    end
    return false
end

-- Namespace alias completion uses the same type/namespace target as navigation.
function M.namespace_members(G, f, namespace, ctx)
    local C, out, seen = context(G, ctx), {}, {}
    local prefix = namespace ~= '' and namespace .. '.' or ''
    -- A dotted namespace declaration need not contain a separate node for
    -- each enclosing namespace (namespace A.B still exposes A then B).
    for _, name in ipairs(C.namespace_children(f, namespace)) do
        seen[name] = true
        out[#out + 1] = { name = name, kind = 'namespace', node = { kind = 'namespace', name = name, qualified = prefix .. name } }
    end
    local files = {}
    for _, g in ipairs(G.file_order) do files[#files + 1] = g end
    for _, g in ipairs(G.new_files or {}) do files[#files + 1] = g end
    for _, g in ipairs(files) do
        if G.files[g].language == 'csharp' and C.same(f, g) then
            for _, id in ipairs(G.id_of[g]) do
                local n = G.nodes[id]
                local suffix = n.qualified:sub(1, #prefix) == prefix and n.qualified:sub(#prefix + 1)
                if suffix and not suffix:find('.', 1, true) and (types[n.kind] or n.kind == 'namespace') and not seen[suffix] then
                    seen[suffix] = true; out[#out + 1] = { name = suffix, kind = n.kind, node = n, file = g }
                end
            end
        end
    end
    return out
end

return M
