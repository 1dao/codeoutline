-- Query-only Go framework relationships. Registrations and generated bridges
-- are possibilities, never ordinary calls or persistent semantic records.
local M = { MAX_FILES = 64, MAX_BYTES = 8388608, MAX_SITES = 256, MAX_LINKS = 512,
    MAX_CANDIDATES = 512, MAX_SCANNED_FILES = 4096, MAX_TIME_MS = 1500 }
local control = require('codeoutline.control')
local verbs = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
    OPTIONS = true, HEAD = true, Get = true, Post = true, Put = true, Patch = true, Delete = true }
local function framework(path)
    if path == 'net/http' then return 'http' end
    if path == 'github.com/gin-gonic/gin' then return 'gin' end
    if path:match('^github%.com/labstack/echo') then return 'echo' end
    if path:match('^github%.com/gofiber/fiber') then return 'fiber' end
    if path:match('^github%.com/go%-chi/chi') then return 'chi' end
end
local function literal(T, i)
    if T.k[i] ~= 'str' then return nil end
    local raw = T:text(i)
    if raw:sub(1, 1) == '`' then return raw:sub(2, -2) end
    if raw:sub(1, 1) ~= '"' or raw:find('\\', 1, true) then return nil end
    return raw:sub(2, -2)
end
local function parts(T, a, b)
    local out, start, i = {}, a, a
    while i <= b + 1 do
        if i == b + 1 or T:text(i) == ',' then
            if start < i then out[#out + 1] = { start, i - 1 } end
            start = i + 1
        elseif T.m[i] and T.m[i] > i then i = T.m[i] end
        i = i + 1
    end
    return out
end

function M.collect(r, T)
    if r.language ~= 'go' then return end
    local D = { sites = {}, dispatchers = {}, assertions = {}, weight = 0, source_bytes = #T.src }
    r.go_frameworks = D
    local aliases = {}
    for _, imp in ipairs(r.imports) do
        local fw = framework(imp.path)
        if fw then aliases[imp.alias or (fw == 'http' and 'http' or fw)] = fw end
    end
    local scopes, stack = {}, {}
    for i = 1, T.n do
        if i % 1024 == 0 then control.check() end
        scopes[i] = stack[#stack] or 0
        if T:text(i) == '{' and T.m[i] then stack[#stack + 1] = i
        elseif T:text(i) == '}' and stack[#stack] and T.m[stack[#stack]] == i then stack[#stack] = nil end
    end
    local function visible(router, at)
        if not router or router.token >= at then return false end
        local scope = scopes[at]
        while scope and scope ~= router.scope and scope ~= 0 do scope = scopes[scope] end
        return scope == router.scope
    end
    local function add(list, entry)
        if #list >= M.MAX_SITES then D.incomplete = true; return end
        list[#list + 1] = entry; D.weight = D.weight + 512 + #(entry.route or '')
    end
    for id, n in ipairs(r.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local routers, invalid = {}, {}
            -- Receiver identities are deliberately local to one declaration.
            -- Reassignments/shadows disable this cheap constructor evidence.
            for i = n.ti, n.tj do
                if i % 1024 == 0 then control.check() end
                if T.k[i] == 'id' and (T:text(i + 1) == ':=' or T:text(i + 1) == '=') then
                    local name, root, method = T:text(i), T:text(i + 2), T:text(i + 4)
                    if routers[name] then invalid[name] = true end
                    if T:text(i + 3) == '.' and T:text(i + 5) == '(' then
                        local fw = aliases[root]
                        if fw and (method == 'New' or method == 'Default' or method == 'NewRouter' or method == 'NewServeMux') then
                            routers[name] = { framework = fw, prefix = '', token = i, scope = scopes[i], alias = root, at = T.s[i + 2] - 1 }
                        elseif not invalid[root] and visible(routers[root], i) and method == 'Group' then
                            local prefix = literal(T, i + 6)
                            if prefix then routers[name] = { framework = routers[root].framework,
                                prefix = routers[root].prefix .. prefix, token = i, scope = scopes[i],
                                alias = routers[root].alias, at = routers[root].at } end
                        end
                    end
                end
            end
            local dispatcher = false
            for i = n.ti, n.tj do
                if i % 1024 == 0 then control.check() end
                local root, method = T:text(i), T:text(i + 2)
                local router = not invalid[root] and routers[root]
                if not visible(router, i) then router = nil end
                local fw = router and router.framework or aliases[root] == 'http' and 'http'
                if T.k[i] == 'id' and T:text(i + 1) == '.' and T:text(i + 3) == '(' and T.m[i + 3] and fw then
                    local args = parts(T, i + 4, T.m[i + 3] - 1)
                    local use = fw == 'gin' and method == 'Use'
                    local group = fw == 'gin' and method == 'Group'
                    local path = args[1] and args[1][1] == args[1][2] and literal(T, args[1][1])
                    local verb = verbs[method] and method:upper() or (method == 'Handle' or method == 'HandleFunc') and 'ANY'
                    if path and verb and fw == 'http' and verb == 'ANY' then
                        local v, p = path:match('^(%u+)%s+(/.*)$')
                        if v and ({ GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
                            HEAD = true, OPTIONS = true, CONNECT = true, TRACE = true })[v] then verb, path = v, p end
                    end
                    if use or (verb or group) and path and path:sub(1, 1) == '/' then
                        for a = use and 1 or 2, #args do
                            local first, last = args[a][1], args[a][2]
                            local name, recv
                            if first == last and T.k[first] == 'id' then name = T:text(first)
                            elseif last == first + 2 and T.k[first] == 'id' and T:text(first + 1) == '.' and T.k[last] == 'id' then
                                name, recv = T:text(last), T:text(first)
                            end
                            if name then add(D.sites, { from = id, name = name, recv = recv, at = T.s[first] - 1,
                                line = T:line(i), framework = fw, route = not (use or group) and (verb .. ' ' .. (router and router.prefix or '') .. path),
                                alias = router and router.alias or root, alias_at = router and router.at or T.s[i] - 1,
                                kind = (use or group) and 'middleware' or 'route' }) end
                        end
                    end
                end
                if n.name == 'Next' and n.recv == 'Context' and T:text(i) == 'handlers'
                    and T:text(i + 1) == '[' and T.m[i + 1] and T:text(T.m[i + 1] + 1) == '(' then dispatcher = true end
                -- protoc server handlers assert the registered server interface.
                if r.path:match('_grpc%.pb%.go$') and T:text(i) == '.' and T:text(i + 1) == '(' and T.m[i + 1] then
                    local close = T.m[i + 1]
                    if close == i + 3 and T.k[i + 2] == 'id' and T:text(close + 1) == '.'
                        and T.k[close + 2] == 'id' and T:text(close + 3) == '(' then
                        add(D.assertions, { from = id, type = T:text(i + 2), name = T:text(close + 2), line = T:line(i) })
                    end
                end
            end
            if dispatcher and r.package == 'gin' then D.dispatchers[id] = true; D.weight = D.weight + 32 end
        end
    end
end

function M.context(G, ctx, report)
    local C = { incomplete = false, stats = { files = 0, bytes = 0, links = 0 } }
    local cache, outgoing = {}, {}
    local methods, deadline
    local function expired()
        control.check()
        deadline = deadline or xtimer.now_ms() + M.MAX_TIME_MS
        if xtimer.now_ms() > deadline then C.incomplete = true; return true end
        return false
    end
    local modules = require('codeoutline.go_modules')
    local function data(f)
        if cache[f] then return cache[f] end
        local rec = G.files[f]
        if rec.language ~= 'go' then return nil end
        local size = ctx.ordinary.source_size(f) or rec.go_frameworks and rec.go_frameworks.source_bytes or 0
        if expired() or C.stats.files >= M.MAX_FILES or C.stats.bytes + size > M.MAX_BYTES then C.incomplete = true; return nil end
        C.stats.files, C.stats.bytes = C.stats.files + 1, C.stats.bytes + size
        local d = ctx.ordinary.data(f).go_frameworks or { sites = {}, dispatchers = {}, assertions = {} }
        if size == 0 and d.source_bytes then
            if C.stats.bytes + d.source_bytes > M.MAX_BYTES then C.incomplete = true; return nil end
            C.stats.bytes = C.stats.bytes + d.source_bytes
        end
        cache[f] = d
        if d.incomplete then C.incomplete = true end
        return d
    end
    local function relevant(rec)
        if rec.language ~= 'go' then return false end
        if rec.package == 'gin' or rec.path:match('_grpc%.pb%.go$') then return true end
        for _, imp in ipairs(rec.imports) do if framework(imp.path) then return true end end
        for _, n in ipairs(rec.nodes) do if n.embedded and n.name:match('^Unimplemented.+Server$') then return true end end
        return false
    end
    local function target(f, site)
        if methods.bound(f, site.alias, site.alias_at) ~= nil then return {} end
        if site.recv then
            local receiver = methods.receiver(f, site.recv, site.at)
            if receiver then
                local out = {}; for _, m in ipairs(methods.members(receiver, f, site.name)) do
                    if m.kind == 'method' then out[#out + 1] = m.id end
                end
                return out
            end
            if receiver == false then return {} end
        elseif methods.bound(f, site.name, site.at) ~= nil then return {} end
        local out = {}
        for _, id in ipairs(modules.resolve(G, f, site.name, site.recv, ctx) or {}) do
            if G.nodes[id].kind == 'function' then out[#out + 1] = id end
        end
        return out
    end
    local function emit(out, source, dst, line, kind, registration)
        if source == dst then return end
        local label = 'possible:go-' .. kind
        for _, e in ipairs(out) do if e.target == dst and e.line == line and e.kind == label then return end end
        if C.stats.links >= M.MAX_LINKS then C.incomplete = true; return end
        C.stats.links = C.stats.links + 1
        out[#out + 1] = { target = dst, line = line, kind = label }
        if report then report:add({ source = source, target = dst, line = line,
            kind = 'possible Go ' .. kind .. ' (framework evidence; runtime execution unverified)', registered_at = registration }) end
    end
    local function signature(f, index)
        local d = methods.data(f)
        local sig = d and d.nodes[index] and d.nodes[index].signature
        if not sig then return nil end
        local aliases = modules.aliases(G, f, ctx)
        local function key(t)
            if not t then return nil end
            if t.kind == 'name' then
                local ids = methods.types(f, t.name)
                if #ids == 1 then return 'type:' .. ids[1] end
                local pkg, name = t.name:match('^([^.]+)%.(.+)$')
                if pkg then return aliases[pkg] and aliases[pkg].path .. '.' .. name end
                if ({ bool = true, byte = true, rune = true, string = true, error = true, any = true,
                    int = true, int8 = true, int16 = true, int32 = true, int64 = true, uint = true,
                    uint8 = true, uint16 = true, uint32 = true, uint64 = true, uintptr = true,
                    float32 = true, float64 = true, complex64 = true, complex128 = true })[t.name] then return t.name end
                return nil
            end
            if t.kind == 'any' then return 'any' end
            if t.kind == 'map' or t.kind == 'function' then return nil end
            local child = key(t.child)
            return child and t.kind .. ':' .. tostring(t.extra or '') .. ':' .. child or nil
        end
        local groups = {}
        for _, list in ipairs({ sig.params, sig.results }) do
            local items = {}; for _, t in ipairs(list) do local k = key(t); if not k then return nil end; items[#items + 1] = k end
            groups[#groups + 1] = table.concat(items, ',')
        end
        return table.concat(groups, ' -> ')
    end
    function C.outgoing(id)
        if outgoing[id] then return outgoing[id] end
        local f, node, out = G.node_file[id], G.nodes[id], {}
        outgoing[id] = out
        if not relevant(G.files[f]) then return out end
        methods = methods or require('codeoutline.go_methods').context(G, ctx)
        local d = data(f); if not d then return out end
        for _, site in ipairs(d.sites) do
            if G.id_of[f][site.from] == id then
                for _, dst in ipairs(target(f, site)) do emit(out, id, dst, site.line, site.route and ('route ' .. site.route) or 'middleware', G.files[f].path .. ':' .. site.line) end
            end
        end
        for _, site in ipairs(d.assertions) do
            if G.id_of[f][site.from] == id then
                for _, ty in ipairs(methods.types(f, site.type)) do
                    for _, m in ipairs(methods.members({ id = ty, pointer = false }, f, site.name)) do
                        emit(out, id, m.id, site.line, 'grpc server assertion')
                    end
                end
            end
        end
        if d.dispatchers[id - G.id_of[f][1] + 1] then
            for g, rec in ipairs(G.files) do
                if g > M.MAX_SCANNED_FILES or expired() then C.incomplete = true; break end
                if relevant(rec) then
                    local other = data(g)
                    for _, site in ipairs(other and other.sites or {}) do
                        if site.framework == 'gin' then for _, dst in ipairs(target(g, site)) do
                            emit(out, id, dst, node.line, 'gin middleware dispatch', rec.path .. ':' .. site.line)
                        end end
                    end
                end
            end
        end
        -- A generated server interface/stub reaches only structs that actually
        -- embed that service's generated Unimplemented server, not namesakes.
        local owner = node.recv or (node.parent and G.files[f].nodes[node.parent].name)
        if owner and G.files[f].path:match('_grpc%.pb%.go$') then
            local service = owner:match('^Unimplemented(.+Server)$') or owner:match('^(.+Server)$')
            if service then
                local stub = 'Unimplemented' .. service
                local expected = signature(f, id - G.id_of[f][1] + 1)
                for candidate, field in ipairs(G.by_name[stub] or {}) do
                    if candidate > M.MAX_CANDIDATES or expired() then C.incomplete = true; break end
                    local n, g = G.nodes[field], G.node_file[field]
                    if n.embedded and n.parent and G.files[g].language == 'go' then
                        local md = methods.data(g)
                        local type_index = n.parent
                        local details = md and md.nodes[type_index]
                        local matches = false
                        for _, embed in ipairs(details and details.embeds or {}) do
                            local ty = embed.kind == 'pointer' and embed.child or embed
                            for _, base in ipairs(ty.kind == 'name' and methods.types(g, ty.name) or {}) do
                                if G.node_file[base] == f and G.nodes[base].name == stub then matches = true end
                            end
                        end
                        if matches and expected then
                            local type_id = G.id_of[g][type_index]
                            for _, m in ipairs(methods.members({ id = type_id, pointer = true }, g, node.name)) do
                                local mf = G.node_file[m.id]
                                if not G.files[mf].path:match('%.pb%.go$') and expected == signature(mf, m.id - G.id_of[mf][1] + 1) then
                                    emit(out, id, m.id, node.line, 'grpc server implementation', G.files[g].path .. ':' .. n.line)
                                end
                            end
                        end
                    end
                end
            end
        end
        return out
    end
    function C.incoming(wanted)
        local result = {}
        local go = false
        for id in pairs(wanted) do if G.files[G.node_file[id]].language == 'go' then go = true; break end end
        if not go then return result end
        for f, rec in ipairs(G.files) do
            if f > M.MAX_SCANNED_FILES or expired() then C.incomplete = true; break end
            if relevant(rec) then
                local d, candidates = data(f), {}
                for _, site in ipairs(d and d.sites or {}) do candidates[G.id_of[f][site.from]] = true end
                for _, site in ipairs(d and d.assertions or {}) do candidates[G.id_of[f][site.from]] = true end
                for index in pairs(d and d.dispatchers or {}) do candidates[G.id_of[f][index]] = true end
                if rec.path:match('_grpc%.pb%.go$') then
                    for index, n in ipairs(rec.nodes) do
                        if index > M.MAX_CANDIDATES then C.incomplete = true; break end
                        if n.kind == 'method' then candidates[G.id_of[f][index]] = true end
                    end
                end
                local ordered = {}; for id in pairs(candidates) do ordered[#ordered + 1] = id end
                table.sort(ordered)
                for _, id in ipairs(ordered) do
                    for _, edge in ipairs(C.outgoing(id)) do
                        if wanted[edge.target] then result[id] = result[id] or {}; result[id][#result[id] + 1] = edge end
                    end
                end
            end
        end
        return result
    end
    return C
end

return M
