-- Query-owned C/C++ call-result receivers. Never infer a type from a member name.
local control = require('codeoutline.control')
local M = { MAX_FILES = 16, MAX_BYTES = 8388608, MAX_DEPTH = 12, MAX_CANDIDATES = 256, MAX_TIME_MS = 400 }
local family = { c = true, cpp = true }
local aggregates = { class = true, struct = true, union = true }
local callable = { ['function'] = true, method = true, prototype = true }
local modifiers = { static = true, inline = true, virtual = true, constexpr = true, extern = true,
    friend = true, __inline = true, __inline__ = true, register = true, typedef = true }
local cv = { const = true, volatile = true, restrict = true, __restrict = true }

local function declared(T, a, b)
    while modifiers[T:text(a)] do a = a + 1 end
    local names, pointer, reference, tag, is_const = {}, 0, false, nil, false
    for i = a, b do
        local s = T:text(i)
        if cv[s] then if s == 'const' and pointer == 0 then is_const = true end
        elseif aggregates[s] then if #names > 0 then return nil end; tag = s
        elseif s == '*' then pointer = pointer + 1
        elseif s == '&' or s == '&&' then reference = true
        elseif s == '::' and pointer == 0 and not reference then names[#names + 1] = s
        elseif T.k[i] == 'id' and pointer == 0 and not reference then
            if #names > 0 and names[#names] ~= '::' then return nil end
            names[#names + 1] = s
        else return nil end
    end
    local name = table.concat(names)
    if name == '' or name == 'auto' or name == 'decltype' or name:sub(-2) == '::' then return nil end
    return { name = name, pointer = pointer, reference = reference, const = is_const, tag = tag, at = T.s[a] - 1 }
end

local expression
expression = function(T, last, depth)
    depth = (depth or 0) + 1
    if depth > M.MAX_DEPTH then return nil end
    if T.k[last] == 'id' then
        local op = T:text(last - 1)
        if op == '.' or op == '->' then
            local receiver, first, size, call = expression(T, last - 2, depth)
            if receiver then return { kind = 'field', receiver = receiver, name = T:text(last), op = op }, first, size + 1, call end
            return nil
        end
        local first = last
        while T:text(first - 1) == '::' and T.k[first - 2] == 'id' do first = first - 2 end
        if T:text(first - 1) == '::' then first = first - 1 end
        return { kind = 'name', name = T.src:sub(T.s[first], T.e[last]):gsub('%s+', ''),
            at = T.s[last] - 1 }, first, 1, false
    end
    if T:text(last) ~= ')' or not T.m[last] then return nil end
    local open = T.m[last]
    if T.k[open - 1] == 'id' then
        local target, first, size = expression(T, open - 1, depth)
        if target then return { kind = 'call', target = target }, first, size + 1, true end
    else
        local previous = T:text(open - 1)
        if previous == '>' or previous == '>>' or previous == ']' or previous == ')' then return nil end
        local value, first, size, call = expression(T, last - 1, depth)
        if first == open + 1 then return value, open, size, call end
    end
end
M.expression = expression

function M.evidence(T, t)
    local op = T:text(t - 1)
    if op ~= '.' and op ~= '->' then return nil end
    local e, _, _, call = expression(T, t - 2)
    if call or not e and (T:text(t - 2) == ')' or T:text(t - 2) == ']') then return 'cxx:expr:' .. (T.s[t] - 1) end
end

function M.collect(r, T)
    if not family[r.language] then return end
    local d = { nodes = {}, expressions = {}, bindings = {}, calls = {}, weight = 0 }
    r.cpp_receivers = d
    local wanted = {}
    local function roots(e)
        if e.kind == 'name' then wanted[e.name] = true
        elseif e.target then roots(e.target)
        elseif e.receiver then roots(e.receiver) end
    end
    for t = 1, T.n do
        if t % 4096 == 0 then control.check() end
        local op = T:text(t - 1)
        if T.k[t] == 'id' and (op == '.' or op == '->') then
            local e, _, size, call = expression(T, t - 2)
            if call or not e and (T:text(t - 2) == ')' or T:text(t - 2) == ']') then
                local at = T.s[t] - 1
                d.expressions[at] = { receiver = e or false, op = op }
                d.weight = d.weight + (size or 1) * 192
                if e then roots(e) end
            end
        end
    end
    local function prefix(ni)
        local a = ni - 1
        while a > 0 do
            local s = T:text(a)
            if T.k[a] ~= 'id' and T.k[a] ~= 'kw' and s ~= '*' and s ~= '&' and s ~= '&&' and s ~= '::' then break end
            a = a - 1
        end
        return a + 1
    end
    local functions = {}
    for id, n in ipairs(r.nodes) do
        if id % 128 == 0 then control.check() end
        local ni, a, b = r.cpp_declaration_tokens and r.cpp_declaration_tokens[id], n.ti, nil
        local const_method = false
        if callable[n.kind] and ni then
            functions[#functions + 1] = n
            local first = ni
            while T:text(first - 1) == '::' and T.k[first - 2] == 'id' do first = first - 2 end
            if T:text(first - 1) == '::' then first = first - 1 end
            b = first - 1
            local open = ni + 1
            if T:text(open) == ')' and T.m[open] == ni - 1 then open, b = ni + 2, ni - 2 end
            if T:text(open) == '(' and T.m[open] then
                local after = T.m[open] + 1
                const_method = T:text(after) == 'const'
                while cv[T:text(after)] or T:text(after) == 'noexcept' do
                    after = after + 1
                    if T:text(after) == '(' and T.m[after] then after = T.m[after] + 1 end
                end
                if T:text(after) == '->' then
                    a, b = after + 1, after + 1
                    while b <= n.tj and T:text(b) ~= '{' and T:text(b) ~= ';' and T:text(b) ~= '=' do b = b + 1 end
                    b = b - 1
                end
            end
        elseif n.kind == 'field' and ni then
            a, b = prefix(ni), ni - 1
            if T:text(ni + 1) == '[' or T:text(ni + 1) == ')' then b = a - 1 end
        elseif n.kind == 'typedef' and ni then
            if T:text(ni + 1) == '=' then a, b = ni + 2, n.tj - 1
            elseif T:text(n.ti) == 'typedef' then a, b = n.ti + 1, ni - 1 end
        end
        d.nodes[id] = { type = b and declared(T, a, b) or false, const_method = const_method }
    end
    local scopes, stack = {}, {}
    for t = 1, T.n do
        if T:text(t) == '{' and T.m[t] then stack[#stack + 1] = t end
        scopes[t] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == t then stack[#stack] = nil end
    end
    for t = 1, T.n do
        if wanted[T:text(t)] then
            local after, a = T:text(t + 1), prefix(t)
            local pointer_callable = T:text(t - 1) == '*' and T:text(t - 2) == '('
            local ty = declared(T, a, t - 1)
            if (ty or pointer_callable or T:text(a) == 'auto' or T:text(t - 1) == '>')
                and (after == ')' or after == ',' or after == ';' or after == '=' or after == '[') then
                local scope = scopes[t]
                local first, last = scope > 0 and T.s[scope] - 1 or 0, scope > 0 and T.e[T.m[scope]] or #T.src
                for _, fn in ipairs(functions) do
                    if fn.ti < t and t < fn.tj and T.s[fn.ti] - 1 > first then first, last = T.s[fn.ti] - 1, T.e[fn.tj] end
                end
                d.bindings[#d.bindings + 1] = { name = T:text(t), type = ty or false, at = T.s[t] - 1, first = first, last = last }
            end
        end
    end
    d.evidence = {}
    for index, ref in ipairs(r.refs) do
        local at = T.s[ref.tok] - 1
        if ref.kind == 'call' then d.calls[at] = ref.binding == 'cpp:?' or false end
        if d.expressions[at] then ref.binding = 'cxx:expr:' .. at; d.evidence[index] = ref.binding; r.has_bindings = true end
    end
    d.weight = d.weight + #r.nodes * 160 + #d.bindings * 192
    r.cpp_declaration_tokens = nil
end

function M.context(G, ctx)
    ctx = ctx or {}
    if ctx.cpp_receivers then return ctx.cpp_receivers end
    local C = { stats = { files = 0, bytes = 0, candidates = 0 }, incomplete = false }
    ctx.cpp_receivers = C
    local deadline, records, visibility = xtimer.now_ms() + M.MAX_TIME_MS, {}, {}
    local function limited() C.incomplete, ctx.cpp_receivers_incomplete = true, true end
    local function expired()
        control.check()
        if xtimer.now_ms() > deadline then limited(); return true end
        return false
    end
    function C.data(f)
        if records[f] ~= nil then return records[f] or nil end
        local rec = G.files[f]
        if not ctx.ordinary or not ctx.ordinary.available(f) then records[f] = false; return nil end
        local size = ctx.ordinary.source_size(f) or rec.size or #rec.nodes * 128
        if expired() or C.stats.files >= M.MAX_FILES or C.stats.bytes + size > M.MAX_BYTES then
            limited(); records[f] = false; return nil
        end
        C.stats.files, C.stats.bytes = C.stats.files + 1, C.stats.bytes + size
        records[f] = ctx.ordinary.data(f).cpp_receivers or false
        return records[f] or nil
    end
    local function active(id)
        local f = G.node_file[id]; local ids = f and G.id_of[f]
        return ids and ids[1] and ids[1] <= id and id <= ids[#ids]
    end
    local function info(id)
        if not active(id) then return nil end
        local f = G.node_file[id]; local d = C.data(f)
        return d and d.nodes[id - G.id_of[f][1] + 1]
    end
    local function visible(f, g)
        if f == g then return true end
        if not visibility[f] then visibility[f] = require('codeoutline.graph').visible_dependencies(G, f, ctx) end
        return visibility[f][g]
    end
    local function bound(f, name, at)
        local d, best = C.data(f), nil
        for _, b in ipairs(d and d.bindings or {}) do
            if b.name == name and b.at < at and b.first <= at and at <= b.last
                and (not best or b.first > best.first or b.first == best.first and b.at > best.at) then best = b end
        end
        return best
    end
    local function scope(id)
        return id and G.nodes[id].qualified:match('^(.*)::[^:]+$') or nil
    end
    local type_of
    type_of = function(f, ty, owner, seen, depth)
        depth, seen = (depth or 0) + 1, seen or {}
        if not ty or depth > M.MAX_DEPTH or expired() then return nil end
        local ids
        if G.files[f].language == 'cpp' then
            -- Decorated aliases must retain indirection. The namespace resolver
            -- intentionally normalizes it away, so leave those aliases unknown.
            for i, alias in ipairs(G.by_name[ty.name:match('([^:]+)$')] or {}) do
                if i > M.MAX_CANDIDATES then limited(); return nil end
                if active(alias) and G.nodes[alias].kind == 'typedef' and visible(f, G.node_file[alias]) then
                    for _, a in ipairs(require('codeoutline.cpp_types').aliases(G, G.node_file[alias], ctx)) do
                        if a.name == G.nodes[alias].name and a.decorated then return nil end
                    end
                end
            end
            ids = require('codeoutline.cpp_types').resolve(G, f, ty.name, { context = ctx, scope = owner, at = ty.at })
        else
            ids = {}
            for i, id in ipairs(G.by_name[ty.name] or {}) do
                if i > M.MAX_CANDIDATES then limited(); return nil end
                local n, g = G.nodes[id], G.node_file[id]
                if active(id) and family[G.files[g].language] and visible(f, g) and not n.parent then
                    if aggregates[n.kind] then ids[#ids + 1] = id
                    elseif n.kind == 'typedef' and not ty.tag then
                        if seen[id] then return nil end
                        local d = info(id); seen[id] = true
                        local value = d and type_of(g, d.type, nil, seen, depth)
                        seen[id] = nil
                        if not value then return nil end
                        return { id = value.id, pointer = value.pointer + ty.pointer, const = value.const or ty.const }
                    end
                end
            end
        end
        if #ids ~= 1 then return nil end
        return { id = ids[1], pointer = ty.pointer, const = ty.const }
    end
    local function members(receiver, name, op, declarations)
        if not receiver or (op == '->' and receiver.pointer ~= 1 or op == '.' and receiver.pointer ~= 0) then return {} end
        local id, result = receiver.id, {}
        if G.files[G.node_file[id]].language == 'cpp' then
            local candidates
            if declarations then
                local known
                candidates, known = require('codeoutline.cpp_types').resolve(G, G.node_file[id], '::' .. G.nodes[id].qualified .. '::' .. name,
                    { context = ctx, accept = { ['function'] = true, method = true, prototype = true, field = true } })
                if known and #candidates == 0 then return {} end
            end
            if not candidates or #candidates == 0 then
                candidates = require('codeoutline.cpp_bindings').resolve(G, G.node_file[id], nil, name,
                    'cpp:type:::' .. G.nodes[id].qualified, nil, ctx) or {}
            end
            for _, mid in ipairs(candidates) do
                local d = receiver.const and callable[G.nodes[mid].kind] and info(mid)
                if not receiver.const or not callable[G.nodes[mid].kind] or d and d.const_method then result[#result + 1] = mid end
            end
            return result
        end
        for i, mid in ipairs(G.by_name[name] or {}) do
            if i > M.MAX_CANDIDATES then limited(); break end
            local n, g = G.nodes[mid], G.node_file[mid]
            if active(mid) and g == G.node_file[id] and n.parent and G.id_of[g][n.parent] == id then result[#result + 1] = mid end
        end
        return result
    end
    C.members = members
    local value
    value = function(f, e, owner, depth)
        depth = (depth or 0) + 1
        if not e or depth > M.MAX_DEPTH or expired() then return nil end
        if e.kind == 'name' then
            local b = bound(f, e.name, e.at)
            return b and type_of(f, b.type, scope(owner)) or nil
        end
        local candidates
        local parent
        if e.kind == 'field' then
            parent = value(f, e.receiver, owner, depth)
            candidates = members(parent, e.name, e.op, true)
        elseif e.kind == 'call' then
            local target = e.target
            if target.kind == 'field' then
                candidates = members(value(f, target.receiver, owner, depth), target.name, target.op, true)
            elseif target.kind == 'name' then
                local d = C.data(f)
                if not d or d.calls[target.at] or bound(f, target.name, target.at) then return nil end
                if G.files[f].language == 'cpp' then
                    candidates = require('codeoutline.cpp_types').resolve(G, f, target.name,
                        { context = ctx, scope = scope(owner), at = target.at, accept = callable })
                else
                    candidates = {}
                    for i, id in ipairs(G.by_name[target.name] or {}) do
                        if i > M.MAX_CANDIDATES then limited(); return nil end
                        local n, g = G.nodes[id], G.node_file[id]
                        if active(id) and callable[n.kind] and not n.parent and visible(f, g)
                            and not (n.static and f ~= g) then candidates[#candidates + 1] = id end
                    end
                end
            end
        end
        local agreed
        for i, id in ipairs(candidates or {}) do
            if i > M.MAX_CANDIDATES then limited(); return nil end
            C.stats.candidates = C.stats.candidates + 1
            if e.kind == 'call' and not callable[G.nodes[id].kind] or e.kind == 'field' and G.nodes[id].kind ~= 'field' then return nil end
            local d = info(id)
            local actual = d and type_of(G.node_file[id], d.type, scope(id))
            if actual and parent and parent.const and actual.pointer == 0 then actual.const = true end
            if not actual or agreed and (agreed.id ~= actual.id or agreed.pointer ~= actual.pointer or agreed.const ~= actual.const) then return nil end
            agreed = actual
        end
        return agreed
    end
    C.receiver = value
    function C.resolve(f, src, name, evidence)
        local at = evidence and tonumber(evidence:match('^cxx:expr:(%d+)$'))
        if not at then return nil end
        local d = C.data(f); local site = d and d.expressions[at]
        if not site then return {}, 'missing C/C++ receiver evidence' end
        return members(value(f, site.receiver, src), name, site.op), 'C/C++ declared call-result receiver'
    end
    return C
end

return M
