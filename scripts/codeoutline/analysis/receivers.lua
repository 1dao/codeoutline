-- Query-owned receiver bindings shared by graph, navigation and completion.
-- Language adapters establish identity; names alone never establish ownership.
local M = { MAX_BINDINGS = 8192, MAX_CANDIDATES = 512, MAX_DEPTH = 16 }
local control = require('codeoutline.shared.control')
local classes = { class = true, interface = true, struct = true, record = true, enum = true, union = true }
local callable = { ['function'] = true, method = true, constructor = true }
local function js(language) return language == 'javascript' or language == 'typescript' or language == 'arkts' end

function M.at(meta, name, offset)
    local best, index, future
    for _, i in ipairs(meta and meta.by_name[name] or {}) do
        local b = meta.bindings[i]
        if b.first <= offset and offset < b.last and b.at <= offset
            and (not best or b.first > best.first or b.first == best.first and b.at > best.at) then best, index = b, i end
        if b.hoisted and b.first <= offset and offset < b.last and b.at > offset
            and (not future or b.first > future.first) then future = b end
    end
    if future and (not best or future.first > best.first) then return { blocked = true }, 0 end
    return best, index
end

function M.collect(r, T)
    local language = r.language
    if language ~= 'python' and language ~= 'kotlin' and not js(language) then return end
    local meta = { bindings = {}, by_name = {}, statics = {}, fields = {}, weight = 128 }
    r.receivers = meta
    local function add(name, token, first, last, value)
        if #meta.bindings >= M.MAX_BINDINGS then meta.incomplete = true; return end
        local b = { name = name, at = token > 0 and T.s[token] - 1 or 0, first = first, last = last,
            owner = value and value.owner, type = value and value.type, static = value and value.static,
            super = value and value.super }
        local n = #meta.bindings + 1; meta.bindings[n] = b
        meta.by_name[name] = meta.by_name[name] or {}; table.insert(meta.by_name[name], n)
        meta.weight = meta.weight + 192 + #name + #(b.type or '')
        if name == 'this' and js(language) then
            add('super', token, first, last, { owner = b.owner, type = b.type, static = b.static, super = true })
        end
        return b
    end
    local function text(i) return i >= 1 and i <= T.n and T:text(i) or '' end
    local function bounds(node) return T.s[node.ti] - 1, T.e[node.tj] + 1 end
    local function enclosing(i)
        local found, index
        for n, node in ipairs(r.nodes) do
            if callable[node.kind] and node.ti <= i and i <= node.tj
                and (not found or node.tj - node.ti < found.tj - found.ti) then found, index = node, n end
        end
        return found, index
    end
    local function written(i)
        if T.k[i] ~= 'id' then return nil end
        local parts = { text(i) }; local j = i + 1
        while text(j) == '.' and T.k[j + 1] == 'id' do parts[#parts + 1] = text(j + 1); j = j + 2 end
        return table.concat(parts, '.'), j
    end
    if language == 'kotlin' then
        local declarations = {}
        for _, node in ipairs(r.nodes) do
            if callable[node.kind] then
                for i = node.ti, node.tj do
                    if text(i) == '(' then declarations[i - 1] = true; break end
                    if text(i) == '{' then break end
                end
                local first, last = bounds(node)
                local p = node.parent
                while p and not classes[r.nodes[p].kind] do p = r.nodes[p].parent end
                local value = node.receiver and { type = node.receiver } or p and { owner = p }
                add('this', node.ti, first, last, value)
                if node.receiver then add('this@' .. node.name, node.ti, first, last, value) end
                while p do
                    add('this@' .. r.nodes[p].name, node.ti, first, last, { owner = p })
                    if not (r.nodes[p].sig or ''):match('%f[%a]inner%f[%A]') then break end
                    p = r.nodes[p].parent
                    while p and not classes[r.nodes[p].kind] do p = r.nodes[p].parent end
                end
            end
        end
        local function value(at)
            local name = text(at)
            if T.k[at] == 'id' and text(at + 1) == '(' then return { type = name } end
            local best
            for _, b in ipairs((T.jvm_bindings or {})[name] or {}) do
                if b.token <= at and b.first <= at and at <= b.last
                    and (not best or b.first > best.first or b.first == best.first and b.token > best.token) then best = b end
            end
            return best and best.type and { type = best.type } or nil
        end
        for i = 1, T.n do
            local body, bound, label
            if not declarations[i] and text(i) == 'with' and text(i + 1) == '(' and T.m[i + 1] then
                body, bound, label = T.m[i + 1] + 1, value(i + 2), 'with'
            elseif not declarations[i] and (text(i) == 'run' or text(i) == 'apply') and text(i - 1) == '.' then
                body, label = text(i + 1) == '(' and T.m[i + 1] and T.m[i + 1] + 1 or i + 1, text(i)
                local at = text(i - 2) == ')' and T.m[i - 2] and T.m[i - 2] - 1 or i - 2
                bound = value(at)
            end
            if body and text(body) == '{' and T.m[body] then
                for _, node in ipairs(r.nodes) do if node.name == label and callable[node.kind] then bound = nil end end
                for _, imp in ipairs(r.imports) do if (imp.alias or imp.path:match('([^.]+)$')) == label then bound = nil end end
                add('this', body, T.s[body] - 1, T.e[T.m[body]] + 1, bound)
                add('this@' .. label, body, T.s[body] - 1, T.e[T.m[body]] + 1, bound)
                if text(i - 1) == '@' and T.k[i - 2] == 'id' then
                    add('this@' .. text(i - 2), body, T.s[body] - 1, T.e[T.m[body]] + 1, bound)
                end
            end
        end
    elseif language == 'python' then
        add('self', 0, 0, #T.src + 1); add('cls', 0, 0, #T.src + 1)
        for n, node in ipairs(r.nodes) do
            if callable[node.kind] then
                local p = node.ti
                while p < node.tj and text(p) ~= 'def' do p = p + 1 end
                p = p + 2
                local close = text(p) == '(' and T.m[p]
                if close then
                    local first, last = bounds(node)
                    local owner = node.parent and classes[r.nodes[node.parent].kind] and node.parent
                    local static, classmethod = false, false
                    for _, decorator in ipairs(node.decorators or {}) do
                        static = static or decorator == 'staticmethod'
                        classmethod = classmethod or decorator == 'classmethod'
                    end
                    for i = p + 1, close - 1 do
                        if T.k[i] == 'id' and (i == p + 1 or text(i - 1) == ',') then
                            local value = text(i + 1) == ':' and { type = written(i + 2) } or nil
                            if i == p + 1 and owner and not static then value = { owner = owner, static = classmethod } end
                            add(text(i), i, first, last, value)
                        end
                    end
                end
            end
        end
        local depth, brackets = 0, {}
        for i = 1, T.n do
            if i % 1024 == 0 then control.check() end
            local prev, next = text(i - 1), text(i + 1)
            if T.k[i] == 'id' and prev ~= '.' and depth == 0 and
                (next == '=' or next == ':=' or prev == 'for' and next == 'in') then
                local node = enclosing(i)
                local first, last = 0, #T.src + 1
                if node then first, last = bounds(node) end
                local value
                if next == '=' or next == ':=' then
                    local name, after = written(i + 2)
                    if name and text(after) == '(' then value = { type = name }
                    elseif name then value = M.at(meta, name, T.s[i] - 1) end
                end
                local b = add(text(i), i, first, last, value)
                if b then b.hoisted = true end
            end
            if T.k[i] == 'id' and prev == 'for' and next == 'in' and depth > 0 then
                local open = brackets[#brackets]
                if open and T.m[open] then
                    local b = add(text(i), i, T.s[open] - 1, T.e[T.m[open]] + 1)
                    if b then b.hoisted = true end
                end
            end
            if text(i) == 'lambda' then
                local colon = i + 1
                while colon < T.n and text(colon) ~= ':' do
                    if T.m[colon] and T.m[colon] > colon then colon = T.m[colon] end
                    colon = colon + 1
                end
                local last = colon + 1
                while last <= T.n and T.k[last] ~= 'nl' and text(last) ~= ',' and text(last) ~= ';'
                    and text(last) ~= ')' and text(last) ~= ']' and text(last) ~= '}' do
                    last = (T.m[last] and T.m[last] > last and T.m[last] or last) + 1
                end
                for j = i + 1, colon - 1 do
                    if T.k[j] == 'id' and (j == i + 1 or text(j - 1) == ',') then
                        add(text(j), j, T.s[i] - 1, T.s[last] and T.s[last] - 1 or #T.src + 1)
                    end
                end
            end
            if text(i) == '(' or text(i) == '[' or text(i) == '{' then depth = depth + 1; brackets[#brackets + 1] = i
            elseif text(i) == ')' or text(i) == ']' or text(i) == '}' then depth = math.max(0, depth - 1); brackets[#brackets] = nil end
        end
    else
        add('this', 0, 0, #T.src + 1)
        for n, node in ipairs(r.nodes) do
            if callable[node.kind] then
                local first, last = bounds(node)
                local owner = node.parent and classes[r.nodes[node.parent].kind] and node.parent
                local arrow, static = false, false
                for i = node.ti, node.tj do
                    if text(i) == '=>' then arrow = true; break end
                    if text(i) == 'static' then static = true end
                    if text(i) == '{' then break end
                end
                meta.statics[n] = static
                local value = owner and { owner = owner, static = static } or arrow and M.at(meta, 'this', first)
                add('this', node.ti, first, last, value)
            elseif node.kind == 'field' then
                meta.statics[n] = text(node.ti) == 'static'
            end
        end
        -- Anonymous ordinary functions introduce their own dynamic this.
        for i = 1, T.n do
            if text(i) == 'function' then
                local p = i + 1
                while p < T.n and text(p) ~= '(' and text(p) ~= '{' do p = p + 1 end
                local close = T.m[p]
                local body = close and close + 1
                while body and body < T.n and text(body) ~= '{' and text(body) ~= ';' do body = body + 1 end
                if body and T.m[body] then
                    local value
                    if text(p + 1) == 'this' and text(p + 2) == ':' then value = { type = written(p + 3) } end
                    add('this', i, T.s[i] - 1, T.e[T.m[body]] + 1, value)
                end
            end
        end
        local bindings = {}
        for _, list in pairs(T.js_bindings or {}) do for _, b in ipairs(list) do bindings[#bindings + 1] = b end end
        table.sort(bindings, function(a, b) return a.token < b.token end)
        for _, b in ipairs(bindings) do
            local first = b.a > 0 and T.s[b.a] - 1 or 0
            local last = b.b > 0 and T.e[b.b] + 1 or #T.src + 1
            local value = b.type ~= '?' and { type = b.type } or nil
            if text(b.token + 1) == '=' and (text(b.token + 2) == 'this' or T.k[b.token + 2] == 'id') then
                value = value or M.at(meta, text(b.token + 2), T.s[b.token] - 1)
            end
            local added = add(b.name, b.token, first, last, value)
            if added then added.hoisted = b.declaration end
        end
    end
    for _, ref in ipairs(r.refs) do
        if ref.recv and text(ref.tok - 3) ~= '.' and text(ref.tok - 3) ~= '?.' then
            local name = ref.recv
            if language == 'kotlin' and text(ref.tok - 3) == '@' and text(ref.tok - 4) == 'this' then name = 'this@' .. name end
            local _, index = M.at(meta, name, T.s[ref.tok] - 1)
            if index then ref.receiver = 'receiver:' .. index end
        end
    end
    for i = 1, T.n - 3 do
        if T.k[i] == 'id' or text(i) == 'this' then
            if text(i + 1) == '.' and T.k[i + 2] == 'id' and text(i + 3) == '=' then
                local _, index = M.at(meta, text(i), T.s[i] - 1)
                if index then meta.fields[#meta.fields + 1] = { binding = index, name = text(i + 2) }; meta.weight = meta.weight + 96 end
            end
        end
    end
end

local function detail(G, f, ctx)
    local rec = G.files[f]
    return ctx and ctx.ordinary and ctx.ordinary.available(f) and ctx.ordinary.data(f) or rec
end

local function owner(G, f, src)
    local p = src and G.nodes[src].parent
    while p do
        local node = G.files[f].nodes[p]
        if classes[node.kind] then return G.id_of[f][p] end
        p = node.parent
    end
end

function M.types(G, f, written, ctx, scope)
    if not written or not written:match('^[%a_$][%w_$.]*$') then return {} end
    local language, rec = G.files[f].language, G.files[f]
    if language == 'java' or language == 'kotlin' then
        return require('codeoutline.analysis.implementations').types(G, f, written, ctx, scope)
    elseif language == 'csharp' then
        return require('codeoutline.analysis.csharp.csharp_bindings').types(G, f, written, 0, ctx, { scope = scope })
    end
    local head, tail = written:match('^([%w_$]+)%.(.+)$')
    if js(language) then
        for _, imp in ipairs(rec.js_imports or {}) do
            if imp.local_name == (head or written) then
                if tail and imp.imported ~= '*' or not tail and imp.imported == '*' then return {} end
                return require('codeoutline.analysis.js.js_resolution').imported(G, f, imp.path, tail or imp.imported, ctx)
            end
        end
    elseif language == 'python' then
        for _, imp in ipairs(detail(G, f, ctx).python_imports or {}) do
            if imp.name == (head or written) then
                if imp.blocked then return {} end
                return require('codeoutline.analysis.python.python_bindings').imported(G, f, imp.path,
                    imp.imported == '*' and (tail or '') or imp.imported .. (tail and '.' .. tail or ''), ctx)
            end
        end
    end
    local result = {}
    for i, id in ipairs(G.by_name[written:match('([^.]+)$')] or {}) do
        if i > M.MAX_CANDIDATES then ctx.receiver_incomplete = true; break end
        local n = G.nodes[id]
        if G.node_file[id] == f and classes[n.kind] and (n.qualified == written or n.name == written) then result[#result + 1] = id end
    end
    return result
end

local function from_binding(G, f, b, ctx)
    if not b then return nil end
    local ids = b.owner and { G.id_of[f][b.owner] } or M.types(G, f, b.type, ctx)
    if b.super then
        local bases = {}
        for _, id in ipairs(ids) do
            for _, base in ipairs(G.nodes[id].extends or G.nodes[id].bases or {}) do
                for _, bid in ipairs(M.types(G, G.node_file[id], base, ctx, G.nodes[id].qualified)) do bases[#bases + 1] = bid end
            end
        end
        ids = bases
    end
    return { kind = 'types', ids = ids, static = b.static, language = G.files[f].language, file = f }
end

local function hierarchy(G, id, ctx, seen, depth)
    seen, depth = seen or {}, depth or 0
    if seen[id] or depth > M.MAX_DEPTH then ctx.receiver_incomplete = true; return nil end
    seen[id] = true
    local node, f = G.nodes[id], G.node_file[id]
    local bases = node.bases or node.extends or {}
    local sequences, direct = {}, {}
    for _, base in ipairs(bases) do
        local ids = M.types(G, f, base, ctx, node.qualified)
        if #ids ~= 1 then ctx.receiver_incomplete = true; seen[id] = nil; return nil end
        local chain = hierarchy(G, ids[1], ctx, seen, depth + 1)
        if not chain then seen[id] = nil; return nil end
        sequences[#sequences + 1] = chain; direct[#direct + 1] = ids[1]
    end
    sequences[#sequences + 1] = direct
    local result = { id }
    while true do
        local candidate, remaining
        for _, sequence in ipairs(sequences) do
            if #sequence > 0 then
                remaining = true
                local eligible = true
                for _, other in ipairs(sequences) do
                    for j = 2, #other do if other[j] == sequence[1] then eligible = false end end
                end
                if eligible then candidate = sequence[1]; break end
            end
        end
        if not remaining then break end
        if not candidate or #result >= M.MAX_CANDIDATES then ctx.receiver_incomplete = true; seen[id] = nil; return nil end
        result[#result + 1] = candidate
        for _, sequence in ipairs(sequences) do if sequence[1] == candidate then table.remove(sequence, 1) end end
    end
    seen[id] = nil
    return result
end

local function ancestors(G, id, ctx)
    local cache = ctx.receiver_hierarchies or {}; ctx.receiver_hierarchies = cache
    if cache[id] then return cache[id] end
    local result = hierarchy(G, id, ctx) or { id }
    if (ctx.receiver_hierarchy_count or 0) < M.MAX_CANDIDATES then
        ctx.receiver_hierarchy_count = (ctx.receiver_hierarchy_count or 0) + 1; cache[id] = result
    end
    return result
end

local function field_visible(target, bound)
    if js(target.language) then return not not target.static == not not bound.static end
    return target.language ~= 'python' or not target.static or bound.static == true
end

function M.member_ids(G, target, name, ctx, accept)
    local result = {}
    for _, cls in ipairs(target.ids or {}) do
        local chain = ancestors(G, cls, ctx)
        for _, id in ipairs(chain or {}) do
            local found, f, shadowed = {}, G.node_file[id], false
            local meta = detail(G, f, ctx).receivers
            for _, field in ipairs(meta and meta.fields or {}) do
                if field.name == name then
                    local bound = from_binding(G, f, meta.bindings[field.binding], ctx)
                    if bound.ids[1] == id and field_visible(target, bound) then shadowed = true; break end
                end
            end
            if shadowed then break end
            for i, mid in ipairs(G.by_name[name] or {}) do
                if i > M.MAX_CANDIDATES then ctx.receiver_incomplete = true; break end
                local node, mf = G.nodes[mid], G.node_file[mid]
                if mf == f and node.parent and G.id_of[mf][node.parent] == id then
                    local n = mid - G.id_of[mf][1] + 1
                    if not js(target.language) or not not (meta and meta.statics[n]) == not not target.static then
                        shadowed = true
                        if not accept or accept[node.kind] then found[#found + 1] = mid end
                    end
                end
            end
            if shadowed then for _, mid in ipairs(found) do result[#result + 1] = mid end; break end
        end
    end
    return result
end

function M.binding(G, f, src, name, ctx, options)
    options = options or {}
    local language = G.files[f].language
    if language == 'kotlin' then
        local meta = (options.record or detail(G, f, ctx)).receivers
        if meta and meta.incomplete then ctx.receiver_incomplete = true end
        local index = options.evidence and tonumber(options.evidence:match('^receiver:(%d+)$'))
        local b = index and meta and meta.bindings[index] or options.offset and M.at(meta, name, options.offset)
        if b then return from_binding(G, f, b, ctx) end
    end
    if language == 'lua' and options.tokens then
        local target, bound = require('codeoutline.analysis.lua.lua_bindings').receiver(G, options.record, options.tokens, name, options.offset, ctx.lua)
        if target then return { kind = 'lua', value = target, file = f } end
        if bound then return { kind = 'lua', value = name == 'self' and { lua_self = { members = {}, fields = {} } }
            or { owner = name, local_only = true }, file = f } end
        return nil
    elseif language == 'rust' and (name == 'Self' or name == 'self') then
        return { kind = 'rust', source = src, instance = name == 'self', file = f }
    elseif language == 'go' and options.offset then
        local value = require('codeoutline.analysis.go.go_methods').context(G, ctx).receiver(f, name, options.offset)
        if value ~= nil then return { kind = 'go', value = value, file = f } end
    elseif language == 'python' or js(language) then
        local meta = (options.record or detail(G, f, ctx)).receivers
        if meta and meta.incomplete then ctx.receiver_incomplete = true end
        local index = options.evidence and tonumber(options.evidence:match('^receiver:(%d+)$'))
        local b = index == 0 and { blocked = true } or index and meta and meta.bindings[index]
            or options.offset and M.at(meta, name, options.offset)
        if b and (index or b.blocked or b.owner or b.type or language == 'python' or name == 'this') then return from_binding(G, f, b, ctx) end
        if js(language) and (name == 'this' or name == 'super') or language == 'python' and (name == 'self' or name == 'cls') then
            return { kind = 'types', ids = {}, language = language, file = f }
        end
    elseif (language == 'java' or language == 'kotlin' or language == 'csharp' or language == 'cpp')
        and (name == 'this' or name == 'super' or name == 'base') then
        local cls = owner(G, f, src)
        if language == 'cpp' and not cls and src then cls = require('codeoutline.analysis.cpp.cpp_types').owner(G, f, G.nodes[src], ctx) end
        local ids = cls and { cls } or {}
        if src then
            local index = src - G.id_of[f][1] + 1
            local info = (detail(G, f, ctx).implementation_evidence or {})[index]
            if info and info.static or G.nodes[src].static then ids = {} end
        end
        if language == 'kotlin' and src and G.nodes[src].receiver then ids = M.types(G, f, G.nodes[src].receiver, ctx) end
        if name ~= 'this' and #ids > 0 then
            if language == 'csharp' then
                ids = require('codeoutline.analysis.csharp.csharp_bindings').base_classes(G, ids, ctx)
            else
                local node = cls and G.nodes[cls]
                local bases = node and (language == 'java' and node.extends or node.bases)
                ids = {}
                for _, base in ipairs(bases or {}) do
                    for _, id in ipairs(M.types(G, f, base, ctx, node.qualified)) do ids[#ids + 1] = id end
                end
            end
        end
        return { kind = 'types', ids = ids, language = language, file = f }
    end
end

function M.resolve(G, f, src, name, kind, recv, evidence, ctx, accept, offset)
    if not ctx then return nil end
    local language = G.files[f].language
    if language == 'go' then
        local ids, reason = require('codeoutline.analysis.go.go_methods').resolve(G, f, name, recv, evidence, ctx)
        if ids ~= nil then return ids, reason or 'receiver: Go method set' end
        return require('codeoutline.analysis.go.go_modules').resolve(G, f, name, recv, ctx)
    end
    if evidence == '?' or evidence == 'py:?' then return nil end
    if language == 'java' and recv == 'super' and evidence == 'jvm:?' then return {}, 'receiver: qualified Java super' end
    if language == 'lua' and (recv == 'self' or evidence and evidence:match('^lua%-self:')) then
        local ids = require('codeoutline.analysis.lua.lua_bindings').resolve(G, f, name, evidence, ctx.lua, recv)
        return ids or {}, 'receiver: Lua lexical binding'
    elseif language == 'rust' and (recv == 'self' or recv == 'Self' or evidence and evidence:match('^rust:path:Self::')) then
        return require('codeoutline.analysis.rust.rust_resolution').receiver_targets(G, f, src, name, recv == 'self', ctx, accept), 'receiver: Rust impl binding'
    end
    local target = recv and M.binding(G, f, src, recv, ctx, { evidence = evidence, offset = offset })
    if not target then return nil end
    if target.kind == 'types' then
        if language == 'cpp' then
            local ids = {}
            for _, id in ipairs(target.ids) do
                local found = require('codeoutline.analysis.cpp.cpp_bindings').resolve(G, f, src, name,
                    'cpp:type:::' .. G.nodes[id].qualified .. '\0' .. (offset or 0), nil, ctx, accept)
                for _, mid in ipairs(found or {}) do ids[#ids + 1] = mid end
            end
            return ids, 'receiver: C++ this binding'
        elseif language == 'csharp' then
            local cls = owner(G, f, src)
            return require('codeoutline.analysis.csharp.csharp_bindings').members(G, f, target.ids, name, false, ctx,
                cls and G.nodes[cls].qualified, recv == 'base'), 'receiver: C# instance binding'
        elseif language == 'java' or language == 'kotlin' then
            local ids = {}
            for _, id in ipairs(target.ids) do
                local found = require('codeoutline.analysis.implementations').resolve(G, f, src, name,
                    'jvm:type:' .. G.nodes[id].qualified .. '\0' .. (offset or 0), ctx)
                for _, mid in ipairs(found or {}) do ids[#ids + 1] = mid end
            end
            return ids, 'receiver: JVM binding'
        end
        return M.member_ids(G, target, name, ctx, accept), 'receiver: lexical binding'
    end
end

function M.completion(C, item)
    local source = C.fn and C.V.id_of[C.f][C.fn]
    local name = item.name
    if C.language == 'kotlin' then
        for i = 3, C.T.n do
            if C.T:text(i) == name and C.T:text(i - 1) == '@' and C.T:text(i - 2) == 'this'
                and C.T:text(i + 1) == '.' and C.T.s[i + 1] - 1 < C.offset
                and (not C.T.e[i + 2] or C.offset <= C.T.e[i + 2]) then name = 'this@' .. name; break end
        end
    end
    local target = M.binding(C.V, C.f, source, name, C.V.js_context,
        { record = C.rec, tokens = C.T, offset = C.offset })
    return target and { receiver = target }
end

function M.entries(C, target)
    local G, ctx = C.V, C.V.js_context
    if target.kind == 'lua' then
        local info = target.value.lua_self
        if not info then return C:entries(target.value) end
        local out = {}
        for name, n in pairs(info.members) do
            local node = C.rec.nodes[n]
            out[#out + 1] = { name = name, node = node, kind = node.kind, file = C.f }
        end
        for name in pairs(info.fields) do out[#out + 1] = { name = name, kind = 'field' } end
        if target.value.modules then
            for _, entry in ipairs(C:module_members(target.value.modules, target.value.module_name)) do
                if not info.members[entry.name] and not info.fields[entry.name] then out[#out + 1] = entry end
            end
        end
        return out
    end
    if target.kind == 'rust' then
        return require('codeoutline.analysis.rust.rust_resolution').receiver_members(G, C.f, target.source, target.instance, ctx,
            function() return C:expired() end)
    elseif target.kind == 'go' then
        return target.value and require('codeoutline.analysis.go.go_methods').context(G, ctx).members(target.value, C.f) or {}
    end
    if target.kind ~= 'types' then return {} end
    if not js(target.language) and target.language ~= 'python' then return C:members(target.ids) end
    local result, names = {}, {}
    for _, cls in ipairs(target.ids) do
        for _, id in ipairs(ancestors(G, cls, ctx)) do
            if C:expired() then return result end
            local f, n = G.node_file[id], id - G.id_of[G.node_file[id]][1] + 1
            local rec = G.files[f]
            local meta = detail(G, f, ctx).receivers
            for _, field in ipairs(meta and meta.fields or {}) do
                local bound = from_binding(G, f, meta.bindings[field.binding], ctx)
                if bound and bound.ids[1] == id and field_visible(target, bound) and not names[field.name] then
                    names[field.name] = true; result[#result + 1] = { name = field.name, kind = 'field' }
                end
            end
            for i, node in ipairs(rec.nodes) do
                if node.parent == n and not names[node.name] then
                    for _, mid in ipairs(M.member_ids(G, target, node.name, ctx)) do
                        result[#result + 1] = { name = node.name, node = G.nodes[mid], kind = G.nodes[mid].kind, file = G.node_file[mid] }
                    end
                    names[node.name] = true
                end
            end
        end
    end
    return result
end

return M
