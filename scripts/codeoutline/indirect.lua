-- Explicit dispatch contracts. No wildcard API guesses or source evaluation.
local control = require('codeoutline.control')
local M = {}
local member = { ['.'] = true, [':'] = true, ['::'] = true, ['->'] = true }

local function value(T, a, b)
    if a == b and T.k[a] == 'str' then
        local raw = T:text(a)
        local q = raw:sub(1, 1)
        if (q == '"' or q == "'") and raw:sub(-1) == q then
            local body = raw:sub(2, -2)
            -- Reject escapes/interpolation instead of silently mis-decoding keys.
            if not body:find('[\\$]') then return { literal = body } end
        end
    end
    if T:text(a) == '&' then a = a + 1 end
    if a > b or (b - a) % 2 ~= 0 or T.k[a] ~= 'id' then return false end
    local parts = { T:text(a) }
    for i = a + 1, b, 2 do
        if not member[T:text(i)] or T.k[i + 1] ~= 'id' then return false end
        parts[#parts + 1] = T:text(i); parts[#parts + 1] = T:text(i + 1)
    end
    return { symbol = table.concat(parts) }
end

function M.collect(r, T)
    local sites, calls = {}, {}
    for index, ref in ipairs(r.refs) do
        if index % 128 == 0 then control.check() end
        local x = ref.tok
        if (ref.kind == 'call' or ref.kind == 'member_call') and T:text(x + 1) == '(' then
            local close = T:match(x + 1)
            if close then
                local first = x
                while first > 2 and member[T:text(first - 1)] and T.k[first - 2] == 'id' do first = first - 2 end
                local call = value(T, first, x)
                if call then calls[call.symbol] = true end
                if not r.collect_dispatch or (type(r.collect_dispatch) == 'table' and not r.collect_dispatch[call and call.symbol]) then goto next_ref end
                local args, a, i = {}, x + 2, x + 2
                while i <= close do
                    if i == close or T:text(i) == ',' then
                        args[#args + 1] = value(T, a, i - 1)
                        a = i + 1
                    elseif T:match(i) and T:match(i) > i then i = T:match(i) end
                    i = i + 1
                end
                if call then sites[#sites + 1] = { call = call.symbol, args = args, from = ref.from, line = ref.line } end
            end
        end
        ::next_ref::
    end
    local names = {}
    for name in pairs(calls) do names[#names + 1] = name end
    table.sort(names)
    if #names > 0 then r.dispatch_calls = names end
    if #sites > 0 then r.dispatch_sites = sites end
end

local function rules_for(G, rules)
    if rules == nil and G.root then
        local f = io.open(G.root .. '/.codeoutline.json', 'rb')
        if f then
            local raw = f:read(65537); f:close()
            assert(#raw <= 65536, '.codeoutline.json exceeds 64 KiB')
            local ok, config = pcall(xutils.json_unpack, raw)
            assert(ok and type(config) == 'table', 'invalid .codeoutline.json')
            rules = config.dispatchRules
        end
    end
    rules = rules or {}
    assert(type(rules) == 'table' and #rules <= 32, 'dispatchRules must contain at most 32 rules')
    for _, r in ipairs(rules) do
        assert(type(r) == 'table' and type(r.call) == 'string' and r.call:match('^[%a_][%w_%.:>%-]*$'), 'invalid dispatchRules.call')
        assert(r.kind == 'target' or r.kind == 'callback' or r.kind == 'event', 'invalid dispatchRules.kind')
        assert(r.language == nil or type(r.language) == 'string', 'invalid dispatchRules.language')
        for _, key in ipairs(r.kind == 'event' and { 'argument', 'keyArgument', 'handlerArgument' } or { 'argument' }) do
            local n = r[key]
            assert(type(n) == 'number' and n >= 1 and n <= 32 and n % 1 == 0, 'invalid dispatchRules.' .. key)
        end
        if r.kind == 'event' then assert(type(r.register) == 'string' and r.register:match('^[%a_][%w_%.:>%-]*$'), 'invalid dispatchRules.register') end
    end
    return rules
end

function M.query(G, rules, report)
    rules = rules_for(G, rules)
    if #rules == 0 then return { outgoing = function() return {} end, incoming = function() return {} end } end
    local graph = require('codeoutline.graph')
    local names, cache, order, bytes, registrations_by_rule = {}, {}, {}, 0, {}
    local dependencies = {}
    for _, rule in ipairs(rules) do names[rule.call] = true; if rule.register then names[rule.register] = true end end
    local function candidate(rec, call)
        if rec.dispatch_sites then return true end -- explicit in-memory parse option
        for _, name in ipairs(rec.dispatch_calls or {}) do if name == call then return true end end
        return false
    end
    local function sites(f)
        local rec = G.files[f]
        if rec.dispatch_sites then return rec.dispatch_sites end
        if cache[f] then return cache[f].sites end
        assert(G.root, 'indirect resolution requires a project root or explicit dispatch parse data')
        local file = assert(io.open(G.root .. '/' .. rec.path, 'rb'), 'cannot read indirect source: ' .. rec.path)
        local raw = file:read('a'); file:close()
        local crc = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
        assert(#raw == rec.size and crc == rec.crc, 'source changed during query; retry: ' .. rec.path)
        local source = raw
        if rec.encoding ~= 'utf-8' and rec.encoding ~= 'utf-8-bom' then
            source = assert(xutils.to_utf8(raw, rec.encoding == 'gbk' and 'gbk' or 'auto'))
        end
        local parsed = assert(require('codeoutline.parse').parse(rec.path, source,
            { ranges = false, dispatch = names, dispatch_only = true }))
        assert(#parsed.nodes == #rec.nodes, 'source encoding changed; refresh index before indirect query: ' .. rec.path)
        for i, n in ipairs(parsed.nodes) do
            assert(n.qualified == rec.nodes[i].qualified and n.line == rec.nodes[i].line,
                'source encoding changed; refresh index before indirect query: ' .. rec.path)
        end
        local result = parsed.dispatch_sites or {}
        local weight = #source + #result * 512
        -- Query-local FIFO: no retained source/tokens and no cross-query invalidation.
        while #order > 0 and (#order >= 16 or bytes + weight > 8 * 1024 * 1024) do
            local old = table.remove(order, 1); bytes = bytes - cache[old].weight; cache[old] = nil
        end
        if weight <= 8 * 1024 * 1024 then
            cache[f] = { sites = result, weight = weight }; order[#order + 1] = f; bytes = bytes + weight
        end
        return result
    end
    local function targets(f, site, arg, literal)
        local name
        if arg then
            if literal then name = arg.literal else name = arg.symbol end
        end
        if not name or not name:match('^[%a_][%w_%.:>%-]*$') then return {} end
        local short = name:match('([%w_]+)$')
        local dependency = dependencies[f]
        if not dependency then
            local deps, paired = graph.dependencies(G, f)
            dependency = { deps, paired }; dependencies[f] = dependency
        end
        local deps, paired = dependency[1], dependency[2]
        local view = G
        if short ~= name then
            local filtered = {}
            for _, id in ipairs(G.by_name[short] or {}) do
                if G.nodes[id].qualified == name then filtered[#filtered + 1] = id end
            end
            view = setmetatable({ by_name = { [short] = filtered } }, { __index = G })
        end
        return graph.resolve(view, f, G.id_of[f][site.from], short, 'ref', nil, deps, paired) or {}
    end
    local function registrations(ri, rule)
        if registrations_by_rule[ri] then return registrations_by_rule[ri] end
        local registrations = {}
        if rule.kind == 'event' then
            for _, f in ipairs(G.file_order) do
                control.check()
                local rec = G.files[f]
                if (not rule.language or rule.language == rec.language) and candidate(rec, rule.register) then
                    for _, site in ipairs(sites(f)) do
                        local key = site.args[rule.keyArgument]
                        if site.call == rule.register and key and key.literal then
                            local bucket = rec.language .. '\0' .. key.literal
                            registrations[bucket] = registrations[bucket] or {}
                            for _, id in ipairs(targets(f, site, site.args[rule.handlerArgument])) do
                                registrations[bucket][id] = registrations[bucket][id]
                                    or (report and (rec.path .. ':' .. site.line) or true)
                            end
                        end
                    end
                end
            end
        end
        registrations_by_rule[ri] = registrations
        return registrations
    end
    local function scan(only, wanted)
        local out = {}
        local files = only and { G.node_file[only] } or G.file_order
        for _, f in ipairs(files) do
            control.check()
            local rec, file_sites = G.files[f], nil
            for ri, rule in ipairs(rules) do
                if (not rule.language or rule.language == rec.language) and candidate(rec, rule.call) then
                    -- Process every applicable rule while this file is available,
                    -- even if event registration scans evict it from the FIFO.
                    file_sites = file_sites or sites(f)
                    for _, site in ipairs(file_sites) do
                        if site.call == rule.call and site.from > 0 and (not only or G.id_of[f][site.from] == only) then
                            local ids, arg, registered = {}, site.args[rule.argument], nil
                            if rule.kind == 'event' then
                                registered = registrations(ri, rule)
                                for id in pairs(arg and arg.literal and registered[rec.language .. '\0' .. arg.literal] or {}) do ids[#ids + 1] = id end
                                table.sort(ids, function(a, b) return graph.before(G, a, b) end)
                            else ids = targets(f, site, arg, rule.kind == 'target') end
                            local src = G.id_of[f][site.from]
                            if report and only and #ids == 0 then
                                local static = arg and (rule.kind == 'callback' and arg.symbol or rule.kind ~= 'callback' and arg.literal)
                                report:add({ source = src, line = site.line, rule = ri, argument = rule.argument, call = rule.call,
                                    reason = not static and 'dispatch argument is dynamic, unsupported or missing'
                                        or rule.kind == 'event' and 'no resolved registration for event key'
                                        or 'dispatch target unresolved or ambiguous' })
                            end
                            for _, id in ipairs(ids) do
                                if not wanted or wanted[id] then
                                if report then
                                    local bucket = registered and arg and arg.literal and registered[rec.language .. '\0' .. arg.literal]
                                    report:add({ source = src, target = id, line = site.line, rule = ri, argument = rule.argument,
                                        call = rule.call, kind = 'configured ' .. rule.kind,
                                        registered_at = bucket and bucket[id] or nil })
                                end
                                out[src] = out[src] or {}
                                out[src][#out[src] + 1] = { target = id, line = site.line, kind = 'indirect:' .. rule.kind .. '#' .. ri }
                                end
                            end
                        end
                    end
                end
            end
        end
        return out
    end
    return { outgoing = function(id) return scan(id)[id] or {} end, incoming = function(wanted) return scan(nil, wanted) end }
end

return M
