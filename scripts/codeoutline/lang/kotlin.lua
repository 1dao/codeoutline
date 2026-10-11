-- Kotlin declarations and call sites over xscan; deliberately not a type checker.
local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')
local M = {}

M.config = {
    keywords = { 'as', 'break', 'class', 'continue', 'do', 'else', 'false', 'for', 'fun',
        'if', 'in', 'interface', 'is', 'null', 'object', 'package', 'return', 'super',
        'this', 'throw', 'true', 'try', 'typealias', 'typeof', 'val', 'var', 'when', 'while', 'import' },
    ops = { '===', '!==', '..<', '?.', '?:', '!!', '::', '->', '==', '!=', '<=', '>=',
        '&&', '||', '++', '--', '+=', '-=', '*=', '/=', '%=', '..' },
    line_comment = { '//' }, block_comment = { { '/*', '*/' } }, nested_comments = true,
    strings = { { '"""', '"""', multiline = true }, { '"', '"', escape = '\\' },
        { "'", "'", escape = '\\' }, { '`', '`' } },
}
M.lang = xscan.lang(M.config)

local MOD = {}
for s in ([[public private protected internal final open abstract sealed data enum annotation value
    inner companion override lateinit const tailrec operator infix inline noinline crossinline
    external suspend expect actual reified vararg out]]):gmatch('%S+') do MOD[s] = true end
local DECL = { class = true, interface = true, object = true, ['fun'] = true,
    val = true, var = true, typealias = true }
local CONTINUE = { ['='] = true, ['.'] = true, ['?.'] = true, ['?:'] = true, [','] = true,
    [':'] = true, ['->'] = true, ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true,
    ['&&'] = true, ['||'] = true, ['in'] = true, ['is'] = true, ['as'] = true, ['by'] = true }
local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function word(T, i, s) return (T.k[i] == 'id' or T.k[i] == 'kw') and T:text(i) == s end

-- xscan handles ordinary/raw strings, but Kotlin templates can nest quoted
-- expressions: "${render("}")}". Hide template interiors before tokenizing,
-- preserving every byte offset/newline; their expressions are not indexed.
local function template_source(src)
    if not src:find('${', 1, true) then return src end
    local quoted, expression
    local function comment(i)
        if src:sub(i, i + 1) == '//' then return src:find('\n', i + 2, true) or #src + 1 end
        if src:sub(i, i + 1) ~= '/*' then return nil end
        local depth = 1
        i = i + 2
        while i <= #src and depth > 0 do
            local pair = src:sub(i, i + 1)
            if pair == '/*' then depth = depth + 1; i = i + 2
            elseif pair == '*/' then depth = depth - 1; i = i + 2
            else i = i + 1 end
        end
        return i
    end
    quoted = function(i, depth)
        if depth > 64 then return #src + 1 end
        local delimiter = src:sub(i, i)
        if delimiter == '"' and src:sub(i, i + 2) == '"""' then delimiter = '"""' end
        local k = i + #delimiter
        while k <= #src do
            if src:sub(k, k + #delimiter - 1) == delimiter then return k + #delimiter end
            local c = src:sub(k, k)
            if c == '\\' and delimiter ~= '"""' and delimiter ~= '`' then k = k + 2
            elseif delimiter:sub(1, 1) == '"' and src:sub(k, k + 1) == '${' then k = expression(k + 2, depth + 1)
            else k = k + 1 end
        end
        return #src + 1
    end
    expression = function(i, depth)
        local braces = 1
        while i <= #src and braces > 0 do
            local c, after = src:sub(i, i), comment(i)
            if after then i = after
            elseif c == '"' or c == "'" or c == '`' then i = quoted(i, depth + 1)
            else
                if c == '{' then braces = braces + 1 elseif c == '}' then braces = braces - 1 end
                i = i + 1
            end
        end
        return i
    end
    local parts, start, i = {}, 1, 1
    while i <= #src do
        local c, after = src:sub(i, i), comment(i)
        if after then i = after
        elseif c == '"' or c == "'" or c == '`' then
            local last = quoted(i, 0)
            if c == '"' then
                local width = src:sub(i, i + 2) == '"""' and 3 or 1
                parts[#parts + 1] = src:sub(start, i + width - 1)
                parts[#parts + 1] = src:sub(i + width, last - width - 1):gsub('[^\r\n]', ' ')
                start = last - width
            end
            i = last
        else i = i + 1 end
    end
    parts[#parts + 1] = src:sub(start)
    return table.concat(parts)
end

local function angles(T, i, b)
    local d = 0
    for j = i, b do
        if is(T, j, '<') then d = d + 1
        elseif is(T, j, '>') then d = d - 1; if d == 0 then return j end
        elseif is(T, j, ';') or is(T, j, '{') or is(T, j, '=') then return nil end
    end
end

local function annotation(T, i, b, skip)
    local j = i + 1
    if is(T, j + 1, ':') then j = j + 2 end -- @file:JvmName, @get:Inject
    if is(T, j, '[') and T.m[j] then return T.m[j] + 1 end
    while j <= b and (T.k[j] == 'id' or T.k[j] == 'kw') do
        skip[j] = true
        j = j + 1
        if is(T, j, '.') then j = j + 1 else break end
    end
    if is(T, j, '(') and T.m[j] then j = T.m[j] + 1 end
    return j
end

-- End of a semicolon-free expression. Groups are skipped whole; operators,
-- chained receivers and control-expression bodies continue across newlines.
local function expression_end(T, a, b)
    local j = a
    while j <= b do
        if is(T, j, ';') then return j - 1 end
        if j > a then
            local s, prev = T:text(j), T:text(j - 1)
            if T.k[j] == 'kw' and DECL[s] and s ~= 'object' then return j - 1 end
            if T:line(j) > T:eline(j - 1) and not CONTINUE[prev]
                and not is(T, j, '.') and not is(T, j, '?.') and not is(T, j, '{')
                and not word(T, j, 'else') and not word(T, j, 'catch') and not word(T, j, 'finally')
                and not (is(T, j - 1, ')') and T.m[j - 1]
                    and (word(T, T.m[j - 1] - 1, 'if') or word(T, T.m[j - 1] - 1, 'when'))) then
                return j - 1
            end
        end
        if T.m[j] and T.m[j] > j then j = T.m[j] end
        j = j + 1
    end
    return b
end

local function type_end(T, a, b)
    local j = a
    while j <= b do
        if is(T, j, '=') or is(T, j, '{') or is(T, j, ';') or word(T, j, 'by') then break end
        if j > a and (word(T, j, 'get') or word(T, j, 'set') or word(T, j, 'where')) then break end
        if j > a and T:line(j) > T:eline(j - 1) and not CONTINUE[T:text(j - 1)] then break end
        if is(T, j, '<') then j = angles(T, j, b) or j
        elseif T.m[j] and T.m[j] > j then j = T.m[j] end
        j = j + 1
    end
    return j - 1
end

local scope
local function add(r, T, start, last, ni, parent, kind, sig_end, extra)
    local n = extra or {}
    n.kind, n.name, n.ni, n.parent = kind, n.name or T:text(ni), ni, parent
    n.ti, n.tj, n.sig = start, math.max(start, last), common.sig(T, start, sig_end or last)
    return common.add_node(r, T, n)
end

local function properties(T, r, a, b, parent, skip)
    local j = a
    while j <= b do
        if (word(T, j, 'val') or word(T, j, 'var')) and T.k[j + 1] == 'id' then
            local ni, last = j + 1, j + 1
            if is(T, ni + 1, ':') then
                last = ni + 2
                while last <= b and not is(T, last, ',') and not is(T, last, '=') do
                    if is(T, last, '<') then last = angles(T, last, b) or last
                    elseif T.m[last] and T.m[last] > last then last = T.m[last] end
                    last = last + 1
                end
                last = last - 1
            end
            add(r, T, j, last, ni, parent, 'property', last,
                { type = last > ni + 1 and common.sig(T, ni + 2, last) or nil })
            skip[ni] = true
            j = last
        elseif T.m[j] and T.m[j] > j then j = T.m[j] end
        j = j + 1
    end
end

scope = function(T, r, a, b, parent, skip)
    local i = a
    while i <= b do
        local start, j, mods = i, i, {}
        while j <= b do
            if is(T, j, '@') then j = annotation(T, j, b, skip)
            elseif T.k[j] == 'id' and MOD[T:text(j)] then mods[T:text(j)] = true; j = j + 1
            else break end
        end
        local s = T:text(j)
        local declaration = T.k[j] == 'kw' and DECL[s]
        if s == 'package' or s == 'import' then
            local parts, k = {}, j + 1
            while k <= b and (T.k[k] == 'id' or T.k[k] == 'kw') do
                parts[#parts + 1] = T:text(k); skip[k] = true; k = k + 1
                if is(T, k, '.') then
                    k = k + 1
                    if is(T, k, '*') then parts[#parts + 1] = '*'; k = k + 1; break end
                else break end
            end
            local path = table.concat(parts, '.')
            if s == 'package' then r.package, r.prefix = path, path
            else
                local alias
                if word(T, k, 'as') and T.k[k + 1] == 'id' then alias = T:text(k + 1); k = k + 2 end
                r.imports[#r.imports + 1] = { path = path, line = T:line(j), alias = alias }
            end
            i = k
        elseif declaration and (s == 'class' or s == 'interface' or s == 'object') then
            local ni = j + 1
            local named = T.k[ni] == 'id'
            if not named and not mods.companion then
                -- Anonymous object expressions: retain their members under the enclosing scope.
                i = j + 1
            else
                local k, ctor, bases, in_bases = named and ni + 1 or ni, nil, {}, false
                if not named then ni = j end
                local last = k - 1
                while k <= b and not is(T, k, '{') and not is(T, k, ';') do
                    if k > last + 1 and T:line(k) > T:eline(k - 1) and not CONTINUE[T:text(k - 1)]
                        and not is(T, k, ':') and not word(T, k, 'where') then break end
                    if T.k[k] == 'kw' and DECL[T:text(k)] then break end
                    if is(T, k, '<') then k = angles(T, k, b) or k
                    elseif is(T, k, '(') and T.m[k] then
                        if not in_bases then ctor = k end
                        k = T.m[k]
                    elseif is(T, k, ':') then in_bases = true
                    elseif in_bases and T.k[k] == 'id' and (is(T, k - 1, ':') or is(T, k - 1, ',')) then
                        local parts = { T:text(k) }
                        while is(T, k + 1, '.') and T.k[k + 2] == 'id' do k = k + 2; parts[#parts + 1] = T:text(k) end
                        bases[#bases + 1] = table.concat(parts, '.')
                    end
                    k = k + 1
                end
                local body = is(T, k, '{') and k or nil
                local close = body and (T.m[body] or b) or k - 1
                local kind = mods.enum and 'enum' or mods.annotation and 'annotation_type' or s == 'interface' and 'interface' or 'class'
                local id = add(r, T, start, close, ni, parent, kind, k - 1,
                    { name = named and T:text(ni) or 'Companion', bases = #bases > 0 and bases or nil,
                        singleton = s == 'object' or nil })
                skip[ni] = true
                if ctor then properties(T, r, ctor + 1, T.m[ctor] - 1, id, skip) end
                if body then
                    local first = body + 1
                    if mods.enum then
                        while first < close and not is(T, first, ';') do
                            if T.k[first] ~= 'id' or MOD[T:text(first)] then break end
                            local name, e = first, first + 1
                            if is(T, e, '(') and T.m[e] then e = T.m[e] + 1 end
                            if is(T, e, '{') and T.m[e] then e = T.m[e] + 1 end
                            add(r, T, name, e - 1, name, id, 'enum_member'); skip[name] = true
                            first = e
                            if is(T, first, ',') then first = first + 1 else break end
                        end
                    end
                    scope(T, r, first, close - 1, id, skip)
                end
                i = close + 1
            end
        elseif declaration and s == 'fun' then
            local k, ni, opening = j + 1
            if is(T, k, '<') then k = (angles(T, k, b) or k) + 1 end
            while k <= b do
                if is(T, k, '(') and T.m[k] then
                    if T.k[k - 1] == 'id' then ni, opening = k - 1, k; break end
                    k = T.m[k]
                elseif is(T, k, '<') then k = angles(T, k, b) or k
                elseif is(T, k, '{') or is(T, k, '=') or is(T, k, ';') then break end
                k = k + 1
            end
            if not opening then i = j + 1
            else
                local after, typ = T.m[opening] + 1, nil
                if is(T, after, ':') then
                    local e = type_end(T, after + 1, b)
                    typ = e >= after + 1 and common.sig(T, after + 1, e) or nil
                    after = e + 1
                end
                -- Generic constraints belong to the header, not a body.
                if word(T, after, 'where') then after = type_end(T, after, b) + 1 end
                local body = is(T, after, '{') and after or nil
                local expr = is(T, after, '=') and after + 1 or nil
                local last = body and (T.m[body] or b) or expr and math.max(after, expression_end(T, expr, b)) or after - 1
                local owner = parent and r.nodes[parent]
                local kind = owner and (owner.kind == 'class' or owner.kind == 'interface' or owner.kind == 'enum') and 'method' or 'function'
                local id = add(r, T, start, last, ni, parent, kind, after - 1,
                    { type = typ, abstract = not body and not expr or nil,
                        static = not parent and mods.private or nil,
                        receiver = is(T, ni - 1, '.') and common.sig(T, j + 1, ni - 2) or nil })
                skip[ni] = true
                if body then scope(T, r, body + 1, last - 1, id, skip)
                elseif expr then scope(T, r, expr, last, id, skip) end
                i = last + 1
            end
        elseif declaration and (s == 'val' or s == 'var' or s == 'typealias') and T.k[j + 1] == 'id' then
            local ni, k, typ = j + 1, j + 2, nil
            if s == 'typealias' and is(T, k, '<') then k = (angles(T, k, b) or k) + 1 end
            local receiver
            if s ~= 'typealias' then
                if is(T, k, '<') then k = (angles(T, k, b) or k) + 1 end
                while (is(T, k, '.') or is(T, k, '?.')) and T.k[k + 1] == 'id' do
                    receiver = common.sig(T, j + 1, k - 1)
                    ni, k = k + 1, k + 2
                end
            end
            if is(T, k, ':') then
                local e = type_end(T, k + 1, b)
                typ = e >= k + 1 and common.sig(T, k + 1, e) or nil; k = e + 1
            end
            local last = (is(T, k, '=') or word(T, k, 'by')) and math.max(k, expression_end(T, k + 1, b)) or k - 1
            -- Accessors extend the property range, and their calls belong to it.
            while word(T, last + 1, 'get') or word(T, last + 1, 'set') do
                local ac = last + 1
                skip[ac] = true
                local e = is(T, ac + 1, '(') and T.m[ac + 1] or ac
                e = e or ac
                if is(T, e + 1, ':') then e = type_end(T, e + 2, b) end
                if is(T, e + 1, '{') then last = T.m[e + 1] or b
                elseif is(T, e + 1, '=') then last = math.max(e + 1, expression_end(T, e + 2, b))
                else last = e end
            end
            local owner = parent and r.nodes[parent]
            local kind = s == 'typealias' and 'typedef' or owner and
                (owner.kind == 'class' or owner.kind == 'interface' or owner.kind == 'enum') and 'property' or 'variable'
            local id = add(r, T, start, last, ni, parent, kind, s == 'typealias' and last or k - 1,
                { type = typ, receiver = receiver, static = not parent and mods.private or nil })
            skip[ni] = true
            if k <= last then scope(T, r, k + 1, last, id, skip) end
            i = last + 1
        elseif word(T, j, 'constructor') and parent and is(T, j + 1, '(') and T.m[j + 1] then
            local k = T.m[j + 1] + 1
            while k <= b and not is(T, k, '{') and T:line(k) == T:eline(k - 1) do k = k + 1 end
            local body = is(T, k, '{') and k
            local last = body and (T.m[body] or b) or k - 1
            local id = add(r, T, start, last, j, parent, 'constructor', k - 1, { name = r.nodes[parent].name })
            skip[j] = true
            if body then scope(T, r, body + 1, last - 1, id, skip) end
            i = last + 1
        elseif is(T, j, '{') then
            local last = T.m[j] or b
            scope(T, r, j + 1, last - 1, parent, skip)
            i = last + 1
        else
            if word(T, j, 'init') then skip[j] = true end
            i = math.max(i + 1, j + 1)
        end
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(template_source(src))
    T.src = src
    -- Escaped identifiers are lexed as one token. Keep byte positions and text
    -- consistent for both native and Lua scanners (native methods use raw data).
    for i = 1, T.n do
        if T.k[i] == 'str' and T:text(i):sub(1, 1) == '`' and T:text(i):sub(-1) == '`' then
            T.k[i], T.s[i], T.e[i] = 'id', T.s[i] + 1, T.e[i] - 1
        end
    end
    function T:text(i) return self.s[i] and self.src:sub(self.s[i], self.e[i]) or '' end
    local r, skip = common.new(path, 'kotlin', opts), {}
    r.package = '' -- Kotlin's default package is shared across source directories.
    scope(T, r, 1, T.n, nil, skip)
    for i = 1, T.n do
        if T.k[i] == 'id' and not skip[i] then
            local nexti = i + 1
            if is(T, nexti, '<') then nexti = (angles(T, nexti, T.n) or nexti - 1) + 1 end
            local call = is(T, nexti, '(') or is(T, nexti, '{')
            local ref = is(T, i - 1, '::')
            if call or ref then
                local member = is(T, i - 1, '.') or is(T, i - 1, '?.') or ref
                local recv = member and (T.k[i - 2] == 'id' or word(T, i - 2, 'this') or word(T, i - 2, 'super')) and T:text(i - 2) or nil
                r.refs[#r.refs + 1] = { tok = i, name = T:text(i), kind = ref and 'ref' or member and 'member_call' or 'call',
                    recv = recv, line = T:line(i) }
            end
        end
    end
    return common.finish(r, T), T
end

return M
