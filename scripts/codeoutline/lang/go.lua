-- lang/go.lua — index-level Go parser: package, imports, functions, methods
-- (receiver type as the qualifier), generics, struct types (+ fields,
-- embedded types), interfaces (+ method sets), type aliases/definitions,
-- top-level var/const, and calls.
--
-- Go statements end at newlines, so specs and members are split with
-- stmt_end(): a statement runs to the end of its line, extended across any
-- bracket group that spans lines.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.config = {
    keywords = {
        'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else', 'fallthrough',
        'for', 'func', 'go', 'goto', 'if', 'import', 'interface', 'map', 'package', 'range',
        'return', 'select', 'struct', 'switch', 'type', 'var',
    },
    ops = {
        '<-', ':=', '...', '&&', '||', '==', '!=', '<=', '>=', '<<', '>>', '&^', '++', '--',
        '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '&^=',
    },
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = {
        { '"', '"', escape = '\\' },
        { "'", "'", escape = '\\' },
        { '`', '`', multiline = true },
    },
}

M.lang = xscan.lang(M.config)

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

-- Last token of the statement starting at x (bounded by b).
local function stmt_end(T, x, b)
    local y = x
    while true do
        if T.m[y] and T.m[y] > y and T.m[y] <= b then y = T.m[y] end
        if y + 1 <= b and T.l[y + 1] == T.el[y] and not is(T, y + 1, ';') then
            y = y + 1
        else
            return y
        end
    end
end

-- Body '{' of a func whose parameter list closes at p, or nil when the
-- declaration has none. `struct{..}` / `interface{..}` in the result type
-- are type literals, not the body.
local function func_body(T, p, b)
    local x = p + 1
    while x <= b do
        if is(T, x, '{') then
            if not (kw(T, x - 1, 'struct') or kw(T, x - 1, 'interface')) then return x end
            x = (T.m[x] or x) + 1
        elseif (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x] + 1
        elseif T.l[x] ~= T.el[x - 1] or is(T, x, ';') then
            return nil                          -- result type ended at the line break
        else
            x = x + 1
        end
    end
    return nil
end

-- Receiver `(r *T)` / `(T[K])` -> type name.
local function receiver_type(T, o, c)
    local name
    for x = o + 1, c - 1 do
        if is(T, x, '[') then break end
        if T.k[x] == 'id' then name = T:text(x) end
    end
    return name
end

-- Struct fields / interface methods between '{' o and '}' c.
local function type_members(T, r, o, c, parent, is_interface)
    local x = o + 1
    while x < c do
        if is(T, x, ';') then
            x = x + 1
        else
            local first, last = x, stmt_end(T, x, c - 1)
            if T.k[first] == 'id' then
                if is_interface then
                    if is(T, first + 1, '(') then
                        common.add_node(r, T, { kind = 'method', name = T:text(first), ni = first, parent = parent,
                            ti = first, tj = last, sig = common.sig(T, first, last), abstract = true })
                    end
                else
                    -- `A, B Type`; a lone `Type` / `pkg.Type` (+ tag) is embedded
                    local names, z = {}, first
                    while T.k[z] == 'id' do
                        names[#names + 1] = z
                        if is(T, z + 1, ',') then z = z + 2 else break end
                    end
                    local embedded = #names == 1 and (last == first or is(T, first + 1, '.')
                        or (last == first + 1 and T.k[last] == 'str'))
                    if embedded then
                        local e = is(T, first + 1, '.') and first + 2 or first
                        common.add_node(r, T, { kind = 'field', name = T:text(e), ni = e, parent = parent,
                            ti = first, tj = last, sig = common.sig(T, first, last), embedded = true })
                    else
                        for _, nz in ipairs(names) do
                            common.add_node(r, T, { kind = 'field', name = T:text(nz), ni = nz, parent = parent,
                                ti = nz, tj = last, sig = common.sig(T, first, last) })
                        end
                    end
                end
            elseif is(T, first, '*') and T.k[first + 1] == 'id' and not is_interface then
                local e = is(T, first + 2, '.') and first + 3 or first + 1
                common.add_node(r, T, { kind = 'field', name = T:text(e), ni = e, parent = parent,
                    ti = first, tj = last, embedded = true })
            end
            x = last + 1
        end
    end
end

-- One type spec at name token x; start is the `type` keyword for the
-- single form. Returns the next index.
local function type_spec(T, r, x, b, start)
    local y = x + 1
    if is(T, y, '[') and T.m[y] then y = T.m[y] + 1 end       -- type parameters
    if is(T, y, '=') then y = y + 1 end                         -- alias
    local kind, body = 'typedef', nil
    if kw(T, y, 'struct') and is(T, y + 1, '{') then
        kind, body = 'struct', y + 1
    elseif kw(T, y, 'interface') and is(T, y + 1, '{') then
        kind, body = 'interface', y + 1
    end
    local stop = body and (T.m[body] or b) or stmt_end(T, x, b)
    local node = common.add_node(r, T, {
        kind = kind, name = T:text(x), ni = x, ti = start or x, tj = stop,
        sig = common.sig(T, start or x, body and body - 1 or stop, 160),
    })
    if body then type_members(T, r, body, stop, node, kind == 'interface') end
    return stop + 1
end

-- var/const specs in [a, b]: one per statement, `a, b = ...` names each.
local function value_specs(T, r, a, b, kind)
    local x = a
    while x <= b do
        local last = stmt_end(T, x, b)
        local z = x
        while T.k[z] == 'id' and z <= last do
            common.add_node(r, T, { kind = kind, name = T:text(z), ni = z, ti = z, tj = last,
                sig = common.sig(T, x, last, 120) })
            if is(T, z + 1, ',') then z = z + 2 else break end
        end
        common.add_calls(r, T, x, last)
        x = last + 1
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'go', opts)
    local i, n = 1, T.n
    while i <= n do
        if kw(T, i, 'package') and T.k[i + 1] == 'id' then
            r.package = T:text(i + 1)
            i = i + 2
        elseif kw(T, i, 'import') then
            local stop = (is(T, i + 1, '(') and T.m[i + 1]) or stmt_end(T, i, n)
            for x = i + 1, stop do
                if T.k[x] == 'str' then
                    r.imports[#r.imports + 1] = { path = T:text(x):sub(2, -2), line = T:line(x),
                        alias = (T.k[x - 1] == 'id' or is(T, x - 1, '.')) and T:text(x - 1) or nil }
                end
            end
            i = stop + 1
        elseif kw(T, i, 'func') then
            local x = i + 1
            local recv
            if is(T, x, '(') and T.m[x] then
                recv = receiver_type(T, x, T.m[x])
                x = T.m[x] + 1
            end
            local p = x + 1
            if is(T, p, '[') and T.m[p] then p = T.m[p] + 1 end   -- type parameters
            if T.k[x] == 'id' and is(T, p, '(') and T.m[p] then
                local pc = T.m[p]
                local body = func_body(T, pc, n)
                local close = body and (T.m[body] or n) or pc
                local node = common.add_node(r, T, {
                    kind = recv and 'method' or 'function', name = T:text(x), ni = x, ti = i, tj = close,
                    sig = common.sig(T, i, body and body - 1 or pc, 200), recv = recv,
                })
                if recv then r.nodes[node].qualified = recv .. '.' .. T:text(x) end
                if body then common.add_calls(r, T, body, close) end
                i = close + 1
            else
                i = x                                   -- func literal / type: not a declaration
            end
        elseif kw(T, i, 'type') then
            if is(T, i + 1, '(') and T.m[i + 1] then
                local c = T.m[i + 1]
                local x = i + 2
                while x < c do
                    if T.k[x] == 'id' then x = type_spec(T, r, x, c - 1) else x = x + 1 end
                end
                i = c + 1
            elseif T.k[i + 1] == 'id' then
                i = type_spec(T, r, i + 1, n, i)
            else
                i = i + 1
            end
        elseif kw(T, i, 'var') or kw(T, i, 'const') then
            local kind = kw(T, i, 'const') and 'constant' or 'variable'
            if is(T, i + 1, '(') and T.m[i + 1] then
                value_specs(T, r, i + 2, T.m[i + 1] - 1, kind)
                i = T.m[i + 1] + 1
            else
                local last = stmt_end(T, i, n)
                value_specs(T, r, i + 1, last, kind)
                i = last + 1
            end
        else
            i = i + 1
        end
    end
    return common.finish(r), T
end

return M
