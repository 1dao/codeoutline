-- common.lua — the per-file result model every language parser fills, plus
-- helpers shared by the parsers.
--
-- Result: {
--   path, language,
--   nodes   = { {kind, name, qualified, line, end_line, sig?, parent?, static?, bases?} },
--   refs    = { {from = node index | 0 (file scope), name, kind, line, recv?} },
--   imports = { {path, line, names?} },
-- }
-- Refs are attributed after parsing: a parser only records where each call
-- sits (token index) and assign_refs() hands it to the innermost node whose
-- token range contains it. That keeps nested functions/classes correct
-- without each parser tracking scope for every call site.

local M = {}

function M.new(path, language)
    return { path = path, language = language, nodes = {}, refs = {}, imports = {} }
end

-- Collapse a token span into a one-line signature.
function M.sig(T, a, b, max)
    local src = T.src:sub(T.s[a], T.e[b])
    src = src:gsub('%s+', ' ')
    max = max or 200
    if #src > max then src = src:sub(1, max) .. '...' end
    return src
end

-- ti/tj: token range the node covers (used for ref attribution, then dropped).
function M.add_node(r, T, f)
    local parent = f.parent and r.nodes[f.parent]
    local sep = f.sep or '.'
    f.qualified = parent and (parent.qualified .. sep .. f.name) or ((r.prefix and (r.prefix .. sep) or '') .. f.name)
    f.line = f.line or T:line(f.ti)
    f.end_line = f.end_line or T:eline(f.tj)
    f.sep = nil
    r.nodes[#r.nodes + 1] = f
    return #r.nodes
end

-- Record every call site in token range [a, b].
local MEMBER = { ['.'] = true, ['->'] = true, ['::'] = true, ['?.'] = true }
function M.add_calls(r, T, a, b)
    local skip = r.skip_calls
    local member = r.member_ops or MEMBER    -- Lua adds ':' (obj:method())
    for _, x in ipairs(T:calls(a, b)) do
        if skip and skip[T:text(x)] then goto next end
        local kind, recv = 'call', nil
        local p = x - 1
        if p >= 1 and T.k[p] == 'op' and member[T:text(p)] then
            kind = 'member_call'
            if T.k[p - 1] == 'id' or T.k[p - 1] == 'kw' then recv = T:text(p - 1) end
        elseif p >= 1 and T.k[p] == 'kw' and T:text(p) == 'new' then
            kind = 'new'
        elseif p >= 1 and T.k[p] == 'op' and T:text(p) == '@' then
            kind = 'annotation'
        end
        r.refs[#r.refs + 1] = { tok = x, name = T:text(x), kind = kind, line = T:line(x), recv = recv }
        ::next::
    end
end

-- Identifiers used as bare values — `lua_pushcfunction(L, fn)`, `{"name", fn}`,
-- `cb = fn;` — the usual way C code registers callbacks. Only single-token
-- operands between separators qualify, which keeps locals-in-expressions out.
local BEFORE = { [','] = true, ['('] = true, ['='] = true, ['{'] = true, ['&'] = true }
local AFTER = { [','] = true, [')'] = true, ['}'] = true, [';'] = true }
function M.add_value_refs(r, T, a, b)
    local seen = {}
    for _, x in ipairs(T:idents(a, b)) do
        local p, q = x - 1, x + 1
        if T.k[p] == 'op' and T.k[q] == 'op' and BEFORE[T:text(p)] and AFTER[T:text(q)] then
            local name = T:text(x)
            if not seen[name] then
                seen[name] = true
                r.refs[#r.refs + 1] = { tok = x, name = name, kind = 'ref', line = T:line(x) }
            end
        end
    end
end

-- Hand each ref to the innermost node whose token range contains it. Node
-- ranges nest or are disjoint, so one sweep with a stack does it.
function M.assign_refs(r)
    local order = {}
    for i, n in ipairs(r.nodes) do if n.ti then order[#order + 1] = i end end
    table.sort(order, function(a, b)
        local na, nb = r.nodes[a], r.nodes[b]
        if na.ti ~= nb.ti then return na.ti < nb.ti end
        if na.tj ~= nb.tj then return na.tj > nb.tj end
        return a < b
    end)
    -- table.sort is unstable (and randomizes pivots on large arrays), so
    -- break ties by insertion order to keep output deterministic.
    for i, ref in ipairs(r.refs) do ref.seq = i end
    table.sort(r.refs, function(a, b)
        if a.tok ~= b.tok then return a.tok < b.tok end
        return a.seq < b.seq
    end)
    local stack, oi = {}, 1
    for _, ref in ipairs(r.refs) do
        while oi <= #order and r.nodes[order[oi]].ti <= ref.tok do
            local n = r.nodes[order[oi]]
            while #stack > 0 and r.nodes[stack[#stack]].tj < n.ti do stack[#stack] = nil end
            stack[#stack + 1] = order[oi]
            oi = oi + 1
        end
        while #stack > 0 and r.nodes[stack[#stack]].tj < ref.tok do stack[#stack] = nil end
        ref.from = stack[#stack] or 0
    end
end

-- Drop parser-internal fields so the result is plain data.
function M.finish(r)
    M.assign_refs(r)
    for _, ref in ipairs(r.refs) do ref.tok, ref.seq = nil, nil end
    for _, n in ipairs(r.nodes) do n.ti, n.tj = nil, nil end
    r.prefix, r.skip_calls = nil, nil
    return r
end

return M
