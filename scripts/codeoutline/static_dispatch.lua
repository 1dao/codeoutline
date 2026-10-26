-- Bounded static registrations, derived on demand; never evaluate source.
local M = {}
local control = require('codeoutline.control')
local callable = { ['function'] = true, method = true, constructor = true }

local function site_key(from, line, recv, name)
    return from .. ':' .. line .. ':' .. tostring(recv) .. ':' .. tostring(name)
end

local function literal(T, i)
    local s = T:text(i)
    if T.k[i] == 'str' and (s:sub(1, 1) == '"' or s:sub(1, 1) == "'")
        and s:sub(-1) == s:sub(1, 1) and not s:find('\\', 1, true) then return s:sub(2, -2) end
end

-- Necessary syntax only: leave scope, shadowing and registration validation to
-- the collector. Token checks work identically with native and Lua scanners.
local function has_dispatch(T, lua)
    local declared, called = {}, {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if lua then
            if T.k[i] == 'kw' and T:text(i) == 'local' then
                local j = i + 1
                while T.k[j] == 'id' do
                    if T:text(j + 1) == '=' and T:text(j + 2) == '{' then declared[T:text(j)] = true end
                    -- A necessary-syntax prefilter only; lexical validity is
                    -- checked below. Include aliases so they cannot hide sites.
                    if T:text(j + 1) == '=' and T.k[j + 2] == 'id' and declared[T:text(j + 2)] then
                        declared[T:text(j)] = true
                    end
                    if T:text(j + 1) ~= ',' then break end
                    j = j + 2
                end
            elseif T.k[i] == 'id' then
                local tail
                if T:text(i + 1) == '.' and T.k[i + 2] == 'id' then tail = i + 3
                elseif T:text(i + 1) == '[' and T.m[i + 1] then tail = T.m[i + 1] + 1 end
                if tail and T:text(tail) == '(' then called[T:text(i)] = true end
            end
        else
            if T.k[i] == 'kw' and (T:text(i) == 'struct' or T:text(i) == 'class')
                and T.k[i + 1] == 'id' and T:text(i + 2) == '{' and T.m[i + 2] then
                for j = i + 3, T.m[i + 2] - 1 do
                    if j % 4096 == 0 then control.check() end
                    if T.k[j] == 'id' and T:text(j - 1) == '*' and T:text(j - 2) == '('
                        and T:text(j + 1) == ')' and T:text(j + 2) == '(' then declared[T:text(j)] = true end
                end
            elseif T.k[i] == 'id' and (T:text(i - 1) == '.' or T:text(i - 1) == '->') then
                if T:text(i + 1) == '(' or T:text(i + 1) == ')' and T:text(i + 2) == '(' then
                    called[T:text(i)] = true
                end
            end
        end
    end
    for name in pairs(declared) do if called[name] then return true end end
    return false
end

function M.collect(r, T)
    local lua = r.language == 'lua'
    if not lua and r.language ~= 'c' and r.language ~= 'cpp' then return end
    local executable
    for _, node in ipairs(r.nodes) do if callable[node.kind] then executable = true; break end end
    if not executable then return end
    local loops = lua and r.ordinary_bindings and require('codeoutline.lua_callback_loops').tokens_candidate(T)
    -- Reject cheap negatives before collecting compact query hints.
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local registration
        if T.k[i] == 'op' and lua and T:text(i) == '=' and T.k[i + 1] == 'id' then
            local prev, before = T:text(i - 1), T:text(i - 2)
            registration = prev == ']' or T.k[i - 1] == 'id'
                and (before == '.' or before == '{' or before == ',' or before == ';')
        end
        if registration or (not lua and T.k[i] == 'op' and T:text(i) == '*' and T:text(i - 1) == '(') then
            r.static_dispatch_candidate = true; break
        end
    end
    if not r.static_dispatch_candidate and not loops then return end
    if r.static_dispatch_candidate and not has_dispatch(T, lua) then
        r.static_dispatch_candidate = nil
        if not loops then return end
    end
    -- Full indexing retains only a syntax candidate. Scope, registry writes
    -- and resolved registrations belong to an open-file/query parse.
    if not r.collect_static_dispatch and (r.defer_analysis or not r.ordinary_bindings and not r.ranges) then
        local targets = {}
        for _, i in ipairs(T:idents(1, T.n)) do
            local prev = T:text(i - 1)
            if prev == '=' or prev == '&' or prev == '{' or prev == ',' then targets[T:text(i)] = true end
        end
        r.static_dispatch_candidate = { targets = targets, syntax = true }
        return
    end
    local scopes, ends, stack, owners = {}, { [0] = T.n }, {}, {}
    local opens = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
    for i = 1, T.n do
        local s = T:text(i)
        if lua and T.k[i] == 'kw' and (s == 'end' or s == 'until') then
            local top = table.remove(stack); if top then ends[top] = i end
        elseif not lua and s == '}' then table.remove(stack) end
        scopes[i] = stack[#stack] or 0
        if (lua and T.k[i] == 'kw' and opens[s]) or (not lua and s == '{') then
            stack[#stack + 1] = i
            if not lua then ends[i] = T.m[i] or T.n end
        end
    end
    -- Only executable owners: an initializer belongs to no caller function.
    local ordered = {}
    for id, n in ipairs(r.nodes) do if callable[n.kind] then ordered[#ordered + 1] = id end end
    local functions_by_token
    if loops then
        functions_by_token = {}
        for _, id in ipairs(ordered) do functions_by_token[r.nodes[id].ti] = id end
    end
    table.sort(ordered, function(a, b) return r.nodes[a].ti < r.nodes[b].ti end)
    local cursor = 1; stack = {}
    for i = 1, T.n do
        while ordered[cursor] and r.nodes[ordered[cursor]].ti <= i do
            stack[#stack + 1] = ordered[cursor]; cursor = cursor + 1
        end
        while stack[#stack] and r.nodes[stack[#stack]].tj < i do table.remove(stack) end
        owners[i] = stack[#stack] or 0
    end
    local data = { sites = {} }
    r.static_dispatch = data
    local bindings, structs = {}, {}
    local function bind(name, token, scope, value)
        value = value or {}
        value.token, value.scope, value.finish = token, scope, ends[scope] or T.n
        bindings[name] = bindings[name] or {}
        for i, previous in ipairs(bindings[name]) do
            if previous.token == token and previous.scope == scope then bindings[name][i] = value; return value end
        end
        table.insert(bindings[name], value)
        return value
    end
    local function binding(name, token)
        local best
        for _, b in ipairs(bindings[name] or {}) do
            if b.token <= token and b.scope <= token and b.finish >= token
                and (not best or b.scope > best.scope or b.scope == best.scope and b.token > best.token) then best = b end
        end
        return best
    end
    local function function_target(name, at, depth)
        depth = depth or 0
        if depth > 8 then return nil end
        local b = binding(name, at)
        if b then
            if b.alias then
                if b.invalid then return nil end
                return function_target(b.alias, b.token - 1, depth + 1)
            end
            if depth > 0 and b.invalid then return nil end
            if not b.function_name then return nil end
            if functions_by_token then
                local id = functions_by_token[b.token]
                return id and r.nodes[id].name == name and id or nil
            end
            for id, n in ipairs(r.nodes) do
                if callable[n.kind] and n.name == name and n.ti == b.token then return id end
            end
            return nil
        end
        -- Alias propagation is limited to lexical locals. Global functions can
        -- be replaced outside this file and have no stable local binding.
        if lua and depth > 0 then return nil end
        local best, best_scope
        for id, n in ipairs(r.nodes) do
            local scope = scopes[n.ti] or 0
            if callable[n.kind] and n.name == name and n.qualified == name
                and scope <= at and (ends[scope] or T.n) >= at and (not lua or n.ti < at)
                and (not best_scope or scope > best_scope or scope == best_scope and n.ti > r.nodes[best].ti) then best, best_scope = id, scope end
        end
        return best
    end
    local function register(bucket, key, a, b, site)
        -- Anonymous/named table functions already belong to the ordinary Lua
        -- binding resolver. Do not replace those edges with an unknown slot.
        if lua and T:text(a) == 'function' then bucket[key] = nil; return end
        if T:text(a) == '&' then a = a + 1 end
        local target = a == b and T.k[a] == 'id' and T:text(a)
        local index = target and function_target(target, a)
        if target and binding(target, a) and not index then target = nil end
        bucket[key] = bucket[key] or {}
        if lua and #bucket[key] > 0 then bucket[key].unknown = true end
        if not target or (lua and not index) then bucket[key].unknown = true; return end
        table.insert(bucket[key], { name = index and r.nodes[index].name or target,
            index = index, line = T:line(site), from = owners[a] })
    end
    local function parts(a, b, separator)
        local result, first, i = {}, a, a
        while i <= b do
            if T:text(i) == separator or lua and T:text(i) == ';' then
                result[#result + 1] = { first, i - 1 }; first = i + 1
            elseif T.m[i] and T.m[i] > i then i = T.m[i]
            elseif lua and ends[i] then i = ends[i] end
            i = i + 1
        end
        if first <= b then result[#result + 1] = { first, b } end
        return result
    end
    local function lvalue_end(i)
        if T.k[i] ~= 'id' then return nil end
        local j = i + 1
        while true do
            if T:text(j) == '.' and T.k[j + 1] == 'id' then j = j + 2
            elseif T:text(j) == '[' and T.m[j] then j = T.m[j] + 1
            else return j end
        end
    end
    local function assignment_end(i)
        local j = lvalue_end(i)
        while j and T:text(j) == ',' do j = lvalue_end(j + 1) end
        return j and T:text(j) == '=' and j or nil
    end
    if lua then
        local statement = { ['local'] = true, ['function'] = true, ['return'] = true,
            ['if'] = true, ['for'] = true, ['while'] = true, ['repeat'] = true,
            ['do'] = true, ['end'] = true, ['else'] = true, ['elseif'] = true,
            ['until'] = true, ['break'] = true, ['goto'] = true }
        local function alias_end(i)
            local next = T:text(i + 1)
            return next == '' or next == ';' or statement[next]
                or T.l[i + 1] > T.l[i] and T.k[i + 1] == 'id'
        end
        -- Lexical local bindings (including unknown parameters) prevent name leaks.
        for i = 1, T.n do
            if T:text(i) == 'function' and T.k[i] == 'kw' then
                local p = i + 1
                while p <= T.n and T:text(p) ~= '(' do p = p + 1 end
                for j = p + 1, (T.m[p] or p) - 1 do
                    if T.k[j] == 'id' then bind(T:text(j), j, i) end
                end
            elseif T:text(i) == 'local' and T.k[i] == 'kw' then
                local j = i + 1
                if T:text(j) == 'function' then
                    bind(T:text(j + 1), i, scopes[i], { function_name = true })
                else
                    while T.k[j] == 'id' do
                        local b = bind(T:text(j), j, scopes[i])
                        if T:text(j + 1) == '=' and T:text(j + 2) == '{' and T.m[j + 2] then
                            b.slots, b.open = {}, j + 2
                        elseif T:text(j - 1) == 'local' and T:text(j + 1) == '='
                            and T.k[j + 2] == 'id' and alias_end(j + 2) then
                            b.alias = T:text(j + 2)
                        end
                        if T:text(j + 1) ~= ',' then break end
                        j = j + 2
                    end
                end
            elseif T:text(i) == 'for' and T.k[i] == 'kw' then
                local first, body = i + 1, i + 1
                while body <= T.n and T:text(body) ~= 'do' do
                    if T.m[body] and T.m[body] > body then body = T.m[body] end
                    body = body + 1
                end
                while T.k[first] == 'id' do
                    bind(T:text(first), first, body)
                    if T:text(first + 1) ~= ',' then break end
                    first = first + 2
                end
            end
        end
        for i = 1, T.n do
            local prev = T:text(i - 1)
            if T.k[i] == 'id' and prev ~= '.' and prev ~= ':' and prev ~= '{' and prev ~= ',' then
                local eq = assignment_end(i)
                local definition = prev == 'function' and T:text(i - 2) ~= 'local' and T:text(i + 1) == '('
                if eq or definition then
                    local j = i
                    while j < (eq or i + 1) do
                        local tail = definition and i + 1 or lvalue_end(j)
                        local existing = binding(T:text(j), j)
                        if tail == j + 1 and existing and existing.token ~= j and prev ~= 'local' then
                            existing.invalid = true
                            bind(T:text(j), j, scopes[j])
                        end
                        j = tail + 1
                    end
                end
            end
        end
        -- Share registry state, not copies: writes through any alias must
        -- invalidate the same slots. Resolve at the initializer's lexical point.
        local function registry(b, depth)
            if not b or depth > 8 then return nil end
            if b.slots then return b end
            if b.alias then return registry(binding(b.alias, b.token - 1), depth + 1) end
        end
        for _, list in pairs(bindings) do
            for _, b in ipairs(list) do
                if b.alias then b.registry = registry(b, 0) end
            end
        end
        for _, list in pairs(bindings) do
            for _, b in ipairs(list) do
                if b.slots then
                    for _, span in ipairs(parts(b.open + 1, T.m[b.open] - 1, ',')) do
                        local a, z, key, eq = span[1], span[2]
                        if T.k[a] == 'id' and T:text(a + 1) == '=' then key, eq = T:text(a), a + 1
                        elseif T:text(a) == '[' and T.m[a] == a + 2 and T:text(a + 3) == '=' then key, eq = literal(T, a + 1), a + 3 end
                        if key then register(b.slots, key, eq + 1, z, a) end
                    end
                end
            end
        end
    else
        -- Inline function-pointer declarations only; typedefs/macros need separate evidence.
        for i = 1, T.n - 2 do
            if (T:text(i) == 'struct' or T:text(i) == 'class') and T.k[i + 1] == 'id'
                and T:text(i + 2) == '{' and T.m[i + 2] then
                local fields, slots = {}, {}
                for _, span in ipairs(parts(i + 3, T.m[i + 2] - 1, ';')) do
                    local a, z, name, pointer = span[1], span[2]
                    for j = a, z do
                        if T:text(j) == '(' and T:text(j + 1) == '*' and T.k[j + 2] == 'id'
                            and T:text(j + 3) == ')' and T:text(j + 4) == '(' then
                            name, pointer = T:text(j + 2), true; break
                        end
                        if T.k[j] == 'id' then name = T:text(j) end
                    end
                    fields[#fields + 1] = { name = name, pointer = pointer }
                    if pointer then slots[name] = {} end
                end
                local name = T:text(i + 1)
                if structs[name] then structs[name].ambiguous = true
                else structs[name] = { fields = fields, slots = slots } end
            end
        end
        -- Unknown parameters/locals shadow file-scope registries and handler names.
        for _, id in ipairs(ordered) do
            local n = r.nodes[id]
            local p = n.ti
            while p <= n.tj and T:text(p) ~= '(' do p = p + 1 end
            ends[n.ti] = n.tj
            if T.m[p] then
                for _, span in ipairs(parts(p + 1, T.m[p] - 1, ',')) do
                    local j = span[2]
                    if T.k[j] == 'id' and j > span[1] then bind(T:text(j), j, n.ti) end
                end
            end
        end
        for i = 1, T.n - 1 do
            if owners[i] > 0 and T.k[i] == 'id' and (T:text(i + 1) == '=' or T:text(i + 1) == ';') then
                local j = i - 1
                while T:text(j) == '*' or T:text(j) == '&' do j = j - 1 end
                if (T.k[j] == 'id' or T.k[j] == 'kw') and T:text(j) ~= 'return'
                    and (T:text(j - 1) == ';' or T:text(j - 1) == '{') then
                    bind(T:text(i), i, scopes[i])
                end
            end
        end
        for i = 1, T.n - 1 do
            local ty = structs[T:text(i)]
            if ty and not ty.ambiguous and (T.k[i] == 'id') then
                local j = i + 1
                while T:text(j) == '*' or T:text(j) == '&' or T:text(j) == 'const' do j = j + 1 end
                if T.k[j] == 'id' and (T:text(j + 1) == '=' or T:text(j + 1) == ';'
                    or T:text(j + 1) == ',' or T:text(j + 1) == ')' or T:text(j + 1) == '[') then
                    local scope = scopes[j]
                    local owner = owners[j]
                    if owner > 0 then
                        local n = r.nodes[owner]
                        -- Parameter scopes start at the function, not the enclosing file.
                        if scope == scopes[n.ti] then scope = n.ti; ends[scope] = n.tj end
                    end
                    local b = bind(T:text(j), j, scope, { type = ty })
                    local eq = j + 1
                    if T:text(eq) == '[' and T.m[eq] then eq = T.m[eq] + 1; b.array = true end
                    if T:text(eq) == '=' and T:text(eq + 1) == '{' and T.m[eq + 1] then
                        local function row(a, z)
                            for k, span in ipairs(parts(a, z, ',')) do
                                local x, y, field = span[1], span[2], ty.fields[k]
                                if T:text(x) == '.' and T.k[x + 1] == 'id' and T:text(x + 2) == '=' then
                                    field = { name = T:text(x + 1), pointer = ty.slots[T:text(x + 1)] ~= nil }; x = x + 3
                                end
                                if field and field.pointer then register(ty.slots, field.name, x, y, span[1]) end
                            end
                        end
                        if b.array then
                            for _, span in ipairs(parts(eq + 2, T.m[eq + 1] - 1, ',')) do
                                if T:text(span[1]) == '{' and T.m[span[1]] == span[2] then row(span[1] + 1, span[2] - 1) end
                            end
                        else row(eq + 2, T.m[eq + 1] - 1) end
                    end
                end
            end
        end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] ~= 'id' or T:text(i - 1) == '.' or T:text(i - 1) == '->'
            or lua and T:text(i - 1) == ':' then goto continue end
        local b = binding(T:text(i), i)
        if not b or (not b.slots and not b.type and not b.registry) then goto continue end
        if lua and T:text(i + 1) == '=' and i ~= b.token then b.invalid = true end
        local key, tail, dynamic
        local member = i + 1
        if not lua and b.array and T:text(member) == '[' and T.m[member] then member = T.m[member] + 1 end
        if T:text(member) == '.' or not lua and T:text(member) == '->' then
            if T.k[member + 1] == 'id' then key, tail = T:text(member + 1), member + 2 end
        elseif lua and T:text(i + 1) == '[' and T.m[i + 1] then
            local close = T.m[i + 1]
            key = close == i + 3 and literal(T, i + 2) or nil
            tail, dynamic = close + 1, not key
        end
        if not tail then goto continue end
        local registry = b.registry or b
        local slots = registry.slots or b.type.slots
        if lua and T:text(tail) == ',' then
            -- A member in a multiple-assignment LHS cannot retain a proven
            -- registration. Do not attempt to pair its RHS expression.
            if assignment_end(i) then
                if dynamic then registry.invalid = true else slots[key] = { unknown = true } end
            end
        elseif T:text(tail) == '=' then
            if dynamic then registry.invalid = true
            elseif lua or slots[key] then
                local last = tail + 1
                if T:text(last) == '&' then last = last + 1 end
                local next = T:text(last + 1)
                local simple = next == ';' or next == '' or lua and (T.l[last + 1] > T.l[last] or next == 'end')
                if lua and (scopes[i] ~= registry.scope or T:text(i - 1) == ',') then slots[key] = { unknown = true }
                else register(slots, key, tail + 1, simple and last or last + 1, i) end
            end
        elseif lua and T:text(i - 1) == 'function' then slots[key] = nil
        elseif (T:text(tail) == '(' or not lua and T:text(tail) == ')' and T:text(tail + 1) == '('
            and T:text(i - 1) == '*' and T:text(i - 2) == '(' and T.m[i - 2] == tail)
            and owners[i] > 0 and (dynamic or slots[key]) then
            data.sites[#data.sites + 1] = { from = owners[i], line = T:line(i), recv = T:text(i),
                ref_recv = member == i + 1 and T:text(i) or false,
                name = key, binding = b, slots = slots, dynamic = dynamic,
                kind = lua and 'indirect:registry' or 'indirect:fn-pointer' }
        end
        ::continue::
    end
    if loops then require('codeoutline.lua_callback_loops').collect(r, T, {
        binding = binding, parts = parts, scopes = scopes, ends = ends,
        owners = owners, function_target = function_target, assignment_end = assignment_end,
    }) end
    -- Flatten shared temporary tables; no tokens/source survive query parsing.
    for _, site in ipairs(data.sites) do
        local entries = site.name and site.slots[site.name]
        local b, valid, depth = site.binding, true, 0
        while b do
            if b.invalid or depth > 8 then valid = false; break end
            depth = depth + 1
            b = b.alias and binding(b.alias, b.token - 1) or nil
        end
        site.registrations = valid and entries and not entries.unknown and entries or {}
        site.slots, site.binding = nil, nil
    end
    if not r.collect_static_dispatch and not r.ordinary_bindings and not r.ranges then
        local targets, members = {}, {}
        for _, site in ipairs(data.sites) do
            if site.name then members[site_key(site.from, site.line, site.ref_recv, site.name)] = true end
            for _, registration in ipairs(site.registrations) do targets[registration.name] = true end
        end
        r.static_dispatch_candidate = #data.sites > 0 and { targets = targets, members = members } or nil
        r.static_dispatch = nil
    end
end

function M.query(G, report, ctx)
    local graph = require('codeoutline.graph')
    local cache, entries = {}, 0
    local empty = { sites = {} }
    local function remember(f, result)
        entries = entries + 1 + #result.sites
        for _, site in ipairs(result.sites) do entries = entries + #site.registrations end
        assert(entries <= (M.max_query_entries or 100000), 'static dispatch query limit exceeded; narrow the project scope')
        cache[f] = result
        return result
    end
    local function data(f)
        local rec = G.files[f]
        if rec.static_dispatch then return rec.static_dispatch end
        if not rec.static_dispatch_candidate or not G.root then return empty end
        if cache[f] then return cache[f] end
        if ctx and ctx.ordinary then
            local result = ctx.ordinary.data(f).static_dispatch or empty
            return remember(f, result)
        end
        local h = assert(io.open(G.root .. '/' .. rec.path, 'rb'), 'cannot read static dispatch source: ' .. rec.path)
        local raw = h:read('a'); h:close()
        local crc = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
        assert(#raw == rec.size and crc == rec.crc, 'source changed during query; retry: ' .. rec.path)
        local source = raw
        if rec.encoding ~= 'utf-8' and rec.encoding ~= 'utf-8-bom' then
            source = assert(xutils.to_utf8(raw, rec.encoding == 'gbk' and 'gbk' or 'auto'))
        end
        local parsed = require('codeoutline.parse').parse(rec.path, source,
            { ranges = false, dispatch_only = true, static_dispatch = true, language = rec.language })
        assert(#parsed.nodes == #rec.nodes, 'source encoding changed; refresh index: ' .. rec.path)
        for i, n in ipairs(parsed.nodes) do
            assert(n.qualified == rec.nodes[i].qualified and n.line == rec.nodes[i].line, 'source encoding changed; refresh index: ' .. rec.path)
        end
        local result = parsed.static_dispatch or { sites = {} }
        return remember(f, result)
    end
    local function scan(f, only, wanted)
        local result, deps, paired = {}
        for _, site in ipairs(data(f).sites) do
            local src = G.id_of[f][site.from]
            if not only or only == src then
                local seen = {}
                for _, registration in ipairs(site.registrations) do
                    local ids
                    if registration.index then ids = { G.id_of[f][registration.index] }
                    else
                        if not deps then deps, paired = graph.dependencies(G, f) end
                        ids = graph.resolve(G, f, G.id_of[f][registration.from], registration.name, 'call', nil, deps, paired) or {}
                    end
                    for _, id in ipairs(ids) do
                        if not seen[id] and (not wanted or wanted[id]) then
                            seen[id] = true
                            result[src] = result[src] or {}
                            result[src][#result[src] + 1] = { target = id, line = site.line, kind = site.kind }
                            if report then report:add({ source = src, target = id, line = site.line, kind = site.kind,
                                call = site.recv .. '.' .. (site.name or '?'), registered_at = G.files[f].path .. ':' .. registration.line }) end
                        end
                    end
                end
                if report and only and not next(seen) then report:add({ source = src, line = site.line,
                    call = site.recv .. '.' .. (site.name or '?'), reason = site.dynamic and 'dynamic registry key'
                        or 'static registration missing, overwritten or unsupported' }) end
            end
        end
        return result
    end
    return {
        outgoing = function(id) return scan(G.node_file[id], id)[id] or {} end,
        incoming = function(wanted)
            local result = {}
            local names = {}
            for id in pairs(wanted) do names[G.nodes[id].name] = true end
            for _, f in ipairs(G.file_order) do
                control.check()
                local hint = G.files[f].static_dispatch_candidate
                local relevant = G.files[f].static_dispatch ~= nil or hint == true
                if type(hint) == 'table' then
                    for name in pairs(names) do if hint.targets[name] then relevant = true; break end end
                end
                if relevant then
                    for src, edges in pairs(scan(f, nil, wanted)) do result[src] = edges end
                end
            end
            return result
        end,
        handles = function(f, i)
            local refs = G.files[f].refs
            if refs.kind[i] ~= 'member_call' then return false end
            local hint = G.files[f].static_dispatch_candidate
            if type(hint) == 'table' and hint.members then
                return hint.members[site_key(refs.from[i], refs.line[i], refs.recv[i], refs.name[i])] == true
            end
            for _, site in ipairs(data(f).sites) do
                if site.from == refs.from[i] and site.line == refs.line[i] and site.ref_recv == refs.recv[i]
                    and site.name == refs.name[i] then return true end
            end
            return false
        end,
    }
end

return M
