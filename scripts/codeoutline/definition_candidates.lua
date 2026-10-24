-- Query-only navigation suggestions, never execution bindings or index data.
local M = { MAX_SCAN = 256, MAX_RESULTS = 8, MAX_SITES = 4, MAX_FILES = 4, MAX_BYTES = 2 * 1048576 }
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

-- Candidates for failures already encountered by an explore query. Reuse its
-- binding/macro context; never broaden graph traversal to hunt for failures.
function M.suggest(G, report, ctx)
    local result = { entries = {}, truncated = report and report.truncated or false,
        stats = { sites = 0, scanned = 0, files = 0, bytes = 0 } }
    local files, macro_ctx = {}, nil
    for _, entry in ipairs(report and report.entries or {}) do
        if entry.reference and entry.reason and not entry.target then
            local f = G.node_file[entry.source]
            local refs = G.files[f].refs
            local site = { name = entry.call, kind = refs.kind[entry.reference], recv = refs.recv[entry.reference],
                evidence = entry.binding, reason = entry.reason }
            local macro = entry.reason == 'unknown or unsupported macro visibility'
                and (G.files[f].language == 'c' or G.files[f].language == 'cpp')
            if macro or M.allowed(site) then
                if result.stats.sites >= M.MAX_SITES then result.truncated = true; break end
                result.stats.sites = result.stats.sites + 1
                local ids, info
                if macro then
                    -- A whole-function graph query may already have exhausted
                    -- its macro budget. Suggestions get a separate bounded
                    -- pass while sharing the existing source/binding caches.
                    if not macro_ctx then
                        macro_ctx = {}; for k, v in pairs(ctx) do macro_ctx[k] = v end
                        macro_ctx.cpp_macro_context = nil
                    end
                    local _, sites = require('codeoutline.cpp_macros').resolve(G, f, site.name, entry.line, macro_ctx, true)
                    ids = sites or {}
                    info = { reason = 'possible macro declaration; binding unconfirmed',
                        truncated = macro_ctx.cpp_macro_context and macro_ctx.cpp_macro_context.incomplete or false, scanned = 0 }
                else ids, info = M.find(G, f, site, ctx) end
                result.stats.scanned = result.stats.scanned + info.scanned
                result.truncated = result.truncated or info.truncated or #ids > M.MAX_RESULTS
                local group = { source = entry.source, path = G.files[f].path, line = entry.line, call = entry.call,
                    resolution_reason = entry.reason, status = 'unconfirmed', candidates = {} }
                for i = 1, math.min(#ids, M.MAX_RESULTS) do
                    control.check()
                    local id = ids[i]
                    local g, node = G.node_file[id], G.nodes[id]
                    local rec = G.files[g]
                    local size = rec.size or 0
                    local accepted = files[g]
                    if not accepted then
                        if result.stats.files < M.MAX_FILES and size <= 1048576 and result.stats.bytes + size <= M.MAX_BYTES then
                            files[g], accepted = true, true
                            result.stats.files, result.stats.bytes = result.stats.files + 1, result.stats.bytes + size
                        else result.truncated = true end
                    end
                    if accepted then
                        group.candidates[#group.candidates + 1] = { id = id, path = rec.path, line = node.line,
                            name = node.name, qualified = node.qualified, kind = node.kind,
                            status = 'unconfirmed', reason = info.reason }
                    end
                end
                if #group.candidates > 0 then result.entries[#result.entries + 1] = group end
            end
        end
    end
    if macro_ctx and macro_ctx.cpp_macro_context then result.stats.macros = macro_ctx.cpp_macro_context.stats end
    return result
end

return M
