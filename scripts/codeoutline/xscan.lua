-- xscan.lua — configurable tokenizer + bracket matcher, pure-Lua reference
-- implementation. The API is the contract for a later C port: language
-- parsers (lang/*.lua) only touch the Tokens methods below, so swapping in
-- the C module needs no parser changes.
--
--   local L = xscan.lang{ ...config... }
--   local t = L:tokenize(src)
--   t.n, t:kind(i), t:text(i), t:line(i), t:eline(i), t:match(i), t:calls(i, j)
--
-- Token kinds: 'id' identifier, 'kw' keyword, 'op' operator/punctuation,
-- 'str' string/char literal, 'num' number, 'dir' preprocessor line,
-- 'nl' logical newline, 'indent'/'dedent' (indent mode only).
--
-- Config keys (all optional):
--   ident_start, ident_char   character ranges, e.g. 'A-Za-z_' (bytes >= 0x80 always count)
--   keywords                  list of reserved words
--   ops                       multi-char operators; longest match wins
--   line_comment              list of prefixes ('//', '#')
--   block_comment             list of {open, close}
--   strings                   list of {open, close, escape = '\\', multiline = bool}
--   string_prefixes           letters allowed before a quote (Python r/b/f/u)
--   directive                 char that starts a whole-line directive at line start ('#')
--   pp_first_branch           C preprocessor: keep only the first live #if branch
--   indent                    emit nl/indent/dedent (Python)
--   long_brackets             Lua [==[ strings ]==] and --[==[ comments ]==]
--   template_literals         JS `a ${b} c` (nested templates in ${})
--   regex_literals            JS /re/flags where an operand may start
--   lifetimes                 Rust 'a lifetimes (vs 'a' chars)
--   raw_strings               Rust r"..", r#"..."#, br#"..."#
--   nested_comments           Rust: block comments nest

-- The runtime's native module (xlua/lua_xscan.c) implements this same
-- contract; prefer it unless XSCAN_PURE_LUA is set (parity testing).
if type(_G.xscan) == 'table' and _G.xscan.lang and os.getenv('XSCAN_PURE_LUA') ~= '1' then
    return _G.xscan
end

local M = {}

local Lang = {}
Lang.__index = Lang

local function char_set(ranges)
    local set = {}
    for i = 128, 255 do set[i] = true end
    local k = 1
    while k <= #ranges do
        local a, b = ranges:byte(k), ranges:byte(k + 2)
        if ranges:sub(k + 1, k + 1) == '-' and b then
            for c = a, b do set[c] = true end
            k = k + 3
        else
            set[a] = true
            k = k + 1
        end
    end
    return set
end

function M.lang(cfg)
    local L = setmetatable({ cfg = cfg }, Lang)
    L.id_start = char_set(cfg.ident_start or 'A-Za-z_')
    L.id_char = char_set(cfg.ident_char or 'A-Za-z0-9_')
    L.keywords = {}
    for _, k in ipairs(cfg.keywords or {}) do L.keywords[k] = true end
    -- Operators bucketed by first byte, longest first.
    L.ops = {}
    for _, op in ipairs(cfg.ops or {}) do
        local b = op:byte(1)
        L.ops[b] = L.ops[b] or {}
        table.insert(L.ops[b], op)
    end
    for _, list in pairs(L.ops) do table.sort(list, function(a, b) return #a > #b end) end
    L.line_comment = cfg.line_comment or {}
    L.block_comment = cfg.block_comment or {}
    L.strings = cfg.strings or {}
    L.prefixes = {}
    for c in (cfg.string_prefixes or ''):gmatch('.') do
        L.prefixes[c:byte()] = true
        L.prefixes[c:upper():byte()] = true
    end
    return L
end

local Tokens = {}
Tokens.__index = Tokens

function Tokens:kind(i) return self.k[i] end
function Tokens:text(i)
    local a = self.s[i]
    if not a then return '' end
    return self.src:sub(a, self.e[i])
end
function Tokens:line(i) return self.l[i] end
function Tokens:eline(i) return self.el[i] end
function Tokens:match(i) return self.m[i] end
function Tokens:is(i, text)
    local a = self.s[i]
    return a ~= nil and self.k[i] ~= 'str' and self.src:sub(a, self.e[i]) == text
end

-- Identifiers in (i, j) that are directly followed by '(' — call sites.
-- Returned as token indices; the parser inspects neighbors for receivers.
function Tokens:calls(i, j)
    local out = {}
    local k, s, src = self.k, self.s, self.src
    for x = i, j - 1 do
        if k[x] == 'id' and k[x + 1] == 'op' and src:byte(s[x + 1]) == 40 and self.e[x + 1] == s[x + 1] then
            out[#out + 1] = x
        end
    end
    return out
end

-- Identifier tokens in (i, j) not followed by '(' — candidate references
-- (function pointers, callbacks registered in tables).
function Tokens:idents(i, j)
    local out = {}
    local k, s, src = self.k, self.s, self.src
    for x = i, j do
        if k[x] == 'id' and not (k[x + 1] == 'op' and src:byte(s[x + 1]) == 40) then
            out[#out + 1] = x
        end
    end
    return out
end

local function starts(src, pos, lit)
    return src:sub(pos, pos + #lit - 1) == lit
end

local function count_nl(src, a, b)
    local n, p = 0, a
    while true do
        p = src:find('\n', p, true)
        if not p or p > b then return n end
        n = n + 1
        p = p + 1
    end
end

-- Lua long bracket opening at p: '[' '='* '['. Returns its level (the
-- number of '='), or nil when p does not open one.
local function long_open(src, p)
    if src:byte(p) ~= 91 then return nil end
    local q, level = p + 1, 0
    while src:byte(q) == 61 do q = q + 1; level = level + 1 end
    if src:byte(q) == 91 then return level end
    return nil
end

-- Last byte of the long bracket opened at p: the first ']' '='*level ']'
-- after it, or the end of the source when it is never closed.
local function long_close(src, p, level)
    local _, stop = src:find(']' .. string.rep('=', level) .. ']', p + level + 2, true)
    return stop or #src
end

-- End of a quoted run opened at p by quote byte q (backslash escapes; stops
-- at a newline so a stray quote cannot swallow the file).
local function skip_quoted(src, p, q)
    local x, len = p + 1, #src
    while x <= len do
        local b = src:byte(x)
        if b == 92 then x = x + 2
        elseif b == q or b == 10 then return x
        else x = x + 1 end
    end
    return len
end

local skip_template

-- Matching '}' of the `${` expression whose '{' is at p.
local function skip_braces(src, p)
    local depth, x, len = 0, p, #src
    while x <= len do
        local b = src:byte(x)
        if b == 123 then depth = depth + 1
        elseif b == 125 then
            depth = depth - 1
            if depth == 0 then return x end
        elseif b == 96 then x = skip_template(src, x)
        elseif b == 34 or b == 39 then x = skip_quoted(src, x, b)
        elseif b == 47 and src:byte(x + 1) == 47 then
            while x <= len and src:byte(x) ~= 10 do x = x + 1 end      -- // comment
        elseif b == 47 and src:byte(x + 1) == 42 then
            x = x + 2                                                  -- block comment
            while x < len and not (src:byte(x) == 42 and src:byte(x + 1) == 47) do x = x + 1 end
            x = x + 1
        end
        x = x + 1
    end
    return len
end

-- Closing backtick of a JS template literal opened at p; `${ ... }` parts
-- may nest strings and further templates.
skip_template = function(src, p)
    local x, len = p + 1, #src
    while x <= len do
        local b = src:byte(x)
        if b == 92 then x = x + 2
        elseif b == 96 then return x
        elseif b == 36 and src:byte(x + 1) == 123 then x = skip_braces(src, x + 1) + 1
        else x = x + 1 end
    end
    return len
end

-- A '/' starts a regex only where an operand may start: not after an
-- identifier, number, string, `)`, `]`, `}`, or a value keyword.
local REGEX_AFTER_VALUE_KW = { this = true, super = true, ['true'] = true, ['false'] = true, null = true }
local function regex_allowed(src, K, S, E, n, ctrl_close)
    if n == 0 then return true end
    local k = K[n]
    if k == 'id' or k == 'num' or k == 'str' then return false end
    local t = src:sub(S[n], E[n])
    -- `if (x) /re/.test(s)`: a ')' closing a control condition ends no operand
    if k == 'op' and t == ')' then return ctrl_close == n end
    if k == 'op' then return not (t == ']' or t == '}') end
    if k == 'kw' then return not REGEX_AFTER_VALUE_KW[t] end
    return true
end

-- Last byte (flags included) of a regex literal opened at p, or nil when
-- the line ends first (then the '/' was a division after all).
local function scan_regex(src, p, id_char)
    local x, len, in_class = p + 1, #src, false
    while x <= len do
        local b = src:byte(x)
        if b == 92 then
            x = x + 2
        elseif b == 10 then
            return nil
        else
            if in_class then
                if b == 93 then in_class = false end
            elseif b == 91 then
                in_class = true
            elseif b == 47 then
                x = x + 1
                while x <= len and id_char[src:byte(x)] do x = x + 1 end
                return x - 1
            end
            x = x + 1
        end
    end
    return nil
end

-- Rust raw string at p: [bc]?r#*" ... "#*. Returns its last byte or nil.
local function scan_raw_string(src, p, id_char)
    if p > 1 and id_char[src:byte(p - 1)] then return nil end
    local x = p
    local c = src:byte(x)
    if c == 98 or c == 99 then x = x + 1 end
    if src:byte(x) ~= 114 then return nil end
    x = x + 1
    local hashes = 0
    while src:byte(x) == 35 do hashes = hashes + 1; x = x + 1 end
    if src:byte(x) ~= 34 then return nil end
    local _, stop = src:find('"' .. string.rep('#', hashes), x + 1, true)
    return stop or #src
end

-- Rust `'a` lifetime (not a `'a'` char) at p: returns its last byte or nil.
local function scan_lifetime(src, p, id_start, id_char)
    local c = src:byte(p + 1)
    if not c or c == 92 or not id_start[c] then return nil end
    local w = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
    if src:byte(p + 1 + w) == 39 then return nil end
    local x = p + 1
    while x <= #src and id_char[src:byte(x)] do x = x + 1 end
    return x - 1
end

local OPEN = { [40] = 41, [91] = 93, [123] = 125 }     -- ( [ {
local CLOSE = { [41] = 40, [93] = 91, [125] = 123 }

function Lang:tokenize(src)
    local cfg = self.cfg
    local T = setmetatable({ src = src, k = {}, s = {}, e = {}, l = {}, el = {}, m = {}, n = 0 }, Tokens)
    local K, S, E, Ln, EL = T.k, T.s, T.e, T.l, T.el
    local n, len, pos, line = 0, #src, 1, 1
    local bol = true                 -- only whitespace seen on this line
    local depth = 0                  -- bracket depth (indent mode ignores newlines inside)
    local skip = false               -- inside a dead preprocessor branch
    local pp = {}                    -- #if frames
    local indents = { 0 }
    local indent_mode = cfg.indent
    local long_brackets = cfg.long_brackets
    local template_literals, regex_literals = cfg.template_literals, cfg.regex_literals
    local lifetimes, raw_strings = cfg.lifetimes, cfg.raw_strings
    local nested_comments = cfg.nested_comments
    -- regex_literals: per open '(' whether it follows if/while/for/with, and
    -- the index of the last ')' closing such a condition (see regex_allowed)
    local parens, ctrl_close = {}, 0
    local dir_byte = cfg.directive and cfg.directive:byte()
    local id_start, id_char, keywords, ops = self.id_start, self.id_char, self.keywords, self.ops

    local function push(kind, a, b, l1, l2)
        if skip then return end
        n = n + 1
        K[n], S[n], E[n], Ln[n], EL[n] = kind, a, b, l1, l2 or l1
    end

    -- At file scope (depth 0) every #if arm is kept: platform variants of
    -- whole functions (#ifdef _WIN32 ... #else ...) are separate, balanced
    -- definitions worth indexing. Inside brackets only the first live arm is
    -- kept, because that is where arms split a construct
    -- (`#ifdef X  if (a) {  #else  if (b) {  #endif`) and would unbalance braces.
    local function directive(text)
        if not cfg.pp_first_branch then return end
        local word = text:match('^#%s*(%a+)')
        if word == 'if' or word == 'ifdef' or word == 'ifndef' then
            local zero = word == 'if' and text:match('^#%s*if%s+0%s*$') ~= nil
            pp[#pp + 1] = { parent = skip, taken = not zero, keep_all = depth == 0 and not zero }
            if zero then skip = true end
        elseif (word == 'elif' or word == 'else') and #pp > 0 then
            local f = pp[#pp]
            if f.keep_all then skip = f.parent
            elseif f.taken then skip = true
            else skip = f.parent; f.taken = true end
        elseif word == 'endif' and #pp > 0 then
            skip = table.remove(pp).parent
        end
    end

    while pos <= len do
        local c = src:byte(pos)
        if c == 10 then
            if indent_mode and depth == 0 and n > 0 and K[n] ~= 'nl' and not skip then
                push('nl', pos, pos, line)
            end
            line = line + 1
            pos = pos + 1
            bol = true
        elseif c == 32 or c == 9 or c == 13 or c == 12 or c == 11 then
            pos = pos + 1
        elseif indent_mode and c == 92 and (src:byte(pos + 1) == 10
            or (src:byte(pos + 1) == 13 and src:byte(pos + 2) == 10)) then
            -- Python `\` continuation: the next line joins this logical line
            pos = pos + (src:byte(pos + 1) == 10 and 2 or 3)
            line = line + 1
        else
            -- Indentation (Python): measured at the first real token of a line.
            if indent_mode and bol and depth == 0 then
                local col_start = pos
                while col_start > 1 and src:byte(col_start - 1) ~= 10 do col_start = col_start - 1 end
                local width = 0
                for x = col_start, pos - 1 do
                    width = width + ((src:byte(x) == 9) and (8 - width % 8) or 1)
                end
                local is_comment = false
                for _, lc in ipairs(self.line_comment) do
                    if starts(src, pos, lc) then is_comment = true end
                end
                if not is_comment then
                    if width > indents[#indents] then
                        indents[#indents + 1] = width
                        push('indent', pos, pos - 1, line)
                    else
                        while width < indents[#indents] do
                            indents[#indents] = nil
                            push('dedent', pos, pos - 1, line)
                        end
                    end
                end
            end

            local handled = false
            -- Directive line (C preprocessor), with '\' continuations.
            if dir_byte and c == dir_byte and bol then
                local p = pos
                local l0 = line
                while true do
                    local nl = src:find('\n', p, true) or (len + 1)
                    local q = nl - 1
                    if src:byte(q) == 13 then q = q - 1 end
                    if src:byte(q) == 92 and nl <= len then
                        line = line + 1
                        p = nl + 1
                    else
                        p = nl
                        break
                    end
                end
                local text = src:sub(pos, p - 1)
                -- A directive is kept when either side of it is live code, so
                -- #include/#define in taken branches still reach the parser.
                local was_skip = skip
                directive(text)
                if not (was_skip and skip) then
                    local now = skip
                    skip = false
                    push('dir', pos, p - 1, l0, line)
                    skip = now
                end
                pos = p
                handled = true
            end
            bol = false

            if not handled then
                for _, lc in ipairs(self.line_comment) do
                    if starts(src, pos, lc) then
                        local lb = long_brackets and long_open(src, pos + #lc)
                        if lb then
                            -- --[==[ block comment ]==]
                            local stop = long_close(src, pos + #lc, lb)
                            line = line + count_nl(src, pos, stop)
                            pos = stop + 1
                        else
                            pos = src:find('\n', pos, true) or (len + 1)
                        end
                        handled = true
                        break
                    end
                end
            end
            if not handled and long_brackets then
                local lb = long_open(src, pos)
                if lb then
                    local stop = long_close(src, pos, lb)
                    local l0 = line
                    line = line + count_nl(src, pos, stop)
                    push('str', pos, stop, l0, line)
                    pos = stop + 1
                    handled = true
                end
            end
            if not handled then
                for _, bc in ipairs(self.block_comment) do
                    if starts(src, pos, bc[1]) then
                        local stop
                        if nested_comments then
                            local nest, p = 1, pos + #bc[1]
                            while p + #bc[2] - 1 <= len do
                                if starts(src, p, bc[1]) then
                                    nest = nest + 1
                                    p = p + #bc[1]
                                elseif starts(src, p, bc[2]) then
                                    nest = nest - 1
                                    if nest == 0 then stop = p + #bc[2] - 1; break end
                                    p = p + #bc[2]
                                else
                                    p = p + 1
                                end
                            end
                        else
                            local _
                            _, stop = src:find(bc[2], pos + #bc[1], true)
                        end
                        stop = stop or len
                        line = line + count_nl(src, pos, stop)
                        pos = stop + 1
                        handled = true
                        break
                    end
                end
            end
            if not handled and template_literals and c == 96 then
                local stop = skip_template(src, pos)
                local l0 = line
                line = line + count_nl(src, pos, stop)
                push('str', pos, stop, l0, line)
                pos = stop + 1
                handled = true
            end
            if not handled and regex_literals and c == 47 and regex_allowed(src, K, S, E, n, ctrl_close) then
                local stop = scan_regex(src, pos, id_char)
                if stop then
                    push('str', pos, stop, line)
                    pos = stop + 1
                    handled = true
                end
            end
            if not handled and lifetimes and c == 39 then
                local stop = scan_lifetime(src, pos, id_start, id_char)
                if stop then
                    push('id', pos, stop, line)
                    pos = stop + 1
                    handled = true
                end
            end
            if not handled and raw_strings and (c == 114 or c == 98 or c == 99) then
                local stop = scan_raw_string(src, pos, id_char)
                if stop then
                    local l0 = line
                    line = line + count_nl(src, pos, stop)
                    push('str', pos, stop, l0, line)
                    pos = stop + 1
                    handled = true
                end
            end
            if not handled then
                -- String, optionally after a prefix (r"", b'', f"""...""").
                local q = pos
                while self.prefixes[src:byte(q)] and q - pos < 2 do q = q + 1 end
                for _, st in ipairs(self.strings) do
                    local open = st[1]
                    if starts(src, q, open) and (q == pos or not id_char[src:byte(pos - 1) or 0]) then
                        local close, esc = st[2], st.escape
                        local p = q + #open
                        local stop
                        while p <= len do
                            local b = src:byte(p)
                            if esc and b == esc:byte() then
                                p = p + 2
                            elseif starts(src, p, close) then
                                stop = p + #close - 1
                                break
                            elseif b == 10 and not st.multiline then
                                stop = p - 1
                                break
                            else
                                p = p + 1
                            end
                        end
                        stop = stop or len
                        local l0 = line
                        line = line + count_nl(src, pos, stop)
                        push('str', pos, stop, l0, line)
                        pos = stop + 1
                        handled = true
                        break
                    end
                end
            end
            if not handled then
                if id_start[c] then
                    local p = pos + 1
                    while p <= len and id_char[src:byte(p)] do p = p + 1 end
                    local word = src:sub(pos, p - 1)
                    push(keywords[word] and 'kw' or 'id', pos, p - 1, line)
                    pos = p
                elseif (c >= 48 and c <= 57) or (c == 46 and (src:byte(pos + 1) or 0) >= 48 and (src:byte(pos + 1) or 0) <= 57) then
                    local p = pos + 1
                    while p <= len do
                        local b = src:byte(p)
                        if id_char[b] or b == 46 or b == 39 then
                            p = p + 1
                        elseif (b == 43 or b == 45) and (src:byte(p - 1) == 101 or src:byte(p - 1) == 69
                            or src:byte(p - 1) == 112 or src:byte(p - 1) == 80) then
                            p = p + 1          -- exponent sign: 1e-5, 0x1p+3
                        else
                            break
                        end
                    end
                    push('num', pos, p - 1, line)
                    pos = p
                else
                    local w = 1
                    local list = ops[c]
                    if list then
                        for _, op in ipairs(list) do
                            if starts(src, pos, op) then w = #op; break end
                        end
                    end
                    if w == 1 and not skip then
                        if OPEN[c] then depth = depth + 1
                        elseif CLOSE[c] and depth > 0 then depth = depth - 1 end
                    end
                    push('op', pos, pos + w - 1, line)
                    if regex_literals and w == 1 and not skip then
                        if c == 40 then
                            local prev = n - 1
                            local ctrl = false
                            if prev >= 1 and K[prev] == 'kw' then
                                local pt = src:sub(S[prev], E[prev])
                                ctrl = pt == 'if' or pt == 'while' or pt == 'for' or pt == 'with'
                            end
                            parens[#parens + 1] = ctrl
                        elseif c == 41 then
                            local ctrl = table.remove(parens)
                            ctrl_close = ctrl and n or 0
                        end
                    end
                    pos = pos + w
                end
            end
        end
    end
    if indent_mode then
        if n > 0 and K[n] ~= 'nl' then push('nl', len + 1, len, line) end
        for _ = 2, #indents do push('dedent', len + 1, len, line) end
    end
    T.n = n
    T:compute_matches()
    return T
end

-- Pair brackets (and indent/dedent). An unbalanced closer is left unmatched
-- instead of unwinding the stack, so one stray brace (usually from a
-- preprocessor branch) doesn't break every later match.
function Tokens:compute_matches()
    local stack, m = {}, self.m
    local K, S, E, src = self.k, self.s, self.e, self.src
    for i = 1, self.n do
        local kind = K[i]
        if kind == 'op' and S[i] == E[i] then
            local c = src:byte(S[i])
            if OPEN[c] then
                stack[#stack + 1] = i
            elseif CLOSE[c] then
                local top = stack[#stack]
                if top and K[top] == 'op' and src:byte(S[top]) == CLOSE[c] then
                    stack[#stack] = nil
                    m[top], m[i] = i, top
                end
            end
        elseif kind == 'indent' then
            stack[#stack + 1] = i
        elseif kind == 'dedent' then
            local top = stack[#stack]
            if top and K[top] == 'indent' then
                stack[#stack] = nil
                m[top], m[i] = i, top
            end
        end
    end
end

return M
