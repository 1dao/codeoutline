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
    local sites = {}
    for _, ref in ipairs(r.refs) do
        local x = ref.tok
        if (ref.kind == 'call' or ref.kind == 'member_call') and T:text(x + 1) == '(' then
            local close = T:match(x + 1)
            if close then
                local first = x
                while first > 2 and member[T:text(first - 1)] and T.k[first - 2] == 'id' do first = first - 2 end
                local call = value(T, first, x)
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
    end
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

function M.edges(G, rules)
    rules = rules_for(G, rules)
    local out = {}
    if #rules == 0 then return out end
    local graph = require('codeoutline.graph')
    local function targets(f, site, arg, literal)
        local name
        if arg then
            if literal then name = arg.literal else name = arg.symbol end
        end
        if not name or not name:match('^[%a_][%w_%.:>%-]*$') then return {} end
        local short = name:match('([%w_]+)$')
        local deps, paired = graph.dependencies(G, f)
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
    for ri, rule in ipairs(rules) do
        local registrations = {}
        if rule.kind == 'event' then
            for _, f in ipairs(G.file_order) do
                control.check()
                local rec = G.files[f]
                if not rule.language or rule.language == rec.language then
                    for _, site in ipairs(rec.dispatch_sites or {}) do
                        local key = site.args[rule.keyArgument]
                        if site.call == rule.register and key and key.literal then
                            local bucket = rec.language .. '\0' .. key.literal
                            registrations[bucket] = registrations[bucket] or {}
                            for _, id in ipairs(targets(f, site, site.args[rule.handlerArgument])) do
                                registrations[bucket][id] = true
                            end
                        end
                    end
                end
            end
        end
        for _, f in ipairs(G.file_order) do
            control.check()
            local rec = G.files[f]
            if not rule.language or rule.language == rec.language then
                for _, site in ipairs(rec.dispatch_sites or {}) do
                    if site.call == rule.call and site.from > 0 then
                        local ids, arg = {}, site.args[rule.argument]
                        if rule.kind == 'event' then
                            for id in pairs(arg and arg.literal and registrations[rec.language .. '\0' .. arg.literal] or {}) do ids[#ids + 1] = id end
                            table.sort(ids, function(a, b) return graph.before(G, a, b) end)
                        else ids = targets(f, site, arg, rule.kind == 'target') end
                        local src = G.id_of[f][site.from]
                        for _, id in ipairs(ids) do
                            out[src] = out[src] or {}
                            out[src][#out[src] + 1] = { target = id, line = site.line, kind = 'indirect:' .. rule.kind .. '#' .. ri }
                        end
                    end
                end
            end
        end
    end
    return out
end

return M
