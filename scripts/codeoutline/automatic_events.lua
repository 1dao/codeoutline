-- Possible Node EventEmitter deliveries, proven to share one local object.
-- No global event-name matching, execution-order inference or resident graph.
local M = { MAX_FILES = 128, MAX_SITES = 512, MAX_TARGETS = 64 }
local control = require('codeoutline.control')
local registrations = { on = true, once = true, addListener = true }
local function supported(rec) return rec.language == 'javascript' or rec.language == 'typescript' end
local function node_events(rec)
    for _, imp in ipairs(rec.js_imports or {}) do if imp.path == 'events' or imp.path == 'node:events' then return true end end
    return false
end

function M.candidate(rec)
    if not supported(rec) or not node_events(rec) then return false end
    for _, call in ipairs(rec.dispatch_calls or {}) do
        if call:match('^[%w_$]+%.emit$') then return true end
    end
    return false
end

local function literal(T, i)
    local s = T:text(i)
    if T.k[i] == 'str' and (s:sub(1, 1) == '"' or s:sub(1, 1) == "'")
        and s:sub(-1) == s:sub(1, 1) and not s:find('[\\$]') then return s:sub(2, -2) end
end

local function statement_end(T, close)
    if not close then return false end
    local ending = T:text(close + 1)
    return ending == ';' or ending == '}' or ending == ''
        or T.l[close + 1] > T.l[close] and (T.k[close + 1] == 'id' or T.k[close + 1] == 'kw')
            and ending ~= 'as' and ending ~= 'satisfies' and ending ~= 'in' and ending ~= 'instanceof'
end

local function statement_start(T, i)
    local previous = T:text(i - 1)
    return previous == '' or previous == ';' or previous == '{' or previous == '}'
        or i > 1 and T.l[i] > T.l[i - 1] and (T.k[i - 1] == 'id' or T.k[i - 1] == 'str'
            or T.k[i - 1] == 'num' or previous == ')' or previous == ']')
end

function M.collect(r, T)
    if not supported(r) or not node_events(r) then return end
    local has_emit = false
    for _, ref in ipairs(r.refs) do if ref.name == 'emit' and ref.recv then has_emit = true; break end end
    if not has_emit then return end
    local expand, binding = require('codeoutline.dispatch_aliases').prepare(r, T)
    -- Unrepresented anonymous function scopes cannot safely share outer locals.
    -- Named handlers and variable-bound arrow functions have parser nodes.
    local headers = {}
    for _, n in ipairs(r.nodes) do
        if n.kind == 'function' or n.kind == 'method' or n.kind == 'constructor' then
            for i = n.ti, n.tj do
                local s = T:text(i)
                if s == 'function' or s == '=>' then headers[i] = true end
                if s == '{' then break end
            end
        end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if (T:text(i) == '=>' or T:text(i) == 'function') and not headers[i] then return end
    end
    local objects, by_token, type_names = {}, {}, {}
    for _, n in ipairs(r.nodes) do
        if n.kind == 'class' or n.kind == 'interface' or n.kind == 'namespace' or n.kind == 'enum' or n.kind == 'type' then type_names[n.name] = true end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T:text(i - 1) == 'const' and T:text(i - 2) ~= 'export' and T.k[i] == 'id' and T:text(i + 1) == '=' and T:text(i + 2) == 'new' then
            local a, last = i + 3, i + 3
            if T:text(last + 1) == '.' and T.k[last + 2] == 'id' then last = last + 2 end
            local open = last + 1
            local factory = T.k[a] == 'id' and expand({ symbol = T.src:sub(T.s[a], T.e[last]):gsub('%s+', '') }, a)
            local token = binding(T:text(i), i)
            if token == i and not type_names[T:text(a)] and T:text(open) == '(' and T.m[open] == open + 1
                and statement_end(T, T.m[open])
                and factory and factory.import and (factory.import.path == 'events' or factory.import.path == 'node:events')
                and (factory.member == 'EventEmitter' or factory.member == 'default') then
                local object = { token = i, name = T:text(i), registrations = {}, emissions = {} }
                objects[#objects + 1], by_token[i] = object, object
            end
        end
    end
    if #objects == 0 then return end
    local refs = {}; for _, ref in ipairs(r.refs) do refs[ref.tok] = ref end
    local count = 0
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'id' then
            local object = by_token[binding(T:text(i), i)]
            if object and i ~= object.token then
                local method, ref = T:text(i + 2), refs[i + 2]
                local previous = T:text(i - 1)
                if not statement_start(T, i) or T:text(i + 1) ~= '.' or previous == '.' or previous == '?.' or not ref
                    or T:text(i + 3) ~= '(' or not (registrations[method] or method == 'emit') then object.invalid = true
                else
                    local close, event = T.m[i + 3], literal(T, i + 4)
                    count = count + 1
                    if count > M.MAX_SITES then r.automatic_events = { incomplete = true }; return end
                    if not statement_end(T, close) or not event or (T:text(i + 5) ~= ',' and i + 5 ~= close) then object.invalid = true
                    elseif registrations[method] then
                        local a, b = i + 6, close - 1
                        local text = T.src:sub(T.s[a] or 1, T.e[b] or 0):gsub('%s+', '')
                        local handler = text:match('^[%a_$][%w_$.]*$') and not type_names[text:match('^[%w_$]+')]
                            and expand({ symbol = text }, a)
                        if handler and (handler.node or handler.import) then
                            object.registrations[#object.registrations + 1] = { event = event, handler = handler,
                                from = ref.from, line = ref.line, token = i }
                        end
                    else object.emissions[#object.emissions + 1] = { event = event, from = ref.from, line = ref.line, token = i } end
                end
            end
        end
    end
    local result = {}
    for _, object in ipairs(objects) do
        if not object.invalid then
            for _, site in ipairs(object.emissions) do
                if site.from > 0 then
                    for _, registration in ipairs(object.registrations) do
                        if site.event == registration.event and (registration.from == 0 or registration.from == site.from
                            and registration.token < site.token) then
                            result[#result + 1] = { from = site.from, line = site.line, handler = registration.handler,
                                registered_at = registration.line, event = site.event, recv = object.name }
                            if #result >= M.MAX_SITES then result.incomplete = true; r.automatic_events = result; return end
                        end
                    end
                end
            end
        end
    end
    r.automatic_events = result
end

function M.context(G, ctx, report)
    local C = { incomplete = false, stats = { files = 0, sites = 0, links = 0 } }
    local shared = require('codeoutline.shared_events').context(G, ctx, report)
    C.stats.shared = shared.stats
    local cache, js = {}, require('codeoutline.js_resolution')
    local function data(f)
        if cache[f] then return cache[f] end
        if not M.candidate(G.files[f]) then return {} end
        if C.stats.files >= M.MAX_FILES then C.incomplete = true; return {} end
        C.stats.files = C.stats.files + 1
        local evidence = ctx.ordinary.data(f).automatic_events or {}
        if evidence.incomplete then C.incomplete = true end
        local result = {}
        for _, site in ipairs(evidence) do
            control.check(); C.stats.sites = C.stats.sites + 1
            local ids = site.handler.node and { G.id_of[f][site.handler.node] }
                or js.imported(G, f, site.handler.import.path, site.handler.member, ctx)
            if ctx.workspace_incomplete then C.incomplete = true end
            if #ids == 1 then
                local id, n = ids[1], G.nodes[ids[1]]
                if n.kind == 'function' or n.kind == 'method' then result[#result + 1] = { source = G.id_of[f][site.from],
                    target = id, line = site.line, kind = 'automatic:event', site = site } end
            end
        end
        cache[f] = result; return result
    end
    local function scan(f, only, wanted, out)
        local count, seen = 0, {}
        for _, edge in ipairs(data(f)) do
            if (not only or edge.source == only) and (not wanted or wanted[edge.target]) then
                local key = edge.source .. ':' .. edge.target .. ':' .. edge.line
                if not seen[key] then
                    if count >= M.MAX_TARGETS then C.incomplete = true; break end
                    seen[key], count = true, count + 1; C.stats.links = C.stats.links + 1
                    out[edge.source] = out[edge.source] or {}; out[edge.source][#out[edge.source] + 1] = edge
                    if report then report:add({ source = edge.source, target = edge.target, line = edge.line,
                        call = edge.site.recv .. '.emit', kind = 'possible event delivery (same local Node EventEmitter and literal event)',
                        registered_at = G.files[f].path .. ':' .. edge.site.registered_at }) end
                end
            end
        end
    end
    function C.outgoing(id)
        local out = {}; scan(G.node_file[id], id, nil, out)
        out[id] = out[id] or {}
        for _, edge in ipairs(shared.outgoing(id)) do out[id][#out[id] + 1] = edge end
        C.incomplete = C.incomplete or shared.incomplete
        return out[id]
    end
    function C.incoming(wanted)
        local out, relevant = {}, false
        for id in pairs(wanted) do if supported(G.files[G.node_file[id]]) then relevant = true; break end end
        if not relevant then return out end
        -- Same-file objects can only register local handlers or imported exports.
        -- Reuse the ordinary binding import closure instead of opening every emitter.
        local candidates = ctx.ordinary.candidates(wanted)
        for _, f in ipairs(G.file_order) do control.check(); if candidates[f] then scan(f, nil, wanted, out) end end
        for source, edges in pairs(shared.incoming(wanted)) do
            out[source] = out[source] or {}
            for _, edge in ipairs(edges) do out[source][#out[source] + 1] = edge end
        end
        C.incomplete = C.incomplete or shared.incomplete
        return out
    end
    return C
end

return M
