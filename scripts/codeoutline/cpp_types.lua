-- Shared C++ name lookup. Alias/import bodies and lexical ranges are query-only.
local M = {}
local control = require('codeoutline.control')
local classes = { class = true, struct = true, union = true }
local declaring = { class = true, struct = true, union = true, enum = true, namespace = true, typedef = true,
    ['function'] = true, method = true, prototype = true, variable = true, field = true, constant = true, macro = true }
local callable = { ['function'] = true, method = true, constructor = true, destructor = true }
local qualifiers = { const = true, volatile = true, struct = true, class = true, union = true }

-- Only named types with cv/pointer/reference decoration. Never erase template
-- arguments or dependent expressions and then guess an unrelated class.
function M.normalize(text)
    if type(text) ~= 'string' then return nil end
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    for _ = 1, 8 do
        local word, rest = text:match('^(%w+)%s+(.+)$')
        if qualifiers[word] then text = rest else break end
    end
    for _ = 1, 8 do
        local before, word = text:match('^(.-)%s+(%w+)$')
        if word == 'const' or word == 'volatile' then text = before
        else
            local stripped = text:gsub('[%*&%s]+$', '')
            if stripped == text then break end
            text = stripped
        end
    end
    text = text:gsub('%s*::%s*', '::')
    local rest = text:gsub('^::', '')
    local parts = {}
    for part in rest:gmatch('[^:]+') do
        if not part:match('^[%a_][%w_]*$') then return nil end
        parts[#parts + 1] = part
    end
    if #parts == 0 or table.concat(parts, '::') ~= rest then return nil end
    if rest == 'auto' or rest == 'decltype' then return nil end
    return text
end

function M.collect(r, T)
    if r.language ~= 'cpp' then return end
    local result, scopes, stack = {}, {}, {}
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        local ns_alias = word == 'namespace' and T.k[i + 1] == 'id' and T:text(i + 2) == '='
        local forward = classes[word] and T.k[i + 1] == 'id' and T:text(i + 2) == ';'
        if word == 'using' or word == 'typedef' or ns_alias or forward then
            local stop = i + 1
            while stop <= T.n and T:text(stop) ~= ';' do
                if T.m[stop] and T.m[stop] > stop then stop = T.m[stop] end
                stop = stop + 1
            end
            local name, first, last, kind
            if forward then name, first, last, kind = i + 1, i + 1, i + 1, 'forward'
            elseif ns_alias then name, first, last, kind = i + 1, i + 3, stop - 1, 'namespace'
            elseif word == 'using' and T:text(i + 1) == 'namespace' then
                name, first, last, kind = i + 1, i + 2, stop - 1, 'directive'
            elseif word == 'using' and T:text(i + 2) == '=' then name, first, last = i + 1, i + 3, stop - 1
            elseif word == 'using' and T.k[stop - 1] == 'id' then
                name, first, last, kind = stop - 1, i + 1, stop - 1, 'using'
            elseif T.k[stop - 1] == 'id' then name, first, last = stop - 1, i + 1, stop - 2 end
            -- Unsupported function-pointer typedefs still introduce a name barrier.
            if not name then
                for j = i + 1, stop - 1 do
                    if T:text(j) == '*' and T.k[j + 1] == 'id' and T:text(j + 2) == ')' then name = j + 1; break end
                end
            end
            if name and stop <= T.n then
                local owner, templated
                for _, n in ipairs(r.nodes) do
                    if (classes[n.kind] or n.kind == 'namespace' or callable[n.kind]) and n.ti < i and i < n.tj then
                        if not owner or n.ti > owner.ti then owner = n end
                        if T:text(n.ti) == 'template' then templated = true end
                    end
                end
                for j = i - 1, 1, -1 do
                    local s = T:text(j)
                    if s == ';' or s == '{' or s == '}' then break end
                    if s == 'template' then templated = true; break end
                end
                local scope = owner and owner.qualified or ''
                local local_alias = owner and callable[owner.kind] or false
                if local_alias then scope = scope:match('^(.*)::[^:]+$') or '' end
                local text = first and T.src:sub(T.s[first], T.e[last])
                local open = scopes[i]
                result[#result + 1] = { name = kind == 'directive' and '*' or T:text(name), kind = kind,
                    target = not templated and M.normalize(text) or false,
                    decorated = not kind and text and (text:find('[*&]') ~= nil or text:match('%f[%w]const%f[%W]') ~= nil
                        or text:match('%f[%w]volatile%f[%W]') ~= nil) or nil,
                    scope = scope, local_alias = local_alias, at = T.s[name] - 1,
                    first = open > 0 and T.s[open] - 1 or 0,
                    last = open > 0 and T.e[T.m[open]] or #T.src }
            end
        end
    end
    if #result > 0 then r.cpp_aliases = result end
end

-- Preserve the whole written qualifier, not just the receiver's final token.
function M.evidence(T, t)
    local first = t
    while T:text(first - 1) == '::' and T.k[first - 2] == 'id' do first = first - 2 end
    if T:text(first - 1) == '::' then first = first - 1 end
    return 'cpp:name:' .. T.src:sub(T.s[first], T.e[t]):gsub('%s+', '') .. '\0' .. (T.s[t] - 1)
end

function M.aliases(G, f, ctx)
    return (ctx and ctx.ordinary and ctx.ordinary.data(f) or G.files[f]).cpp_aliases or {}
end

-- opts.at is a byte position in file f, normally the receiver declaration.
-- The boolean result distinguishes an unknown name from a known but unresolved
-- declaration, so completion cannot revive a hidden outer type on failure.
function M.resolve(G, f, written, opts)
    opts = opts or {}
    written = M.normalize(written)
    if not written then return {}, true end
    local ctx, accept = opts.context, opts.accept or classes
    local visibility, records = {}, {}
    local function dependencies(file)
        if not visibility[file] then visibility[file] = require('codeoutline.graph').visible_dependencies(G, file, ctx) end
        return visibility[file]
    end
    local function visible(file, target)
        if file == target then return true end
        return dependencies(file)[target]
    end
    local function aliases(file)
        if not records[file] then records[file] = opts.aliases and opts.aliases(file) or M.aliases(G, file, ctx) end
        return records[file]
    end
    local lists = {}
    local function files(file)
        if not lists[file] then
            local list = { file }
            -- A resident boolean says whether a header can change lookup without
            -- introducing an indexed name. Detailed evidence remains query-only.
            for g in pairs(dependencies(file)) do if G.files[g].cpp_imports then list[#list + 1] = g end end
            table.sort(list, function(a, b) return G.files[a].path < G.files[b].path end)
            lists[file] = list
        end
        return lists[file]
    end
    local function add(ids, more)
        local seen = {}; for _, id in ipairs(ids) do seen[id] = true end
        for _, id in ipairs(more) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    end
    local seen = {}
    local resolve
    local function follow(alias, file, depth)
        if opts.undecorated and alias.decorated then return {}, true end
        if not alias.target then return {} end
        local key = file .. ':' .. alias.at
        if seen[key] or depth >= 8 then return {}, true end
        seen[key] = true
        local ids = resolve(file, alias.target, alias.scope, alias.at, depth + 1)
        seen[key] = nil
        if alias.kind == 'namespace' or alias.kind == 'directive' then
            local kept = {}
            for _, id in ipairs(ids) do if G.nodes[id].kind == 'namespace' then kept[#kept + 1] = id end end
            ids = kept
        end
        return ids
    end
    local function named(file, qualified, at, depth)
        local tail = qualified:match('([^:]+)$')
        local found, ids = false, {}
        for index, id in ipairs(G.by_name[tail] or {}) do
            if index % 128 == 0 then control.check() end
            local n, g = G.nodes[id], G.node_file[id]
            if n.qualified == qualified and declaring[n.kind] and visible(file, g) then
                if n.kind == 'typedef' then
                    local matched = false
                    for _, alias in ipairs(aliases(g)) do
                        if not alias.kind and not alias.local_alias and (alias.scope ~= '' and alias.scope .. '::' or '') .. alias.name == qualified then
                            matched = true
                            if g ~= file or not at or alias.at <= at then found = true; add(ids, follow(alias, g, depth)) end
                        end
                    end
                    if not matched then found = true end -- unsupported alias is a barrier
                else
                    found = true
                    add(ids, { id })
                end
            end
        end
        for _, g in ipairs(files(file)) do
            control.check()
            for _, alias in ipairs(aliases(g)) do
                if alias.kind and alias.kind ~= 'directive' and not alias.local_alias
                    and (alias.scope ~= '' and alias.scope .. '::' or '') .. alias.name == qualified
                    and (g ~= file or not at or alias.at <= at) then
                    found = true
                    if alias.kind == 'forward' then
                        -- Preserve completion's existing incomplete-type aid,
                        -- but require an explicit forward declaration first.
                        if opts.forward then
                            for _, id in ipairs(G.by_name[tail] or {}) do
                                local n = G.nodes[id]
                                if n.qualified == qualified and classes[n.kind] then add(ids, { id }) end
                            end
                        end
                    else add(ids, follow(alias, g, depth)) end
                end
            end
        end
        return ids, found
    end
    local function qualified(file, name, at, depth)
        local ids, found = named(file, name, at, depth)
        if found then return ids, true end
        -- A class alias may qualify a nested type, e.g. Alias::Inner.
        local prefix, suffix = name:match('^(.*)::([^:]+)$')
        if prefix and depth < 8 then
            local owners, known = qualified(file, prefix, at, depth + 1)
            if known then
                local result = {}
                for _, owner in ipairs(owners) do
                    local node = G.nodes[owner]
                    local more
                    if node.kind == 'namespace' then more = resolve(file, suffix, node.qualified, at, depth + 1, true)
                    else more = named(file, node.qualified .. '::' .. suffix, nil, depth + 1) end
                    add(result, more)
                end
                if #owners > 0 then return result, true end
            end
        end
        return {}, false
    end
    resolve = function(file, name, scope, at, depth, only_scope)
        control.check()
        if depth > 8 then return {}, true end
        if name:sub(1, 2) == '::' then return qualified(file, name:sub(3), at, depth) end
        local head, tail = name:match('^([^:]+)::(.*)$')
        head = head or name
        if at then
            local best
            for _, alias in ipairs(aliases(file)) do
                if alias.kind ~= 'directive' and alias.local_alias and alias.name == head and alias.at <= at and alias.first <= at and at <= alias.last
                    and (not best or alias.first > best.first or alias.first == best.first and alias.at > best.at) then best = alias end
            end
            if best then
                local ids = follow(best, file, depth)
                if not tail then return ids, true end
                local result = {}
                for _, id in ipairs(ids) do
                    local more = qualified(file, G.nodes[id].qualified .. '::' .. tail, nil, depth + 1)
                    add(result, more)
                end
                return result, true
            end
        end
        while true do
            local prefix = scope and scope ~= '' and scope .. '::' or ''
            local ids, found
            if not tail then ids, found = named(file, prefix .. name, at, depth)
            else
                ids, found = qualified(file, prefix .. name, at, depth)
                if not found then
                    local _, declared = named(file, prefix .. head, at, depth)
                    found = declared
                end
            end
            -- using-directives contribute candidates only in their lexical
            -- scope. Imported headers contribute namespace/file scope, never locals.
            for _, g in ipairs(files(file)) do
                for _, alias in ipairs(aliases(g)) do
                    if alias.kind == 'directive' and alias.scope == (scope or '')
                        and not (g == f and alias.at == opts.exclude)
                        and (not alias.local_alias or g == file and at and alias.first <= at and at <= alias.last)
                        and (g ~= file or not at or alias.at <= at) then
                        local namespaces = follow(alias, g, depth)
                        for _, id in ipairs(namespaces) do
                            local q = G.nodes[id].qualified
                            local key = file .. ':' .. q .. ':' .. name
                            if not seen[key] then
                                seen[key] = true
                                local more, known = resolve(file, '::' .. q .. '::' .. name, '', at, depth + 1)
                                seen[key] = nil
                                if known then found = true; add(ids, more) end
                            end
                        end
                    end
                end
            end
            if found then return ids, true end
            if only_scope or not scope or scope == '' then break end
            scope = scope:match('^(.*)::[^:]+$') or ''
        end
        return {}, false
    end
    local ids, known = resolve(f, written, opts.scope, opts.at, 0)
    local result, qualified = {}, nil
    for _, id in ipairs(ids) do
        local n = G.nodes[id]
        -- Distinct qualified names are an ambiguity, not a locality contest.
        if qualified and qualified ~= n.qualified then return {}, true end
        qualified = n.qualified
        if accept[n.kind] then result[#result + 1] = id end
    end
    if opts.definitions and #result > 0 then
        local _, paired = require('codeoutline.graph').visible_dependencies(G, f, ctx)
        local definitions = {}
        for _, id in ipairs(G.by_name[G.nodes[result[1]].name] or {}) do
            local n, g = G.nodes[id], G.node_file[id]
            if n.qualified == qualified and accept[n.kind] and not n.decl and n.kind ~= 'prototype'
                and (g == f or visible(f, g) or paired[g]) and not (n.static and g ~= f and paired[g]) then
                definitions[#definitions + 1] = id
            end
        end
        if #definitions > 0 then result = definitions end
    end
    return result, known
end

-- Namespace members are restricted to declarations visible to the requester.
-- Overlay nodes replace the resident by_owner entries just as by_name does.
function M.namespace_members(G, f, namespace, ctx, at, seen, depth)
    seen, depth = seen or {}, depth or 0
    if seen[namespace] or depth > 8 then return {} end
    seen[namespace] = true
    local deps = require('codeoutline.graph').visible_dependencies(G, f, ctx)
    local result = {}
    local function add(id)
        local n, g = G.nodes[id], G.node_file[id]
        if (g == f or deps[g]) and n.qualified:match('^(.*)::[^:]+$') == namespace then
            result[#result + 1] = { name = n.name, kind = n.kind, node = n, file = g }
        end
    end
    for _, id in ipairs(G.by_owner[namespace] or {}) do
        if not (G.drafts and G.drafts[G.node_file[id]]) then add(id) end
    end
    for g in pairs(G.drafts or {}) do for _, id in ipairs(G.id_of[g]) do add(id) end end
    local files = { f }; for g in pairs(deps) do if G.files[g].cpp_imports then files[#files + 1] = g end end
    table.sort(files, function(a, b) return G.files[a].path < G.files[b].path end)
    local any = setmetatable({}, { __index = function() return true end })
    for _, g in ipairs(files) do
        control.check()
        for _, alias in ipairs(M.aliases(G, g, ctx)) do
            if not alias.local_alias and alias.scope == namespace and (g ~= f or not at or alias.at <= at) then
                if alias.kind == 'directive' and alias.target then
                    local ids = M.resolve(G, g, alias.target,
                        { scope = alias.scope, at = alias.at, exclude = alias.at, context = ctx, accept = { namespace = true } })
                    for _, id in ipairs(ids) do
                        for _, entry in ipairs(M.namespace_members(G, f, G.nodes[id].qualified, ctx, at, seen, depth + 1)) do
                            result[#result + 1] = entry
                        end
                    end
                elseif alias.kind ~= 'forward' then
                    local ids = M.resolve(G, f, '::' .. namespace .. '::' .. alias.name, { context = ctx, at = at, accept = any })
                    for _, id in ipairs(ids) do
                        local n = G.nodes[id]
                        result[#result + 1] = { name = alias.name, kind = n.kind, node = n, file = G.node_file[id] }
                    end
                end
            end
        end
    end
    return result
end

function M.imported_members(G, f, scope, at, ctx)
    local deps = require('codeoutline.graph').visible_dependencies(G, f, ctx)
    local result, names = {}, {}
    local any = setmetatable({}, { __index = function() return true end })
    local function active(alias, file)
        if file == f and alias.at > at then return false end
        if alias.local_alias then return file == f and alias.first <= at and at <= alias.last end
        return alias.scope == '' or scope == alias.scope or (scope or ''):sub(1, #alias.scope + 2) == alias.scope .. '::'
    end
    local files = { f }; for g in pairs(deps) do if G.files[g].cpp_imports then files[#files + 1] = g end end
    table.sort(files, function(a, b) return G.files[a].path < G.files[b].path end)
    for _, g in ipairs(files) do
        control.check()
        for _, alias in ipairs(M.aliases(G, g, ctx)) do
            if active(alias, g) then
                if alias.kind == 'directive' and alias.target then
                    local ids = M.resolve(G, g, alias.target,
                        { scope = alias.scope, at = alias.at, exclude = alias.at, context = ctx, accept = { namespace = true } })
                    for _, id in ipairs(ids) do
                        for _, entry in ipairs(M.namespace_members(G, f, G.nodes[id].qualified, ctx, at)) do names[entry.name] = true end
                    end
                else names[alias.name] = true end
            end
        end
    end
    for name in pairs(names) do
        local ids = M.resolve(G, f, name, { scope = scope, at = at, context = ctx, accept = any })
        for _, id in ipairs(ids) do
            local n = G.nodes[id]
            result[#result + 1] = { name = name, kind = n.kind, node = n, file = G.node_file[id] }
        end
    end
    return result
end

return M
