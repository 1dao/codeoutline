-- C++ override evidence belongs to a query, never the resident index.
local M = { MAX_ALIAS_FILES = 128, MAX_ALIAS_BYTES = 1024 * 1024 }
local control = require('codeoutline.control')
local lookup = require('codeoutline.cpp_types')
local classes = { class = true, struct = true }
local cv = { const = true, volatile = true }
local builtin = { void = true, bool = true, char = true, wchar_t = true, char8_t = true,
    char16_t = true, char32_t = true, short = true, int = true, long = true,
    signed = true, unsigned = true, float = true, double = true }
local modifiers = { virtual = true, static = true, inline = true, constexpr = true,
    consteval = true, explicit = true, friend = true, extern = true }

local function tokens(T, a, b)
    local out = {}
    for i = a, b do out[#out + 1] = T:text(i) end
    return out
end

local function parameter(T, a, b)
    for i = a, b do if T:text(i) == '=' then b = i - 1; break end end
    -- A trailing identifier is a name only when a type precedes it. Preserve
    -- unnamed `const Item`, qualified types, and all pointer/cv decoration.
    if T.k[b] == 'id' and T:text(b - 1) ~= '::' then
        local typed = false
        for i = a, b - 1 do
            local s = T:text(i)
            if not cv[s] and s ~= 'struct' and s ~= 'class' and s ~= '::' then typed = true end
        end
        if typed then b = b - 1 end
    end
    return tokens(T, a, b)
end

function M.collect(r, T)
    local evidence = {}
    for id, n in ipairs(r.nodes) do
        if id % 128 == 0 then control.check() end
        if classes[n.kind] or n.kind == 'method' then
            local d = { at = T.s[n.ti] - 1 }
            if classes[n.kind] then d.hierarchy_bases = require('codeoutline.type_bases').collect(T, n, r.language) end
            local ni, opening
            for i = n.ti, n.tj do
                local s = T:text(i)
                if s == '{' then break end
                if s == 'template' or s == '<' or s == '>' then d.unsupported = true end
                if s == 'virtual' or s == 'static' or s == 'final' or s == 'friend' then d[s] = true end
                if s == n.name and T:text(i + 1) == '(' and n.kind == 'method' then
                    ni, opening = i, i + 1; break
                end
            end
            if n.kind == 'method' and opening and T.m[opening] then
                local close, params, first = T.m[opening], {}, opening + 1
                local i = first
                while i <= close do
                    local s = T:text(i)
                    if i == close or s == ',' then
                        if first < i then params[#params + 1] = parameter(T, first, i - 1) end
                        first = i + 1
                    elseif T.m[i] and T.m[i] > i then i = T.m[i] end
                    i = i + 1
                end
                if #params == 1 and #params[1] == 1 and params[1][1] == 'void' then params = {} end
                d.params = params
                local head = ni
                while T:text(head - 1) == '::' and T.k[head - 2] == 'id' do head = head - 2 end
                if T:text(head - 1) == '::' then head = head - 1 end
                local ret = {}
                for j = n.ti, head - 1 do
                    local s = T:text(j)
                    if not modifiers[s] then ret[#ret + 1] = s end
                end
                d.returns = ret
                i = close + 1
                while i <= n.tj do
                    local s = T:text(i)
                    if s == '{' or s == ';' then break end
                    if cv[s] or s == 'final' or s == 'override' then d[s] = true
                    elseif s == '&' or s == '&&' then d.ref = s
                    elseif s == '=' and T:text(i + 1) == '0' then d.pure = true; i = i + 1
                    elseif s == 'noexcept' then
                        if T:text(i + 1) == '(' and T.m[i + 1] then i = T.m[i + 1] end
                    else d.unsupported = true end
                    i = i + 1
                end
            elseif n.kind == 'method' then d.unsupported = true end
            evidence[id] = d
        end
    end
    r.implementation_evidence = evidence
end

function M.context(G, ctx, report, limits, C)
    local details, owners, chains, lists, outgoing, incoming = {}, {}, {}, {}, {}, {}
    local alias_records, alias_count, alias_bytes, alias_limited = {}, 0, 0, false
    local function aliases(f)
        if alias_records[f] then return alias_records[f] end
        if alias_limited then return {} end
        local data = lookup.aliases(G, f, ctx)
        local weight = 0
        for _, alias in ipairs(data) do
            weight = weight + 128
            for _, value in pairs(alias) do if type(value) == 'string' then weight = weight + #value end end
        end
        if alias_count >= M.MAX_ALIAS_FILES or alias_bytes + weight > M.MAX_ALIAS_BYTES then
            alias_limited, C.incomplete = true, true; return {}
        end
        -- Retain only the alias arrays already produced by the shared loader.
        -- Repeated parameter lookups must not thrash its 16-file source FIFO.
        alias_count, alias_bytes = alias_count + 1, alias_bytes + weight
        alias_records[f] = data
        C.stats.cpp_alias_files, C.stats.cpp_alias_bytes = alias_count, alias_bytes
        return data
    end
    local function info(id)
        if not details[id] then
            local f = G.node_file[id]
            local data = ctx.ordinary and ctx.ordinary.data(f) or G.files[f]
            details[id] = (data.implementation_evidence or {})[id - G.id_of[f][1] + 1] or {}
        end
        return details[id]
    end
    local function resolve(id, text, accept)
        local ids = lookup.resolve(G, G.node_file[id], text, { context = ctx,
            scope = G.nodes[id].qualified, at = info(id).at, accept = accept or classes,
            undecorated = true, aliases = aliases })
        if ctx.include_incomplete then C.incomplete = true end
        return #ids == 1 and ids[1] or nil
    end
    local function owner(id)
        if owners[id] == nil then
            local n, f = G.nodes[id], G.node_file[id]
            local parent = n.parent and G.id_of[f][n.parent]
            owners[id] = parent and classes[G.nodes[parent].kind] and parent
                or resolve(id, n.qualified:match('^(.*)::[^:]+$')) or false
        end
        return owners[id] or nil
    end
    local function ancestry(id)
        if chains[id] then return chains[id] end
        local out, visited, current = {}, {}, id
        while current do
            control.check()
            if visited[current] or #out > limits.MAX_DEPTH or C.stats.hierarchy >= limits.MAX_HIERARCHY then
                C.incomplete = true; out = {}; break
            end
            visited[current] = true; C.stats.hierarchy = C.stats.hierarchy + 1
            local n, d = G.nodes[current], info(current)
            local bases = n.bases or {}
            -- Multiple/virtual inheritance, templates, and unresolved bases
            -- need a final-overrider model; do not approximate by class name.
            if d.unsupported or d.virtual or current ~= id and d.final or #bases > 1 then out = {}; break end
            if #bases == 0 then break end
            local parent = resolve(current, bases[1])
            if not parent then out = {}; break end
            out[#out + 1] = parent; current = parent
        end
        chains[id] = out; return out
    end
    local function type_key(id, words, value)
        if not words or #words == 0 then return nil end
        local base, layers, layer = {}, {}, {}
        layers[1] = layer
        for _, s in ipairs(words) do
            if cv[s] then layer[s] = true
            elseif s == '*' or s == '&' or s == '&&' then
                if layer.op == '&' or layer.op == '&&' then return nil end
                layer = { op = s }; layers[#layers + 1] = layer
            elseif s == '::' or s:match('^[%a_][%w_]*$') then
                if #layers ~= 1 then return nil end
                if s ~= 'struct' and s ~= 'class' and s ~= 'enum' then base[#base + 1] = s end
            else return nil end
        end
        if #base == 0 then return nil end
        local primitive = true
        for _, s in ipairs(base) do if not builtin[s] then primitive = false end end
        local canonical
        if primitive then
            canonical = table.concat(base, ' ')
            canonical = canonical:gsub('^signed int$', 'int'):gsub('^signed$', 'int')
                :gsub('^unsigned$', 'unsigned int'):gsub('short int$', 'short'):gsub('long int$', 'long')
        else
            local written = table.concat(base):gsub('::', ':')
            if written:find('[^%w_:]') or not written:match('^:?[A-Za-z_][%w_:]*$') then return nil end
            -- Adjacent identifiers are not a qualified named type.
            for i = 2, #base do if base[i] ~= '::' and base[i - 1] ~= '::' then return nil end end
            local ty = resolve(id, table.concat(base), { class = true, struct = true, enum = true })
            if not ty then return nil end
            canonical = '#' .. ty
        end
        local result = { canonical }
        for i, part in ipairs(layers) do
            local ignore = value and i == #layers and part.op ~= '&' and part.op ~= '&&'
            result[#result + 1] = (part.op or '') .. (not ignore and part.const and ' const' or '')
                .. (not ignore and part.volatile and ' volatile' or '')
        end
        return table.concat(result)
    end
    local function signature(id)
        local d, cls = info(id), owner(id)
        if not cls or not d.params or d.unsupported or d.friend or info(cls).unsupported
            or info(cls).virtual or #(G.nodes[cls].bases or {}) > 1 then return nil end
        local enclosing, depth = cls, 0
        while enclosing do
            if info(enclosing).unsupported then return nil end
            depth = depth + 1
            if depth > limits.MAX_DEPTH + 1 then C.incomplete = true; return nil end
            local n, f = G.nodes[enclosing], G.node_file[enclosing]
            enclosing = n.parent and G.id_of[f][n.parent]
            if enclosing and not classes[G.nodes[enclosing].kind] then enclosing = nil end
        end
        local params = {}
        for _, p in ipairs(d.params) do
            local key = type_key(id, p, true)
            if not key then return nil end
            params[#params + 1] = key
        end
        local ret = type_key(id, d.returns, false)
        if not ret then return nil end
        return table.concat(params, ',') .. '|' .. (d.const and 'const' or '')
            .. (d.volatile and 'volatile' or '') .. (d.ref or ''), ret
    end
    local function methods(name)
        if lists[name] then return lists[name] end
        local groups, by_id, ordered, checked = {}, {}, {}, 0
        for _, id in ipairs(G.by_name[name] or {}) do
            control.check()
            if G.nodes[id].kind == 'method' and G.files[G.node_file[id]].language == 'cpp' then
                if checked >= limits.MAX_CANDIDATES then C.incomplete = true; break end
                checked = checked + 1; C.stats.candidates = C.stats.candidates + 1
                local sig, ret = signature(id)
                if sig then
                    local cls, d = owner(id), info(id)
                    groups[cls] = groups[cls] or {}
                    local group = groups[cls][sig]
                    if not group then
                        group = { cls = cls, sig = sig, ret = ret, ids = {} }; groups[cls][sig] = group
                        ordered[#ordered + 1] = group
                    end
                    if group.ret ~= ret then group.invalid = true end
                    group.ids[#group.ids + 1] = id; by_id[id] = group
                    local n, f = G.nodes[id], G.node_file[id]
                    if n.parent and G.id_of[f][n.parent] == cls then group.declared = true end
                    for _, flag in ipairs({ 'virtual', 'pure', 'static', 'final' }) do if d[flag] then group[flag] = true end end
                    if not G.nodes[id].decl then
                        if group.body then group.invalid = true end
                        group.body = id
                    end
                end
            end
        end
        for _, members in pairs(groups) do
            for _, group in pairs(members) do if not group.declared then group.invalid = true end end
        end
        local result = { groups = groups, by_id = by_id, ordered = ordered }; lists[name] = result; return result
    end
    local function inherited(list, group)
        local result = {}
        for _, cls in ipairs(ancestry(group.cls)) do
            local parent = list.groups[cls] and list.groups[cls][group.sig]
            if parent then result[#result + 1] = parent end
        end
        return result
    end
    local function contract(list, group)
        if group.invalid or group.static then return false end
        local virtual = group.virtual
        for _, parent in ipairs(inherited(list, group)) do
            if parent.invalid or parent.static or parent.final or parent.ret ~= group.ret then return false end
            virtual = virtual or parent.virtual
        end
        return virtual
    end
    local function matches(list, base, candidate)
        if candidate.invalid or candidate.pure or candidate.static or candidate.ret ~= base.ret or base.final then return false end
        for _, parent in ipairs(inherited(list, candidate)) do
            if parent == base then return true end
            if parent.invalid or parent.static or parent.final or parent.ret ~= candidate.ret then return false end
        end
        return false
    end
    local function link(source, target)
        C.stats.links = C.stats.links + 1
        if report then report:add({ source = source, target = target, line = G.nodes[source].line,
            kind = 'possible implementation (C++ virtual declaration and exact signature)' }) end
    end
    local function potential(id)
        local cls = owner(id)
        if not cls or info(cls).final then return false end
        if #(G.nodes[cls].bases or {}) > 0 or info(id).virtual then return true end
        -- A class-outside body inherits the virtual marker from its declaration.
        -- A plain root method must not expand hundreds of same-name candidates.
        for _, declaration in ipairs(G.by_qualified[G.nodes[id].qualified] or {}) do
            if G.files[G.node_file[declaration]].language == 'cpp' and G.nodes[declaration].kind == 'method'
                and owner(declaration) == cls and info(declaration).virtual then return true end
        end
        return false
    end
    local D = {}
    function D.outgoing(id)
        if outgoing[id] then return outgoing[id] end
        if not potential(id) then outgoing[id] = {}; return outgoing[id] end
        local result, list = {}, methods(G.nodes[id].name)
        local base = list.by_id[id]
        if base and contract(list, base) and not base.final then
            for _, group in ipairs(list.ordered) do
                if group.sig == base.sig and matches(list, base, group) then
                    if #result >= limits.MAX_TARGETS then C.incomplete = true; break end
                    local target = group.body or group.ids[1]
                    result[#result + 1] = target
                end
            end
        end
        if alias_limited then result = {} end
        for _, target in ipairs(result) do link(id, target) end
        table.sort(result); outgoing[id] = result; return result
    end
    function D.incoming(id)
        if incoming[id] then return incoming[id] end
        local cls = owner(id)
        if not cls or #(G.nodes[cls].bases or {}) == 0 then incoming[id] = {}; return incoming[id] end
        local result, list = {}, methods(G.nodes[id].name)
        local candidate = list.by_id[id]
        if candidate then
            for _, base in ipairs(inherited(list, candidate)) do
                if contract(list, base) and matches(list, base, candidate) then
                    for _, source in ipairs(base.ids) do
                        if #result >= limits.MAX_TARGETS then C.incomplete = true; break end
                        result[#result + 1] = source
                    end
                end
            end
        end
        if alias_limited then result = {} end
        for _, source in ipairs(result) do link(source, id) end
        table.sort(result); incoming[id] = result; return result
    end
    return D
end

return M
