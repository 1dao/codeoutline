-- Explicit type sites; detailed binding and ranges belong to queries only.
local M = { languages = { c = true, cpp = true, csharp = true, java = true,
    kotlin = true, typescript = true, arkts = true, go = true, rust = true } }
local builtin = {}
for word in ([[void bool boolean byte sbyte char wchar_t char16_t char32_t short int long float double decimal
 signed unsigned const volatile static extern inline virtual public private protected internal abstract override
 final sealed readonly ref out in params mut dyn impl auto var val let new class struct union enum interface
 record typename template typedef using extends implements throws where async await return yield get set
 string object any unknown never number symbol bigint undefined null true false self Self super this
 int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128
 rune error chan map func type pub fn trait i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64
 Unit Nothing Any Boolean Byte Short Int Long Float Double Char String dynamic]]):gmatch('%S+') do builtin[word] = true end
local callable = { ['function'] = true, method = true, prototype = true, constructor = true, destructor = true }
local containers = { class = true, struct = true, union = true, interface = true, record = true, enum = true }

function M.collect(r, T)
    if not M.languages[r.language] or r.cpp_aliases_only or r.dispatch_only then return end
    local language, sites, names, seen = r.language, {}, {}, {}
    local details = r.ordinary_bindings or r.ranges
    local suffix = language == 'typescript' or language == 'arkts' or language == 'kotlin' or language == 'rust'
    local prefix = language == 'c' or language == 'cpp' or language == 'java' or language == 'csharp'
    local separator = (language == 'c' or language == 'cpp' or language == 'rust') and '::' or '.'
    for _, n in ipairs(r.nodes) do if n.type_token then names[n.type_token] = true end end
    local function add(t, role, first, last)
        local name = T:text(t)
        if seen[t] or names[t] or T.k[t] ~= 'id' or not name:match('^[%a_$][%w_$]*$') then return end
        seen[t] = true
        local a = t
        while a > (first or 1) and T:text(a - 1) == separator and T.k[a - 2] == 'id' do a = a - 2 end
        if T:text(t + 1) == separator and t + 1 <= (last or T.n) then return end
        local written = T.src:sub(T.s[a], T.e[t]):gsub('%s+', '')
        local site = { tok = t, name = name, kind = 'type', line = T:line(t), type_role = role,
            recv = a < t and written:sub(1, #written - #name - #separator) or nil }
        sites[#sites + 1] = site
        if details then
            site.type_use = { role = role, written = written, line = site.line, first = T.s[t] - 1, last = T.e[t], at = T.s[a] - 1 }
            local tag = T:text(a - 1)
            if tag == 'struct' or tag == 'union' or tag == 'enum' or tag == 'class' then site.type_use.elaborated = tag end
        end
    end
    local function range(a, b, role, exclude)
        if not a or not b or a > b then return end
        for _, t in ipairs(T:idents(a, b)) do if t ~= exclude then add(t, role, a, b) end end
    end
    local function cut(a, b)
        local depth = 0
        for i = a, b do
            local s = T:text(i)
            if s == '<' then depth = depth + 1 elseif s == '>' then depth = math.max(0, depth - 1) end
            if depth == 0 and (s == '=' or s == '{' or s == 'where') then return i - 1 end
        end
        return b
    end
    local function angle(a, b, owner)
        if T:text(a) ~= '<' and not (language == 'go' and T:text(a) == '[') then return a end
        local open, close = T:text(a), T:text(a) == '[' and ']' or '>'
        local depth, expect = 1, true
        for i = a + 1, math.min(b, a + 256) do
            local s = T:text(i)
            if s == open then depth = depth + 1 elseif s == close then depth = depth - 1 end
            if depth == 0 then return i + 1 end
            if depth == 1 then
                if s == ',' then expect = true
                elseif T.k[i] == 'id' and expect then
                    names[i], expect = true, false
                    if r.ordinary_bindings or r.ranges then
                        r.type_parameters = r.type_parameters or {}
                        r.type_parameters[#r.type_parameters + 1] = { name = s, first = T.s[owner.ti] - 1, last = T.e[owner.tj] }
                    end
                elseif s == 'extends' or s == ':' then
                    local j = i + 1
                    while j <= b and T:text(j) ~= ',' and T:text(j) ~= close do j = j + 1 end
                    range(i + 1, j - 1, 'constraint')
                end
            end
        end
        return b + 1
    end
    local function parameter(a, b, role)
        b = cut(a, b)
        if a > b then return end
        if suffix then
            for i = a, b do if T:text(i) == ':' then range(i + 1, b, role); return end end
            return
        end
        if language == 'go' then
            if T.k[a] == 'id' and T:text(a + 1) ~= '.' and a < b then
                local i = a + 1
                while T:text(i) == ',' and T.k[i + 1] == 'id' do i = i + 2 end
                range(i, b, role)
            else range(a, b, role) end
            return
        end
        local last, count, depth, primitive = nil, 0, 0, false
        for i = a, b do
            local s = T:text(i)
            if s == '<' then depth = depth + 1 elseif s == '>' then depth = math.max(0, depth - 1) end
            if depth == 0 then
                if T.k[i] == 'id' then last, count = i, count + 1 end
                if s == 'int' or s == 'char' or s == 'void' or s == 'string' or s == 'bool' then primitive = true end
            end
        end
        local exclude = last and (count > 1 or primitive) and T:text(last - 1) ~= separator
            and T:text(last + 1) ~= '<' and last or nil
        range(a, b, role, exclude)
    end
    local function parameters(a, b, role)
        local start, i, depth = a, a, 0
        while i <= b + 1 do
            local s = T:text(i)
            if i == b + 1 or s == ',' and depth == 0 then parameter(start, i - 1, role); start = i + 1
            elseif s == '<' then depth = depth + 1
            elseif s == '>' then depth = math.max(0, depth - 1)
            elseif T.m[i] and T.m[i] > i then i = T.m[i] end
            i = i + 1
        end
    end
    local declaration_prefixes = {}
    for index, n in ipairs(r.nodes) do
        if index % 128 == 0 then require('codeoutline.control').check() end
        local ni = n.type_token
        if ni and (callable[n.kind] or containers[n.kind] or n.kind == 'typedef') then
            local a = n.ti
            while builtin[T:text(a)] and T:text(a) ~= 'template' and T:text(a) ~= 'void' do a = a + 1 end
            if language == 'java' and T:text(a) == '<' then angle(a, n.tj, n) end
            if language == 'cpp' then
                for j = n.ti, math.max(1, n.ti - 256), -1 do
                    local s = T:text(j)
                    if s == 'template' and T:text(j + 1) == '<' then angle(j + 1, n.tj, { ti = j, tj = n.tj }); break end
                    if j < n.ti and (s == ';' or s == '{' or s == '}') then break end
                end
            end
        end
        if ni and callable[n.kind] then
            local p = angle(ni + 1, n.tj, n)
            if T:text(p) == '(' and T.m[p] then
                local ending = T.m[p]
                parameters(p + 1, ending - 1, 'parameter')
                if prefix then range(n.ti, ni - 1, 'return') end
                local a = ending + 1
                if language == 'go' then
                    local b = a
                    while b <= n.tj and T:text(b) ~= '{' and T:text(b) ~= ';' and T.k[b] ~= 'nl' do b = b + 1 end
                    if T:text(a) == '(' and T.m[a] then parameters(a + 1, T.m[a] - 1, 'return') else range(a, b - 1, 'return') end
                    if T:text(n.ti + 1) == '(' and T.m[n.ti + 1] then parameters(n.ti + 2, T.m[n.ti + 1] - 1, 'receiver') end
                elseif T:text(a) == ':' or T:text(a) == '->' then range(a + 1, cut(a + 1, n.tj), 'return') end
            end
        elseif ni and containers[n.kind] then
            local a, mode = angle(ni + 1, n.tj, n), nil
            if T:text(a) == '(' and T.m[a] then parameters(a + 1, T.m[a] - 1, 'parameter'); a = T.m[a] + 1 end
            for i = a, n.tj do
                local s = T:text(i)
                if s == '{' then break end
                if s == ':' or s == 'extends' or s == 'implements' then mode = i + 1 end
                if mode and T.k[i] == 'id' then add(i, 'inheritance', mode, n.tj) end
            end
        elseif ni and (n.kind == 'field' or n.kind == 'property' or n.kind == 'variable' or n.kind == 'constant') then
            if prefix then
                local span = declaration_prefixes[n.tj]
                if not span then
                    local a = n.ti
                    if a >= ni then
                        a = ni - 1
                        while a > 0 and T:text(a) ~= ';' and T:text(a) ~= '{' and T:text(a) ~= '}' do a = a - 1 end
                        a = a + 1
                    end
                    span = { a, ni - 1 }; declaration_prefixes[n.tj] = span
                end
                range(span[1], span[2], n.kind == 'field' and 'field' or 'variable')
            elseif suffix and T:text(ni + 1) == ':' then range(ni + 2, cut(ni + 2, n.tj), (n.kind == 'field' or n.kind == 'property') and 'field' or 'variable')
            elseif language == 'go' then
                if n.embedded then range(n.ti, n.tj, 'inheritance') else range(ni + 1, cut(ni + 1, n.tj), n.kind == 'field' and 'field' or 'variable') end
            end
        elseif ni and n.kind == 'typedef' then
            local first_site, a, b = #sites + 1
            if prefix then
                if T:text(n.ti) == 'using' then a, b = ni + 2, n.tj - 1 else a, b = n.ti + 1, ni - 1 end
            else
                a = angle(ni + 1, n.tj, n); if T:text(a) == '=' then a = a + 1 end
                b = cut(a, n.tj)
            end
            range(a, b, 'alias')
            if details then
                local first, last = a, b
                if T:text(last) == ';' then last = last - 1 end
                local tag = T:text(first)
                if tag == 'struct' or tag == 'class' or tag == 'union' or tag == 'enum' then first = first + 1 end
                local plain, identifier = first <= last, true
                for j = first, last do
                    if identifier then plain = plain and T.k[j] == 'id'
                    else plain = plain and (T:text(j) == '.' or T:text(j) == '::') end
                    identifier = not identifier
                end
                -- Containers, unions, function types and pointer decoration are
                -- type uses, but do not make the alias identical to an element type.
                if plain and not identifier and (language ~= 'go' or T:text(ni + 1) == '=') then
                    for j = first_site, #sites do sites[j].type_use.alias_name = n.name end
                elseif language == 'go' and T:text(ni + 1) ~= '=' then
                    for j = first_site, #sites do sites[j].type_use.role = 'underlying' end
                end
            end
        end
    end
    local function import_alias(t)
        for i = t - 2, math.max(1, t - 128), -1 do
            local s = T:text(i)
            if s == 'import' or s == 'use' then return true end
            if s == ';' or s == '=' or s == 'return' or s == 'function' or s == 'fn' then return false end
            if s == '{' then
                for j = i - 1, math.max(1, i - 4), -1 do if T:text(j) == 'import' or T:text(j) == 'use' then return true end end
                return false
            end
        end
        return false
    end
    for _, i in ipairs(T:idents(1, T.n)) do
        local prev = T:text(i - 1)
        if prev == 'new' or prev == 'as' or prev == 'is' or prev == 'instanceof' then
            local j = i
            while T:text(j + 1) == separator and T.k[j + 2] == 'id' do j = j + 2 end
            if prev ~= 'as' or not import_alias(i) then range(i, j, prev == 'new' and 'construction' or 'cast') end
        elseif prev == '<' and (T:text(i - 2) == 'static_cast' or T:text(i - 2) == 'dynamic_cast'
            or T:text(i - 2) == 'const_cast' or T:text(i - 2) == 'reinterpret_cast') then
            local j = i; while j <= math.min(T.n, i + 128) and T:text(j) ~= '>' do j = j + 1 end
            if T:text(j) == '>' then range(i, j - 1, 'cast') end
        elseif (language == 'go' or language == 'rust') and T:text(i + 1) == '{'
            and (prev == '=' or prev == ':=' or prev == 'return' or prev == '&') then add(i, 'construction')
        elseif prefix and (prev == 'struct' or prev == 'class' or prev == 'union' or prev == 'enum') then add(i, 'variable')
        elseif prefix and (prev == ';' or prev == '{' or prev == '}' or prev == 'const' or prev == 'static') then
            local j = i
            while T:text(j + 1) == separator and T.k[j + 2] == 'id' do j = j + 2 end
            local p = j + 1
            if T:text(p) == '<' then
                local depth = 1; p = p + 1
                while p <= math.min(T.n, j + 128) and depth > 0 do
                    if T:text(p) == '<' then depth = depth + 1 elseif T:text(p) == '>' then depth = depth - 1 end
                    p = p + 1
                end
            end
            while T:text(p) == '*' or T:text(p) == '&' or T:text(p) == '&&' or T:text(p) == 'const' do p = p + 1 end
            if T.k[p] == 'id' and (T:text(p + 1) == '=' or T:text(p + 1) == ';' or T:text(p + 1) == ','
                or T:text(p + 1) == '[' or T:text(p + 1) == '{') then range(i, p - 1, 'variable') end
        elseif (suffix or language == 'go') and (prev == 'let' or prev == 'var' or prev == 'val' or prev == 'const') then
            local p = i + 1
            if suffix and T:text(p) == ':' then p = p + 1 elseif suffix then p = T.n + 1 end
            local b = p
            while b <= T.n and T:text(b) ~= '=' and T:text(b) ~= ';' and T:text(b) ~= '{'
                and T.k[b] ~= 'nl' and T:line(b) == T:line(i) do b = b + 1 end
            range(p, b - 1, 'variable')
        end
    end
    for _, i in ipairs(T:calls(1, T.n)) do
        local a = i
        while T:text(a - 1) == separator and T.k[a - 2] == 'id' do a = a - 2 end
        if T:text(a - 1) == 'new' then add(i, 'construction', a, i) end
    end
    local typed = {}; for _, site in ipairs(sites) do typed[site.tok] = site end
    local count, kept = #r.refs, 0
    for i = 1, count do
        local ref = r.refs[i]
        local site = typed[ref.tok]
        if not site or site.type_role == 'construction' or ref.name ~= site.name then
            kept = kept + 1; r.refs[kept] = ref
        end
    end
    for i = kept + 1, count do r.refs[i] = nil end
    for _, site in ipairs(sites) do r.refs[#r.refs + 1] = site end
end
return M
