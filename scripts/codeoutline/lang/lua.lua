-- lang/lua.lua — index-level Lua parser: functions in every definition form
-- (`function a.b:c()`, `local function f()`, `x = function()`, table fields
-- `{ call = function() }`), top-level locals, require/dofile imports, and
-- calls (including `f "str"` / `f {...}` and `obj:method()`).
--
-- Lua blocks close with keywords, not brackets, so the parser pairs
-- function/if/do/repeat with end/until itself; brackets come from xscan.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.config = {
    keywords = {
        'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto',
        'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true',
        'until', 'while',
    },
    ops = { '...', '..', '==', '~=', '<=', '>=', '<<', '>>', '//', '::' },
    line_comment = { '--' },
    strings = { { '"', '"', escape = '\\' }, { "'", "'", escape = '\\' } },
    long_brackets = true,
}

M.lang = xscan.lang(M.config)

local OPENS = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
local IMPORTS = { require = true, dofile = true, loadfile = true }

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

-- Pair block keywords: function/if/do/repeat -> end/until. while/for need
-- no entry of their own; their `do` opens the block.
local function block_matches(T)
    local bm, stack = {}, {}
    for i = 1, T.n do
        if T.k[i] == 'kw' then
            local t = T:text(i)
            if OPENS[t] then
                stack[#stack + 1] = i
            elseif t == 'end' or t == 'until' then
                local top = stack[#stack]
                if top then
                    stack[#stack] = nil
                    bm[top], bm[i] = i, top
                end
            end
        end
    end
    return bm
end

-- Dotted/colon name ending at token x (walking left): "a.b:c" -> parts, start.
local function name_chain_left(T, x)
    local parts, y = { T:text(x) }, x
    while (is(T, y - 1, '.') or is(T, y - 1, ':')) and T.k[y - 2] == 'id' do
        table.insert(parts, 1, T:text(y - 1))
        table.insert(parts, 1, T:text(y - 2))
        y = y - 2
    end
    return table.concat(parts), y
end

-- The unmatched '{' enclosing token i, if any (table constructor).
local function enclosing_brace(T, i, floor)
    local y = i - 1
    while y >= floor do
        local m = T.m[y]
        if is(T, y, '}') and m then
            y = m - 1
        elseif is(T, y, ')') and m then
            y = m - 1
        elseif is(T, y, ']') and m then
            y = m - 1
        elseif is(T, y, '{') then
            return y
        elseif is(T, y, '(') or is(T, y, '[') then
            return nil                  -- inside a call/index, not a table
        else
            y = y - 1
        end
    end
    return nil
end

-- What a table constructor at '{' b is assigned to: `NAME = {`,
-- `local NAME = {`, `a.b = {`, or `return {` (the module table).
local function table_owner(T, b, stem)
    if is(T, b - 1, '=') and T.k[b - 2] == 'id' then
        local name = name_chain_left(T, b - 2)
        return name
    end
    if kw(T, b - 1, 'return') then return stem end
    -- nested field: key = { ... }
    return nil
end

local function string_value(T, i)
    local s = T:text(i)
    return s:match('^"(.*)"$') or s:match("^'(.*)'$")
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'lua', opts)
    r.member_ops = { ['.'] = true, [':'] = true }
    local stem = path:match('([^/\\]+)%.lua$') or path
    local bm = block_matches(T)
    local defs = {}            -- name tokens of definitions (not calls)
    -- innermost function node containing a token, for nesting/qualification
    local fn_stack = {}

    local function parent_at(i)
        while #fn_stack > 0 and r.nodes[fn_stack[#fn_stack]].tj < i do fn_stack[#fn_stack] = nil end
        return fn_stack[#fn_stack]
    end

    for i = 1, T.n do
        local k = T.k[i]
        if k == 'kw' and T:text(i) == 'function' then
            local close = bm[i] or T.n
            local parent = parent_at(i)
            local name, qualified, kind, start, name_tok
            if T.k[i + 1] == 'id' then
                -- function a.b:c(...)  /  local function f(...)
                local x = i + 1
                while (is(T, x + 1, '.') or is(T, x + 1, ':')) and T.k[x + 2] == 'id' do x = x + 2 end
                name = T:text(x)
                name_tok = x
                qualified = common.sig(T, i + 1, x):gsub('%s', '')
                kind = is(T, x - 1, ':') and 'method' or 'function'
                start = kw(T, i - 1, 'local') and i - 1 or i
                defs[x] = true
            elseif is(T, i - 1, '=') and T.k[i - 2] == 'id' then
                -- x = function / a.b = function / { key = function }
                local lhs, y = name_chain_left(T, i - 2)
                name = T:text(i - 2)
                name_tok = i - 2
                qualified = lhs
                kind = 'function'
                start = kw(T, y - 1, 'local') and y - 1 or y
                defs[i - 2] = true
                local b = enclosing_brace(T, i - 2, 1)
                if b and (is(T, y - 1, '{') or is(T, y - 1, ',') or is(T, y - 1, ';')) then
                    local owner = table_owner(T, b, stem)
                    if owner then qualified = owner .. '.' .. lhs end
                end
            elseif is(T, i - 1, '=') and is(T, i - 2, ']') and T.m[i - 2] == i - 4 and T.k[i - 3] == 'str' then
                -- t['key'] = function / M.stubs["@run"] = function
                local key = string_value(T, i - 3)
                if key and T.k[i - 5] == 'id' then
                    local lhs, y = name_chain_left(T, i - 5)
                    name = key
                    name_tok = i - 3
                    qualified = lhs .. '.' .. key
                    kind = 'function'
                    start = y
                end
            end
            if name then
                -- nested definitions qualify under their enclosing function
                local sep_q = qualified
                if parent and not qualified:find('[%.:]') then
                    sep_q = r.nodes[parent].qualified .. '.' .. qualified
                end
                -- signature runs to the parameter list's ')'
                local p = i + 1
                while p < close and not is(T, p, '(') do p = p + 1 end
                local node = common.add_node(r, T, {
                    kind = kind, name = name, ni = name_tok, ti = start, tj = close,
                    sig = common.sig(T, start, T.m[p] or p),
                    ['local'] = kw(T, start, 'local') or nil,
                })
                r.nodes[node].qualified = sep_q
                r.nodes[node].parent = parent
                fn_stack[#fn_stack + 1] = node
            end
        elseif k == 'kw' and T:text(i) == 'local' and not parent_at(i) and T.k[i + 1] == 'id' then
            -- top-level `local a, b = ...` (not `local function`)
            local x = i + 1
            while T.k[x] == 'id' do
                if not kw(T, x + 2, 'function') or not is(T, x + 1, '=') then
                    common.add_node(r, T, { kind = 'variable', name = T:text(x), ni = x, ti = x, tj = x, ['local'] = true })
                end
                if is(T, x + 1, ',') then x = x + 2 else break end
            end
        elseif k == 'id' and IMPORTS[T:text(i)] then
            local arg = is(T, i + 1, '(') and i + 2 or i + 1
            if T.k[arg] == 'str' then
                local v = string_value(T, arg)
                if v then r.imports[#r.imports + 1] = { path = v, line = T:line(i), kind = T:text(i) } end
            end
        end
    end

    -- Calls: `f(...)`, plus Lua's paren-less `f "s"` / `f {...}` forms.
    common.add_calls(r, T, 1, T.n)
    for i = 1, T.n - 1 do
        if T.k[i] == 'id' and not defs[i] and (T.k[i + 1] == 'str' or is(T, i + 1, '{'))
            and not (T.k[i - 1] == 'kw' and T:text(i - 1) == 'local') then
            local kind, recv = 'call', nil
            if is(T, i - 1, '.') or is(T, i - 1, ':') then
                kind = 'member_call'
                if T.k[i - 2] == 'id' then recv = T:text(i - 2) end
            end
            r.refs[#r.refs + 1] = { tok = i, name = T:text(i), kind = kind, line = T:line(i), recv = recv }
        end
    end
    -- A definition's own name token is never a call.
    local kept = {}
    for _, ref in ipairs(r.refs) do
        if not defs[ref.tok] then kept[#kept + 1] = ref end
    end
    r.refs = kept
    r.member_ops = nil
    return common.finish(r), T
end

return M
