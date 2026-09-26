-- lang/rust.lua — index-level Rust parser: modules (inline and `mod x;`),
-- `use` imports, functions, structs (+ named fields), enums (+ variants),
-- unions, traits (+ method signatures / default bodies), impl blocks (methods
-- qualified by the implementing type, `impl Trait for Type` recorded),
-- type aliases, consts / statics, macro_rules!, and calls incl. `name!(..)`.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.config = {
    keywords = {
        'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn', 'else', 'enum',
        'extern', 'false', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop', 'match', 'mod', 'move',
        'mut', 'pub', 'ref', 'return', 'self', 'Self', 'static', 'struct', 'super', 'trait', 'true',
        'type', 'unsafe', 'use', 'where', 'while',
    },
    ops = {
        '..=', '...', '<<=', '>>=', '->', '=>', '::', '..', '==', '!=', '<=', '>=', '&&', '||',
        '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>',
    },
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = {
        { '"', '"', escape = '\\', multiline = true },
        { "'", "'", escape = '\\' },
    },
    string_prefixes = 'bc',
    lifetimes = true,
    raw_strings = true,
    nested_comments = true,
}

M.lang = xscan.lang(M.config)

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

local function angle(T, i)
    if T.k[i] ~= 'op' then return 0 end
    local t = T:text(i)
    if t == '<' then return 1 elseif t == '>' then return -1 elseif t == '>>' then return -2 end
    return 0
end

-- Index after a generic list at '<' i.
local function skip_angle(T, i, limit)
    if not is(T, i, '<') then return i end
    local d, x = 0, i
    while x <= limit do
        if (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x]
        elseif not is(T, x, '->') then
            d = d + angle(T, x)
            if d <= 0 then return x + 1 end
        end
        x = x + 1
    end
    return i + 1
end

-- Item end: the '{' body's match, or the terminating ';' at depth 0.
local function item_end(T, x, b)
    local d = 0
    while x <= b do
        if is(T, x, ';') and d == 0 then return x, nil end
        if is(T, x, '{') and d == 0 then return T.m[x] or b, x end
        if (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x]
        elseif not is(T, x, '->') and not is(T, x, '=>') then
            d = math.max(0, d + angle(T, x))
        end
        x = x + 1
    end
    return b, nil
end

-- Type name in `impl<T> Trait<X> for Type<Y> where ...` / `impl Type`.
local function impl_target(T, x, body)
    x = skip_angle(T, x, body)
    local first, trait
    local d, y = 0, x
    local names = {}
    while y < body do
        if T.k[y] == 'kw' and T:text(y) == 'where' and d == 0 then break end
        if kw(T, y, 'for') and d == 0 then
            trait = names[#names]
            names = {}
        elseif (T.k[y] == 'id' or kw(T, y, 'Self')) and d == 0 and not is(T, y + 1, '::')
            and T:text(y):sub(1, 1) ~= "'" then              -- 'static is a lifetime, not the type
            names[#names + 1] = T:text(y)
        end
        d = math.max(0, d + angle(T, y))
        y = y + 1
    end
    first = names[1]
    if not first then
        -- `impl Trait for ()` / tuples: no identifier, use the type's text
        local from = x
        for z = x, body - 1 do if kw(T, z, 'for') then from = z + 1 end end
        local to = body - 1
        for z = from, body - 1 do if T.k[z] == 'kw' and T:text(z) == 'where' then to = z - 1; break end end
        if to >= from then first = common.sig(T, from, to, 60):gsub('%s', '') end
    end
    return first, trait
end

-- Record calls in [a, b], including macro invocations `name!(..)` / `name![..]`.
local function calls(r, T, a, b)
    common.add_calls(r, T, a, b)
    for x = a, b - 2 do
        if T.k[x] == 'id' and is(T, x + 1, '!') and (is(T, x + 2, '(') or is(T, x + 2, '[') or is(T, x + 2, '{')) then
            r.refs[#r.refs + 1] = { tok = x, name = T:text(x), kind = 'macro', line = T:line(x) }
        end
    end
end

local parse_items

-- Named fields / variants inside '{' o .. '}' c (struct, enum, union).
local function body_members(T, r, o, c, parent, kind)
    local x = o + 1
    while x < c do
        while is(T, x, '#') and is(T, x + 1, '[') and T.m[x + 1] do x = T.m[x + 1] + 1 end
        if kw(T, x, 'pub') then
            x = x + 1
            if is(T, x, '(') and T.m[x] then x = T.m[x] + 1 end
        end
        if T.k[x] == 'id' and (kind == 'enum' or is(T, x + 1, ':')) then
            common.add_node(r, T, { kind = kind == 'enum' and 'enum_member' or 'field', name = T:text(x),
                parent = parent, ti = x, tj = x })
        end
        while x < c and not is(T, x, ',') do
            if T.m[x] and T.m[x] > x then x = T.m[x] + 1
            elseif is(T, x, '<') then x = skip_angle(T, x, c)
            else x = x + 1 end
        end
        x = x + 1
    end
end

-- Items in [a, b]; impl_type qualifies methods inside impl blocks.
parse_items = function(T, r, a, b, parent, impl_type, in_trait)
    local i = a
    while i <= b do
        -- attributes, visibility and qualifiers before the item keyword
        local start = i
        local x = i
        while true do
            if is(T, x, '#') and (is(T, x + 1, '[') or (is(T, x + 1, '!') and is(T, x + 2, '['))) then
                local o = is(T, x + 1, '[') and x + 1 or x + 2
                x = (T.m[o] or o) + 1
                start = x
            elseif kw(T, x, 'pub') then
                x = x + 1
                if is(T, x, '(') and T.m[x] then x = T.m[x] + 1 end
            elseif kw(T, x, 'async') or kw(T, x, 'unsafe') or (kw(T, x, 'const') and (kw(T, x + 1, 'fn')
                or kw(T, x + 1, 'unsafe') or kw(T, x + 1, 'async') or kw(T, x + 1, 'extern')))
                or (T.k[x] == 'id' and T:text(x) == 'default' and (kw(T, x + 1, 'fn') or kw(T, x + 1, 'type'))) then
                x = x + 1
            elseif kw(T, x, 'extern') and (kw(T, x + 1, 'fn') or (T.k[x + 1] == 'str' and kw(T, x + 2, 'fn'))) then
                x = x + (T.k[x + 1] == 'str' and 2 or 1)
            else
                break
            end
        end
        if x > b then break end
        local t = T.k[x] == 'kw' and T:text(x) or (T.k[x] == 'id' and T:text(x))
        local stop
        if t == 'fn' and T.k[x + 1] == 'id' then
            local name_tok = x + 1
            local p = skip_angle(T, x + 2, b)
            local e, body = item_end(T, p, b)
            local node = common.add_node(r, T, {
                kind = (impl_type or in_trait) and 'method' or 'function', name = T:text(name_tok),
                parent = parent, ti = start, tj = e,
                sig = common.sig(T, start, body and body - 1 or e, 200), abstract = (not body) or nil,
            })
            if impl_type then r.nodes[node].qualified = impl_type .. '::' .. T:text(name_tok) end
            if body then
                calls(r, T, body, e)
                -- nested items (fn inside fn) are rare; bodies are not re-parsed
            end
            stop = e
        elseif (t == 'struct' or t == 'enum' or t == 'union') and T.k[x + 1] == 'id' then
            local e, body = item_end(T, x + 2, b)
            local node = common.add_node(r, T, { kind = t == 'enum' and 'enum' or 'struct', name = T:text(x + 1),
                parent = parent, ti = start, tj = e, sig = common.sig(T, start, body and body - 1 or e, 160) })
            if body then body_members(T, r, body, e, node, t) end
            stop = e
        elseif t == 'trait' and T.k[x + 1] == 'id' then
            local e, body = item_end(T, x + 2, b)
            local node = common.add_node(r, T, { kind = 'interface', name = T:text(x + 1), parent = parent,
                ti = start, tj = e, sig = common.sig(T, start, body and body - 1 or e, 160) })
            if body then parse_items(T, r, body + 1, e - 1, node, nil, true) end
            stop = e
        elseif t == 'impl' then
            local e, body = item_end(T, x + 1, b)
            if body then
                local ty, trait = impl_target(T, x + 1, body)
                local node = common.add_node(r, T, { kind = 'impl', name = ty or 'impl', parent = parent,
                    ti = start, tj = e, sig = common.sig(T, start, body - 1, 160), trait = trait })
                r.nodes[node].qualified = ty or 'impl'
                parse_items(T, r, body + 1, e - 1, node, ty, false)
            end
            stop = e
        elseif t == 'mod' and T.k[x + 1] == 'id' then
            local e, body = item_end(T, x + 2, b)
            if body then
                local node = common.add_node(r, T, { kind = 'namespace', name = T:text(x + 1), parent = parent,
                    ti = start, tj = e })
                parse_items(T, r, body + 1, e - 1, node, nil, false)
            else
                -- `mod x;` declares a file module: a node and an import of x.rs / x/mod.rs
                common.add_node(r, T, { kind = 'namespace', name = T:text(x + 1), parent = parent, ti = start, tj = e })
                r.imports[#r.imports + 1] = { path = T:text(x + 1), line = T:line(x), kind = 'mod' }
            end
            stop = e
        elseif t == 'use' then
            local e = item_end(T, x + 1, b)
            r.imports[#r.imports + 1] = { path = common.sig(T, x + 1, e - 1, 400):gsub('%s', ''), line = T:line(x) }
            stop = e
        elseif (t == 'type') and T.k[x + 1] == 'id' then
            local e = item_end(T, x + 2, b)
            common.add_node(r, T, { kind = 'typedef', name = T:text(x + 1), parent = parent, ti = start, tj = e,
                sig = common.sig(T, start, e, 160) })
            stop = e
        elseif (t == 'const' or t == 'static') then
            local y = x + 1
            if kw(T, y, 'mut') then y = y + 1 end
            local e = item_end(T, y, b)
            if T.k[y] == 'id' then
                local node = common.add_node(r, T, { kind = t == 'const' and 'constant' or 'variable', name = T:text(y),
                    parent = parent, ti = start, tj = e, sig = common.sig(T, start, math.min(e, y + 2), 120) })
                if impl_type then r.nodes[node].qualified = impl_type .. '::' .. T:text(y) end
                calls(r, T, y, e)
            end
            stop = e
        elseif t == 'macro_rules' and is(T, x + 1, '!') and T.k[x + 2] == 'id' then
            local o = x + 3
            local e = (T.m[o] or o)
            if is(T, e + 1, ';') then e = e + 1 end
            common.add_node(r, T, { kind = 'macro', name = T:text(x + 2), parent = parent, ti = start, tj = e })
            stop = e
        elseif kw(T, x, 'extern') and kw(T, x + 1, 'crate') then
            local e = item_end(T, x, b)
            if T.k[x + 2] == 'id' then r.imports[#r.imports + 1] = { path = T:text(x + 2), line = T:line(x), kind = 'crate' } end
            stop = e
        elseif kw(T, x, 'extern') and T.k[x + 1] == 'str' and is(T, x + 2, '{') and T.m[x + 2] then
            parse_items(T, r, x + 3, T.m[x + 2] - 1, parent, nil, false)   -- extern "C" { fn ...; }
            stop = T.m[x + 2]
        else
            -- top-level macro invocation or anything else: skip one token/group
            if T.k[x] == 'id' and is(T, x + 1, '!') then
                local e = item_end(T, x + 2, b)
                calls(r, T, x, e)
                stop = e
            else
                stop = x
            end
        end
        i = math.max(stop, i) + 1
    end
end

function M.parse(path, src)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'rust')
    parse_items(T, r, 1, T.n, nil, nil, false)
    -- '::' is the path separator: fix qualified names built with '.'
    for _, n in ipairs(r.nodes) do n.qualified = n.qualified:gsub('%.', '::') end
    return common.finish(r), T
end

return M
