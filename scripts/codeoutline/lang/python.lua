-- lang/python.lua — index-level Python parser: classes (+ bases), functions,
-- methods, decorators, module/class-level assignments, imports, and calls.
--
-- xscan's indent mode turns blocks into indent..dedent pairs in the match
-- table, so a block's extent is one lookup and nesting falls out of recursion.

local xscan = require('codeoutline.xscan')
local common = require('codeoutline.common')

local M = {}

M.config = {
    keywords = {
        'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
        'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for',
        'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or',
        'pass', 'raise', 'return', 'try', 'while', 'with', 'yield',
    },
    ops = {
        '**=', '//=', '>>=', '<<=', '->', ':=', '**', '//', '<<', '>>', '<=', '>=', '==',
        '!=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '@=', '...',
    },
    line_comment = { '#' },
    strings = {
        { '"""', '"""', escape = '\\', multiline = true },
        { "'''", "'''", escape = '\\', multiline = true },
        { '"', '"', escape = '\\' },
        { "'", "'", escape = '\\' },
    },
    string_prefixes = 'rbfu',
    indent = true,
}

M.lang = xscan.lang(M.config)

local function is(T, i, s) return T.k[i] == 'op' and T:text(i) == s end
local function kw(T, i, s) return T.k[i] == 'kw' and T:text(i) == s end

-- End of the logical line starting at i: the 'nl' token at bracket depth 0.
local function line_end(T, i, b)
    local j = i
    while j <= b and T.k[j] ~= 'nl' do
        if T.m[j] and T.m[j] > j and T.k[j] == 'op' then j = T.m[j] + 1 else j = j + 1 end
    end
    return math.min(j, b)
end

-- Dotted name starting at i ("a.b.c"); returns text and next index.
local function dotted(T, i)
    local parts, j = {}, i
    while T.k[j] == 'id' or (T.k[j] == 'op' and T:text(j) == '.') do
        parts[#parts + 1] = T:text(j)
        j = j + 1
    end
    return table.concat(parts), j
end

local function parse_imports(T, r, i, e)
    if kw(T, i, 'import') then
        local j = i + 1
        while j < e do
            local name, nj = dotted(T, j)
            if name ~= '' then r.imports[#r.imports + 1] = { path = name, line = T:line(i) } end
            j = nj
            if kw(T, j, 'as') then j = j + 2 end
            if is(T, j, ',') then j = j + 1 elseif name == '' then j = j + 1 end
        end
    else -- from X import a, b
        local j = i + 1
        local mod = ''
        while is(T, j, '.') or is(T, j, '...') do mod = mod .. T:text(j); j = j + 1 end
        local name
        name, j = dotted(T, j)
        mod = mod .. name
        local names = {}
        for x = j, e do
            if T.k[x] == 'id' and not kw(T, x - 1, 'as') then names[#names + 1] = T:text(x) end
            if T.k[x] == 'op' and T:text(x) == '*' then names[#names + 1] = '*' end
        end
        r.imports[#r.imports + 1] = { path = mod, line = T:line(i), names = names }
    end
end

local parse_block

-- Statement header [i, e] (e is 'nl'); if followed by an indented block,
-- returns the block's indent and dedent indices.
local function block_after(T, e)
    local o = e + 1
    if T.k[o] == 'indent' and T.m[o] then return o, T.m[o] end
    return nil
end

parse_block = function(T, r, a, b, parent, in_class)
    local i = a
    local decorators, deco_start = nil, nil
    while i <= b do
        local k = T.k[i]
        if k == 'nl' or k == 'indent' or k == 'dedent' then
            i = i + 1
        else
            local e = line_end(T, i, b)
            local bo, bc = block_after(T, e)
            local head = i
            if kw(T, head, 'async') then head = head + 1 end

            if is(T, i, '@') then
                decorators = decorators or {}
                deco_start = deco_start or i
                decorators[#decorators + 1] = dotted(T, i + 1)
                common.add_calls(r, T, i, e)
                i = e + 1
            elseif kw(T, head, 'def') or kw(T, head, 'class') then
                local is_class = kw(T, head, 'class')
                local name_tok = head + 1
                local stop = bc or e
                -- A block's dedent sits at the next statement's first token,
                -- so the block ends on the line of the last token before it.
                local last = stop
                while last > i and (T.k[last] == 'dedent' or T.k[last] == 'nl') do last = last - 1 end
                local node = common.add_node(r, T, {
                    kind = is_class and 'class' or (in_class and 'method' or 'function'),
                    name = T:text(name_tok), ni = name_tok, parent = parent,
                    ti = deco_start or i, tj = stop, range_end = last, end_line = T:eline(last),
                    sig = common.sig(T, i, e - 1),
                    decorators = decorators,
                    async = head ~= i or nil,
                })
                if is_class and is(T, name_tok + 1, '(') and T.m[name_tok + 1] then
                    local bases = {}
                    local x = name_tok + 2
                    while x < T.m[name_tok + 1] do
                        local nm, nx = dotted(T, x)
                        if nm ~= '' and not is(T, nx, '=') then bases[#bases + 1] = nm end
                        -- skip to next top-level ','
                        x = nx
                        while x < T.m[name_tok + 1] and not is(T, x, ',') do
                            x = (T.m[x] and T.m[x] > x) and T.m[x] + 1 or x + 1
                        end
                        x = x + 1
                    end
                    r.nodes[node].bases = bases
                end
                -- Calls in defaults, base-class args, and a one-line body;
                -- start past `def name` so the definition isn't a call to itself.
                common.add_calls(r, T, name_tok + 1, e)
                if bo then
                    parse_block(T, r, bo + 1, bc - 1, node, is_class)
                end
                decorators, deco_start = nil, nil
                i = (bc or e) + 1
            else
                decorators, deco_start = nil, nil
                if kw(T, i, 'import') or kw(T, i, 'from') then
                    parse_imports(T, r, i, e)
                elseif T.k[i] == 'id' and (is(T, i + 1, '=') or (is(T, i + 1, ':') and not bo))
                    and (parent == nil or in_class) then
                    -- NAME = ... / NAME: type = ... at module or class level
                    common.add_node(r, T, {
                        kind = in_class and 'field' or 'variable', name = T:text(i), ni = i,
                        parent = parent, ti = i, tj = e, sig = common.sig(T, i, e - 1, 120),
                    })
                end
                common.add_calls(r, T, i, e)
                if bo then
                    -- if/for/while/try/with blocks: defs inside keep the same owner
                    parse_block(T, r, bo + 1, bc - 1, parent, in_class)
                    i = bc + 1
                else
                    i = e + 1
                end
            end
        end
    end
end

function M.parse(path, src, language, opts)
    local T = M.lang:tokenize(src)
    local r = common.new(path, 'python', opts)
    parse_block(T, r, 1, T.n, nil, false)
    return common.finish(r, T), T
end

return M
