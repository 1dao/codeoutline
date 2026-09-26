-- lang/c.lua — index-level C parser: functions, prototypes, structs/unions/
-- enums (+ members), typedefs, globals, macros, #includes, and the calls and
-- callback references inside bodies and initializers.
--
-- Declarations are parsed; bodies are skipped with the bracket match table
-- and only scanned for call sites. The preprocessor is handled the way ctags
-- does it: keep the first live #if branch (xscan pp_first_branch), so both
-- arms of an #ifdef never meet in one token stream.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.keywords = {
    'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do', 'double',
    'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline', 'int', 'long',
    'register', 'restrict', 'return', 'short', 'signed', 'sizeof', 'static', 'struct',
    'switch', 'typedef', 'union', 'unsigned', 'void', 'volatile', 'while',
    '_Bool', '_Complex', '_Atomic', '_Static_assert', '_Noreturn', '_Thread_local',
    '_Alignas', '_Alignof', '__inline', '__inline__', '__restrict', '__volatile__',
}

M.ops = {
    '->', '++', '--', '<<=', '>>=', '<<', '>>', '<=', '>=', '==', '!=', '&&', '||',
    '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '...', '::', '##',
}

M.config = {
    keywords = M.keywords,
    ops = M.ops,
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
    string_prefixes = 'LuU8',
    directive = '#',
    pp_first_branch = true,
}

M.lang = xscan.lang(M.config)
-- Macro bodies are re-tokenized without directive handling to find calls.
local body_cfg = {}
for k, v in pairs(M.config) do body_cfg[k] = v end
body_cfg.directive, body_cfg.pp_first_branch = nil, nil
local body_lang = xscan.lang(body_cfg)

-- Names that look like a call but decorate a declaration.
local ATTR = {
    __attribute__ = true, __attribute = true, __declspec = true, __asm__ = true,
    __asm = true, asm = true, alignas = true, _Alignas = true,
}
local AGGREGATE = { struct = true, union = true, enum = true }

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end

-- `int (name)(args)` — Lua's headers wrap API names in parens to block
-- macro expansion. Return the inner identifier's index for a `(id)` group
-- ending at p, otherwise p itself.
local function paren_name(T, p)
    if is(T, p, ')') and T.m[p] == p - 2 and T.k[p - 1] == 'id' then return p - 1 end
    return p
end

-- First token of a declaration whose name is at `x`: walk back over type
-- words and pointer stars, stopping at anything that ends a prior construct
-- (so a preceding `MACRO(args)` without ';' is not swallowed).
local function decl_start(T, a, x)
    local y = x - 1
    while y >= a do
        local k = T.k[y]
        if k == 'id' or k == 'kw' or (k == 'op' and (T:text(y) == '*' or T:text(y) == '&')) then
            y = y - 1
        elseif is(T, y, ')') and T.m[y] and T.m[y] >= a and ATTR[T:text(T.m[y] - 1)] then
            y = T.m[y] - 2        -- __attribute__((...)) before the type
        else
            break
        end
    end
    return y + 1
end

-- If the '{' at j opens a function body, return name index, '(' and ')'.
local function function_head(T, a, j)
    local x = j - 1
    while x >= a do
        if is(T, x, ')') then
            local o = T.m[x]
            if not o or o <= a then return nil end
            local p = paren_name(T, o - 1)
            if T.k[p] == 'id' and ATTR[T:text(p)] then
                x = p - 1                          -- trailing __attribute__((...))
            elseif T.k[p] == 'id' then
                return p, o, x
            else
                return nil
            end
        elseif T.k[x] == 'id' or (T.k[x] == 'kw' and T:text(x) == 'const') then
            x = x - 1                              -- trailing macro, e.g. NOEXCEPT
        else
            return nil
        end
    end
    return nil
end

-- When a body's '{' has no match (unbalanced preprocessor arms), end the
-- body at the next '}' in column 1 — the conventional function end.
local function fallback_close(T, j, b)
    for y = j + 1, b do
        if is(T, y, '}') and (T.s[y] == 1 or T.src:byte(T.s[y] - 1) == 10) then return y end
    end
    return b
end

local function handle_directive(T, r, i)
    local text = T:text(i)
    local inc = text:match('^#%s*include%s*[<"]([^>"]+)[>"]')
    if inc then
        r.imports[#r.imports + 1] = { path = inc, line = T:line(i), system = text:match('^#%s*include%s*<') ~= nil }
        return
    end
    local name, rest = text:match('^#%s*define%s+([%a_][%w_]*)(.*)$')
    if not name then return end
    common.add_node(r, T, {
        kind = 'macro', name = name, ti = i, tj = i,
        sig = common.sig(T, i, i, 160),
    })
    -- Calls inside a function-like macro body belong to the macro.
    if rest:sub(1, 1) == '(' then
        local body = rest:gsub('\\\r?\n', ' \n')
        local BT = body_lang:tokenize(body)
        for _, x in ipairs(BT:calls(1, BT.n)) do
            r.refs[#r.refs + 1] = {
                tok = i, name = BT:text(x), kind = 'call', line = T:line(i) + BT:line(x) - 1,
            }
        end
    end
end

-- Enum members and struct/union fields directly inside '{' o .. '}' c.
local function members(T, r, o, c, parent, is_enum)
    local x = o + 1
    while x < c do
        -- one member runs to ',' (enum) or ';' (struct) at this depth
        local y = x
        while y < c and not is(T, y, is_enum and ',' or ';') do
            y = (T.m[y] and T.m[y] > y) and T.m[y] + 1 or y + 1
        end
        if is_enum then
            if T.k[x] == 'id' then
                common.add_node(r, T, { kind = 'enum_member', name = T:text(x), parent = parent, ti = x, tj = math.max(x, y - 1) })
            end
        else
            -- field names: identifiers followed by ';' ',' '[' ':' at this depth
            for z = x, y - 1 do
                if T.k[z] == 'id' and T.k[z + 1] == 'op' then
                    local nx = T:text(z + 1)
                    if (nx == ';' or nx == ',' or nx == '[' or nx == ':') or z + 1 == y then
                        common.add_node(r, T, { kind = 'field', name = T:text(z), parent = parent, ti = z, tj = z })
                    end
                end
                if is(T, z, '(') and is(T, z + 1, '*') and T.k[z + 2] == 'id' then
                    common.add_node(r, T, { kind = 'field', name = T:text(z + 2), parent = parent, ti = z + 2, tj = z + 2 })
                end
                if T.m[z] and T.m[z] > z then break end    -- nested struct / fn-pointer: skip
            end
        end
        x = y + 1
    end
end

local parse_range

-- Handle one statement in [i, j] where j is ';' (or the last token).
local function declaration(T, r, i, j, parent)
    local first = T:text(i)
    if first == 'typedef' then
        -- alias = last top-level identifier; function-pointer typedefs keep
        -- it inside the first paren group: typedef int (*name)(...);
        local name_tok
        local y = i + 1
        while y < j do
            if T.k[y] == 'id' then name_tok = y end
            if T.m[y] and T.m[y] > y then
                if not name_tok or is(T, y, '(') then
                    for z = y + 1, T.m[y] - 1 do
                        if T.k[z] == 'id' then name_tok = z; break end
                    end
                    if is(T, y, '(') then break end
                end
                y = T.m[y] + 1
            else
                y = y + 1
            end
        end
        if name_tok then
            common.add_node(r, T, { kind = 'typedef', name = T:text(name_tok), parent = parent, ti = i, tj = j, sig = common.sig(T, i, j) })
        end
        return
    end
    local is_extern = first == 'extern' and T.k[i + 1] ~= 'str'
    -- Walk the top level of the statement.
    local y, eq = i, nil
    local names = {}
    while y < j do
        if is(T, y, '=') and not eq then eq = y end
        if is(T, y, '(') and T.m[y] then
            local p = paren_name(T, y - 1)
            if not eq and p >= i and T.k[p] == 'id' and not ATTR[T:text(p)] then
                if p == i then
                    -- MACRO(args); at file scope: a call, not a declaration
                    common.add_calls(r, T, i, j)
                    return
                end
                common.add_node(r, T, {
                    kind = 'prototype', name = T:text(p), parent = parent,
                    ti = decl_start(T, i, p), tj = j, sig = common.sig(T, decl_start(T, i, p), T.m[y]),
                    static = first == 'static' or nil,
                })
                return
            end
            y = T.m[y] + 1
        elseif (is(T, y, '[') or is(T, y, '{')) and T.m[y] then
            y = T.m[y] + 1
        else
            if T.k[y] == 'id' and not eq and T.k[y + 1] == 'op' then
                local nx = T:text(y + 1)
                if nx == '=' or nx == ';' or nx == ',' or nx == '[' then names[#names + 1] = y end
            end
            if is(T, y, ',') then eq = nil end
            y = y + 1
        end
    end
    if is_extern then names = {} end    -- extern int x; is a declaration of a def elsewhere
    for _, x in ipairs(names) do
        common.add_node(r, T, {
            kind = 'variable', name = T:text(x), parent = parent, ti = x, tj = j,
            static = first == 'static' or nil, sig = common.sig(T, i, math.min(j, x + 1)),
        })
    end
    common.add_calls(r, T, i, j)
    common.add_value_refs(r, T, i, j)
end

-- Parse the statements in token range [a, b].
parse_range = function(T, r, a, b, parent)
    local i = a
    while i <= b do
        local k = T.k[i]
        if k == 'dir' then
            handle_directive(T, r, i)
            i = i + 1
        elseif k == 'op' and (T:text(i) == ';' or T:text(i) == '}') then
            i = i + 1
        else
            local j, done = i, false
            while j <= b and not done do
                local kj = T.k[j]
                if kj == 'dir' then
                    declaration(T, r, i, j - 1, parent)
                    j = j - 1
                    done = true
                elseif is(T, j, ';') then
                    declaration(T, r, i, j, parent)
                    done = true
                elseif is(T, j, '{') then
                    local name, o, c = function_head(T, i, j)
                    local close = T.m[j] or fallback_close(T, j, b)
                    if name then
                        local start = decl_start(T, i, name)
                        if start > i then common.add_calls(r, T, i, start - 1) end   -- MACRO(...) before it
                        common.add_node(r, T, {
                            kind = 'function', name = T:text(name), parent = parent,
                            ti = start, tj = close, sig = common.sig(T, start, c),
                            static = T:text(start) == 'static' or nil,
                        })
                        common.add_calls(r, T, j, close)
                        common.add_value_refs(r, T, j, close)
                        j = close
                        done = true
                    elseif T.k[j - 1] == 'str' and T:text(j - 2) == 'extern' then
                        -- extern "C" { ... }: transparent
                        parse_range(T, r, j + 1, close - 1, parent)
                        j = close
                        done = true
                    else
                        -- aggregate definition or brace initializer
                        local agg
                        for y = i, j - 1 do
                            if T.k[y] == 'kw' and AGGREGATE[T:text(y)] then agg = y; break end
                        end
                        if agg and not (function() for y = i, agg do if is(T, y, '=') then return true end end end)() then
                            local kind = T:text(agg)
                            local name_tok = (T.k[agg + 1] == 'id' and agg + 1 < j) and agg + 1 or nil
                            -- typedef struct {..} Alias;  names the struct after its alias
                            local stop = close + 1
                            while stop <= b and not is(T, stop, ';') and T.k[stop] ~= 'dir' do
                                stop = (T.m[stop] and T.m[stop] > stop) and T.m[stop] + 1 or stop + 1
                            end
                            local alias
                            if T:text(i) == 'typedef' then
                                for y = close + 1, stop - 1 do
                                    if T.k[y] == 'id' then alias = y; break end
                                end
                            end
                            local nm = name_tok or alias
                            local node
                            if nm then
                                node = common.add_node(r, T, {
                                    kind = kind, name = T:text(nm), parent = parent,
                                    ti = i, tj = close, sig = common.sig(T, i, j - 1),
                                })
                                members(T, r, j, close, node, kind == 'enum')
                            elseif kind == 'enum' then
                                members(T, r, j, close, parent, true)    -- anonymous enum constants
                            end
                            if alias and alias ~= nm then
                                common.add_node(r, T, { kind = 'typedef', name = T:text(alias), parent = parent, ti = alias, tj = alias })
                            elseif not alias and stop > close + 1 then
                                -- struct X {..} var;  → globals after the body
                                declaration(T, r, close + 1, math.min(stop, b), parent)
                            end
                            j = math.min(stop, b)
                            done = true
                        else
                            j = close + 1              -- initializer braces: keep scanning to ';'
                        end
                    end
                elseif (is(T, j, '(') or is(T, j, '[')) and T.m[j] then
                    j = T.m[j] + 1
                else
                    j = j + 1
                end
            end
            if not done then
                declaration(T, r, i, math.min(j, b), parent)
            end
            i = math.max(j, i) + 1
        end
    end
end

function M.parse(path, src)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'c')
    r.skip_calls = ATTR
    parse_range(T, r, 1, T.n, nil)
    return common.finish(r), T
end

-- Exposed for the C++ parser (lang/cpp.lua), which reuses these pieces.
M.parse_range = parse_range
M.function_head = function_head
M.decl_start = decl_start
M.declaration = declaration
M.members = members
M.handle_directive = handle_directive
M.fallback_close = fallback_close
M.paren_name = paren_name
M.ATTR = ATTR

return M
