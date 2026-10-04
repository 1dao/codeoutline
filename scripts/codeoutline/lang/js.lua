-- lang/js.lua — index-level JavaScript / TypeScript parser: functions,
-- arrow functions bound to names, classes (+ members: methods, accessors,
-- fields, constructors), TS interfaces, type aliases, enums, namespaces,
-- `a.b = function` assignments, module-level constants, ES imports /
-- require(), and calls.
--
-- JS has automatic semicolon insertion, so instead of statement parsing the
-- file is scanned for definition patterns at any depth; ranges come from
-- the bracket match table and nesting from containing ranges.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

-- Reserved words only: contextual ones (type, get, set, async, of, as,
-- static, declare, readonly...) stay identifiers because code uses them as
-- names (`node.type`, `map.get(k)`); the parser checks their text instead.
M.config = {
    keywords = {
        'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger', 'default', 'delete',
        'do', 'else', 'enum', 'export', 'extends', 'false', 'finally', 'for', 'function', 'if',
        'import', 'in', 'instanceof', 'let', 'new', 'null', 'return', 'super', 'switch', 'this',
        'throw', 'true', 'try', 'typeof', 'var', 'void', 'while', 'with', 'yield',
    },
    ops = {
        '>>>=', '...', '===', '!==', '**=', '&&=', '||=', '??=', '<<=', '>>=', '>>>', '=>', '?.',
        '??', '**', '==', '!=', '<=', '>=', '&&', '||', '++', '--', '+=', '-=', '*=', '/=', '%=',
        '&=', '|=', '^=', '<<', '>>',
    },
    ident_start = 'A-Za-z_$',
    ident_char = 'A-Za-z0-9_$',
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
    template_literals = true,
    regex_literals = true,
}

M.lang = xscan.lang(M.config)

local MODIFIERS = {
    static = true, async = true, get = true, set = true, public = true, private = true,
    protected = true, readonly = true, abstract = true, override = true, declare = true,
    accessor = true, export = true, default = true,
}

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end
local function word(T, i, s) return (T.k[i] == 'id' or T.k[i] == 'kw') and T:text(i) == s end

-- Skip a TS generic parameter list at '<' i; returns the next index.
local function skip_angle(T, i, limit)
    if not is(T, i, '<') then return i end
    local d, x = 0, i
    while x <= limit do
        local t = T.k[x] == 'op' and T:text(x)
        if t == '<' then d = d + 1
        elseif t == '>' then d = d - 1
        elseif t == '>>' then d = d - 2
        elseif t == '>>>' then d = d - 3
        elseif t == '=>' then -- arrow inside a generic default: keep going
        elseif (t == '(' or t == '[' or t == '{') and T.m[x] then x = T.m[x] end
        if d <= 0 then return x + 1 end
        x = x + 1
    end
    return i + 1
end

-- The body '{' after a parameter list closing at p (skipping a TS return
-- type annotation), or nil when there is none (overload / abstract / sig).
-- A '{' directly after ':' '|' '&' '<' ',' is an object type, not a body.
local TYPE_BEFORE = { [':'] = true, ['|'] = true, ['&'] = true, ['<'] = true, [','] = true, ['=>'] = false }
local function body_after(T, p, limit)
    local x = p + 1
    while x <= limit do
        if is(T, x, '{') then
            local prev = T.k[x - 1] == 'op' and T:text(x - 1)
            if prev and TYPE_BEFORE[prev] then
                x = (T.m[x] or x) + 1
            else
                return x
            end
        elseif is(T, x, ';') or is(T, x, '}') or is(T, x, ',') and x > p + 1 then
            return nil
        elseif (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x] + 1
        elseif is(T, x, '<') then
            x = skip_angle(T, x, limit)
        elseif is(T, x, '=>') then
            return nil                              -- `): Type => ...` is not a declaration head
        elseif T.l[x] ~= T.el[x - 1] and not is(T, x - 1, ':') and not is(T, x - 1, '|')
            and not is(T, x, '|') and not is(T, x, '&') and not is(T, x, '.') then
            return nil                              -- next line starts something else (ASI)
        else
            x = x + 1
        end
    end
    return nil
end

-- End of an expression-bodied statement starting at x: ';' or the line end
-- at bracket depth 0 (ASI), extended across groups and trailing operators.
local CONT = { ['.'] = true, ['?.'] = true, ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true,
    ['&&'] = true, ['||'] = true, ['??'] = true, ['?'] = true, [':'] = true, [','] = true, ['='] = true,
    ['=>'] = true, ['|'] = true, ['&'] = true }
local function expr_end(T, x, limit)
    local y = x
    while y <= limit do
        if T.m[y] and T.m[y] > y then y = T.m[y] end
        local nx = y + 1
        if nx > limit or is(T, nx, ';') or is(T, nx, '}') or is(T, nx, ')') or is(T, nx, ']') then return y end
        if is(T, nx, ',') and T.l[nx] == T.el[y] then return y end
        if T.l[nx] ~= T.el[y] then
            local contd = (T.k[y] == 'op' and CONT[T:text(y)]) or (T.k[nx] == 'op' and CONT[T:text(nx)])
            if not contd then return y end
        end
        y = nx
    end
    return limit
end

-- Arrow function / function expression starting at x (after '=' or ':')?
-- Returns the token range [x, stop] of the function, or nil.
local function func_expr(T, x, limit)
    local y = x
    if word(T, y, 'async') then y = y + 1 end
    if kw(T, y, 'function') then
        local p = y + 1
        if is(T, p, '*') then p = p + 1 end
        if T.k[p] == 'id' then p = p + 1 end
        p = skip_angle(T, p, limit)
        if is(T, p, '(') and T.m[p] then
            local b = body_after(T, T.m[p], limit)
            if b then return x, T.m[b] or limit, b end
        end
        return nil
    end
    y = skip_angle(T, y, limit)
    local arrow
    if is(T, y, '(') and T.m[y] then
        arrow = T.m[y] + 1
        if is(T, arrow, ':') then                    -- (x): T => ...
            local z = arrow + 1
            while z <= limit and not is(T, z, '=>') and not is(T, z, ';') and T.l[z] == T.l[arrow] do
                z = (T.m[z] and T.m[z] > z) and T.m[z] + 1 or z + 1
            end
            arrow = z
        end
    elseif T.k[y] == 'id' then
        arrow = y + 1
    end
    if arrow and is(T, arrow, '=>') then
        if is(T, arrow + 1, '{') and T.m[arrow + 1] then return x, T.m[arrow + 1], arrow + 1 end
        return x, expr_end(T, arrow + 1, limit), arrow + 1
    end
    return nil
end

local parse_class_body

-- Scan [a, b] for definitions; `parent` is the enclosing node (if any).
local function scan(T, r, a, b, parent, defs, stem)
    local i = a
    while i <= b do
        local k, t = T.k[i], T:text(i)
        local handled = false
        if k == 'kw' and t == 'function' then
            local p = i + 1
            if is(T, p, '*') then p = p + 1 end
            if T.k[p] == 'id' then
                local name_tok = p
                p = skip_angle(T, p + 1, b)
                if is(T, p, '(') and T.m[p] then
                    local body = body_after(T, T.m[p], b)
                    local start = i
                    while start > a and (word(T, start - 1, 'async') or kw(T, start - 1, 'export')
                        or kw(T, start - 1, 'default') or word(T, start - 1, 'declare')) do start = start - 1 end
                    local close = body and (T.m[body] or b) or T.m[p]
                    defs[name_tok] = true
                    local node = common.add_node(r, T, { kind = 'function', name = T:text(name_tok), ni = name_tok, parent = parent,
                        ti = start, tj = close, sig = common.sig(T, start, body and body - 1 or T.m[p], 200) })
                    if body then scan(T, r, body + 1, close - 1, node, defs, stem) end
                    i = close + 1
                    handled = true
                end
            end
        elseif (k == 'kw' and t == 'class' and (T.k[i + 1] == 'id' or kw(T, i + 1, 'extends') or is(T, i + 1, '{'))
            and not is(T, i - 1, '.') and not is(T, i - 1, '<'))       -- not JSX `class="..."`
            or ((t == 'interface') and k == 'id' and T.k[i + 1] == 'id') then
            local name_tok = T.k[i + 1] == 'id' and i + 1 or nil
            if name_tok and T:text(name_tok) == 'extends' then name_tok = nil end
            local x = i + 1
            while x <= b and not is(T, x, '{') do
                if (is(T, x, '(') or is(T, x, '[')) and T.m[x] then x = T.m[x] end
                if is(T, x, ';') then break end
                x = x + 1
            end
            if is(T, x, '{') and T.m[x] and (name_tok or not is(T, i - 1, '=')) then
                local start = i
                while start > a and (kw(T, start - 1, 'export') or kw(T, start - 1, 'default')
                    or word(T, start - 1, 'abstract') or word(T, start - 1, 'declare')) do start = start - 1 end
                local extends, implements = {}, {}
                local mode
                for y = (name_tok or i) + 1, x - 1 do
                    if kw(T, y, 'extends') then mode = extends
                    elseif word(T, y, 'implements') then mode = implements
                    elseif mode and T.k[y] == 'id' and not is(T, y - 1, '.') and not is(T, y - 1, '<') then
                        local nm, z = T:text(y), y
                        while is(T, z + 1, '.') and T.k[z + 2] == 'id' do nm = nm .. '.' .. T:text(z + 2); z = z + 2 end
                        mode[#mode + 1] = nm
                    end
                end
                local kind = t == 'class' and 'class' or 'interface'
                local node = common.add_node(r, T, {
                    kind = kind, name = name_tok and T:text(name_tok) or (is(T, i - 1, '=') and T:text(i - 2)) or 'default',
                    ni = name_tok or i,
                    parent = parent, ti = start, tj = T.m[x], sig = common.sig(T, start, x - 1, 200),
                    extends = #extends > 0 and extends or nil, implements = #implements > 0 and implements or nil,
                })
                if name_tok then defs[name_tok] = true end
                parse_class_body(T, r, x, T.m[x], node, defs, stem)
                i = T.m[x] + 1
                handled = true
            end
        elseif k == 'kw' and t == 'enum' and T.k[i + 1] == 'id' and is(T, i + 2, '{') and T.m[i + 2] then
            local c = T.m[i + 2]
            local node = common.add_node(r, T, { kind = 'enum', name = T:text(i + 1), ni = i + 1, parent = parent, ti = i, tj = c })
            local x = i + 3
            while x < c do
                if T.k[x] == 'id' or T.k[x] == 'str' then
                    local nm = T.k[x] == 'str' and T:text(x):sub(2, -2) or T:text(x)
                    common.add_node(r, T, { kind = 'enum_member', name = nm, ni = x, parent = node, ti = x, tj = x })
                end
                while x < c and not is(T, x, ',') do x = (T.m[x] and T.m[x] > x) and T.m[x] + 1 or x + 1 end
                x = x + 1
            end
            i = c + 1
            handled = true
        elseif k == 'id' and t == 'type' and T.k[i + 1] == 'id' and (is(T, i + 2, '=') or is(T, i + 2, '<'))
            and not is(T, i - 1, '.') then
            local y = skip_angle(T, i + 2, b)
            if is(T, y, '=') then
                local stop = expr_end(T, y + 1, b)
                common.add_node(r, T, { kind = 'typedef', name = T:text(i + 1), ni = i + 1, parent = parent, ti = i, tj = stop,
                    sig = common.sig(T, i, stop, 160) })
                i = stop + 1
                handled = true
            end
        elseif k == 'id' and (t == 'namespace' or t == 'module') and (T.k[i + 1] == 'id' or T.k[i + 1] == 'str')
            and not is(T, i - 1, '.') then
            local x = i + 1
            while x <= b and (T.k[x] == 'id' or is(T, x, '.') or T.k[x] == 'str') do x = x + 1 end
            if is(T, x, '{') and T.m[x] then
                local nm = common.sig(T, i + 1, x - 1):gsub('%s', ''):gsub('^["\']', ''):gsub('["\']$', '')
                local node = common.add_node(r, T, { kind = 'namespace', name = nm, ni = i + 1, nj = x - 1, parent = parent, ti = i, tj = T.m[x] })
                scan(T, r, x + 1, T.m[x] - 1, node, defs, stem)
                i = T.m[x] + 1
                handled = true
            end
        elseif k == 'kw' and (t == 'const' or t == 'let' or t == 'var') and T.k[i + 1] == 'id' then
            -- const name = <function|arrow|value>; destructuring is skipped
            local name_tok = i + 1
            local y = name_tok + 1
            if is(T, y, ':') then                          -- const x: Type = ...
                y = y + 1
                while y <= b and not is(T, y, '=') and not is(T, y, ';') and T.l[y] == T.l[name_tok] do
                    y = (T.m[y] and T.m[y] > y) and T.m[y] + 1 or (is(T, y, '<') and skip_angle(T, y, b) or y + 1)
                end
            end
            if is(T, y, '=') then
                local fs, fe, fb = func_expr(T, y + 1, b)
                local start = kw(T, i - 1, 'export') and i - 1 or i
                if fs then
                    defs[name_tok] = true
                    local node = common.add_node(r, T, { kind = 'function', name = T:text(name_tok), ni = name_tok, parent = parent,
                        ti = start, tj = fe, sig = common.sig(T, start, math.max(fb - 1, name_tok), 200) })
                    if fb and is(T, fb, '{') then scan(T, r, fb + 1, fe - 1, node, defs, stem) end
                    i = fe + 1
                    handled = true
                elseif not parent then
                    local stop = expr_end(T, y + 1, b)
                    defs[name_tok] = true
                    common.add_node(r, T, { kind = 'variable', name = T:text(name_tok), ni = name_tok, ti = start, tj = stop,
                        sig = common.sig(T, start, math.min(stop, y + 1), 120) })
                    -- keep scanning inside the initializer (object literals with functions, IIFEs)
                end
            end
        elseif k == 'id' and is(T, i + 1, ':') and (is(T, i - 1, '{') or is(T, i - 1, ',')) and not defs[i]
            and func_expr(T, i + 2, b) then
            -- object literal property: { key: function () {}, other: (x) => {} }
            local fs, fe, fb = func_expr(T, i + 2, b)
            defs[i] = true
            local node = common.add_node(r, T, { kind = 'function', name = t, parent = parent,
                ti = i, tj = fe, sig = common.sig(T, i, math.max(fb - 1, i), 200) })
            if is(T, fb, '{') then scan(T, r, fb + 1, fe - 1, node, defs, stem) end
            i = fe + 1
            handled = true
        elseif k == 'id' and not defs[i] and (is(T, i + 1, '(') or is(T, i + 1, '<'))
            and (is(T, i - 1, '{') or is(T, i - 1, ',')
                or ((word(T, i - 1, 'async') or word(T, i - 1, 'get') or word(T, i - 1, 'set') or is(T, i - 1, '*'))
                    and (is(T, i - 2, '{') or is(T, i - 2, ','))))
            and (function()
                local p = skip_angle(T, i + 1, b)
                if not (is(T, p, '(') and T.m[p]) then return false end
                local body = body_after(T, T.m[p], b)
                return body and T.l[body] == T.el[T.m[p]]
            end)() then
            -- object literal method shorthand: { fetch(req) { ... } }
            local p = skip_angle(T, i + 1, b)
            local body = body_after(T, T.m[p], b)
            local close = T.m[body] or b
            defs[i] = true
            local node = common.add_node(r, T, { kind = 'method', name = t, parent = parent,
                ti = i, tj = close, sig = common.sig(T, i, body - 1, 200) })
            scan(T, r, body + 1, close - 1, node, defs, stem)
            i = close + 1
            handled = true
        elseif k == 'id' and is(T, i + 1, '=') and is(T, i - 1, '.') and not defs[i] then
            -- a.b.c = function / arrow (exports.x = ..., Foo.prototype.bar = ...)
            local fs, fe, fb = func_expr(T, i + 2, b)
            if fs then
                local parts, y = { T:text(i) }, i
                while is(T, y - 1, '.') and (T.k[y - 2] == 'id' or T.k[y - 2] == 'kw') do
                    table.insert(parts, 1, T:text(y - 2))
                    y = y - 2
                end
                defs[i] = true
                local node = common.add_node(r, T, { kind = 'function', name = T:text(i), ni = i, parent = parent,
                    ti = y, tj = fe, sig = common.sig(T, y, math.max(fb - 1, i), 200) })
                r.nodes[node].qualified = table.concat(parts, '.')
                if fb and is(T, fb, '{') then scan(T, r, fb + 1, fe - 1, node, defs, stem) end
                i = fe + 1
                handled = true
            end
        elseif (k == 'kw' and t == 'import') or (k == 'kw' and t == 'export') then
            -- import x from 'm' / import 'm' / export ... from 'm'
            local x = i + 1
            local stop = math.min(b, i + 400)
            if is(T, x, '(') and T.k[x + 1] == 'str' then
                r.imports[#r.imports + 1] = { path = T:text(x + 1):sub(2, -2), line = T:line(i), dynamic = true }
            else
                while x <= stop do
                    if T.k[x] == 'str' and (k == 'kw' and t == 'import' and x == i + 1 or word(T, x - 1, 'from')) then
                        r.imports[#r.imports + 1] = { path = T:text(x):sub(2, -2), line = T:line(i) }
                        break
                    end
                    if is(T, x, ';') or (T.l[x] ~= T.l[i] and not (is(T, x - 1, ',') or is(T, x - 1, '{')
                        or is(T, x, '}') or word(T, x, 'from') or T.k[x] == 'id' or is(T, x, ','))) then break end
                    if kw(T, x, 'function') or kw(T, x, 'class') or kw(T, x, 'const') then break end
                    x = x + 1
                end
            end
        elseif k == 'id' and t == 'require' and is(T, i + 1, '(') and T.k[i + 2] == 'str' then
            r.imports[#r.imports + 1] = { path = T:text(i + 2):sub(2, -2), line = T:line(i), kind = 'require' }
        end
        if not handled then i = i + 1 end
    end
end

-- Members of a class / interface body between '{' o and '}' c.
parse_class_body = function(T, r, o, c, parent, defs, stem)
    local x = o + 1
    while x < c do
        if is(T, x, ';') or is(T, x, ',') then
            x = x + 1
        elseif is(T, x, '@') then
            -- decorator: @name, @a.b, @name(...)
            x = x + 1
            while T.k[x] == 'id' or is(T, x, '.') do x = x + 1 end
            if is(T, x, '(') and T.m[x] then x = T.m[x] + 1 end
        else
            local start = x
            -- a modifier word is only a modifier when another member name follows
            -- (`get<T>(...)` / `static()` are methods named get / static)
            local function names_follow(y)
                local k2 = T.k[y]
                return k2 == 'id' or k2 == 'kw' or k2 == 'str' or k2 == 'num' or is(T, y, '#') or is(T, y, '[') or is(T, y, '*')
            end
            while (T.k[x] == 'id' and MODIFIERS[T:text(x)] and names_follow(x + 1) and T.l[x + 1] == T.l[x])
                or is(T, x, '*') do
                x = x + 1
            end
            local name_tok, name
            if T.k[x] == 'id' or T.k[x] == 'kw' or T.k[x] == 'num' then
                name_tok, name = x, T:text(x)
            elseif T.k[x] == 'str' then
                name_tok, name = x, T:text(x):sub(2, -2)
            elseif is(T, x, '#') and T.k[x + 1] == 'id' then
                name_tok, name = x + 1, '#' .. T:text(x + 1)
                x = x + 1
            elseif is(T, x, '[') and T.m[x] then
                name_tok, name = x, nil                    -- computed key: skip below
                x = T.m[x]
            end
            if not name_tok then
                x = x + 1
            else
                local y = x + 1
                if is(T, y, '?') or is(T, y, '!') then y = y + 1 end
                y = skip_angle(T, y, c)
                if is(T, y, '(') and T.m[y] then
                    -- method / constructor / signature
                    local body = body_after(T, T.m[y], c - 1)
                    local close = body and (T.m[body] or c - 1) or T.m[y]
                    if not body then
                        -- signature: runs to ';' / line end
                        close = expr_end(T, T.m[y], c - 1)
                    end
                    if name then
                        defs[name_tok] = true
                        local kind = (name == 'constructor') and 'constructor' or 'method'
                        local node = common.add_node(r, T, { kind = kind, name = name, ni = name_tok, parent = parent,
                            ti = start, tj = close, sig = common.sig(T, start, body and body - 1 or T.m[y], 200),
                            abstract = (not body) or nil })
                        if body then scan(T, r, body + 1, close - 1, node, defs, stem) end
                    end
                    x = close + 1
                else
                    -- field: name?: Type = init
                    local stop = expr_end(T, x, c - 1)
                    local eq
                    local z = y
                    while z <= stop do
                        if is(T, z, '=') then eq = z; break end
                        if (is(T, z, '(') or is(T, z, '{') or is(T, z, '[')) and T.m[z] then z = T.m[z] end
                        z = z + 1
                    end
                    if name then
                        defs[name_tok] = true
                        -- (not `eq and func_expr(...)`: `and` would keep only the first result)
                        local fs, fe, fb
                        if eq then fs, fe, fb = func_expr(T, eq + 1, c - 1) end
                        if fs then
                            local node = common.add_node(r, T, { kind = 'method', name = name, ni = name_tok, parent = parent,
                                ti = start, tj = fe, sig = common.sig(T, start, math.max(fb - 1, name_tok), 200) })
                            if is(T, fb, '{') then scan(T, r, fb + 1, fe - 1, node, defs, stem) end
                            stop = math.max(stop, fe)
                        else
                            common.add_node(r, T, { kind = 'field', name = name, ni = name_tok, parent = parent,
                                ti = start, tj = stop, sig = common.sig(T, start, stop, 120) })
                            if eq then scan(T, r, eq + 1, stop, parent, defs, stem) end
                        end
                    end
                    x = stop + 1
                end
            end
        end
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, language or 'javascript', opts)
    local defs = {}
    local stem = path:match('([^/\\]+)%.[^./\\]+$') or path
    scan(T, r, 1, T.n, nil, defs, stem)
    common.add_calls(r, T, 1, T.n)
    local kept = {}
    for _, ref in ipairs(r.refs) do
        if not defs[ref.tok] then kept[#kept + 1] = ref end
    end
    r.refs = kept
    return common.finish(r, T), T
end

return M
