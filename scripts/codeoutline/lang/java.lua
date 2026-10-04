-- lang/java.lua — index-level Java parser: package, imports, classes /
-- interfaces / enums / records / annotation types (+ extends/implements),
-- methods, constructors, fields, enum constants, and calls.
--
-- Generics are not bracket-matched by xscan ('<' is also less-than), so
-- declarations track angle depth themselves; bodies need no generics
-- handling because they are only scanned for call sites.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.config = {
    keywords = {
        'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char', 'class',
        'const', 'continue', 'default', 'do', 'double', 'else', 'enum', 'extends', 'final',
        'finally', 'float', 'for', 'goto', 'if', 'implements', 'import', 'instanceof', 'int',
        'interface', 'long', 'native', 'new', 'package', 'private', 'protected', 'public',
        'return', 'short', 'static', 'strictfp', 'super', 'switch', 'synchronized', 'this',
        'throw', 'throws', 'transient', 'try', 'void', 'volatile', 'while',
        'true', 'false', 'null',
    },
    ops = {
        '>>>=', '<<=', '>>=', '->', '::', '++', '--', '&&', '||', '==', '!=', '<=', '>=',
        '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '...', '<<', '>>>', '>>',
    },
    ident_start = 'A-Za-z_$',
    ident_char = 'A-Za-z0-9_$',
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = {
        { '"""', '"""', escape = '\\', multiline = true },   -- text blocks
        { '"', '"', escape = '\\' },
        { "'", "'", escape = '\\' },
    },
}

M.lang = xscan.lang(M.config)

local TYPE_KW = { class = 'class', interface = 'interface', enum = 'enum' }

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end

-- Change in generic angle depth for token i ('>>' closes two levels).
local function angle(T, i)
    if T.k[i] ~= 'op' then return 0 end
    local t = T:text(i)
    if t == '<' then return 1 end
    if t == '>' then return -1 end
    if t == '>>' then return -2 end
    if t == '>>>' then return -3 end
    return 0
end

-- Next index after an annotation starting at '@' i: @A, @a.b.C, @A(...).
local function skip_annotation(T, i)
    local j = i + 1
    while T.k[j] == 'id' or is(T, j, '.') do j = j + 1 end
    if is(T, j, '(') and T.m[j] then j = T.m[j] + 1 end
    return j
end

-- Type names listed after extends/implements up to '{' (generic args dropped).
local function supertypes(T, a, b)
    local out, depth, x = {}, 0, a
    while x < b do
        depth = depth + angle(T, x)
        if depth == 0 and T.k[x] == 'id' then
            local name, y = T:text(x), x + 1
            while is(T, y, '.') and T.k[y + 1] == 'id' do
                name = name .. '.' .. T:text(y + 1)
                y = y + 2
            end
            out[#out + 1] = name
            x = y
        else
            x = x + 1
        end
    end
    return out
end

local parse_members

-- Type declaration: keyword token at kw, '{' at o. Returns the node index.
local function type_decl(T, r, i, kwi, o, parent, kind)
    local name_tok = kwi + 1
    local node = common.add_node(r, T, {
        kind = kind, name = T:text(name_tok), ni = name_tok, parent = parent,
        ti = i, tj = T.m[o] or T.n, sig = common.sig(T, i, o - 1),
    })
    local n = r.nodes[node]
    for x = name_tok + 1, o - 1 do
        local t = T.k[x] == 'kw' and T:text(x)
        if t == 'extends' or t == 'implements' then
            local stop = o
            for y = x + 1, o - 1 do
                if T.k[y] == 'kw' and (T:text(y) == 'implements' or T:text(y) == 'extends') or (T.k[y] == 'id' and T:text(y) == 'permits') then
                    stop = y; break
                end
            end
            local list = supertypes(T, x + 1, stop)
            if t == 'extends' then
                n.extends = list
            else
                n.implements = list
            end
        end
    end
    if kind == 'record' and is(T, name_tok + 1, '(') and T.m[name_tok + 1] then
        -- record components become fields
        local c = T.m[name_tok + 1]
        for x = name_tok + 2, c - 1 do
            if T.k[x] == 'id' and (is(T, x + 1, ',') or x + 1 == c) then
                common.add_node(r, T, { kind = 'field', name = T:text(x), ni = x, parent = node, ti = x, tj = x })
            end
        end
    end
    local close = T.m[o] or T.n
    local start = o + 1
    if kind == 'enum' then
        -- constants: NAME [(args)] [{ body }] , ... up to ';' or '}'
        local x = o + 1
        while x < close and not is(T, x, ';') do
            while is(T, x, '@') do x = skip_annotation(T, x) end
            if T.k[x] == 'id' then
                local y = x + 1
                if is(T, y, '(') and T.m[y] then y = T.m[y] + 1 end
                if is(T, y, '{') and T.m[y] then y = T.m[y] + 1 end
                common.add_node(r, T, { kind = 'enum_member', name = T:text(x), ni = x, parent = node, ti = x, tj = y - 1 })
                common.add_calls(r, T, x + 1, y - 1)
                x = y
            end
            if is(T, x, ',') then
                x = x + 1
            elseif not (T.k[x] == 'id' or is(T, x, '@') or is(T, x, ';')) then
                x = x + 1
            end
        end
        start = x + 1
    end
    parse_members(T, r, start, close - 1, node, T:text(name_tok))
    return node
end

-- Members of a type body in [a, b].
parse_members = function(T, r, a, b, parent, class_name)
    local i = a
    local ann_start           -- annotations before a member start its range (as javac does)
    while i <= b do
        if is(T, i, ';') then
            i = i + 1
        elseif is(T, i, '@') and not (T.k[i + 1] == 'kw' and T:text(i + 1) == 'interface') then
            ann_start = ann_start or i
            i = skip_annotation(T, i)
        else
            local mstart = ann_start or i
            ann_start = nil
            -- scan one member to ';' or a '{'
            local j, done = i, false
            local eq
            while j <= b and not done do
                if is(T, j, '=') and not eq then eq = j end
                if is(T, j, ';') then
                    -- field(s) or abstract method
                    local p
                    for y = i, j - 1 do
                        if is(T, y, '(') and T.m[y] and T.k[y - 1] == 'id' and not eq then p = y - 1; break end
                        if eq and y >= eq then break end
                    end
                    if p then
                        common.add_node(r, T, { kind = 'method', name = T:text(p), ni = p, parent = parent, ti = mstart, tj = j, sig = common.sig(T, i, T.m[p + 1]), abstract = true })
                    else
                        -- field names: identifiers at angle depth 0 followed by = , ;
                        -- (initializer bracket groups are skipped whole, so
                        -- commas inside call args don't start a new name)
                        local d, init, y = 0, false, i
                        while y < j do
                            d = d + angle(T, y)
                            if is(T, y, '=') then init = true
                            elseif is(T, y, ',') and d == 0 then init = false
                            elseif not init and d == 0 and T.k[y] == 'id' and T.k[y + 1] == 'op' then
                                local nx = T:text(y + 1)
                                -- `Type[] name`: a '[' after the type, not the name
                                local array_type = nx == '[' and T.m[y + 1] and T.k[T.m[y + 1] + 1] == 'id'
                                if (nx == '=' or nx == ';' or nx == ',' or nx == '[') and not array_type then
                                    common.add_node(r, T, { kind = 'field', name = T:text(y), ni = y, parent = parent, ti = y, tj = j, sig = common.sig(T, i, math.min(j - 1, y + 1)) })
                                end
                            end
                            if init and T.m[y] and T.m[y] > y and T.k[y] == 'op' then y = T.m[y] end
                            y = y + 1
                        end
                        common.add_calls(r, T, i, j)
                    end
                    done = true
                elseif is(T, j, '{') then
                    local kwi, kind
                    for y = i, j - 1 do
                        local t = T:text(y)
                        if T.k[y] == 'kw' and TYPE_KW[t] then
                            kwi, kind = y, TYPE_KW[t]
                            if is(T, y - 1, '@') then kind = 'annotation_type' end
                            break
                        elseif T.k[y] == 'id' and t == 'record' and T.k[y + 1] == 'id' then
                            kwi, kind = y, 'record'
                            break
                        end
                    end
                    local close = T.m[j] or b
                    if kwi and not eq then
                        type_decl(T, r, mstart, kwi, j, parent, kind)
                        j = close
                    elseif eq then
                        j = close                  -- array initializer / anonymous class: continue to ';'
                    else
                        -- method / constructor: '(' group before '{' (skip throws ...)
                        local x = j - 1
                        while x >= i and not is(T, x, ')') do x = x - 1 end
                        local o = x >= i and T.m[x]
                        local calls_from = i
                        if o and T.k[o - 1] == 'id' then
                            calls_from = o      -- skip `name(`: not a call to itself
                            local name = T:text(o - 1)
                            common.add_node(r, T, {
                                kind = (name == class_name) and 'constructor' or 'method',
                                name = name, ni = o - 1, parent = parent, ti = mstart, tj = close,
                                sig = common.sig(T, i, x),
                            })
                        end
                        -- initializer blocks and bodies: calls only
                        common.add_calls(r, T, calls_from, close)
                        j = close
                    end
                    done = not eq
                elseif T.m[j] and T.m[j] > j and T.k[j] == 'op' and T:text(j) ~= '{' then
                    j = T.m[j]
                end
                if not done then j = j + 1 end
            end
            i = j + 1
        end
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'java', opts)
    local i = 1
    while i <= T.n do
        if T.k[i] == 'kw' and T:text(i) == 'package' then
            local j = i + 1
            local parts = {}
            while not is(T, j, ';') and j <= T.n do parts[#parts + 1] = T:text(j); j = j + 1 end
            r.package = table.concat(parts)
            r.prefix = r.package
            i = j + 1
        elseif T.k[i] == 'kw' and T:text(i) == 'import' then
            local j = i + 1
            local static = T.k[j] == 'kw' and T:text(j) == 'static'
            if static then j = j + 1 end
            local parts = {}
            while not is(T, j, ';') and j <= T.n do parts[#parts + 1] = T:text(j); j = j + 1 end
            r.imports[#r.imports + 1] = { path = table.concat(parts), line = T:line(i), static = static or nil }
            i = j + 1
        else
            break
        end
    end
    parse_members(T, r, i, T.n, nil, nil)
    return common.finish(r), T
end

return M
