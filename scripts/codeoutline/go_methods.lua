-- Query-owned Go signatures, method sets and declared receiver bindings.
local control = require('codeoutline.control')
local M = { MAX_FILES = 16, MAX_BYTES = 8388608, MAX_TYPES = 512, MAX_NODES = 8192,
    MAX_DEPTH = 16, MAX_RESULTS = 64, MAX_CANDIDATES = 512, MAX_TIME_MS = 500 }
local kinds = { struct = true, interface = true, typedef = true }

local function statement_end(T, a, b)
    local i = a
    while i <= b do
        if T.m[i] and T.m[i] > i then i = T.m[i] end
        if i >= b or T:text(i + 1) == ';' or T.l[i + 1] > T.el[i] then return i end
        i = i + 1
    end
    return b
end

local type_expr, parameters
type_expr = function(T, a, b, depth)
    depth = (depth or 0) + 1
    if a > b or depth > 16 then return nil end
    local first = T:text(a)
    local function wrap(kind, start, extra)
        local child = type_expr(T, start, b, depth)
        return child and { kind = kind, child = child, extra = extra } or nil
    end
    if first == '*' then return wrap('pointer', a + 1) end
    if first == '...' then return wrap('variadic', a + 1) end
    if first == '(' and T.m[a] == b then return type_expr(T, a + 1, b - 1, depth) end
    if first == '[' and T.m[a] then
        local close = T.m[a]
        if close == a + 1 then return wrap('slice', close + 1) end
        local size = close == a + 2 and tonumber(T:text(a + 1))
        if size and size >= 0 and size <= 9007199254740991 and size == math.floor(size) then return wrap('array', close + 1, size) end
        return nil
    end
    if first == 'map' and T:text(a + 1) == '[' and T.m[a + 1] then
        local close = T.m[a + 1]
        local key, value = type_expr(T, a + 2, close - 1, depth), type_expr(T, close + 1, b, depth)
        return key and value and { kind = 'map', key = key, child = value } or nil
    end
    if first == 'chan' then return wrap('channel', T:text(a + 1) == '<-' and a + 2 or a + 1,
        T:text(a + 1) == '<-' and 'send' or 'both') end
    if first == '<-' and T:text(a + 1) == 'chan' then return wrap('channel', a + 2, 'receive') end
    if first == 'interface' and T:text(a + 1) == '{' and T.m[a + 1] == a + 2 and b == a + 2 then return { kind = 'any' } end
    if first == 'func' and T:text(a + 1) == '(' and T.m[a + 1] then
        local close = T.m[a + 1]
        local params = parameters(T, a + 2, close - 1)
        local results = {}
        if close < b then
            if T:text(close + 1) == '(' and T.m[close + 1] == b then results = parameters(T, close + 2, b - 1)
            else local ty = type_expr(T, close + 1, b, depth); results = ty and { ty } or nil end
        end
        return params and results and { kind = 'function', params = params, results = results } or nil
    end
    if T.k[a] == 'id' and a == b then return { kind = 'name', name = first, at = T.s[a] - 1 } end
    if T.k[a] == 'id' and T:text(a + 1) == '.' and T.k[a + 2] == 'id' and b == a + 2 then
        return { kind = 'name', name = first .. '.' .. T:text(a + 2), at = T.s[a] - 1 }
    end
end

parameters = function(T, a, b)
    local spans, start, i = {}, a, a
    while i <= b + 1 do
        if i == b + 1 or T:text(i) == ',' then
            if start < i then spans[#spans + 1] = { start, i - 1 } end
            start = i + 1
        elseif T.m[i] and T.m[i] > i then i = T.m[i] end
        i = i + 1
    end
    local types, names, pending, named = {}, {}, {}, false
    local function add(ty, name)
        types[#types + 1], names[#names + 1] = ty, name or false
    end
    for _, span in ipairs(spans) do
        local x, y = span[1], span[2]
        local ty = T.k[x] == 'id' and type_expr(T, x + 1, y)
        local named_form = T.k[x] == 'id' and x < y and T:text(x + 1) ~= '.'
            and not (T:text(x + 1) == '[' and T.m[x + 1] == y)
        if ty or named_form then
            named = true
            for _, token in ipairs(pending) do add(ty or false, { name = T:text(token), token = token }) end
            pending = {}; add(ty or false, { name = T:text(x), token = x })
        elseif x == y and T.k[x] == 'id' then pending[#pending + 1] = x
        else
            if named then return nil end
            for _, token in ipairs(pending) do add(type_expr(T, token, token)) end
            pending = {}; ty = type_expr(T, x, y)
            add(ty or false)
        end
    end
    if named and #pending > 0 then return nil end
    for _, token in ipairs(pending) do add(type_expr(T, token, token)) end
    for index, ty in ipairs(types) do if ty and ty.kind == 'variadic' and index ~= #types then return nil end end
    return types, names
end

local function signature(T, open, last)
    local close = T.m[open]
    if not close then return nil end
    local params, names = parameters(T, open + 1, close - 1)
    if not params then return nil end
    local after, results, result_names = close + 1, {}, {}
    if T:text(after) == '(' and T.m[after] and T.m[after] <= last then
        results, result_names = parameters(T, after + 1, T.m[after] - 1)
        after = T.m[after] + 1
    elseif after <= last and T:text(after) ~= '{' and T:text(after) ~= ';' then
        local ending = after
        while ending < last and T:text(ending + 1) ~= '{' and T:text(ending + 1) ~= ';'
            and T.l[ending + 1] == T.el[ending] do
            if T.m[ending] and T.m[ending] > ending then ending = T.m[ending] end
            if ending >= last then break end
            ending = ending + 1
        end
        local ty = type_expr(T, after, ending)
        if not ty then return nil end
        results, after = { ty }, ending + 1
    end
    if not results then return nil end
    return { params = params, results = results }, names, result_names, after
end

local function function_body(T, close, last)
    local at = close + 1
    while at <= last do
        local word = T:text(at)
        if word == '{' then
            if T:text(at - 1) ~= 'struct' and T:text(at - 1) ~= 'interface' then return at end
            at = (T.m[at] or at) + 1
        elseif (word == '(' or word == '[') and T.m[at] then at = T.m[at] + 1
        elseif word == ';' or T.l[at] > T.el[at - 1] then return nil
        else at = at + 1 end
    end
end

-- Only identifiers, direct calls and parenthesized versions have a proven
-- receiver path here. Fields, indexing, assertions and generic calls stay unknown.
local function expression(T, last, depth)
    depth = (depth or 0) + 1
    if depth > 16 then return nil end
    if T.k[last] == 'id' and T:text(last - 1) ~= '.' then
        return { kind = 'binding_value', name = T:text(last), at = T.s[last] - 1 }, last, 1
    end
    if T:text(last) ~= ')' or not T.m[last] then return nil end
    local open = T.m[last]
    if T.k[open - 1] == 'id' then
        local name_at, first, count = open - 1, open - 1, 1
        local call = { kind = 'call_result', name = T:text(name_at), at = T.s[name_at] - 1, result = 1, arity = 1 }
        if T:text(name_at - 1) == '.' then
            local receiver, start, size = expression(T, name_at - 2, depth)
            if not receiver then return nil end
            first, count = start, count + size
            if receiver.kind == 'binding_value' then call.recv = receiver.name
            else call.receiver = receiver end
        end
        return call, first, count
    end
    local value, first, count = expression(T, last - 1, depth)
    if first == open + 1 then return value, open, count end
end
M.expression = expression

function M.collect(r, T)
    if r.language ~= 'go' then return end
    local data = { nodes = {}, bindings = {}, shadows = {}, evidence = {}, receivers = {}, receiver_weight = 0 }
    r.go_methods = data
    local children, scopes, stack, functions, named_functions = {}, {}, {}, {}, {}
    for i = 1, T.n do
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i end
        scopes[i] = stack[#stack] or 0
        if stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    for id, n in ipairs(r.nodes) do
        if n.parent then children[n.parent] = children[n.parent] or {}; children[n.parent][#children[n.parent] + 1] = id end
    end
    local function binding(name, ty, token, first, last, generic)
        if name == '_' then return end
        data.bindings[#data.bindings + 1] = { name = name, type = ty or false, at = T.s[token] - 1,
            first = first, last = last, generic = generic or nil }
    end
    for id, n in ipairs(r.nodes) do
        if id % 128 == 0 then control.check() end
        local d = {}; data.nodes[id] = d
        if kinds[n.kind] then
            local name_at = n.ti
            if T:text(name_at) == 'type' then name_at = name_at + 1 end
            local bracket = name_at + 1
            d.generic = T:text(bracket) == '[' and T.m[bracket] and T.m[bracket] > bracket + 2
                and T.k[bracket + 1] == 'id' or nil
            local after = name_at + 1
            if d.generic then after = (T.m[after] or after) + 1 end
            d.alias = T:text(after) == '=' or nil
            if d.alias then after = after + 1 end
            d.underlying = type_expr(T, after, n.tj)
            d.embeds, d.fields = {}, {}
            if n.kind == 'interface' then
                local open = after + 1
                if T:text(after) ~= 'interface' or T:text(open) ~= '{' or not T.m[open] then d.unsupported = true
                else
                    local i, last = open + 1, T.m[open] - 1
                    while i <= last do
                        if T:text(i) == ';' then i = i + 1
                        else
                            local finish = statement_end(T, i, last)
                            if T:text(i + 1) ~= '(' then
                                local ty = type_expr(T, i, finish)
                                if not ty or ty.kind ~= 'name' then d.unsupported = true else d.embeds[#d.embeds + 1] = ty end
                            end
                            i = finish + 1
                        end
                    end
                end
            elseif n.kind == 'struct' then
                for _, child in ipairs(children[id] or {}) do
                    local field = r.nodes[child]
                    if field.kind == 'field' then
                        d.fields[#d.fields + 1] = child
                        local last = field.tj
                        if T.k[last] == 'str' then last = last - 1 end
                        if not field.embedded and T:text(field.ti + 1) == '[' and T.m[field.ti + 1] == last then d.unsupported = true end
                        if field.embedded then
                            local ty = type_expr(T, field.ti, last)
                            if ty then d.embeds[#d.embeds + 1] = ty else d.unsupported = true end
                        end
                    end
                end
            elseif not d.alias and not d.underlying then d.unsupported = true end
        elseif n.kind == 'method' or n.kind == 'function' then
            named_functions[n.ti] = true
            local at, receiver, recv_name = n.ti, nil, nil
            if T:text(at) == 'func' then
                at = at + 1
                if T:text(at) == '(' and T.m[at] then
                    local close = T.m[at]
                    receiver = type_expr(T, at + 1, close - 1)
                    if not receiver and T.k[at + 1] == 'id' then
                        recv_name, receiver = T:text(at + 1), type_expr(T, at + 2, close - 1)
                    end
                    at = close + 1
                end
            end
            local open = at + 1
            d.generic = T:text(open) == '[' or (n.recv and not receiver) or nil
            if T:text(open) == '[' then open = (T.m[open] or open) + 1 end
            if T:text(open) == '(' then
                local sig, names, result_names, body = signature(T, open, n.tj)
                d.signature, d.receiver = sig, receiver
                local params = sig and sig.params
                if not body and T.m[open] then
                    body = function_body(T, T.m[open], n.tj)
                    params, names = parameters(T, open + 1, T.m[open] - 1)
                end
                if body and T:text(body) == '{' and T.m[body] then
                    local first, last = T.s[body] - 1, T.e[T.m[body]]
                    if d.generic then functions[#functions + 1] = { first = first, last = last, generic = true } end
                    for _, list in ipairs({ names or {}, result_names or {} }) do
                        for index, entry in ipairs(list) do
                            if entry then binding(entry.name, (list == names and params or sig.results)[index], entry.token, first, last, d.generic) end
                        end
                    end
                    if recv_name then binding(recv_name, receiver, n.ti, first, last, d.generic) end
                end
            end
        end
    end
    local function declaration(name_at, ending, ty, token)
        local scope = scopes[name_at]
        local first, last = scope > 0 and T.s[scope] - 1 or 0, scope > 0 and T.e[T.m[scope]] or #T.src
        local generic = false
        for _, fn in ipairs(functions) do if fn.generic and fn.first <= first and last <= fn.last then generic = true; break end end
        for i = name_at - 1, math.max(1, name_at - 64), -1 do
            local word = T:text(i)
            if word == ';' or word == '{' or word == '}' then break end
            if word == 'if' or word == 'for' or word == 'switch' then generic = true; break end
        end
        binding(T:text(name_at), ty, token or name_at, first, last, generic)
        local entry = data.bindings[#data.bindings]
        if entry and entry.name == T:text(name_at) then entry.at = scope == 0 and 0 or T.e[ending] end
    end
    local function initializer(a, b, depth)
        depth = (depth or 0) + 1
        if depth > 16 then return nil end
        if T:text(a) == '(' and T.m[a] == b then return initializer(a + 1, b - 1, depth) end
        if a == b and T.k[a] == 'id' then
            return { kind = 'binding_value', name = T:text(a), at = T.s[a] - 1 }
        end
        local address = T:text(a) == '&'
        if address then a = a + 1 end
        if T:text(a) == 'new' and T:text(a + 1) == '(' and T.m[a + 1] == b then
            local ty = type_expr(T, a + 2, b - 1)
            return ty and { kind = 'pointer', child = ty, builtin_new = true, at = T.s[a] - 1 } or nil
        end
        if not address then
            local value, first = expression(T, b)
            if first == a then return value end
        end
        local open = a
        while open <= b and T:text(open) ~= '{' do open = open + 1 end
        if T:text(open) ~= '{' or T.m[open] ~= b then return nil end
        local ty = type_expr(T, a, open - 1)
        return ty and (address and { kind = 'pointer', child = ty } or ty) or nil
    end
    local function initializers(a, b, count)
        local values, start, i = {}, a, a
        while i <= b + 1 do
            if i == b + 1 or T:text(i) == ',' then
                values[#values + 1] = initializer(start, i - 1) or false; start = i + 1
            elseif T.m[i] and T.m[i] > i then i = T.m[i] end
            i = i + 1
        end
        if #values == 1 and values[1] and values[1].kind == 'call_result' then
            local call = values[1]; values = {}
            for index = 1, count do values[index] = { kind = call.kind, name = call.name, recv = call.recv,
                receiver = call.receiver, at = call.at, result = index, arity = count } end
        elseif #values ~= count then return {} end
        return values
    end
    local function variable(first, finish)
        local after = first + 1
        while T:text(after) == ',' and T.k[after + 1] == 'id' do after = after + 2 end
        local equal = after
        while equal <= finish and T:text(equal) ~= '=' do equal = equal + 1 end
        local ty = type_expr(T, after, equal - 1)
        local values = not ty and after == equal and initializers(equal + 1, finish, (after - first + 1) / 2) or {}
        for x = first, after - 1, 2 do declaration(x, finish, ty or values[(x - first) / 2 + 1]) end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T:text(i) == 'var' and T.k[i + 1] == 'id' then
            local finish = statement_end(T, i + 1, T.n)
            variable(i + 1, finish)
        elseif T:text(i) == 'var' and T:text(i + 1) == '(' and T.m[i + 1] then
            local at, last = i + 2, T.m[i + 1] - 1
            while at <= last do
                if T:text(at) == ';' then at = at + 1
                else local ending = statement_end(T, at, last); if T.k[at] == 'id' then variable(at, ending) end; at = ending + 1 end
            end
        elseif T:text(i) == 'type' and T.k[i + 1] == 'id' and scopes[i] > 0 then
            local scope = scopes[i]
            data.shadows[#data.shadows + 1] = { name = T:text(i + 1), first = T.s[i] - 1, last = T.e[T.m[scope]] }
        elseif T:text(i) == 'type' and T:text(i + 1) == '(' and T.m[i + 1] and scopes[i] > 0 then
            local at, last, scope = i + 2, T.m[i + 1] - 1, scopes[i]
            while at <= last do
                if T:text(at) == ';' then at = at + 1
                else
                    if T.k[at] == 'id' then data.shadows[#data.shadows + 1] = {
                        name = T:text(at), first = T.s[i] - 1, last = T.e[T.m[scope]] } end
                    at = statement_end(T, at, last) + 1
                end
            end
        elseif T:text(i) == 'func' and not named_functions[i] and T:text(i + 1) == '(' then
            local sig, names, results, body = signature(T, i + 1, T.n)
            local params = sig and sig.params
            if not body and T.m[i + 1] then
                body = function_body(T, T.m[i + 1], T.n)
                params, names = parameters(T, i + 2, T.m[i + 1] - 1)
            end
            if body and T:text(body) == '{' and T.m[body] then
                for _, list in ipairs({ names or {}, results or {} }) do
                    for index, entry in ipairs(list) do
                        if entry then binding(entry.name, (list == names and params or sig.results)[index], entry.token,
                            T.s[body] - 1, T.e[T.m[body]]) end
                    end
                end
            end
        elseif T:text(i) == ':=' and T.k[i - 1] == 'id' then
            local first, finish = i - 1, statement_end(T, i + 1, T.n)
            while T:text(first - 1) == ',' and T.k[first - 2] == 'id' do first = first - 2 end
            if T:text(i + 1) == 'range' and T:text(first - 1) == 'for' then
                local open = i + 2
                while open <= T.n and T:text(open) ~= '{' and T:text(open) ~= ';' do
                    if T.m[open] and T.m[open] > open then open = T.m[open] end
                    open = open + 1
                end
                local value = T:text(open) == '{' and T.m[open] and initializer(i + 2, open - 1)
                if T:text(open) == '{' and T.m[open] then
                    for x = first, i - 1, 2 do binding(T:text(x), value and { kind = 'range_value', child = value,
                        result = (x - first) / 2 + 1, arity = (i - first + 1) / 2 }, x, T.s[open] - 1, T.e[T.m[open]]) end
                else for x = first, i - 1, 2 do declaration(x, finish) end end
            else
                local values = initializers(i + 1, finish, (i - first + 1) / 2)
                for x = first, i - 1, 2 do declaration(x, finish, values[(x - first) / 2 + 1]) end
            end
        end
    end
    table.sort(functions, function(a, b) return a.first < b.first end)
    local function generic_at(at)
        local lo, hi = 1, #functions
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if functions[mid].first <= at then lo = mid + 1 else hi = mid - 1 end
        end
        return hi > 0 and at <= functions[hi].last
    end
    for index, ref in ipairs(r.refs) do
        local at = T.s[ref.tok] - 1
        local receiver, _, size
        if T:text(ref.tok - 1) == '.' then receiver, _, size = expression(T, ref.tok - 2) end
        if generic_at(at) then
            ref.binding = 'go:?'; data.evidence[index] = ref.binding; r.has_bindings = true
        elseif receiver and receiver.kind ~= 'binding_value' then
            data.receivers[at] = receiver; data.receiver_weight = data.receiver_weight + size * 192
            ref.binding = 'go:expr:' .. at; data.evidence[index] = ref.binding; r.has_bindings = true
        elseif ref.recv then
            ref.binding = 'go:recv:' .. (T.s[ref.tok] - 1); r.has_bindings = true
            if T.el[ref.tok - 3] == T.l[ref.tok - 2] and (T:text(ref.tok - 3) == '.'
                or T:text(ref.tok - 3) == ')' or T:text(ref.tok - 3) == ']') then ref.binding = 'go:?' end
            data.evidence[index] = ref.binding
        elseif ref.kind == 'call' then
            ref.binding = 'go:call:' .. (T.s[ref.tok] - 1)
            data.evidence[index] = ref.binding; r.has_bindings = true
        elseif ref.kind == 'member_call' then
            ref.binding = 'go:?'; data.evidence[index] = ref.binding; r.has_bindings = true
        end
    end
end

local primitive = {}
for word in ('bool string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 error any'):gmatch('%S+') do primitive[word] = word end
primitive.byte, primitive.rune = 'uint8', 'int32'

function M.context(G, ctx, report)
    ctx = ctx or {}
    if ctx.go_methods then
        if report then ctx.go_methods.report = report end
        return ctx.go_methods
    end
    local C = { incomplete = false, report = report, stats = { files = 0, bytes = 0, sets = 0, candidates = 0, links = 0 } }
    local deadline = xtimer.now_ms() + M.MAX_TIME_MS
    ctx.go_methods = C
    local data, packages, owners, sets, signatures, outgoing, incoming = {}, {}, {}, {}, {}, {}, {}
    local modules = require('codeoutline.go_modules')
    local function limited() C.incomplete, ctx.go_methods_incomplete = true, true end
    local function expired()
        control.check()
        if xtimer.now_ms() > deadline then limited(); return true end
        return false
    end
    function C.data(f)
        if data[f] ~= nil then return data[f] or nil end
        local rec = G.files[f]
        if ctx.ordinary and not ctx.ordinary.available(f) then data[f] = false; return nil end
        local size = (ctx.ordinary and ctx.ordinary.source_size(f)) or rec.size or #rec.nodes * 128
        if expired() or C.stats.files >= M.MAX_FILES or C.stats.bytes + size > M.MAX_BYTES then limited(); data[f] = false; return nil end
        C.stats.files, C.stats.bytes = C.stats.files + 1, C.stats.bytes + size
        local parsed = ctx.ordinary and ctx.ordinary.data(f) or rec
        data[f] = parsed.go_methods or false
        return data[f] or nil
    end
    local function info(id)
        local f = G.node_file[id]
        if not G.id_of[f][1] or id < G.id_of[f][1] or id > G.id_of[f][#G.id_of[f]] then return nil end
        local d = C.data(f)
        return d and d.nodes[id - G.id_of[f][1] + 1] or nil
    end
    local function peers(f)
        if not packages[f] then
            local files = modules.peers(G, f, ctx) or {}
            local members = {}; for _, g in ipairs(files) do members[g] = true end
            packages[f] = { files = files, members = members,
                key = (G.files[f].path:match('^(.*)/') or '') .. '\0' .. (G.files[f].package or '') }
        end
        return packages[f]
    end
    function C.bound(f, name, at)
        local d, best = C.data(f), nil
        if not d then return false end
        for _, entry in ipairs(d.bindings) do
            if entry.name == name and entry.first <= at and at <= entry.last and entry.at <= at
                and (not best or entry.first > best.first or entry.first == best.first and entry.at > best.at) then best = entry end
        end
        return best
    end
    local function shadowed(f, name, at)
        local d = C.data(f)
        if not d then return true end
        for _, entry in ipairs(d.shadows) do
            if entry.name == name and entry.first <= at and at <= entry.last then return true end
        end
        return false
    end
    local function named(f, name, at)
        local alias, member = name:match('^([%w_]+)%.([%w_]+)$')
        local files
        if at then
            if shadowed(f, alias or name, at) then return {}, true end
            if C.bound(f, alias or name, at) then return {}, true end
        end
        if alias then
            if not member:match('^%u') then return {}, true end
            local imports = modules.aliases(G, f, ctx)
            local entry = imports[alias]
            if not entry then return {}, true end
            files, name = {}, member
            for _, g in ipairs(entry.files) do files[g] = true end
        else files = peers(f).members end
        local ids, found = {}, false
        for i, id in ipairs(G.by_name[name] or {}) do
            if i > M.MAX_NODES then limited(); return {}, true end
            local n, g = G.nodes[id], G.node_file[id]
            if files[g] and not n.parent and n.kind ~= 'method' then
                found = true
                if kinds[n.kind] then ids[#ids + 1] = id end
            end
        end
        return ids, found or alias ~= nil
    end
    local canonical, resolve_type
    resolve_type = function(f, ty, seen, depth)
        depth, seen = (depth or 0) + 1, seen or {}
        if not ty or ty.kind ~= 'name' or depth > M.MAX_DEPTH then return nil end
        local ids = named(f, ty.name, ty.at)
        if #ids ~= 1 then return nil end
        local id, d = ids[1], info(ids[1])
        if not d or d.generic or seen[id] then return nil end
        if d.alias then
            seen[id] = true
            return resolve_type(G.node_file[id], d.underlying, seen, depth)
        end
        return id
    end
    canonical = function(f, ty, path, depth)
        path, depth = path or {}, (depth or 0) + 1
        if not ty or depth > M.MAX_DEPTH then return nil end
        if ty.kind == 'name' then
            local ids, known = named(f, ty.name)
            if #ids == 0 and not known then return primitive[ty.name] and 'builtin:' .. primitive[ty.name] or nil end
            if #ids ~= 1 then return nil end
            local id, d = ids[1], info(ids[1])
            if not d or d.generic or path[id] then return nil end
            if d.alias then
                path[id] = true; local result = canonical(G.node_file[id], d.underlying, path, depth); path[id] = nil
                return result
            end
            return 'type:' .. id
        elseif ty.kind == 'any' then return 'builtin:any' end
        if ty.kind == 'function' then
            local parts = {}
            for _, list in ipairs({ ty.params, ty.results }) do
                local items = {}
                for _, item in ipairs(list) do
                    local value = canonical(f, item, path, depth)
                    if not value then return nil end
                    items[#items + 1] = value
                end
                parts[#parts + 1] = table.concat(items, ',')
            end
            return 'func(' .. table.concat(parts, ')->(') .. ')'
        end
        local child = canonical(f, ty.child, path, depth)
        if not child then return nil end
        if ty.kind == 'map' then
            local key = canonical(f, ty.key, path, depth)
            return key and 'map[' .. key .. ']' .. child or nil
        end
        return ty.kind .. ':' .. tostring(ty.extra or '') .. '[' .. child .. ']'
    end
    function C.signature(id)
        if signatures[id] ~= nil then return signatures[id] or nil end
        local d, f = info(id), G.node_file[id]
        if not d or d.generic or not d.signature then signatures[id] = false; return nil end
        local result = {}
        for _, list in ipairs({ d.signature.params, d.signature.results }) do
            local items = {}
            for _, ty in ipairs(list) do
                local value = canonical(f, ty)
                if not value then signatures[id] = false; return nil end
                items[#items + 1] = value
            end
            result[#result + 1] = table.concat(items, ',')
        end
        signatures[id] = table.concat(result, ' -> ')
        return signatures[id]
    end
    local function method_key(f, name)
        return name:match('^%u') and name or peers(f).key .. '\0' .. name
    end
    function C.owner(id)
        if owners[id] ~= nil then return owners[id] or nil end
        local n, f = G.nodes[id], G.node_file[id]
        local owner
        if n.parent and G.files[f].nodes[n.parent].kind == 'interface' then owner = G.id_of[f][n.parent]
        elseif n.kind == 'method' and n.recv then
            local ids = named(f, n.recv)
            if #ids == 1 and G.nodes[ids[1]].kind ~= 'typedef' then owner = ids[1]
            else owner = resolve_type(f, { kind = 'name', name = n.recv }) end
        end
        owners[id] = owner or false
        return owner
    end
    local function declarations(id, filter)
        local n, f, out, seen = G.nodes[id], G.node_file[id], {}, {}
        local function add(mid)
            local g = G.node_file[mid]
            if not G.id_of[g][1] or mid < G.id_of[g][1] or mid > G.id_of[g][#G.id_of[g]] then return end
            if filter and not filter[G.nodes[mid].name] then return end
            if not seen[mid] and peers(f).members[g] and G.nodes[mid].kind == 'method' and C.owner(mid) == id then
                seen[mid] = true; out[#out + 1] = mid
            end
        end
        for i, mid in ipairs(G.by_owner[n.qualified] or {}) do
            if i > M.MAX_NODES then limited(); break end
            add(mid)
        end
        for g in pairs(G.drafts or {}) do
            if peers(f).members[g] then for _, mid in ipairs(G.id_of[g]) do add(mid) end end
        end
        return out
    end
    local function set(id, pointer, path, depth, filter)
        local names = {}
        for name in pairs(filter or {}) do names[#names + 1] = name end
        table.sort(names)
        local key = id .. (pointer and '*' or '') .. ':' .. (filter and table.concat(names, '\0') or '*')
        if sets[key] then return sets[key] end
        depth, path = depth or 0, path or {}
        if expired() or depth > M.MAX_DEPTH or C.stats.sets >= M.MAX_TYPES then limited(); return { entries = {}, valid = false } end
        if path[id] then return { entries = {}, valid = false } end
        C.stats.sets = C.stats.sets + 1
        local d, n, f = info(id), G.nodes[id], G.node_file[id]
        local result = { entries = {}, valid = d ~= nil and not d.generic and not d.unsupported }
        if not d or not result.valid then sets[key] = result; return result end
        if n.kind == 'interface' and pointer then result.valid = false; sets[key] = result; return result end
        path[id] = true
        local function add(name, entry)
            if entry.ids then
                local ids = {}; for _, mid in ipairs(entry.ids) do ids[#ids + 1] = mid end
                entry.ids = ids
            end
            local old = result.entries[name]
            if old and n.kind == 'interface' then
                if old.signature and old.signature == entry.signature then
                    local seen = {}; for _, mid in ipairs(old.ids or {}) do seen[mid] = true end
                    for _, mid in ipairs(entry.ids or {}) do if not seen[mid] then old.ids[#old.ids + 1] = mid end end
                else result.valid = false; result.entries[name] = { depth = 0, blocked = true } end
            elseif not old or entry.depth < old.depth then result.entries[name] = entry
            elseif old.depth == entry.depth then
                result.entries[name] = { depth = old.depth, blocked = true }
            end
        end
        for _, mid in ipairs(declarations(id, filter)) do
            local md, mf = info(mid), G.node_file[mid]
            local usable = md and not md.generic and (n.kind == 'interface' or md.receiver)
            local is_pointer = usable and md.receiver and md.receiver.kind == 'pointer'
            local sig = usable and C.signature(mid)
            add(method_key(mf, G.nodes[mid].name), { depth = 0, ids = { mid }, signature = sig,
                blocked = not usable or is_pointer and not pointer })
        end
        for _, field in ipairs(d.fields or {}) do
            local mid = G.id_of[f][field]
            if not filter or filter[G.nodes[mid].name] then add(method_key(f, G.nodes[mid].name), { depth = 0, field = mid, blocked = true }) end
        end
        if n.kind == 'typedef' and not d.alias then
            local ty = d.underlying
            if not ty or ty.kind == 'pointer' or ty.kind == 'name' and not primitive[ty.name] then result.valid = false end
            if ty and ty.kind == 'pointer' then result.invalid = true end
        end
        for _, embedded in ipairs(d.embeds or {}) do
            local ptr, ty = embedded.kind == 'pointer', embedded.kind == 'pointer' and embedded.child or embedded
            local base = resolve_type(f, ty)
            if not base or ptr and G.nodes[base].kind == 'interface'
                or n.kind == 'interface' and G.nodes[base].kind ~= 'interface' then
                result.valid = false
                if base and ptr and G.nodes[base].kind == 'interface' then result.invalid = true end
            else
                local inherited = set(base, G.nodes[base].kind ~= 'interface' and (pointer or ptr), path, depth + 1, filter)
                if not inherited.valid then result.valid = false end
                if inherited.invalid then result.invalid = true end
                for name, entry in pairs(inherited.entries) do
                    add(name, { depth = entry.depth + 1, ids = entry.ids, signature = entry.signature,
                        field = entry.field, blocked = entry.blocked })
                end
            end
        end
        path[id] = nil; sets[key] = result
        return result
    end
    C.method_set = set
    local value_type
    value_type = function(f, ty, path, depth)
        path, depth = path or {}, (depth or 0) + 1
        if not ty or depth > M.MAX_DEPTH or expired() then return nil end
        if ty.kind == 'binding_value' then
            local entry = C.bound(f, ty.name, ty.at)
            if not entry or entry.generic or path[entry] then return nil end
            path[entry] = true
            local result, origin = value_type(f, entry.type, path, depth)
            path[entry] = nil; return result, origin
        elseif ty.kind == 'call_result' then
            local ids
            if ty.receiver or ty.recv then
                local receiver
                if ty.receiver then receiver = C.expression_receiver(f, ty.receiver, path, depth)
                else receiver = C.receiver(f, ty.recv, ty.at, path, depth) end
                if receiver == false or receiver and receiver.type_expr then return nil end
                if receiver then
                    ids = {}; for _, member in ipairs(C.members(receiver, f, ty.name)) do
                        if member.kind == 'method' then ids[#ids + 1] = member.id end
                    end
                else ids = modules.resolve(G, f, ty.name, ty.recv, ctx) end
            elseif not C.bound(f, ty.name, ty.at) and not shadowed(f, ty.name, ty.at) then
                ids = modules.resolve(G, f, ty.name, nil, ctx)
            end
            if not ids or #ids ~= 1 then return nil end
            local d, origin = info(ids[1]), G.node_file[ids[1]]
            if not d or d.generic or not d.signature or #d.signature.results ~= ty.arity then return nil end
            return value_type(origin, d.signature.results[ty.result], path, depth)
        elseif ty.kind == 'range_value' then
            local collection, origin = value_type(f, ty.child, path, depth)
            local visited = {}
            for _ = 1, M.MAX_DEPTH do
                if not collection then return nil end
                if collection.kind ~= 'name' then break end
                local ids, known = named(origin, collection.name, collection.at)
                if #ids == 0 and not known and collection.name == 'string' then
                    if ty.arity > 2 then return nil end
                    return { kind = 'builtin', name = ty.result == 1 and 'int' or 'int32' }, origin
                end
                if #ids ~= 1 or visited[ids[1]] then return nil end
                local d = info(ids[1]); visited[ids[1]] = true
                if not d or d.generic then return nil end
                collection, origin = d.underlying, G.node_file[ids[1]]
            end
            if not collection then return nil end
            if collection.kind == 'pointer' and collection.child.kind == 'array' then collection = collection.child end
            if collection.kind == 'channel' then
                if collection.extra == 'send' or ty.arity ~= 1 then return nil end
                return collection.child, origin
            elseif collection.kind == 'slice' or collection.kind == 'array' or collection.kind == 'map' then
                if ty.arity > 2 then return nil end
                return ty.result == 1 and (collection.kind == 'map' and collection.key or { kind = 'builtin', name = 'int' })
                    or collection.child, origin
            end
            return nil
        end
        return ty, f
    end
    function C.expression_receiver(f, expression, path, depth)
        local ty, origin = value_type(f, expression, path, depth)
        if not ty then return false end
        local pointer = ty.kind == 'pointer'
        local id = resolve_type(origin, pointer and ty.child or ty)
        return id and { id = id, pointer = pointer, addressable = false, type_expr = false } or false
    end
    function C.receiver(f, name, at, path, depth)
        local entry = C.bound(f, name, at)
        if entry == false then return false end
        if not entry and shadowed(f, name, at) then return false end
        local ty, addressable
        if entry then
            if entry.generic or not entry.type then return false end
            ty, addressable = entry.type, true
            if ty.builtin_new then
                local _, shadowed = named(f, 'new', ty.at)
                if shadowed then return false end
            end
        else ty = { kind = 'name', name = name, at = at } end
        local origin
        ty, origin = value_type(f, ty, path, depth)
        if not ty then return false end
        local pointer = ty.kind == 'pointer'
        local id = resolve_type(origin, pointer and ty.child or ty)
        if not id then
            if not entry and modules.aliases(G, f, ctx)[name] then return nil end
            return false
        end
        return { id = id, pointer = pointer, addressable = addressable or false, type_expr = not entry }
    end
    function C.members(receiver, requesting, name)
        local pointer = receiver.pointer or receiver.addressable and G.nodes[receiver.id].kind ~= 'interface'
        local methods, result = set(receiver.id, pointer, nil, nil, name and { [name] = true }), {}
        for name, entry in pairs(methods.entries) do
            local exported = name:match('^%u')
            local visible = exported or name:sub(1, #peers(requesting).key + 1) == peers(requesting).key .. '\0'
            if visible and (methods.valid or entry.depth == 0) then
                if entry.field and not receiver.type_expr then
                    local id = entry.field
                    result[#result + 1] = { name = G.nodes[id].name, kind = 'field', node = G.nodes[id], file = G.node_file[id], id = id }
                elseif not entry.blocked then
                    for _, id in ipairs(entry.ids or {}) do result[#result + 1] = { name = G.nodes[id].name,
                        kind = 'method', node = G.nodes[id], file = G.node_file[id], id = id } end
                end
            end
        end
        table.sort(result, function(a, b) return a.name < b.name or a.name == b.name and a.file < b.file end)
        return result
    end
    function C.resolve(f, name, recv, evidence)
        if evidence == 'go:?' then return {}, 'unsupported Go receiver chain' end
        local expression_at = evidence and tonumber(evidence:match('^go:expr:(%d+)$'))
        if expression_at then
            local d = C.data(f)
            local expression = d and d.receivers[expression_at]
            local receiver = expression and C.expression_receiver(f, expression)
            if not receiver then return {}, 'unknown Go receiver expression' end
            local result = {}
            for _, entry in ipairs(C.members(receiver, f, name)) do if entry.id then result[#result + 1] = entry.id end end
            return result, 'Go call-result method set'
        end
        if not recv then
            local at = evidence and tonumber(evidence:match('^go:call:(%d+)$'))
            if at and C.bound(f, name, at) ~= nil then return {}, 'unresolved local Go callable' end
            return nil
        end
        local at = evidence and tonumber(evidence:match('^go:recv:(%d+)$'))
        if not at then
            if modules.aliases(G, f, ctx)[recv] then return nil end
            return {}, 'Go receiver has no lexical binding evidence'
        end
        local receiver = C.receiver(f, recv, at)
        if receiver == false then return {}, 'unknown or shadowed Go receiver' end
        if not receiver then return nil end
        local result = {}
        for _, entry in ipairs(C.members(receiver, f, name)) do if entry.name == name and entry.id then result[#result + 1] = entry.id end end
        return result, 'Go method set'
    end
    local function satisfies(id, contract, pointer)
        if G.nodes[id].kind == 'interface' then return false end
        local wanted, count, filter = set(contract, false), 0, {}
        for _, entry in pairs(wanted.entries) do
            if entry.ids then filter[G.nodes[entry.ids[1]].name] = true end
        end
        local got = set(id, pointer, nil, nil, filter)
        if not wanted.valid or got.invalid then return false end
        for name, entry in pairs(wanted.entries) do
            if entry.blocked or not entry.signature then return false end
            count = count + 1
            local actual = got.entries[name]
            if not actual or actual.blocked or actual.signature ~= entry.signature then return false end
            if not got.valid and actual.depth ~= 0 then return false end
        end
        return count > 0, got
    end
    C.satisfies = satisfies
    function C.types(f, written)
        local pointer = written:sub(1, 1) == '*'
        local id = resolve_type(f, { kind = 'name', name = pointer and written:sub(2) or written })
        return id and { id } or {}
    end
    local function implementers(contract)
        local wanted, seed, shortest = set(contract, false), nil, math.huge
        if not wanted.valid then return {} end
        for _, entry in pairs(wanted.entries) do
            if entry.blocked or not entry.ids or not entry.signature then return {} end
            local list = G.by_name[G.nodes[entry.ids[1]].name] or {}
            if #list < shortest then seed, shortest = list, #list end
        end
        if not seed then return {} end
        -- Embedders need not declare the wanted method. Follow only indexed
        -- embedded-field names, never a global type/interface Cartesian product.
        local candidates, seen, queue = {}, {}, {}
        local function add(id)
            if not id or seen[id] then return end
            seen[id] = true
            if #queue >= M.MAX_CANDIDATES then limited(); return end
            queue[#queue + 1] = id
        end
        for i, mid in ipairs(seed) do
            if i > M.MAX_CANDIDATES then limited(); break end
            if G.files[G.node_file[mid]].language == 'go' then add(C.owner(mid)) end
        end
        local i = 1
        while i <= #queue do
            if expired() then break end
            local id = queue[i]; i = i + 1
            control.check(); C.stats.candidates = C.stats.candidates + 1
            if satisfies(id, contract, false) or satisfies(id, contract, true) then candidates[#candidates + 1] = id end
            if #candidates >= M.MAX_RESULTS then limited(); break end
            for index, field in ipairs(G.by_name[G.nodes[id].name] or {}) do
                if index > M.MAX_CANDIDATES then limited(); break end
                local n, f = G.nodes[field], G.node_file[field]
                if G.files[f].language == 'go' and n.embedded and n.parent then
                    local parent = G.id_of[f][n.parent]
                    local d = info(parent)
                    if d then
                        for _, ty in ipairs(d.embeds) do
                            if resolve_type(f, ty.kind == 'pointer' and ty.child or ty) == id then add(parent) end
                        end
                    end
                end
            end
        end
        return candidates
    end
    function C.outgoing(id)
        if outgoing[id] then return outgoing[id] end
        local owner = G.nodes[id].kind == 'interface' and id or C.owner(id)
        local result, seen = {}, {}
        if owner and G.nodes[owner].kind == 'interface' then
            for _, candidate in ipairs(implementers(owner)) do
                if id == owner then result[#result + 1] = candidate
                else
                    local key = method_key(G.node_file[id], G.nodes[id].name)
                    local matched, methods = satisfies(candidate, owner, false)
                    if not matched then matched, methods = satisfies(candidate, owner, true) end
                    local entry = matched and methods.entries[key]
                    for _, mid in ipairs(entry and entry.ids or {}) do
                        if mid ~= id and not G.nodes[mid].abstract and not seen[mid] then
                            seen[mid] = true; result[#result + 1] = mid; C.stats.links = C.stats.links + 1
                            if C.report then C.report:add({ source = id, target = mid, line = G.nodes[id].line,
                                kind = 'possible Go implementation (method set and exact signature)' }) end
                        end
                    end
                end
            end
        end
        outgoing[id] = result; return result
    end
    function C.incoming(id)
        if incoming[id] then return incoming[id] end
        local result, seen = {}, {}
        for i, base in ipairs(G.by_name[G.nodes[id].name] or {}) do
            if i > M.MAX_CANDIDATES then limited(); break end
            if G.files[G.node_file[base]].language == 'go' and G.nodes[base].kind == 'method' then
                local owner = C.owner(base)
                if owner and G.nodes[owner].kind == 'interface' then
                    for _, mid in ipairs(C.outgoing(base)) do
                        if mid == id and not seen[base] then seen[base] = true; result[#result + 1] = base end
                    end
                end
            end
        end
        incoming[id] = result; return result
    end
    return C
end

function M.resolve(G, f, name, recv, evidence, ctx)
    return M.context(G, ctx).resolve(f, name, recv, evidence)
end

return M
