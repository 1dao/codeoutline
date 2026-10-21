-- Query-owned, bounded lexical aliases for explicit dispatch contracts.
-- No execution, basename guesses or persistent binding graph.
local M = {}
local control = require('codeoutline.control')
local member = { ['.'] = true, [':'] = true, ['::'] = true, ['->'] = true }
local supported = { lua = true, javascript = true, typescript = true, python = true, c = true, cpp = true }
local callable = { ['function'] = true, method = true, constructor = true }
local statements = { ['local'] = true, ['function'] = true, ['end'] = true, ['return'] = true,
    ['if'] = true, ['else'] = true, ['elseif'] = true, ['until'] = true, ['for'] = true,
    ['while'] = true, ['do'] = true, ['repeat'] = true, ['break'] = true }

local function quoted(T, i, language)
    local s = T:text(i)
    if T.k[i] == 'str' and language == 'lua' then return require('codeoutline.lua_literal').decode(s) end
    if T.k[i] == 'str' and (s:sub(1, 1) == '"' or s:sub(1, 1) == "'")
        and s:sub(-1) == s:sub(1, 1) and not s:find('[\\$]') then return s:sub(2, -2) end
end

local function name(T, i)
    if T.k[i] ~= 'id' then return nil, i end
    local result = T:text(i)
    i = i + 1
    while member[T:text(i)] and T.k[i + 1] == 'id' do
        result = result .. T:text(i) .. T:text(i + 1); i = i + 2
    end
    return result, i
end

local function simple(T, i, language, symbols_only)
    local start = i
    if T:text(i) == '&' then i = i + 1 end
    local symbol, ending = name(T, i)
    local literal = not symbols_only and quoted(T, i, language)
    if literal then ending = i + 1 end
    if not symbol and not literal then return false end
    local next = T:text(ending)
    local boundary = next == '' or next == ';' or next == '}' or T.k[ending] == 'nl'
        or language == 'lua' and statements[next]
        or T.l[ending] and T.l[ending] > T.l[ending - 1]
            and (T.k[ending] == 'id' or T.k[ending] == 'kw' and next ~= 'and' and next ~= 'or')
    if not boundary then return false end
    return { symbol = symbol, literal = literal, token = start }, ending
end
M.simple = simple

-- Only remember literal service constructors; validate the factory's lexical
-- identity during expansion, after imports, shadowing and writes are known.
local function service_initializer(T, i)
    local factory, open = name(T, i)
    if not factory or T:text(open) ~= '(' or not T.m[open] then return nil end
    local service = quoted(T, open + 1, 'lua')
    if not service or (T:text(open + 2) ~= ',' and open + 2 ~= T.m[open]) then return nil end
    local ending = T.m[open] + 1
    local next = T:text(ending)
    if next ~= '' and next ~= ';' and not statements[next]
        and not (T.l[ending] and T.l[ending] > T.l[ending - 1]
            and (T.k[ending] == 'id' or T.k[ending] == 'kw' and next ~= 'and' and next ~= 'or')) then return nil end
    return { service = service, factory = { symbol = factory }, token = i }
end

local function is_service_factory(value)
    return value and not value.node and (not value.import or value.import.path == 'skynet')
        and (value.symbol == 'skynet.uniqueservice' or value.symbol == 'skynet.newservice')
end

local function initializer(T, i, typed)
    if T:text(i + 1) == '=' then return i + 1 end
    -- C/C++ inline function-pointer declarators, not a call-result expression.
    if T:text(i - 2) == '(' and T:text(i - 1) == '*' and T:text(i + 1) == ')'
        and T:text(i + 2) == '(' and T.m[i + 2] and T:text(T.m[i + 2] + 1) == '=' then
        return T.m[i + 2] + 1
    end
    if typed and T:text(i + 1) == ':' then
        local _, j = name(T, i + 2)
        if T:text(j) == '=' then return j end
    end
end

local function lvalue_end(T, i)
    if T.k[i] ~= 'id' then return nil end
    i = i + 1
    while true do
        if member[T:text(i)] and T.k[i + 1] == 'id' then i = i + 2
        elseif T:text(i) == '[' and T.m[i] then i = T.m[i] + 1
        else return i end
    end
end

-- Import descriptors are syntax only. Lexical declarations and writes below
-- decide whether an import can actually be used at a query site.
local function imports(r, T)
    local result = {}
    if r.language ~= 'lua' and r.language ~= 'javascript' and r.language ~= 'typescript'
        and r.language ~= 'python' then return result end
    local function add(local_name, path, imported, token)
        result[#result + 1] = { name = local_name, path = path, imported = imported, token = token }
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local s = T.k[i] == 'kw' and T:text(i)
        if r.language == 'lua' and s == 'local' and T.k[i + 1] == 'id' and T:text(i + 2) == '='
            and (T:text(i + 3) == 'require' or T:text(i + 3) == 'dofile')
            and (T:text(i + 4) == '(' and T.m[i + 4] == i + 6 and quoted(T, i + 5, 'lua')
                or quoted(T, i + 4, 'lua')) then
            local path = quoted(T, i + 4, 'lua') or quoted(T, i + 5, 'lua')
            add(T:text(i + 1), path, '*', i + 1)
            result[#result].loader = T:text(i + 3)
        elseif (r.language == 'javascript' or r.language == 'typescript') and s == 'import'
            and T:text(i + 1) ~= '(' then
            local j, entries = i + 1, {}
            if T.k[j] == 'id' then entries[#entries + 1] = { T:text(j), 'default', j }; j = j + 1 end
            if T:text(j) == ',' then j = j + 1 end
            if T:text(j) == '*' and T:text(j + 1) == 'as' and T.k[j + 2] == 'id' then
                entries[#entries + 1] = { T:text(j + 2), '*', j + 2 }; j = j + 3
            elseif T:text(j) == '{' and T.m[j] then
                local close = T.m[j]; j = j + 1
                while j < close do
                    if T.k[j] == 'id' then
                        local original, alias, tok = T:text(j), T:text(j), j; j = j + 1
                        if T:text(j) == 'as' and T.k[j + 1] == 'id' then alias, tok, j = T:text(j + 1), j + 1, j + 2 end
                        entries[#entries + 1] = { alias, original, tok }
                    else j = j + 1 end
                end
                j = close + 1
            end
            if T:text(j) == 'from' and quoted(T, j + 1) then
                for _, e in ipairs(entries) do add(e[1], quoted(T, j + 1), e[2], e[3]) end
            end
        elseif r.language == 'python' and s == 'import' and T:text(i - 1) ~= '.' then
            -- A from-import is handled at its `from` token.
            local first = i
            while first > 1 and T.k[first - 1] ~= 'nl' do first = first - 1 end
            if T:text(first) ~= 'from' then
                local j = i + 1
                while T.k[j] == 'id' do
                    local path
                    path, j = name(T, j)
                    if T:text(j) == 'as' and T.k[j + 1] == 'id' then add(T:text(j + 1), path, '*', j + 1)
                        j = j + 2
                    else add(path:match('^[^.]+'), path:match('^[^.]+'), '*', j - 1) end
                    if T:text(j) ~= ',' then break end
                    j = j + 1
                end
            end
        elseif r.language == 'python' and s == 'from' then
            local prefix, j = '', i + 1
            while T:text(j) == '.' or T:text(j) == '...' do prefix = prefix .. T:text(j); j = j + 1 end
            local path
            path, j = name(T, j)
            path = prefix .. (path or '')
            if path == '' then path = nil end
            if path and T:text(j) == 'import' then
                j = j + 1
                if T:text(j) == '(' then j = j + 1 end
                while T.k[j] == 'id' do
                    local original, alias, tok = T:text(j), T:text(j), j; j = j + 1
                    if T:text(j) == 'as' and T.k[j + 1] == 'id' then alias, tok, j = T:text(j + 1), j + 1, j + 2 end
                    add(alias, path, original, tok)
                    if T:text(j) ~= ',' then break end
                    j = j + 1
                end
            end
        end
    end
    return result
end
M.imports = imports

-- Cheap, conservative roots let aliases reach the query parser without
-- performing scope analysis at index time. Existing dispatch_calls stores them.
function M.hints(r, T, calls)
    if not supported[r.language] then return end
    local roots, values = {}, {}
    for call in pairs(calls) do roots[call:match('^([%w_$]+)')] = true end
    local function add(n, v)
        values[n] = values[n] or {}; values[n][#values[n] + 1] = v
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'op' and T:text(i) == '=' then
            local lhs = T.k[i - 1] == 'id' and i - 1
            -- A type annotation may separate the local name from `=`. All
            -- identifier components are conservative roots, not proven bindings.
            if lhs then
                local v = simple(T, i + 1, r.language, true)
                if v and v.symbol then
                    add(T:text(lhs), v.symbol)
                    local j = lhs
                    while j > 2 and T:text(j - 1) == '.' and T.k[j - 2] == 'id' do j = j - 2 end
                    if T:text(j - 1) == ':' and T.k[j - 2] == 'id' then add(T:text(j - 2), v.symbol) end
                end
            elseif T:text(i - 1) == ')' and T.m[i - 1] then
                local p = T.m[i - 1]
                if T:text(p - 1) == ')' and T.k[p - 2] == 'id' and T:text(p - 3) == '*'
                    and T:text(p - 4) == '(' then
                    local v = simple(T, i + 1, r.language, true)
                    if v and v.symbol then add(T:text(p - 2), v.symbol) end
                end
            end
        end
    end
    for _, imp in ipairs(imports(r, T)) do
        if imp.path:match('^[%a_][%w_%.]*$') and not (imp.imported == '*' and imp.name == imp.path) then
            add(imp.name, imp.path .. (imp.imported ~= '*' and '.' .. imp.imported or ''))
        end
    end
    local seen = {}
    local function visit(n, depth)
        if seen[n] and seen[n] <= depth or depth > 8 then return end
        seen[n] = depth
        for _, v in ipairs(values[n] or {}) do
            calls['@' .. v] = true
            visit(v:match('^([%w_$]+)'), depth + 1)
        end
    end
    for n in pairs(roots) do visit(n, 0) end
end

function M.prepare(r, T)
    if not supported[r.language] then return function(v) return v end end
    local lua, python = r.language == 'lua', r.language == 'python'
    local js = r.language == 'javascript' or r.language == 'typescript'
    local scopes, ends, stack = {}, { [0] = T.n }, {}
    local opens = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
    for i = 1, T.n do
        local s = T:text(i)
        if lua and T.k[i] == 'kw' and (s == 'end' or s == 'until') then
            local top = table.remove(stack); if top then ends[top] = i end
        elseif not lua and (python and T.k[i] == 'dedent' or not python and s == '}') then table.remove(stack) end
        scopes[i] = stack[#stack] or 0
        if lua and T.k[i] == 'kw' and opens[s] or python and T.k[i] == 'indent'
            or not lua and not python and s == '{' then
            stack[#stack + 1] = i
            if not lua then ends[i] = T.m[i] or T.n end
        end
    end
    local bindings, imported, callable_declarations = {}, {}, {}
    local function function_scope(at)
        local owner
        for _, n in ipairs(r.nodes) do
            if callable[n.kind] and n.ti <= at and at <= n.tj and (not owner or n.ti > owner.ti) then owner = n end
        end
        return owner and owner.ti or 0, owner and owner.tj or T.n
    end
    local function add(n, token, scope, v, finish)
        local b = { name = n, token = token, scope = scope, finish = finish or ends[scope] or T.n, value = v }
        bindings[n] = bindings[n] or {}; bindings[n][#bindings[n] + 1] = b
        return b
    end
    local function binding(n, at)
        local best
        for _, b in ipairs(bindings[n] or {}) do
            if b.scope <= at and at <= b.finish and (b.token <= at or js or python)
                and (not best or b.scope > best.scope or b.scope == best.scope and b.token > best.token) then best = b end
        end
        return best
    end
    for _, imp in ipairs(imports(r, T)) do
        imported[imp.token] = true
        local scope, finish = scopes[imp.token], nil
        if js then scope = 0 elseif python then scope, finish = function_scope(imp.token) end
        add(imp.name, imp.token, scope, { import = imp, symbol = imp.name }, finish)
    end
    -- Function declarations and all header identifiers provide lexical barriers
    -- for parameters, including unsupported typed/destructured parameter forms.
    for id, n in ipairs(r.nodes) do
        if callable[n.kind] then
            if js and n.kind == 'function' then
                for j = n.ti, math.min(n.tj, n.ti + 4) do
                    local prev = T:text(j - 1)
                    if T:text(j) == n.name and (prev == 'const' or prev == 'let' or prev == 'var') then
                        callable_declarations[j] = id; break
                    end
                end
            end
            local p = n.ti
            while p <= n.tj and T:text(p) ~= '(' and T:text(p) ~= '{' and T:text(p) ~= '=>' do p = p + 1 end
            if T:text(p) == '(' and T.m[p] then
                for j = p + 1, T.m[p] - 1 do if T.k[j] == 'id' then add(T:text(j), j, n.ti, false, n.tj) end end
                if lua then
                    for j = n.ti, p - 1 do
                        if T:text(j) == ':' then add('self', p, n.ti, false, n.tj); break end
                    end
                end
            elseif T:text(p) == '=>' and T.k[p - 1] == 'id' then add(T:text(p - 1), p - 1, n.ti, false, n.tj) end
            -- Locally declared named functions are exact targets, not a global
            -- name-only guess. Lua local functions start at the `local` token.
            if n.qualified == n.name or n.parent and (lua or python) then
                add(n.name, n.ti, scopes[n.ti], { node = id, symbol = n.name })
            end
        end
    end
    local declaration = {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        if js and (word == 'const' or word == 'let' or word == 'var')
            and (T:text(i + 1) == '{' or T:text(i + 1) == '[') and T.m[i + 1] then
            for j = i + 2, T.m[i + 1] - 1 do
                if T.k[j] == 'id' then add(T:text(j), j, scopes[i], false) end
            end
        elseif lua and word == 'local' and T.k[i + 1] == 'id' and T:text(i + 2) == ',' then
            local j = i + 1
            while T.k[j] == 'id' do
                add(T:text(j), j, scopes[i], false)
                if T:text(j + 1) ~= ',' then break end
                j = j + 2
            end
        elseif (lua or python) and word == 'for' then
            local scope, finish
            if lua then
                scope = i + 1
                while scope <= T.n and T:text(scope) ~= 'do' do
                    if T.m[scope] and T.m[scope] > scope then scope = T.m[scope] end
                    scope = scope + 1
                end
                finish = ends[scope]
            else scope, finish = function_scope(i) end
            local j = i + 1
            while T.k[j] == 'id' do
                add(T:text(j), j, scope, false, finish)
                if T:text(j + 1) ~= ',' then break end
                j = j + 2
            end
        elseif python and word == 'as' and T.k[i + 1] == 'id' and not imported[i + 1] then
            local scope, finish = function_scope(i)
            add(T:text(i + 1), i + 1, scope, false, finish)
        elseif not lua and not python and word == 'catch' and T:text(i + 1) == '(' and T.m[i + 1] then
            local close = T.m[i + 1]
            local scope = T:text(close + 1) == '{' and close + 1 or scopes[i]
            for j = i + 2, close - 1 do
                if T.k[j] == 'id' then add(T:text(j), j, scope, false) end
            end
        elseif python and (word == 'global' or word == 'nonlocal' or word == 'del') then
            local j, scope, finish = i + 1, function_scope(i)
            while T.k[j] == 'id' do
                add(T:text(j), j, scope, false, finish)
                if T:text(j + 1) ~= ',' then break end
                j = j + 2
            end
        end
        if T.k[i] == 'id' and not imported[i] then
            local prev, next = T:text(i - 1), T:text(i + 1)
            local eq = initializer(T, i, js)
            local local_decl = lua and prev == 'local' or js and (prev == 'const' or prev == 'let' or prev == 'var')
            if python and (next == '=' or next == ':') and not member[prev] then local_decl = true end
            if (r.language == 'c' or r.language == 'cpp') and eq
                and (T.k[i - 1] == 'id' or T.k[i - 1] == 'kw' or prev == '*') then local_decl = true end
            if (r.language == 'c' or r.language == 'cpp') and (next == ';' or next == ',')
                and (T.k[i - 1] == 'id' or prev == '*') then local_decl = true end
            if local_decl then
                declaration[i] = true
                local scope, finish = scopes[i], nil
                if python or js and prev == 'var' then scope, finish = function_scope(i) end
                local v = eq and simple(T, eq + 1, r.language) or false
                if callable_declarations[i] then v = { node = callable_declarations[i], symbol = T:text(i) } end
                if lua and eq and not v then v = service_initializer(T, eq + 1) or false end
                if lua and eq and T:text(eq + 1) == '{' then v = { namespace = true } end
                local b = add(T:text(i), i, scope, v, finish)
                if python or js and prev == 'var' then
                    for _, other in ipairs(bindings[b.name]) do
                        if other ~= b and other.scope == b.scope then other.invalid, b.invalid = true, true end
                    end
                end
            end
        end
    end
    local service_writes = {}
    -- Any later write poisons that lexical binding for this whole query. This
    -- deliberately avoids inventing execution order across functions/branches.
    for i = 1, T.n do
        if js and (T:text(i) == '{' or T:text(i) == '[') and T.m[i] and T:text(T.m[i] + 1) == '=' then
            for j = i + 1, T.m[i] - 1 do
                local b = T.k[j] == 'id' and binding(T:text(j), i)
                if b then b.invalid = true end
            end
        end
        if T.k[i] == 'id' and not declaration[i] and not imported[i] and not member[T:text(i - 1)] then
            local tail = lvalue_end(T, i)
            local next = T:text(tail)
            local last = tail
            if lua or python then
                while last and T:text(last) == ',' do last = lvalue_end(T, last + 1) end
            end
            if next == '=' or next:match('^[+%-%*/%%&|%^]=') or next == '++' or next == '--'
                or last and T:text(last) == '=' or T:text(i - 1) == '++' or T:text(i - 1) == '--' then
                local b = binding(T:text(i), i)
                if b then b.invalid = true end
                if lua then
                    local name = T:text(i)
                    local value = next == '=' and tail == i + 1 and T:text(i - 1) ~= ','
                        and (service_initializer(T, i + 2) or simple(T, i + 2, 'lua')) or false
                    service_writes[name] = service_writes[name] or {}
                    service_writes[name][#service_writes[name] + 1] = {
                        binding = b, token = i, scope = scopes[i], value = value,
                    }
                end
            end
        end
    end
    local expand
    expand = function(v, at, depth)
        if not v or not v.symbol then return v end
        depth = depth or 0
        if depth > 8 then return false end
        local head, suffix = v.symbol:match('^([%w_$]+)(.*)$')
        local b = binding(head, at)
        -- A single later initialization of a nil/uninitialized handle is useful
        -- for navigation. Keep ordinary aliases poisoned, and require assignment
        -- and use in the same block; no branch or cross-function ordering guesses.
        if suffix == '' and (not b or not b.value) then
            local write
            for _, candidate in ipairs(service_writes[head] or {}) do
                if candidate.binding == b then
                    if write then write = false; break end
                    write = candidate
                end
            end
            if write and write.token < at and write.scope == scopes[at] and write.value then
                local value = write.value
                if value.factory then
                    local factory = expand(value.factory, value.token, depth + 1)
                    if is_service_factory(factory) then
                        return { service = value.service, token = write.token }
                    end
                else
                    local resolved = expand(value, write.token, depth + 1)
                    if resolved and resolved.service then return resolved end
                end
            end
        end
        if not b then return v end
        if b.invalid or not b.value or b.token > at and not b.value.node then return false end
        local target = b.value
        if target.factory then
            if suffix ~= '' then return false end
            local factory = expand(target.factory, target.token, depth + 1)
            if is_service_factory(factory) then
                return { service = target.service, token = b.token }
            end
            return false
        end
        if target.namespace then
            local short = suffix:match('^[%.:]([%w_]+)$')
            if not short then return false end
            b.members = b.members or require('codeoutline.lua_bindings').local_members(r.nodes, scopes,
                b.name, b.token, b.scope, b.finish)
            local id = b.members[short]
            return id and { node = id, symbol = r.nodes[id].qualified } or false
        end
        if target.import then
            local imp = target.import
            if imp.loader and binding(imp.loader, imp.token) then return false end
            if imp.imported == 'default' and suffix ~= '' then return false end
            local part = imp.imported ~= '*' and imp.imported ~= 'default' and imp.imported or ''
            if imp.imported == 'default' then part = 'default' end
            if suffix ~= '' then part = part .. (part == '' and suffix:sub(2) or suffix) end
            local canonical = imp.path:match('^[%a_][%w_%.]*$') and imp.path .. (part ~= '' and '.' .. part or '')
            return { symbol = canonical or v.symbol, import = imp, member = part, token = imp.token }
        end
        if target.node then
            if suffix ~= '' then return false end
            return { symbol = target.symbol, node = target.node, token = b.token }
        end
        if suffix ~= '' then
            if not target.symbol or target.literal then return false end
            return expand({ symbol = target.symbol .. suffix }, b.token - 1, depth + 1)
        end
        return expand(target, b.token - 1, depth + 1)
    end
    return function(v, at) return expand(v, at, 0) end
end

return M
