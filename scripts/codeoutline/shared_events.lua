-- Query-owned ES module EventEmitter identities. Indexing keeps only role bits.
local M = { MAX_FILES = 32, MAX_BYTES = 2097152, MAX_FILE_BYTES = 262144,
    MAX_SITES = 512, MAX_TARGETS = 64, MAX_DEPTH = 8, MAX_MS = 200 }
local control = require('codeoutline.control')
local methods = { emit = 1, on = 2, once = 2, addListener = 2,
    off = 4, removeListener = 4, removeAllListeners = 4 }
local function supported(r) return r.language == 'javascript' or r.language == 'typescript' end
local function builtin(path) return path == 'events' or path == 'node:events' end

function M.roles(r, calls)
    if not supported(r) then return 0 end
    local found = {}
    for name in pairs(calls) do
        local role = methods[name:match('%.([%w_$]+)$')]
        if role then found[role] = true end
    end
    for _, imp in ipairs(r.js_imports or {}) do if builtin(imp.path) then found[8] = true end end
    return (found[1] and 1 or 0) + (found[2] and 2 or 0) + (found[4] and 4 or 0) + (found[8] and 8 or 0)
end

local function has(r, role)
    if not supported(r) then return false end
    local roles = r.event_roles
    if roles == nil then
        local calls = {}; for _, name in ipairs(r.dispatch_calls or {}) do calls[name] = true end
        roles = M.roles(r, calls)
    end
    if role == 7 then return roles % 8 ~= 0 end
    return math.floor(roles / role) % 2 == 1
end

local function literal(T, i)
    local s = T:text(i)
    if T.k[i] == 'str' and (s:sub(1, 1) == '"' or s:sub(1, 1) == "'")
        and s:sub(-1) == s:sub(1, 1) and not s:find('[\\$]') then return s:sub(2, -2) end
end
local function ending(T, i)
    return T:text(i + 1) == ';' or T:text(i + 1) == '' or T:text(i + 1) == '}'
        or T.l[i + 1] and T.l[i + 1] > T.l[i] and T.k[i + 1] ~= 'op'
end

function M.collect(r, T)
    if not supported(r) or not r.js_imports or #r.js_imports == 0 then return end
    local candidate, imported = false, {}
    for _, imp in ipairs(r.js_imports) do
        imported[imp.local_name] = true
        if builtin(imp.path) then candidate = true end
    end
    if not candidate then
        for _, ref in ipairs(r.refs) do if ref.recv and methods[ref.name] then candidate = true; break end end
        for _, export in ipairs(r.js_exports or {}) do
            if not export.path and imported[export.local_name] then candidate = true; break end
        end
    end
    if not candidate then return end
    local expand, binding = require('codeoutline.dispatch_aliases').prepare(r, T)
    local result = { objects = {}, exports = {}, entities = {}, sites = {}, weight = 0 }
    r.shared_events = result
    local headers, classes, skip, objects, refs, variables = {}, {}, {}, {}, {}, {}
    for id, n in ipairs(r.nodes) do
        if not n.parent and n.kind == 'variable' then variables[n.name] = id end
        if n.kind == 'class' or n.kind == 'interface' then classes[n.name] = true end
        if n.kind == 'function' or n.kind == 'method' or n.kind == 'constructor' then
            for i = n.ti, n.tj do
                if T:text(i) == 'function' or T:text(i) == '=>' then headers[i] = true end
                if T:text(i) == '{' then break end
            end
        end
    end
    for _, ref in ipairs(r.refs) do refs[ref.tok] = ref end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        local word = T:text(i)
        if (word == 'function' or word == '=>') and not headers[i] then result.unsupported = true; return end
        if word == 'import' and T:text(i + 1) ~= '(' or word == 'export' and T:text(i + 1) == '{' then
            local j = i + 1
            while j <= T.n do
                skip[j] = true
                if T.m[j] and T.m[j] > j then
                    for x = j, T.m[j] do skip[x] = true end
                    j = T.m[j]
                end
                if T:text(j) == ';' or T.k[j] == 'str' or T:text(j) == '}' or j > i + 1 and (T.l[j + 1] or math.huge) > T.l[j] then break end
                j = j + 1
            end
        elseif word == 'export' and T:text(i + 1) == 'default' and T.k[i + 2] == 'id' then skip[i + 2] = true end
        if T:text(i - 1) == 'const' and T.k[i] == 'id' and T:text(i + 1) == '='
            and T:text(i + 2) == 'new' and T.k[i + 3] == 'id' then
            local last = i + 3
            if T:text(last + 1) == '.' and T.k[last + 2] == 'id' then last = last + 2 end
            local open = last + 1
            local factory = expand({ symbol = T.src:sub(T.s[i + 3], T.e[last]):gsub('%s+', '') }, i + 3)
            local token, scope = binding(T:text(i), i)
            if token == i and scope == 0 and not classes[T:text(i + 3)] and factory and factory.import
                and builtin(factory.import.path) and (factory.member == 'EventEmitter' or factory.member == 'default')
                and T:text(open) == '(' and T.m[open] == open + 1 and ending(T, T.m[open]) then
                local object = { name = T:text(i), token = i }
                object.node = variables[object.name]
                if object.node then objects[i] = object end
            end
        end
    end
    local entities = {}
    local function entity(name, at)
        local token = binding(name, at)
        local object = token and objects[token]
        local value = not object and expand({ symbol = name }, at)
        local key, descriptor
        if object then key, descriptor = 'local:' .. token, { object = object.name }
        elseif value and value.import and not builtin(value.import.path) and value.member:match('^[%w_$]+$') then
            key, descriptor = value.import.path .. '\0' .. value.member, { path = value.import.path, member = value.member }
        else return end
        if not entities[key] then
            if #result.entities >= M.MAX_SITES then result.incomplete = true; return end
            descriptor.name = name; result.entities[#result.entities + 1] = descriptor
            entities[key] = descriptor; result.weight = result.weight + 256
        end
        return entities[key]
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if not skip[i] and T.k[i] == 'id' and T:text(i - 1) ~= '.' and T:text(i - 1) ~= '?.'
            and T:text(i - 1) ~= 'const' and not objects[i] then
            local e = entity(T:text(i), i)
            if e then
                local method, ref, open = T:text(i + 2), refs[i + 2], i + 3
                local before = T:text(i - 1)
                local start = before == '' or before == ';' or before == '{' or before == '}'
                    or T.l[i] > T.l[i - 1] and T.k[i - 1] ~= 'op'
                -- Simple local aliases of an imported binding reuse lexical validation.
                local alias = e.path and before == '=' and T:text(i - 3) == 'const' and ending(T, i)
                if alias then
                elseif not start or T:text(i + 1) ~= '.' or not ref or T:text(open) ~= '('
                    or not T.m[open] or not ending(T, T.m[open]) or not methods[method] or methods[method] == 4 then e.invalid = true
                else
                    local close, event = T.m[open], literal(T, open + 1)
                    local handler
                    if methods[method] == 2 and T:text(open + 2) == ',' then
                        local text = T.src:sub(T.s[open + 3] or 1, T.e[close - 1] or 0):gsub('%s+', '')
                        handler = text:match('^[%a_$][%w_$.]*$') and not classes[text:match('^[%w_$]+')]
                            and expand({ symbol = text }, open + 3)
                        if not handler or not (handler.node or handler.import) or ref.from ~= 0 then e.invalid = true end
                    end
                    if not event or T:text(open + 2) ~= ',' and open + 2 ~= close then e.invalid = true end
                    if not e.invalid and (method == 'emit' or handler) then
                        if #result.sites >= M.MAX_SITES then result.incomplete = true; break end
                        result.sites[#result.sites + 1] = { entity = e, event = event, method = method, handler = handler,
                            from = ref.from, line = ref.line, first = T.s[open + 1] - 1, last = T.e[open + 1] }
                        result.weight = result.weight + 512
                    end
                end
            end
        end
    end
    for token, object in pairs(objects) do
        local e = entity(object.name, T.n)
        if e and not e.invalid then result.objects[object.name] = object end
    end
    for _, export in ipairs(r.js_exports or {}) do
        if not export.path and export.local_name then
            local e = entity(export.local_name, T.n)
            result.exports[export.local_name] = e
            if e and e.object and result.objects[e.object] then result.objects[e.object].exported = true end
        end
    end
end

function M.context(G, ctx, report)
    if ctx.shared_event_context then return ctx.shared_event_context end
    local reasons = {}
    local C = { incomplete = false, stats = { files = 0, bytes = 0, sites = 0, links = 0, identities = 0,
        incomplete_reasons = reasons } }
    local function incomplete(reason) C.incomplete = true; reasons[reason] = true end
    ctx.shared_event_context = C
    local js = require('codeoutline.js_resolution')
    local cache, identities, buses, started = {}, {}, {}, nil
    local all_files, emitting = nil, {}
    local function files()
        if not all_files then
            all_files = {}; local seen = {}
            for _, list in ipairs({ G.file_order, G.new_files or {} }) do for _, f in ipairs(list) do
                if not seen[f] then seen[f] = true; all_files[#all_files + 1] = f end
            end end
            table.sort(all_files, function(a,b) return G.files[a].path < G.files[b].path end)
        end
        return all_files
    end
    local function emits(f)
        if not emitting[f] then
            local found, refs = {}, G.files[f].refs
            for i, name in ipairs(refs.name) do
                if i % 128 == 0 then control.check() end
                if name == 'emit' and refs.recv[i] and refs.from[i] > 0 then
                    found[G.id_of[f][refs.from[i]]] = true
                end
            end
            emitting[f] = found
        end
        return emitting[f]
    end
    local function allowed()
        control.check(); started = started or xtimer.now_ms()
        if xtimer.now_ms() - started > M.MAX_MS then incomplete('time_limit'); return false end
        return true
    end
    local function data(f)
        if cache[f] ~= nil then return cache[f] or nil end
        local rec = G.files[f]
        if not supported(rec) or not allowed() then return end
        local size = ctx.ordinary.source_size(f) or 0
        if C.stats.files >= M.MAX_FILES then incomplete('file_limit'); return end
        if size > M.MAX_FILE_BYTES then incomplete('file_size_limit'); return end
        if C.stats.bytes + size > M.MAX_BYTES then incomplete('source_byte_limit'); return end
        C.stats.files, C.stats.bytes = C.stats.files + 1, C.stats.bytes + size
        local d = ctx.ordinary.data(f).shared_events
        if d and d.unsupported then incomplete('unsupported_syntax'); d = nil end
        if d and d.incomplete then incomplete('site_limit'); d = nil end
        if d and C.stats.sites + #d.sites + #d.entities > M.MAX_SITES then incomplete('site_limit'); d = nil end
        if d then C.stats.sites = C.stats.sites + #d.sites + #d.entities end
        cache[f] = d or false; return d
    end
    local identity, descriptor
    descriptor = function(f, e, seen, depth)
        if not e or e.invalid or not allowed() then return end
        if e.object then
            local d = data(f); local object = d and d.objects[e.object]
            if object and object.exported then return { key = f .. '\0' .. object.node, file = f, node = G.id_of[f][object.node] } end
        elseif e.path then
            local target = js.module(G, f, e.path, ctx)
            if target then return identity(target, e.member, seen, depth + 1) end
        end
    end
    identity = function(f, name, seen, depth)
        if depth > M.MAX_DEPTH then incomplete('depth_limit'); return end
        if not allowed() then return end
        local key = f .. '\0' .. name
        if identities[key] ~= nil then return identities[key] or nil end
        if seen[key] then incomplete('cyclic_export'); return end
        seen[key] = true; C.stats.identities = C.stats.identities + 1
        local entries, explicit, found, ambiguous = G.files[f].js_exports or {}, false, nil, false
        for _, e in ipairs(entries) do if e.name == name then explicit = true end end
        for _, e in ipairs(entries) do
            if e.name == name or not explicit and e.name == '*' and name ~= 'default' then
                local value, want = nil, e.local_name == '*' and name or e.local_name
                if e.path then
                    local target = js.module(G, f, e.path, ctx)
                    if target then value = identity(target, want, seen, depth + 1) end
                else
                    local d = data(f)
                    value = d and descriptor(f, d.exports[want], seen, depth)
                end
                if value then
                    if found and found.key ~= value.key then ambiguous = true else found = value end
                end
            end
        end
        seen[key] = nil
        if ambiguous then incomplete('ambiguous_binding'); found = nil end
        identities[key] = found or false; return found
    end
    local function handler(f, value)
        if value.node then return { G.id_of[f][value.node] } end
        return js.imported(G, f, value.import.path, value.member, ctx)
    end
    local function load_bus(owner)
        if buses[owner.key] then return buses[owner.key] end
        local out, emits, registrations, invalid = {}, {}, {}, false
        buses[owner.key] = out
        local related = ctx.ordinary.candidates({ [owner.node] = true })
        for _, f in ipairs(files()) do
            if related[f] and has(G.files[f], 7) then
                if not allowed() then return {} end
                local d = data(f)
                if d then
                    local selected = {}
                    for _, e in ipairs(d.entities) do
                        -- Resolve identity even for poisoned uses, so remove/escape
                        -- in one consumer invalidates this bus's whole result.
                        local copy = {}; for k, v in pairs(e) do if k ~= 'invalid' then copy[k] = v end end
                        local value = descriptor(f, copy, {}, 0)
                        if value and value.key == owner.key then selected[e] = true; invalid = invalid or e.invalid end
                    end
                    for _, site in ipairs(d.sites) do if selected[site.entity] then
                        local value = { file = f, site = site }
                        if site.method == 'emit' and site.from > 0 then emits[#emits + 1] = value
                        elseif site.method ~= 'emit' then registrations[#registrations + 1] = value end
                    end end
                end
            end
        end
        if C.incomplete or invalid then return out end
        local seen = {}
        for _, emit in ipairs(emits) do for _, reg in ipairs(registrations) do
            if emit.file ~= reg.file and emit.site.event == reg.site.event then
                local ids = handler(reg.file, reg.site.handler)
                if #ids == 1 and (G.nodes[ids[1]].kind == 'function' or G.nodes[ids[1]].kind == 'method') then
                    local source = G.id_of[emit.file][emit.site.from]
                    local key = source .. ':' .. ids[1] .. ':' .. emit.site.line
                    if not seen[key] then
                        if C.stats.links >= M.MAX_TARGETS then incomplete('target_limit'); buses[owner.key] = {}; return {} end
                        seen[key] = true; C.stats.links = C.stats.links + 1
                        out[#out + 1] = { source = source, target = ids[1], line = emit.site.line,
                            kind = 'automatic:event', site = emit.site, registered_at = G.files[reg.file].path .. ':' .. reg.site.line }
                    end
                end
            end
        end end
        return out
    end
    local function edges_for(f, site)
        local owner = descriptor(f, site.entity, {}, 0)
        return owner and load_bus(owner) or {}
    end
    local function publish(edge)
        if report then report:add({ source = edge.source, target = edge.target, line = edge.line,
            call = edge.site.entity.name .. '.emit', kind = 'possible event delivery (shared imported Node EventEmitter and literal event)',
            registered_at = edge.registered_at }) end
    end
    function C.outgoing(id)
        local f, out, seen = G.node_file[id], {}, {}
        if not has(G.files[f], 1) or not emits(f)[id] then return out end
        local d = data(f)
        for _, site in ipairs(d and d.sites or {}) do
            if site.method == 'emit' and G.id_of[f][site.from] == id then
                for _, edge in ipairs(edges_for(f, site)) do
                    if edge.source == id and edge.site == site and not seen[edge] then seen[edge] = true; out[#out + 1] = edge; publish(edge) end
                end
            end
        end
        return out
    end
    function C.incoming(wanted)
        local related, out, seen = ctx.ordinary.candidates(wanted), {}, {}
        for _, f in ipairs(files()) do if related[f] and has(G.files[f], 2) then
            local d = data(f)
            for _, site in ipairs(d and d.sites or {}) do if site.handler then
                local ids, relevant = handler(f, site.handler), false
                for _, id in ipairs(ids) do if wanted[id] then relevant = true end end
                if relevant then for _, edge in ipairs(edges_for(f, site)) do
                    if wanted[edge.target] and not seen[edge] then
                        seen[edge] = true; out[edge.source] = out[edge.source] or {}; out[edge.source][#out[edge.source] + 1] = edge; publish(edge)
                    end
                end end
            end end
        end end
        return out
    end
    function C.definition(f, offset, line)
        if not has(G.files[f], 1) then return {} end
        if line then
            local found, refs = false, G.files[f].refs
            for i, name in ipairs(refs.name) do if name == 'emit' and refs.line[i] == line then found = true; break end end
            if not found then return {} end
        end
        local d, out, seen, recognized = data(f), {}, {}, false
        for _, site in ipairs(d and d.sites or {}) do
            if site.method == 'emit' and site.first <= offset and offset < site.last and site.from > 0 then
                recognized = true
                for _, edge in ipairs(C.outgoing(G.id_of[f][site.from])) do
                    if edge.site == site and not seen[edge.target] then seen[edge.target] = true; out[#out + 1] = edge.target end
                end
            end
        end
        return out, recognized
    end
    return C
end

return M
