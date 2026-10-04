-- lang/csharp.lua — index-level C# parser: namespaces (block and
-- file-scoped), usings, classes / structs / interfaces / records / enums
-- (+ bases), methods, constructors (with `: base(...)`), destructors,
-- operators, properties (accessor and expression-bodied), fields, events,
-- delegates, enum members, attributes, and calls.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

-- Reserved keywords only; contextual ones (get, set, value, var, record,
-- partial, async, await, where, init, global, nameof...) stay identifiers.
M.config = {
    keywords = {
        'abstract', 'as', 'base', 'bool', 'break', 'byte', 'case', 'catch', 'char', 'checked',
        'class', 'const', 'continue', 'decimal', 'default', 'delegate', 'do', 'double', 'else',
        'enum', 'event', 'explicit', 'extern', 'false', 'finally', 'fixed', 'float', 'for',
        'foreach', 'goto', 'if', 'implicit', 'in', 'int', 'interface', 'internal', 'is', 'lock',
        'long', 'namespace', 'new', 'null', 'object', 'operator', 'out', 'override', 'params',
        'private', 'protected', 'public', 'readonly', 'ref', 'return', 'sbyte', 'sealed', 'short',
        'sizeof', 'stackalloc', 'static', 'string', 'struct', 'switch', 'this', 'throw', 'true',
        'try', 'typeof', 'uint', 'ulong', 'unchecked', 'unsafe', 'ushort', 'using', 'virtual',
        'void', 'volatile', 'while',
    },
    ops = {
        '??=', '<<=', '>>=', '>>>', '=>', '::', '?.', '??', '++', '--', '&&', '||', '==', '!=',
        '<=', '>=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>',
    },
    ident_start = 'A-Za-z_@',
    ident_char = 'A-Za-z0-9_',
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = {
        { '"""', '"""', multiline = true },            -- raw string literal
        { '$"""', '"""', multiline = true },
        { '$@"', '"', multiline = true },              -- verbatim: "" escapes a quote
        { '@$"', '"', multiline = true },
        { '@"', '"', multiline = true },
        { '$"', '"', escape = '\\' },
        { '"', '"', escape = '\\' },
        { "'", "'", escape = '\\' },
    },
    directive = '#',
    pp_first_branch = true,
}

M.lang = xscan.lang(M.config)

local TYPE_KW = { class = 'class', struct = 'struct', interface = 'interface', enum = 'enum' }

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

local function angle(T, i)
    if T.k[i] ~= 'op' then return 0 end
    local t = T:text(i)
    if t == '<' then return 1 elseif t == '>' then return -1 elseif t == '>>' then return -2
    elseif t == '>>>' then return -3 end
    return 0
end

-- Dotted name at x: "A.B.C", next index.
local function dotted(T, x)
    local parts = {}
    while T.k[x] == 'id' do
        parts[#parts + 1] = T:text(x)
        if is(T, x + 1, '.') and T.k[x + 2] == 'id' then x = x + 2 else x = x + 1; break end
    end
    return table.concat(parts, '.'), x
end

-- First parameter list of the member [i, j): the '(' at angle depth 0 whose
-- previous token is the member name (`Name(`, `Name<T>(`, `operator +(`).
-- Returns name, name token, '(' index — or nil.
local function member_head(T, i, j)
    local d = 0
    local x = i
    while x < j do
        if is(T, x, '(') and d == 0 then
            local p = x - 1
            if T.k[p] == 'op' and kw(T, p - 1, 'operator') then return 'operator' .. T:text(p), p - 1, x, p end
            if is(T, p, '>') or is(T, p, '>>') then
                local dd = 0
                while p > i do
                    dd = dd - angle(T, p)
                    if dd <= 0 then break end
                    p = p - 1
                end
                p = p - 1
            end
            if T.k[p] == 'id' then
                if is(T, p - 1, '~') then return '~' .. T:text(p), p - 1, x, p end
                if kw(T, p - 1, 'operator') then return 'operator ' .. T:text(p), p - 1, x, p end   -- conversion
                return T:text(p), p, x, p
            end
            if T.k[p] == 'op' and kw(T, p - 1, 'operator') then return 'operator' .. T:text(p), p - 1, x, p end
            if T.k[p] == 'kw' and kw(T, p - 1, 'operator') then return 'operator ' .. T:text(p), p - 1, x, p end
            -- not after a name: a tuple type such as `(int, string) Name(...)`
            if T.m[x] then x = T.m[x] end
        elseif (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x]
        elseif is(T, x, '=') or is(T, x, '=>') then
            return nil
        elseif not kw(T, x - 1, 'operator') then
            d = math.max(0, d + angle(T, x))       -- `operator <(...)` is not a generic list
        end
        x = x + 1
    end
    return nil
end

local parse_members

-- Base list between ':' and '{' (generic arguments and `where` dropped).
local function bases(T, a, b)
    local out, d, x = {}, 0, a
    while x < b do
        if T.k[x] == 'id' and T:text(x) == 'where' and d == 0 then break end
        d = d + angle(T, x)
        if d == 0 and T.k[x] == 'id' then
            local nm, nx = dotted(T, x)
            out[#out + 1] = nm
            x = nx
        else
            x = x + 1
        end
    end
    return out
end

local function type_decl(T, r, i, kwi, o, parent, kind)
    local name_tok = kwi + 1
    if kind == 'record' and (kw(T, name_tok, 'class') or kw(T, name_tok, 'struct')) then name_tok = name_tok + 1 end
    local bodyless = is(T, o, ';')
    local close = bodyless and o or (T.m[o] or T.n)
    local node = common.add_node(r, T, { kind = kind, name = T:text(name_tok), ni = name_tok, parent = parent,
        ti = i, tj = close, sig = common.sig(T, i, o - 1, 200) })
    -- `: Base, IFace` after the name, generic parameters and record params
    local x = name_tok + 1
    local d = 0
    while x < o do
        d = d + angle(T, x)
        if d == 0 and is(T, x, ':') then
            r.nodes[node].bases = bases(T, x + 1, o)
            break
        end
        if is(T, x, '(') and T.m[x] then
            if kind == 'record' then               -- positional record parameters -> properties
                for z = x + 1, T.m[x] - 1 do
                    if T.k[z] == 'id' and (is(T, z + 1, ',') or z + 1 == T.m[x] or is(T, z + 1, '=')) then
                        common.add_node(r, T, { kind = 'property', name = T:text(z), ni = z, parent = node, ti = z, tj = z })
                    end
                end
            end
            x = T.m[x]
        end
        x = x + 1
    end
    if bodyless then
        return close
    elseif kind == 'enum' then
        local y = o + 1
        while y < close do
            while is(T, y, '[') and T.m[y] do y = T.m[y] + 1 end
            if T.k[y] == 'id' then
                common.add_node(r, T, { kind = 'enum_member', name = T:text(y), ni = y, parent = node, ti = y, tj = y })
            end
            while y < close and not is(T, y, ',') do y = (T.m[y] and T.m[y] > y) and T.m[y] + 1 or y + 1 end
            y = y + 1
        end
    else
        parse_members(T, r, o + 1, close - 1, node, T:text(name_tok))
    end
    return close
end

-- Declarations in token range [a, b].
parse_members = function(T, r, a, b, parent, class_name)
    local i = a
    while i <= b do
        local k, t = T.k[i], T:text(i)
        if k == 'dir' then
            i = i + 1
        elseif is(T, i, ';') then
            i = i + 1
        elseif is(T, i, '[') and T.m[i] then
            i = T.m[i] + 1                                       -- [Attribute]
        elseif (k == 'kw' and t == 'using') or (k == 'id' and t == 'global' and kw(T, i + 1, 'using')) then
            local j = i
            while j <= b and not is(T, j, ';') do j = j + 1 end
            local x = kw(T, i, 'using') and i + 1 or i + 2
            if kw(T, x, 'static') then x = x + 1 end
            if T.k[x] == 'id' and is(T, x + 1, '=') then x = x + 2 end   -- alias
            local path = dotted(T, x)
            if path ~= '' then r.imports[#r.imports + 1] = { path = path, line = T:line(i) } end
            i = j + 1
        elseif k == 'kw' and t == 'namespace' then
            local name, x = dotted(T, i + 1)
            if is(T, x, '{') and T.m[x] then
                local node = common.add_node(r, T, { kind = 'namespace', name = name, ni = i + 1, nj = x - 1, parent = parent, ti = i, tj = T.m[x] })
                parse_members(T, r, x + 1, T.m[x] - 1, node, nil)
                i = T.m[x] + 1
            else
                -- file-scoped: namespace A.B;  applies to the rest of the file
                local node = common.add_node(r, T, { kind = 'namespace', name = name, ni = i + 1, nj = x - 1, parent = parent, ti = i, tj = b })
                parse_members(T, r, x + 1, b, node, nil)
                i = b + 1
            end
        else
            -- one member: to ';' or its '{'-body
            local j, eq, done = i, nil, false
            local d = 0
            while j <= b and not done do
                if (is(T, j, '=') or is(T, j, '=>')) and not eq and d == 0 and not kw(T, j - 1, 'operator') then eq = j end
                local rec_kw
                if is(T, j, ';') then
                    for y = i, j - 1 do
                        if T.k[y] == 'id' and T:text(y) == 'record' and (T.k[y + 1] == 'id'
                            or kw(T, y + 1, 'class') or kw(T, y + 1, 'struct')) then rec_kw = y; break end
                        if is(T, y, '(') or is(T, y, '=') then break end
                    end
                end
                if is(T, j, ';') and rec_kw then
                    -- positional record without a body: record Point(int X, int Y);
                    type_decl(T, r, i, rec_kw, j, parent, 'record')
                    done = true
                elseif is(T, j, ';') then
                    -- declaration without a '{' body
                    local is_delegate = false
                    for y = i, j do if kw(T, y, 'delegate') then is_delegate = true; break end end
                    local name, nt, o, ne = member_head(T, i, j)
                    if name and (not eq or eq > o) then
                        local kind = is_delegate and 'typedef' or (name == class_name and 'constructor')
                            or (name:sub(1, 1) == '~' and 'destructor') or 'method'
                        common.add_node(r, T, { kind = kind, name = name, ni = nt, nj = ne, parent = parent, ti = i, tj = j,
                            sig = common.sig(T, i, T.m[o] or o, 200), abstract = (not eq) or nil })
                        common.add_calls(r, T, (T.m[o] or o) + 1, j)
                    elseif eq and is(T, eq, '=>') and T.k[eq - 1] == 'id' then
                        -- expression-bodied property: int X => expr;
                        common.add_node(r, T, { kind = 'property', name = T:text(eq - 1), ni = eq - 1, parent = parent,
                            ti = i, tj = j, sig = common.sig(T, i, eq - 1, 160) })
                        common.add_calls(r, T, eq, j)
                    else
                        -- fields / events: names at angle depth 0 followed by = , ;
                        local dd, init, y = 0, false, i
                        while y < j do
                            dd = dd + angle(T, y)
                            if is(T, y, '=') then init = true
                            elseif is(T, y, ',') and dd == 0 then init = false
                            elseif not init and dd == 0 and T.k[y] == 'id' and T.k[y + 1] == 'op' then
                                local nx = T:text(y + 1)
                                if nx == '=' or nx == ';' or nx == ',' then
                                    common.add_node(r, T, { kind = 'field', name = T:text(y), ni = y, parent = parent,
                                        ti = y, tj = j, sig = common.sig(T, i, math.min(j - 1, y + 1), 160) })
                                end
                            end
                            if init and T.m[y] and T.m[y] > y and T.k[y] == 'op' then y = T.m[y] end
                            y = y + 1
                        end
                        common.add_calls(r, T, i, j)
                    end
                    done = true
                elseif is(T, j, '{') then
                    local close = T.m[j] or b
                    local kwi, kind
                    if not eq then
                        for y = i, j - 1 do
                            local ty = T:text(y)
                            if T.k[y] == 'kw' and TYPE_KW[ty] and not kw(T, y - 1, 'record') then
                                kwi, kind = y, TYPE_KW[ty]; break
                            elseif T.k[y] == 'id' and ty == 'record' and (T.k[y + 1] == 'id' or kw(T, y + 1, 'class')
                                or kw(T, y + 1, 'struct')) then
                                kwi, kind = y, 'record'; break
                            elseif is(T, y, '(') and T.m[y] then
                                break                          -- a parameter list comes first: a method
                            end
                        end
                    end
                    if kwi then
                        type_decl(T, r, i, kwi, j, parent, kind)
                        j = close
                        done = true
                    elseif eq then
                        j = close                          -- initializer { ... }: continue to ';'
                    else
                        local name, nt, o, ne = member_head(T, i, j)
                        if name and o < j then
                            local kind = (name == class_name and 'constructor')
                                or (name:sub(1, 1) == '~' and 'destructor') or 'method'
                            common.add_node(r, T, { kind = kind, name = name, ni = nt, nj = ne, parent = parent, ti = i, tj = close,
                                sig = common.sig(T, i, T.m[o] or o, 200) })
                            common.add_calls(r, T, (T.m[o] or o) + 1, close)
                            j = close
                            done = true
                        elseif T.k[j - 1] == 'id' then
                            -- property with accessors: Type Name { get; set; } [= init;]
                            common.add_node(r, T, { kind = 'property', name = T:text(j - 1), ni = j - 1, parent = parent,
                                ti = i, tj = close, sig = common.sig(T, i, j - 1, 160) })
                            common.add_calls(r, T, j, close)
                            if is(T, close + 1, '=') then
                                local y = close + 1
                                while y <= b and not is(T, y, ';') do y = (T.m[y] and T.m[y] > y) and T.m[y] + 1 or y + 1 end
                                common.add_calls(r, T, close + 1, y)
                                close = y
                            end
                            j = close
                            done = true
                        else
                            common.add_calls(r, T, i, close)   -- indexer / static ctor-like blocks
                            j = close
                            done = true
                        end
                    end
                elseif (is(T, j, '(') or is(T, j, '[')) and T.m[j] then
                    j = T.m[j]
                else
                    d = math.max(0, d + angle(T, j))
                end
                if not done then j = j + 1 end
            end
            i = j + 1
        end
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'csharp', opts)
    parse_members(T, r, 1, T.n, nil, nil)
    return common.finish(r), T
end

return M
