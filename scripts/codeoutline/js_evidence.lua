-- Token-derived ES module bindings and bounded lexical receiver declarations.
local M = {}
local control = require('codeoutline.control')
local function identifier(T, i) return T.k[i] == 'id' or T:text(i) == 'default' end
local function literal(T, i)
    if T.k[i] ~= 'str' then return nil end
    local s = T:text(i)
    if s:find('\\', 1, true) then return nil end
    return s:sub(2, -2)
end
local function type_name(T, i)
    if T.k[i] ~= 'id' then return nil end
    local name = T:text(i)
    if T:text(i + 1) == '.' and T.k[i + 2] == 'id' then return name .. '.' .. T:text(i + 2), i + 3 end
    return name, i + 1
end

function M.collect(r, T)
    if r.language ~= 'javascript' and r.language ~= 'typescript' and r.language ~= 'arkts' then return end
    r.js_imports, r.js_exports = {}, {}
    local skip = {}
    local function export(name, local_name, path)
        r.js_exports[#r.js_exports + 1] = { name = name, local_name = local_name, path = path }
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        if (word == 'import' or word == 'export') and T.k[i] == 'kw' then
            local x = i + 1
            if T:text(x) == 'type' then x = x + 1 end
            if T:text(x) ~= '(' then
                local entries, star = {}, false
                if word == 'import' and T.k[x] == 'id' then
                    entries[#entries + 1] = { local_name = T:text(x), imported = 'default' }; x = x + 1
                    if T:text(x) == ',' then x = x + 1 end
                end
                if T:text(x) == '*' then
                    star = true; x = x + 1
                    if T:text(x) == 'as' and T.k[x + 1] == 'id' then
                        entries[#entries + 1] = { local_name = T:text(x + 1), imported = '*' }; x = x + 2
                    end
                elseif T:text(x) == '{' and T.m[x] then
                    local close = T.m[x]; x = x + 1
                    while x < close do
                        if T:text(x) == 'type' and identifier(T, x + 1) then x = x + 1 end
                        if identifier(T, x) then
                            local original, alias = T:text(x), T:text(x); x = x + 1
                            if T:text(x) == 'as' and identifier(T, x + 1) then alias = T:text(x + 1); x = x + 2 end
                            entries[#entries + 1] = { local_name = alias, imported = original }
                        else x = x + 1 end
                    end
                    x = close + 1
                end
                local path = T:text(x) == 'from' and literal(T, x + 1) or nil
                if word == 'import' and path then
                    for _, entry in ipairs(entries) do entry.path = path; r.js_imports[#r.js_imports + 1] = entry end
                    for n = i, x + 1 do skip[n] = true end
                elseif word == 'export' then
                    for _, entry in ipairs(entries) do export(entry.local_name, entry.imported, path) end
                    if star and #entries == 0 and path then export('*', '*', path) end
                    if #entries > 0 or star then for n = i, x do skip[n] = true end end
                    if T:text(i + 1) == 'default' and T.k[i + 2] == 'id' then export('default', T:text(i + 2)) end
                end
            end
        end
    end
    for _, n in ipairs(r.nodes) do
        if not n.parent then
            local a = n.ti
            -- Variable nodes may begin at the binding rather than `export const`.
            while a > 1 and T.l[a - 1] == T.l[n.ti] and
                (T:text(a - 1) == 'const' or T:text(a - 1) == 'let' or T:text(a - 1) == 'var'
                    or T:text(a - 1) == 'export' or T:text(a - 1) == 'default' or T:text(a - 1) == 'async') do a = a - 1 end
            if T:text(a) == 'export' then export(T:text(a + 1) == 'default' and 'default' or n.name, n.name) end
        end
    end

    -- Braces provide block lifetime; node ranges extend parameter bindings to bodies.
    local scopes, stack = {}, {}
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    local bindings, parameters, alias_tokens = {}, {}, {}
    local callable_at = {}
    for _, n in ipairs(r.nodes) do
        if n.kind == 'function' or n.kind == 'method' or n.kind == 'constructor' then
            for i = n.ti, n.tj do
                if T:text(i) == '(' and T.m[i] then
                    local j, close = i + 1, T.m[i]
                    while j < close do
                        if T.k[j] == 'id' and (j == i + 1 or T:text(j - 1) == ',') then parameters[j] = true end
                        if T.m[j] and T.m[j] > j then j = T.m[j] end
                        j = j + 1
                    end
                    break
                elseif T:text(i) == '{' then break end
            end
        end
    end
    local function scope_for(i, parameter)
        if parameter then
            local best
            for _, n in ipairs(r.nodes) do
                if (n.kind == 'function' or n.kind == 'method' or n.kind == 'constructor') and n.ti <= i and n.tj >= i
                    and (not best or n.tj - n.ti < best.tj - best.ti) then best = n end
            end
            if best then return best.ti, best.tj end
        end
        local s = scopes[i]
        return s, s > 0 and T.m[s] or T.n
    end
    for index, n in ipairs(r.nodes) do
        if n.kind == 'function' then
            for i = n.ti, math.min(n.tj, n.ti + 5) do
                if T:text(i) == n.name and (T:text(i - 1) == 'function' or T:text(i - 1) == 'const'
                    or T:text(i - 1) == 'let' or T:text(i - 1) == 'var') then
                    callable_at[i] = index
                    if T:text(i - 1) == 'function' then
                        local a, b = scope_for(n.ti)
                        bindings[#bindings + 1] = { name = n.name, type = '?', token = i, a = a, b = b,
                            declaration = true, target = index, hoisted = true }
                    end
                    break
                end
            end
        end
    end
    for i = 1, T.n do
        if T.k[i] == 'id' and not skip[i] then
            local prev, next = T:text(i - 1), T:text(i + 1)
            local declaration = prev == 'const' or prev == 'let' or prev == 'var'
            local parameter = parameters[i]
            local assignment = next == '=' and prev ~= '.' and prev ~= '?.'
            if declaration or parameter or assignment then
                local typ, after
                if next == ':' then
                    typ, after = type_name(T, i + 2)
                    -- Union/array/generic types require more than a simple type name.
                    if after and T:text(after) ~= '=' and T:text(after) ~= ',' and T:text(after) ~= ')' and T:text(after) ~= ';' then typ = nil end
                elseif next == '=' and T:text(i + 2) == 'new' then typ = type_name(T, i + 3) end
                local a, b = scope_for(i, parameter)
                local eq = next == '=' and i + 1 or after
                if r.ordinary_bindings and declaration and eq and T:text(eq) == '=' and T.k[eq + 1] == 'id' then
                    alias_tokens[i] = require('codeoutline.dispatch_aliases').simple(T, eq + 1, r.language, true) and 'simple' or true
                end
                bindings[#bindings + 1] = { name = T:text(i), type = typ or '?', token = i, a = a, b = b,
                    declaration = declaration or parameter, target = declaration and callable_at[i] or nil }
            end
        end
    end
    local by_name = {}
    for _, binding in ipairs(bindings) do
        by_name[binding.name] = by_name[binding.name] or {}
        by_name[binding.name][#by_name[binding.name] + 1] = binding
    end
    -- Reuse dispatch's bounded lexical validation in explicit query parses.
    -- Ordinary indexing leaves this extra evidence ungenerated.
    local expand
    local function alias_evidence(name, at, token)
        if alias_tokens[token] ~= 'simple' then return '?' end
        expand = expand or require('codeoutline.dispatch_aliases').prepare(r, T)
        local v = expand({ symbol = name }, at)
        if v and v.node then return 'node:' .. v.node end
        if v and v.import then return 'import:' .. v.import.path .. '\0' .. v.member end
        return '?'
    end
    for index, ref in ipairs(r.refs) do
        if index % 128 == 0 then control.check() end
        local target = ref.recv or ref.name
        local best
        for _, binding in ipairs(by_name[target] or {}) do
            if binding.name == target and binding.a <= ref.tok and binding.b >= ref.tok
                and (binding.token <= ref.tok or binding.declaration) then
                if not best or binding.b - binding.a < best.b - best.a
                    or (binding.a == best.a and binding.b == best.b and binding.token > best.token and binding.token <= ref.tok) then best = binding end
            end
        end
        if best then
            if not ref.recv and alias_tokens[best.token] then ref.js_receiver = alias_evidence(ref.name, ref.tok, best.token)
            elseif not ref.recv and best.target and (best.token <= ref.tok or best.hoisted) then ref.js_receiver = 'node:' .. best.target
            else ref.js_receiver = ref.recv and best.token <= ref.tok and best.type or '?' end
        end
        if ref.kind == 'member_call' and (not ref.recv or T:text(ref.tok - 3) == '.' or T:text(ref.tok - 3) == '?.') then
            ref.js_receiver = '?' -- A field/call-result chain is not the local variable sharing its tail.
        end
    end
    if next(alias_tokens) then
        for _, e in ipairs(r.js_exports) do
            if not e.path then
                for _, b in ipairs(by_name[e.local_name] or {}) do
                    if b.a == 0 and alias_tokens[b.token] then
                        e.binding = alias_evidence(e.local_name, T.n, b.token)
                        break
                    end
                end
            end
        end
    end
end

return M
