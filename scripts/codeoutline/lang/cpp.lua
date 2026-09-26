-- lang/cpp.lua — index-level C++ parser: namespaces, classes/structs/unions
-- (+ bases, members), enums (incl. `enum class`), functions and methods
-- (inline and out-of-line `A::B::f`), constructors with init lists,
-- destructors, operators, templates, `using` aliases, plus everything the C
-- parser handles (macros, #include, typedefs, globals, calls).
--
-- Built on the C parser's helpers rather than its main loop, so C results
-- stay exactly as validated. Qualified names use '::'.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')
local c = require('codeoutline.lang.c')

local M = {}

local KEYWORDS = {}
for _, k in ipairs(c.keywords) do KEYWORDS[#KEYWORDS + 1] = k end
for k in ([[alignas alignof asm bool catch char8_t char16_t char32_t class concept consteval
    constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast
    explicit export false friend mutable namespace new noexcept nullptr operator private
    protected public reinterpret_cast requires static_assert static_cast template this
    thread_local throw true try typeid typename using virtual wchar_t]]):gmatch('%S+') do
    KEYWORDS[#KEYWORDS + 1] = k
end

local OPS = {}
for _, o in ipairs(c.ops) do OPS[#OPS + 1] = o end
for _, o in ipairs({ '->*', '.*', '<=>' }) do OPS[#OPS + 1] = o end

M.config = {
    keywords = KEYWORDS,
    ops = OPS,
    line_comment = { '//' },
    block_comment = { { '/*', '*/' } },
    strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
    string_prefixes = 'LuU8R',
    directive = '#',
    pp_first_branch = true,
}

M.lang = xscan.lang(M.config)

local ATTR = {}
for k in pairs(c.ATTR) do ATTR[k] = true end
ATTR.decltype = true

local ACCESS = { public = true, private = true, protected = true }
local QT_SECTIONS = { signals = true, slots = true, Q_SIGNALS = true, Q_SLOTS = true }
-- Tokens that may follow a parameter list before the body.
local TRAIL_KW = { const = true, noexcept = true, volatile = true, mutable = true, throw = true, try = true }
local CLASSLIKE = { class = true, struct = true, union = true }

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

-- Change in template angle depth ('>>' closes two).
local function angle(T, i)
    if T.k[i] ~= 'op' then return 0 end
    local t = T:text(i)
    if t == '<' then return 1 elseif t == '>' then return -1 elseif t == '>>' then return -2 end
    return 0
end

-- Index after a template argument list opening at '<' i, or nil.
local function skip_angle(T, i, limit)
    local d = 0
    local x = i
    while x <= limit do
        if is(T, x, ';') or is(T, x, '{') or is(T, x, '}') then return nil end
        if (is(T, x, '(') or is(T, x, '[')) and T.m[x] then
            x = T.m[x]
        else
            d = d + angle(T, x)
            if d <= 0 then return x + 1 end
        end
        x = x + 1
    end
    return nil
end

-- Skip backwards over a template argument list ending at '>' / '>>' x.
local function skip_angle_back(T, x, floor)
    local d = 0
    while x >= floor do
        d = d - angle(T, x)
        if d <= 0 then return x - 1 end
        x = x - 1
    end
    return floor - 1
end

-- The declarator name whose parameter list opens at '(' o. Returns
-- { first = first token of the qualified name, name = text, quals = {...} }.
local function name_before_paren(T, o, floor)
    local p = o - 1
    local first, name
    if p < floor then return nil end
    if is(T, p, ')') and T.m[p] == p - 1 and kw(T, p - 2, 'operator') then
        first, name = p - 2, 'operator()'
    elseif is(T, p, ']') and T.m[p] == p - 1 and kw(T, p - 2, 'operator') then
        first, name = p - 2, 'operator[]'
    elseif T.k[p] == 'op' then
        local q = p
        while q > p - 3 and q >= floor and not kw(T, q, 'operator') do q = q - 1 end
        if not kw(T, q, 'operator') then return nil end
        local parts = {}
        for z = q + 1, p do parts[#parts + 1] = T:text(z) end
        first, name = q, 'operator' .. table.concat(parts)
    elseif T.k[p] == 'id' or (T.k[p] == 'kw' and kw(T, p - 1, 'operator')) then
        p = c.paren_name(T, p)
        if kw(T, p - 1, 'operator') then
            first, name = p - 1, 'operator ' .. T:text(p)       -- conversion: operator bool
        elseif is(T, p - 1, '~') then
            first, name = p - 1, '~' .. T:text(p)
        elseif T.k[p] == 'id' then
            first, name = p, T:text(p)
        else
            return nil
        end
    else
        return nil
    end
    -- qualifier chain: A::B::name, A<T>::name
    local quals = {}
    local q = first - 1
    while q > floor and is(T, q, '::') do
        local z = q - 1
        if is(T, z, '>') or is(T, z, '>>') then z = skip_angle_back(T, z, floor) end
        if T.k[z] ~= 'id' then break end
        table.insert(quals, 1, T:text(z))
        first = z
        q = z - 1
    end
    return { first = first, name = name, quals = quals }
end

-- If the '{' at j opens a function body, describe the head; the parameter
-- list is found by walking back over trailing qualifiers, a trailing return
-- type (`-> T`), noexcept(...)/attribute groups and macros.
local function cpp_head(T, a, j)
    local x = j - 1
    -- trailing return type: `) -> T {`
    local y, guard = x, 0
    while y > a and guard < 40 do
        if is(T, y, '->') then
            x = y - 1
            break
        end
        if is(T, y, ';') or is(T, y, '{') or is(T, y, '}') or is(T, y, '=') or is(T, y, ')') and not T.m[y] then break end
        if (is(T, y, ')') or is(T, y, ']')) and T.m[y] then y = T.m[y] - 1 else y = y - 1 end
        guard = guard + 1
    end
    while x >= a do
        if is(T, x, ')') then
            local o = T.m[x]
            if not o or o <= a then return nil end
            local p = o - 1
            if (T.k[p] == 'kw' and (T:text(p) == 'noexcept' or T:text(p) == 'throw' or T:text(p) == 'decltype'))
                or (T.k[p] == 'id' and ATTR[T:text(p)]) then
                x = p - 1                          -- noexcept(...), __attribute__((...))
            else
                local info = name_before_paren(T, o, a)
                if not info then return nil end
                info.open, info.close = o, x
                return info
            end
        elseif is(T, x, ']') and T.m[x] and is(T, T.m[x] + 1, '[') then
            x = T.m[x] - 1                         -- [[attribute]]
        elseif (T.k[x] == 'kw' and TRAIL_KW[T:text(x)]) or T.k[x] == 'id' or is(T, x, '&') or is(T, x, '&&') then
            x = x - 1                              -- const, override, final, &&, macros
        else
            return nil
        end
    end
    return nil
end

-- Constructor init list after ') :' at colon index k: returns the body '{'.
local function init_list_body(T, k, b)
    local x = k + 1
    while x <= b do
        if T.k[x] ~= 'id' then return nil end
        x = x + 1
        while is(T, x, '::') and T.k[x + 1] == 'id' do x = x + 2 end
        if is(T, x, '<') then
            x = skip_angle(T, x, b)
            if not x then return nil end
        end
        if (is(T, x, '(') or is(T, x, '{')) and T.m[x] then x = T.m[x] + 1 else return nil end
        if is(T, x, '...') then x = x + 1 end
        if is(T, x, ',') then
            x = x + 1
        elseif is(T, x, '{') then
            return x
        else
            return nil
        end
    end
    return nil
end

-- Statement `[i, j]` ending in ';': prototypes, fields/variables, aliases.
local function cpp_decl(T, r, i, j, parent)
    local first = T:text(i)
    if first == 'typedef' then return c.declaration(T, r, i, j, parent) end
    if first == 'using' then
        if T.k[i + 1] == 'id' and is(T, i + 2, '=') then
            common.add_node(r, T, { kind = 'typedef', name = T:text(i + 1), parent = parent, ti = i, tj = j, sig = common.sig(T, i, j) })
        end
        return
    end
    if first == 'friend' or first == 'static_assert' or first == 'namespace' then return end
    if first == 'enum' then return end                    -- enum class X : int;
    if T.k[i] == 'kw' and CLASSLIKE[first] and j - i <= 3 then
        return                                             -- class X;  (struct X *p; still falls through)
    end
    local is_extern = first == 'extern' and T.k[i + 1] ~= 'str'
    local y, eq, d = i, nil, 0
    local names = {}
    while y < j do
        d = d + angle(T, y)
        if d < 0 then d = 0 end
        if is(T, y, '=') and not eq and d == 0 and not kw(T, y - 1, 'operator') then eq = y end
        if is(T, y, '(') and T.m[y] then
            if not eq and d == 0 then
                local info = name_before_paren(T, y, i)
                if info and info.first > i - 1 and not ATTR[info.name] then
                    local ctor = parent and r.nodes[parent].name == info.name
                    if info.first == i and #info.quals == 0 and not info.name:find('^[~o]') and not ctor then
                        common.add_calls(r, T, i, j)          -- MACRO(args);
                        return
                    end
                    common.add_node(r, T, {
                        kind = 'prototype', name = info.name, parent = parent,
                        ti = i, tj = j, sig = common.sig(T, i, T.m[y]),
                        quals = #info.quals > 0 and info.quals or nil,
                        static = first == 'static' or nil,
                    })
                    common.add_calls(r, T, T.m[y] + 1, j)     -- default member initializers etc.
                    return
                end
            end
            y = T.m[y] + 1
        elseif (is(T, y, '[') or is(T, y, '{')) and T.m[y] then
            if T.k[y - 1] == 'id' and is(T, y, '{') and not eq and d == 0 then names[#names + 1] = y - 1 end
            y = T.m[y] + 1
        else
            if T.k[y] == 'id' and not eq and d == 0 and T.k[y + 1] == 'op' then
                local nx = T:text(y + 1)
                if nx == '=' or nx == ';' or nx == ',' or nx == '[' or nx == ':' then names[#names + 1] = y end
            end
            if is(T, y, ',') and d == 0 then eq = nil end
            y = y + 1
        end
    end
    if is_extern then names = {} end
    for _, x in ipairs(names) do
        -- `int Shape::counter_ = 0;` defines a static member of Shape
        local quals, q = {}, x - 1
        while is(T, q, '::') and T.k[q - 1] == 'id' do
            table.insert(quals, 1, T:text(q - 1))
            q = q - 2
        end
        common.add_node(r, T, {
            kind = 'variable', name = T:text(x), parent = parent, ti = x, tj = j,
            static = first == 'static' or nil, sig = common.sig(T, i, math.min(j, x + 1)),
            quals = #quals > 0 and quals or nil,
        })
    end
    common.add_calls(r, T, i, j)
    common.add_value_refs(r, T, i, j)
end

local cpp_range

-- class/struct/union/enum definition with its body '{' at j.
local function aggregate(T, r, i, head, j, close, b, parent, agg)
    local kind = T:text(agg)
    local x = agg + 1
    if kind == 'enum' and (kw(T, x, 'class') or kw(T, x, 'struct')) then x = x + 1 end
    while is(T, x, '[') and T.m[x] do x = T.m[x] + 1 end                 -- [[attr]]
    while T.k[x] == 'id' and ATTR[T:text(x)] and is(T, x + 1, '(') and T.m[x + 1] do x = T.m[x + 1] + 1 end
    -- `class MYLIB_API Widget final : Base` -> the last identifier of the
    -- run before ':' / '{' / '<' is the name; earlier ones are export macros
    local name_tok
    while T.k[x] == 'id' and x < j do
        local t = T:text(x)
        if t ~= 'final' and t ~= 'sealed' then name_tok = x end
        if is(T, x + 1, '::') and T.k[x + 2] == 'id' then
            x = x + 2
        elseif T.k[x + 1] == 'id' then
            x = x + 1
        else
            break
        end
    end
    -- bases: `: public A, private ns::B<T>`
    local bases
    if name_tok and kind ~= 'enum' then
        local y = name_tok + 1
        if is(T, y, '<') then y = skip_angle(T, y, j) or y end
        while T.k[y] == 'id' and (T:text(y) == 'final' or T:text(y) == 'sealed') do y = y + 1 end
        if is(T, y, ':') then
            bases = {}
            local z = y + 1
            while z < j do
                if T.k[z] == 'kw' and (ACCESS[T:text(z)] or T:text(z) == 'virtual') then
                    z = z + 1
                elseif T.k[z] == 'id' then
                    local nm = T:text(z)
                    z = z + 1
                    while is(T, z, '::') and T.k[z + 1] == 'id' do nm = nm .. '::' .. T:text(z + 1); z = z + 2 end
                    bases[#bases + 1] = nm
                    if is(T, z, '<') then z = skip_angle(T, z, j) or j end
                else
                    z = z + 1
                end
            end
        end
    end
    -- trailing declarators: `} name;` / typedef alias
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
            ti = i, tj = close, sig = common.sig(T, head, j - 1), bases = bases,
        })
        if kind == 'enum' then
            c.members(T, r, j, close, node, true)
        else
            cpp_range(T, r, j + 1, close - 1, node)
        end
    elseif kind == 'enum' then
        c.members(T, r, j, close, parent, true)
    else
        cpp_range(T, r, j + 1, close - 1, parent)       -- anonymous struct/union members
    end
    if alias and alias ~= nm then
        common.add_node(r, T, { kind = 'typedef', name = T:text(alias), parent = parent, ti = alias, tj = alias })
    elseif not alias and stop > close + 1 then
        cpp_decl(T, r, close + 1, math.min(stop, b), parent)
    end
    return math.min(stop, b)
end

-- Parse the declarations in token range [a, b].
cpp_range = function(T, r, a, b, parent)
    local i = a
    while i <= b do
        local k = T.k[i]
        local t = T:text(i)
        if k == 'dir' then
            c.handle_directive(T, r, i)
            i = i + 1
        elseif k == 'op' and (t == ';' or t == '}') then
            i = i + 1
        elseif (k == 'kw' and ACCESS[t] or k == 'id' and QT_SECTIONS[t]) and is(T, i + 1, ':') then
            i = i + 2                                          -- public:  signals:
        elseif k == 'kw' and ACCESS[t] and T.k[i + 1] == 'id' and QT_SECTIONS[T:text(i + 1)] and is(T, i + 2, ':') then
            i = i + 3                                          -- public slots:
        elseif k == 'kw' and t == 'namespace' then
            local j = i + 1
            while j <= b and not is(T, j, '{') and not is(T, j, ';') and not is(T, j, '=') do j = j + 1 end
            if is(T, j, '{') then
                local close = T.m[j] or c.fallback_close(T, j, b)
                local full = common.sig(T, i + 1, j - 1):gsub('%s', ''):gsub('^inline', '')
                local node = parent
                if full ~= '' and j > i + 1 then
                    -- C++17 `namespace a::b {`: name is the last part, the rest qualifies it
                    local quals = {}
                    for part in full:gmatch('[^:]+') do quals[#quals + 1] = part end
                    local name = table.remove(quals)
                    node = common.add_node(r, T, {
                        kind = 'namespace', name = name, parent = parent, ti = i, tj = close,
                        quals = #quals > 0 and quals or nil,
                    })
                end
                cpp_range(T, r, j + 1, close - 1, node)
                i = close + 1
            else
                while j <= b and not is(T, j, ';') do j = j + 1 end   -- namespace alias
                i = j + 1
            end
        elseif k == 'kw' and t == 'extern' and T.k[i + 1] == 'str' and is(T, i + 2, '{') then
            local close = T.m[i + 2] or c.fallback_close(T, i + 2, b)
            cpp_range(T, r, i + 3, close - 1, parent)           -- extern "C" { ... }
            i = close + 1
        else
            -- template<...> prefix: the declaration proper starts after it
            local head = i
            while kw(T, head, 'template') and is(T, head + 1, '<') do
                head = skip_angle(T, head + 1, b) or (head + 2)
            end
            local j, done, eq, d = head, false, nil, 0
            while j <= b and not done do
                local kj = T.k[j]
                if kj == 'dir' then
                    if j > head then cpp_decl(T, r, head, j - 1, parent) end
                    j = j - 1
                    done = true
                elseif is(T, j, ';') then
                    cpp_decl(T, r, head, j, parent)
                    done = true
                elseif kj == 'kw' and ACCESS[T:text(j)] and is(T, j + 1, ':') and j > head then
                    -- a macro line without ';' (Q_OBJECT) ran into `public:`
                    j = j - 1
                    done = true
                elseif is(T, j, ':') and is(T, j - 1, ')') and not eq then
                    local body = init_list_body(T, j, b)
                    if body then
                        local info = cpp_head(T, head, j)
                        local close = T.m[body] or c.fallback_close(T, body, b)
                        if info then
                            common.add_node(r, T, {
                                kind = 'function', name = info.name, parent = parent, ti = i, tj = close,
                                sig = common.sig(T, head, info.close),
                                quals = #info.quals > 0 and info.quals or nil,
                            })
                        end
                        common.add_calls(r, T, j, close)       -- init list + body
                        common.add_value_refs(r, T, body, close)
                        j = close
                        done = true
                    else
                        j = j + 1
                    end
                elseif is(T, j, '{') then
                    local close = T.m[j] or c.fallback_close(T, j, b)
                    local info = not eq and cpp_head(T, head, j)
                    local agg
                    if not info and not eq then
                        local y, dd = head, 0
                        while y < j do
                            dd = dd + angle(T, y)
                            if dd == 0 and T.k[y] == 'kw' and (CLASSLIKE[T:text(y)] or T:text(y) == 'enum') then agg = y; break end
                            if (is(T, y, '(') or is(T, y, '[')) and T.m[y] then y = T.m[y] end
                            y = y + 1
                        end
                    end
                    if info then
                        common.add_node(r, T, {
                            kind = 'function', name = info.name, parent = parent, ti = i, tj = close,
                            sig = common.sig(T, head, info.close),
                            quals = #info.quals > 0 and info.quals or nil,
                            static = T:text(head) == 'static' or nil,
                        })
                        common.add_calls(r, T, info.close + 1, close)
                        common.add_value_refs(r, T, j, close)
                        j = close
                        done = true
                    elseif agg then
                        j = aggregate(T, r, i, head, j, close, b, parent, agg)
                        done = true
                    else
                        j = close + 1                          -- initializer braces / lambda
                    end
                else
                    if is(T, j, '=') and d == 0 and not kw(T, j - 1, 'operator') then eq = j end
                    d = math.max(0, d + angle(T, j))
                    if (is(T, j, '(') or is(T, j, '[')) and T.m[j] then
                        j = T.m[j] + 1
                    else
                        j = j + 1
                    end
                end
            end
            if not done and j > head then
                cpp_decl(T, r, head, math.min(j, b), parent)
            end
            i = math.max(j, i) + 1
        end
    end
end

-- Kinds and '::'-qualified names, fixed up once the tree is known:
-- members of a class become methods/fields, `A::f` out-of-line
-- definitions become methods of A, and ctor/dtor names are recognized.
local CLASS_KINDS = { class = true, struct = true, union = true }
local function finalize(r)
    for _, n in ipairs(r.nodes) do
        local p = n.parent and r.nodes[n.parent]
        local owner = p and CLASS_KINDS[p.kind] and p or nil
        local quals = n.quals
        if quals then
            local prefix = (p and p.kind == 'namespace') and (p.qualified .. '::') or ''
            n.qualified = prefix .. table.concat(quals, '::') .. '::' .. n.name
        else
            n.qualified = p and (p.qualified .. '::' .. n.name) or n.name
        end
        -- `static` on a class member is not internal linkage: only file- or
        -- namespace-scope statics are invisible outside their file
        if owner or quals then n.static = nil end
        local cls_name = owner and owner.name or (quals and quals[#quals])
        -- an in-class declaration stays marked, so resolution prefers the
        -- out-of-line definition the way it prefers definitions over prototypes
        if n.kind == 'prototype' and (owner or quals) then n.decl = true end
        if n.kind == 'function' or n.kind == 'prototype' then
            if cls_name and n.name == cls_name then
                n.kind = 'constructor'
            elseif cls_name and n.name == '~' .. cls_name then
                n.kind = 'destructor'
            elseif owner or quals then
                n.kind = 'method'
            end
        elseif n.kind == 'variable' and (owner or quals) then
            n.kind = 'field'
        end
        n.quals = nil
    end
end

function M.parse(path, src)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'cpp')
    r.skip_calls = ATTR
    cpp_range(T, r, 1, T.n, nil)
    finalize(r)
    return common.finish(r), T
end

-- A .h file is C++ when it uses C++-only syntax; otherwise the C parser
-- keeps handling it (C code may use `new`/`class` as plain identifiers).
function M.looks_cpp(src)
    return src:find('%f[%w_]namespace%s+[%w_]*%s*{') or src:find('%f[%w_]class%s+[%w_]+%s*[:{]')
        or src:find('%f[%w_]template%s*<') or src:find('%f[%w_]public%s*:') or src:find('%f[%w_]std::')
end

return M
