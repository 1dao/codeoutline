-- Explicit dispatch contracts. No wildcard API guesses or source evaluation.
local control = require('codeoutline.control')
local M = {}
local aliases = require('codeoutline.dispatch_aliases')
local member = { ['.'] = true, [':'] = true, ['::'] = true, ['->'] = true }

local function value(T, a, b, language)
    if a == b and T.k[a] == 'str' then
        local raw = T:text(a)
        if language == 'lua' then
            local literal = require('codeoutline.lua_literal').decode(raw)
            return literal and { literal = literal } or false
        end
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
    local expand = r.collect_dispatch and aliases.prepare(r, T)
    for index, ref in ipairs(r.refs) do
        if index % 128 == 0 then control.check() end
        local x = ref.tok
        if (ref.kind == 'call' or ref.kind == 'member_call') and T:text(x + 1) == '(' then
            local close = T:match(x + 1)
            if close then
                local first = x
                while first > 2 and member[T:text(first - 1)] and T.k[first - 2] == 'id' do first = first - 2 end
                local call = value(T, first, x, r.language)
                if call then calls[call.symbol] = true end
                if not r.collect_dispatch then goto next_ref end
                local api = call and expand(call, first)
                if not api or not api.symbol or type(r.collect_dispatch) == 'table'
                    and not r.collect_dispatch[call.symbol] and not r.collect_dispatch[api.symbol] then goto next_ref end
                local args, ranges, a, i = {}, r.ranges and {} or nil, x + 2, x + 2
                while i <= close do
                    if i == close or T:text(i) == ',' then
                        args[#args + 1] = expand(value(T, a, i - 1, r.language), a)
                        if ranges then ranges[#args] = a < i and { T.s[a] - 1, T.e[i - 1] } or false end
                        a = i + 1
                    elseif T:match(i) and T:match(i) > i then i = T:match(i)
                    elseif r.language == 'lua' and T.k[i] == 'kw' and T:text(i) == 'function' then
                        local depth = 1
                        while depth > 0 and i < close do
                            i = i + 1
                            local kw = T.k[i] == 'kw' and T:text(i)
                            if kw == 'function' or kw == 'if' or kw == 'do' or kw == 'repeat' then depth = depth + 1
                            elseif kw == 'end' or kw == 'until' then depth = depth - 1 end
                        end
                        if depth > 0 then break end
                    end
                    i = i + 1
                end
                if call then sites[#sites + 1] = { call = call.symbol, api = api.symbol,
                    args = args, ranges = ranges, from = ref.from, line = ref.line } end
            end
        end
        ::next_ref::
    end
    if not r.collect_dispatch and next(calls) then aliases.hints(r, T, calls) end
    local names = {}
    for name in pairs(calls) do names[#names + 1] = name end
    table.sort(names)
    if #names > 0 then r.dispatch_calls = names end
    local roles = require('codeoutline.shared_events').roles(r, calls)
    if roles ~= 0 then r.event_roles = roles end
    if r.collect_dispatch then r.dispatch_sites = sites end
end

local function rules_for(G, rules)
    local config = require('codeoutline.rules')
    if rules ~= nil then return config.dispatch(rules) end
    return config.load(G.root).dispatch
end

function M.candidate(rec, call)
    if rec.dispatch_sites then return true end -- explicit in-memory parse option
    for _, name in ipairs(rec.dispatch_calls or {}) do
        if name == call then return true end
        if name:sub(1, 1) == '@' then
            local root = name:sub(2)
            if root == call or call:sub(1, #root + 1) == root .. '.'
                or call:sub(1, #root + 1) == root .. ':'
                or call:sub(1, #root + 2) == root .. '->' then return true end
        end
    end
    return false
end

function M.query(G, rules, report)
    rules = rules_for(G, rules)
    if #rules == 0 then return { outgoing = function() return {} end, incoming = function() return {} end } end
    local graph = require('codeoutline.graph')
    local names, cache, order, bytes, registrations_by_rule = {}, {}, {}, 0, {}
    local dependencies = {}
    for _, rule in ipairs(rules) do names[rule.call] = true; if rule.register then names[rule.register] = true end end
    local candidate = M.candidate
    local function sites(f, literals)
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
        -- Target rules can only obtain a literal command from this file. Reject
        -- broad module hints before scope/registry analysis, but decode escaped
        -- Lua literals so aliases and alternate spellings remain candidates.
        if literals and rec.language == 'lua' then
            local relevant = false
            for name in pairs(literals) do if source:find(name, 1, true) then relevant = true; break end end
            if not relevant and source:find('\\', 1, true) then
                local T = require('codeoutline.lang.lua').lang:tokenize(source)
                local decode = require('codeoutline.lua_literal').decode
                for i = 1, T.n do
                    if i % 4096 == 0 then control.check() end
                    if T.k[i] == 'str' and literals[decode(T:text(i))] then relevant = true; break end
                end
            end
            -- Do not cache negatives: later incoming calls can request other
            -- targets within this same query, and outgoing needs all sites.
            if not relevant then return {} end
        end
        local parsed = assert(require('codeoutline.parse').parse(rec.path, source,
            { ranges = false, dispatch = names, dispatch_only = true, language = rec.language }))
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
        if arg and not literal and arg.node then return { G.id_of[f][arg.node] } end
        if arg and not literal and arg.import then
            local imp = arg.import
            local rec = G.files[f]
            if rec.language == 'javascript' or rec.language == 'typescript' or rec.language == 'arkts' then
                local js = require('codeoutline.js_resolution')
                dependencies.js = dependencies.js or js.context(G)
                return js.imported(G, f, imp.path, arg.member, dependencies.js) or {}
            elseif rec.language == 'lua' then
                local bindings = require('codeoutline.lua_bindings')
                dependencies.lua = dependencies.lua or bindings.context(G)
                local result = {}
                for _, file in ipairs(bindings.modules(G, { path = imp.path, kind = imp.loader }, dependencies.lua)) do
                    local record = G.files[file]
                    local exports = require('codeoutline.foreign').exports(record, 'lua', imp.path) or record.lua_exports
                    local id = exports and exports[arg.member]
                    if id then result[#result + 1] = G.id_of[file][id] end
                end
                return result
            elseif rec.language == 'python' then
                local base = imp.path:gsub('%.', '/')
                local file = G.file_index[base .. '.py'] or G.file_index[base .. '/__init__.py']
                local result = {}
                for _, id in ipairs(file and G.id_of[file] or {}) do
                    local n = G.nodes[id]
                    if not n.parent and n.name == arg.member then result[#result + 1] = id end
                end
                return result
            end
            return {}
        end
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
                        if (site.call == rule.register or site.api == rule.register) and key and key.literal then
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
        local literals
        if wanted then
            local targets_only = true
            for _, rule in ipairs(rules) do if rule.kind ~= 'target' then targets_only = false; break end end
            if targets_only then
                literals = {}
                for id in pairs(wanted) do
                    local node = G.nodes[id]
                    literals[node.name], literals[node.qualified or node.name] = true, true
                end
            end
        end
        local files = only and { G.node_file[only] } or G.file_order
        for _, f in ipairs(files) do
            control.check()
            local rec, file_sites = G.files[f], nil
            for ri, rule in ipairs(rules) do
                if (not rule.language or rule.language == rec.language) and candidate(rec, rule.call) then
                    -- Process every applicable rule while this file is available,
                    -- even if event registration scans evict it from the FIFO.
                    file_sites = file_sites or sites(f, literals)
                    for _, site in ipairs(file_sites) do
                        if (site.call == rule.call or site.api == rule.call) and site.from > 0 and (not only or G.id_of[f][site.from] == only) then
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
    return { outgoing = function(id) return scan(id)[id] or {} end, incoming = function(wanted) return scan(nil, wanted) end,
        resolve_targets = targets }
end

return M
