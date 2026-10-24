-- Query-only navigation suggestions, never execution bindings or index data.
local M = { MAX_SCAN = 256, MAX_RESULTS = 8 }
local control = require('codeoutline.control')
local graph = require('codeoutline.graph')
local callable = { ['function'] = true, prototype = true, method = true, constructor = true }
local types = { class = true, struct = true, union = true, interface = true, record = true,
    enum = true, typedef = true }
local values = { variable = true, constant = true, field = true, enum_member = true }
local reasons = { ['no indexed target'] = true, ['no eligible target'] = true,
    ['unresolved c++ name'] = true, ['name/locality match'] = true,
    ['multiple name/locality candidates'] = true }
local function normalized(name) return (name:gsub('::', '.'):gsub(':', '.'):gsub('^%.', '')) end

function M.allowed(site)
    if not site or site.decl or not site.name or not site.name:match('^[%a_$][%w_$]*$') then return false end
    if not reasons[site.reason] and not (site.reason or ''):match('^ambiguous name candidates') then return false end
    -- A known binding that failed is a barrier, not permission to guess another
    -- imported value, local, receiver type, package, or constructor.
    if site.evidence ~= nil and site.evidence ~= ''
        and not (type(site.evidence) == 'string' and site.evidence:match('^cpp:name:')) then return false end
    return site.kind == 'call' or site.kind == 'ref' or site.kind == 'symbol' or site.kind == 'new'
        or site.kind == 'member_call' or site.kind == 'member_symbol'
end

function M.find(G, f, site, ctx)
    local info = { truncated = false, scanned = 0, reason = 'exact name; binding unconfirmed' }
    if not M.allowed(site) then return {}, info end
    local language = G.files[f].language
    -- These languages have package/project visibility that a name-only search
    -- cannot establish. Their existing resolvers retain authority.
    if language == 'go' or language == 'rust' or language == 'csharp' then return {}, info end
    if (language == 'c' or language == 'cpp')
        and require('codeoutline.cpp_includes').policy(G, f, ctx).configured then return {}, info end
    local qualified
    if site.evidence and site.evidence ~= '' then qualified = site.evidence:match('^cpp:name:(.-)%z') end
    qualified = qualified and normalized(qualified)
    if qualified and not qualified:find('.', 1, true) then qualified = nil end
    if site.recv then
        if site.recv == 'self' or site.recv == 'this' or site.recv == 'cls' then return {}, info end
        qualified = qualified or normalized(site.recv .. '.' .. site.name)
    elseif site.kind == 'member_call' or site.kind == 'member_symbol' then return {}, info end
    local list, hits = G.by_name[site.name] or {}, {}
    local source_dir = G.files[f].path:match('^(.*)/') or ''
    for i = 1, math.min(#list, M.MAX_SCAN) do
        if i % 16 == 0 then control.check() end
        info.scanned = i
        local id = list[i]
        local node, g = G.nodes[id], G.node_file[id]
        local rec = G.files[g]
        local parent = node.parent and rec.nodes[node.parent]
        local published = language == 'lua' and require('codeoutline.lua_bindings').exported(node, site.name, G.lua_global_export_tables)
        local kind = site.kind == 'new' and types[node.kind]
            or site.kind ~= 'new' and (callable[node.kind]
                or (site.kind == 'symbol' or site.kind == 'member_symbol') and (types[node.kind] or values[node.kind]))
        local name_matches = (node.name == site.name or published) and (normalized(node.qualified) == site.name or published)
        if qualified then
            name_matches = normalized(node.qualified) == qualified
            if not name_matches and language == 'lua' then
                for _, alias in ipairs(require('codeoutline.lua_bindings').aliases(node, G.lua_global_export_tables)) do
                    if normalized(alias) == qualified then name_matches = true; break end
                end
            end
        end
        -- No macros, private locals, nested functions or unrelated class methods.
        -- Even same-file locals require lexical evidence from the strict resolver.
        if kind and name_matches and graph.family(rec.language) == graph.family(language)
            and (not node['local'] or published) and not (node.static and g ~= f)
            and (not parent or parent.kind == 'namespace' or qualified and (types[parent.kind]))
            and (qualified or node.kind ~= 'method' and node.kind ~= 'constructor') then
            local score = g == f and 100 or (rec.path:match('^(.*)/') or '') == source_dir and 20 or 0
            if node.kind ~= 'prototype' and not node.decl then score = score + 1 end
            hits[#hits + 1] = { id = id, score = score }
        end
    end
    info.truncated = #list > M.MAX_SCAN
    table.sort(hits, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return graph.before(G, a.id, b.id)
    end)
    local ids = {}
    for i = 1, math.min(#hits, M.MAX_RESULTS) do ids[i] = hits[i].id end
    info.truncated = info.truncated or #hits > M.MAX_RESULTS
    return ids, info
end

return M
