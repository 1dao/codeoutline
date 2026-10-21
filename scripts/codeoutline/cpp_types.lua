-- Shared C++ named-type lookup. Alias bodies and lexical ranges are query-only.
local M = {}
local control = require('codeoutline.control')
local classes = { class = true, struct = true, union = true }
local declaring = { class = true, struct = true, union = true, enum = true, namespace = true, typedef = true }
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
        if word == 'using' and T.k[i + 1] == 'id' and T:text(i + 2) == '=' or word == 'typedef' then
            local stop = i + 1
            while stop <= T.n and T:text(stop) ~= ';' do
                if T.m[stop] and T.m[stop] > stop then stop = T.m[stop] end
                stop = stop + 1
            end
            local name, first, last
            if word == 'using' then name, first, last = i + 1, i + 3, stop - 1
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
                result[#result + 1] = { name = T:text(name), target = not templated and M.normalize(text) or false,
                    scope = scope, local_alias = local_alias, at = T.s[name] - 1,
                    first = open > 0 and T.s[open] - 1 or 0,
                    last = open > 0 and T.e[T.m[open]] or #T.src }
            end
        end
    end
    if #result > 0 then r.cpp_aliases = result end
end

-- opts.at is a byte position in file f, normally the receiver declaration.
-- The boolean result distinguishes an unknown name from a known but unresolved
-- declaration, so completion cannot revive a hidden outer type on failure.
function M.resolve(G, f, written, opts)
    opts = opts or {}
    written = M.normalize(written)
    if not written then return {}, true end
    local deps, ctx, accept = opts.deps or {}, opts.context, opts.accept or classes
    local visibility = { [f] = deps }
    local function visible(file, target)
        if file == target then return true end
        if not visibility[file] then visibility[file] = require('codeoutline.graph').dependencies(G, file, ctx) end
        return visibility[file][target]
    end
    local function aliases(file)
        local rec = G.files[file]
        return (ctx and ctx.ordinary and ctx.ordinary.data(file) or rec).cpp_aliases or {}
    end
    local seen = {}
    local resolve
    local function follow(alias, file, depth)
        if not alias.target then return {} end
        local key = file .. ':' .. alias.at
        if seen[key] or depth >= 8 then return {} end
        seen[key] = true
        local ids = resolve(file, alias.target, alias.scope, alias.at, depth + 1)
        seen[key] = nil
        return ids
    end
    local function named(file, qualified, at, depth)
        local tail = qualified:match('([^:]+)$')
        local found, ids, unique = false, {}, {}
        local function add(more) for _, id in ipairs(more) do if not unique[id] then unique[id] = true; ids[#ids + 1] = id end end end
        for _, id in ipairs(G.by_name[tail] or {}) do
            local n, g = G.nodes[id], G.node_file[id]
            if n.qualified == qualified and declaring[n.kind] and visible(file, g) then
                if n.kind == 'typedef' then
                    local matched = false
                    for _, alias in ipairs(aliases(g)) do
                        if not alias.local_alias and (alias.scope ~= '' and alias.scope .. '::' or '') .. alias.name == qualified then
                            matched = true
                            if g ~= file or not at or alias.at <= at then found = true; add(follow(alias, g, depth)) end
                        end
                    end
                    if not matched then found = true end -- unsupported alias is a barrier
                else
                    found = true
                    if accept[n.kind] then add({ id }) end
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
                    local more = named(file, G.nodes[owner].qualified .. '::' .. suffix, nil, depth + 1)
                    for _, id in ipairs(more) do result[#result + 1] = id end
                end
                -- Namespace nodes are not class results, so do not stop lexical
                -- lookup merely because a namespace prefix exists.
                if #owners > 0 then return result, true end
            end
        end
        return {}, false
    end
    resolve = function(file, name, scope, at, depth)
        control.check()
        if depth > 8 then return {}, true end
        if name:sub(1, 2) == '::' then return qualified(file, name:sub(3), at, depth) end
        local head, tail = name:match('^([^:]+)::(.*)$')
        head = head or name
        if at then
            local best
            for _, alias in ipairs(aliases(file)) do
                if alias.local_alias and alias.name == head and alias.at <= at and alias.first <= at and at <= alias.last
                    and (not best or alias.first > best.first or alias.first == best.first and alias.at > best.at) then best = alias end
            end
            if best then
                local ids = follow(best, file, depth)
                if not tail then return ids, true end
                local result = {}
                for _, id in ipairs(ids) do
                    local more = qualified(file, G.nodes[id].qualified .. '::' .. tail, nil, depth + 1)
                    for _, target in ipairs(more) do result[#result + 1] = target end
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
            if found then return ids, true end
            if not scope or scope == '' then break end
            scope = scope:match('^(.*)::[^:]+$') or ''
        end
        return {}, false
    end
    return resolve(f, written, opts.scope, opts.at, 0)
end

return M
