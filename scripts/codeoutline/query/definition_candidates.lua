-- Query-only navigation suggestions, never execution bindings or index data.
local M = { MAX_SCAN = 256, MAX_RESULTS = 8, MAX_SITES = 4, MAX_FILES = 4, MAX_BYTES = 2 * 1048576 }
local control = require('codeoutline.shared.control')
local graph = require('codeoutline.analysis.graph')
local callable = { ['function'] = true, prototype = true, method = true, constructor = true }
local types = { class = true, struct = true, union = true, interface = true, record = true,
    enum = true, typedef = true }
local values = { variable = true, constant = true, field = true, enum_member = true }
local function normalized(name) return (name:gsub('::', '.'):gsub(':', '.'):gsub('^%.', '')) end

-- An empty answer leaves the editor and the agent nothing to inspect, so a
-- failed binding still gets name-based suggestions. They remain unconfirmed
-- candidates: never call edges, references or index data.
function M.allowed(site)
    if not site or site.decl or not site.name or not site.name:match('^[%a_$][%w_$]*$') then return false end
    -- A table literal declared in this file is a bound receiver, not a failed
    -- one: its whole contents are visible, so another file's member is a
    -- different object. A module binding stays eligible because members can be
    -- attached to it from other files.
    if type(site.evidence) == 'string' and site.evidence:match('^lua%-local:') then return false end
    return site.kind == 'call' or site.kind == 'ref' or site.kind == 'symbol' or site.kind == 'new'
        or site.kind == 'member_call' or site.kind == 'member_symbol'
end

function M.find(G, f, site, ctx, lua_self, lua_initializers)
    local info = { truncated = site and site.macro_state == 'limited' or false,
        scanned = 0, reason = 'exact name; binding unconfirmed' }
    if not lua_self and not M.allowed(site) then return {}, info end
    local language = G.files[f].language
    -- These languages have package/project visibility that a name-only search
    -- cannot establish. Their existing resolvers retain authority.
    local unresolved_receiver = site.reason == 'receiver binding unresolved'
    if not unresolved_receiver and (language == 'go' or language == 'rust' or language == 'csharp') then return {}, info end
    if unresolved_receiver then info.reason = 'matching member name; receiver binding unconfirmed' end
    local configured = (language == 'c' or language == 'cpp')
        and require('codeoutline.analysis.cpp.cpp_includes').policy(G, f, ctx).configured
    local qualified
    if type(site.evidence) == 'string' then qualified = site.evidence:match('^cpp:name:(.-)%z%d+$') end
    qualified = qualified and normalized(qualified)
    if qualified and not qualified:find('.', 1, true) then qualified = nil end
    if not lua_self then
        if site.recv then
            if site.recv == 'self' or site.recv == 'this' or site.recv == 'cls' then return {}, info end
            qualified = qualified or normalized(site.recv .. '.' .. site.name)
        elseif not unresolved_receiver and (site.kind == 'member_call' or site.kind == 'member_symbol') then return {}, info end
    end
    local list = G.by_name[site.name] or {}
    -- A Lua member alias is only reachable through its dotted name; its bare
    -- key stays unpublished unless the owner is a configured export table.
    local dotted = language == 'lua' and qualified and G.by_name[qualified]
    if dotted and dotted ~= list then
        local merged, seen = {}, {}
        for _, id in ipairs(list) do merged[#merged + 1], seen[id] = id, true end
        for _, id in ipairs(dotted) do
            if not seen[id] then merged[#merged + 1], seen[id] = id, true end
        end
        list = merged
    end
    local source_dir = G.files[f].path:match('^(.*)/') or ''
    -- `bare` drops the receiver qualifier: the member name alone still names a
    -- definition worth offering, including top-level method definitions.
    local function scan(qualifier, bare)
        local hits, macro_hits, scanned = {}, {}, 0
        for i = 1, math.min(#list, M.MAX_SCAN) do
            if i % 16 == 0 then control.check() end
            scanned = i
            local id = list[i]
            local node, g = G.nodes[id], G.node_file[id]
            local rec = G.files[g]
            local parent = node.parent and rec.nodes[node.parent]
            local published = language == 'lua' and require('codeoutline.analysis.lua.lua_bindings').exported(node, site.name, G.lua_global_export_tables)
            local kind = site.kind == 'new' and types[node.kind]
                or site.kind ~= 'new' and (callable[node.kind]
                    or (site.kind == 'symbol' or site.kind == 'member_symbol') and (types[node.kind] or values[node.kind]))
            -- Unresolved macro visibility can still offer unconfirmed definition
            -- tags for navigation, including when include paths are configured.
            -- An explicit undef remains a barrier.
            if node.kind == 'macro' then
                kind = site.kind == 'call' and (site.macro_state == 'unseen'
                    or site.macro_state == 'uncertain' or site.macro_state == 'limited')
                    and (g ~= f or site.line and node.line < site.line)
            end
            local name_matches = node.name == site.name or published
            if not bare then name_matches = name_matches and (normalized(node.qualified) == site.name or published) end
            local aliased = language == 'lua' and require('codeoutline.analysis.lua.lua_bindings').member_alias(node, qualifier)
            if qualifier then name_matches = normalized(node.qualified) == qualifier or aliased end
            if bare and unresolved_receiver then name_matches = name_matches and graph.owner(node.qualified) ~= nil end
            -- Restrict receiver candidates to members and exclude nested
            -- functions unless they are recognized Lua initializer members.
            -- A lexical self can inherit through runtime metatables. The editor
            -- can offer method definition tags even without a receiver binding.
            local lua_method = lua_self and rec.language == 'lua' and node.name == site.name and not parent
                and not graph.is_decl(node) and (node.kind == 'method' or node.kind == 'function' and graph.owner(node.qualified))
            local initialized_member = lua_initializers and language == 'lua' and rec.language == 'lua' and site.recv and parent
                and callable[parent.kind] and (node.kind == 'function' or node.kind == 'method')
                and graph.owner(parent.qualified) == site.recv and normalized(node.qualified) == qualifier
            if lua_method or not lua_self and kind and name_matches and graph.family(rec.language) == graph.family(language)
                and (not node['local'] or published or aliased) and not (node.static and g ~= f)
                and (not parent or parent.kind == 'namespace'
                    or (qualifier or unresolved_receiver) and (types[parent.kind] or parent.kind == 'impl')
                    or initialized_member)
                and (qualifier or bare or node.kind ~= 'method' and node.kind ~= 'constructor') then
                local score = g == f and 100 or (rec.path:match('^(.*)/') or '') == source_dir and 20 or 0
                if node.kind ~= 'prototype' and not node.decl then score = score + 1 end
                local bucket = node.kind == 'macro' and macro_hits or hits
                bucket[#bucket + 1] = { id = id, score = score }
            end
        end
        return hits, macro_hits, scanned
    end
    local hits, macro_hits, scanned = scan(qualified, false)
    -- An unbound receiver still names a member. Offer the bare name instead of
    -- an empty answer, keeping the qualified match authoritative when it hits.
    if #hits == 0 and #macro_hits == 0 and (qualified or unresolved_receiver) and not lua_self then
        hits, macro_hits, scanned = scan(nil, true)
    end
    info.scanned = scanned
    -- Ordinary definitions are more useful than unrelated proxy macros.
    if #hits == 0 then hits = macro_hits
    elseif configured then hits = {} end
    info.truncated = info.truncated or #list > M.MAX_SCAN
    -- Prefer implementations over repeated API declarations. A declaration is
    -- still useful when the project has no matching implementation at all.
    local defined = {}
    for _, hit in ipairs(hits) do
        local node = G.nodes[hit.id]
        if not graph.is_decl(node) then defined[node.qualified] = true end
    end
    local kept = {}
    for _, hit in ipairs(hits) do
        local node = G.nodes[hit.id]
        if not graph.is_decl(node) or not defined[node.qualified] then kept[#kept + 1] = hit end
    end
    hits = kept
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
                evidence = entry.binding, reason = entry.reason, macro_state = entry.macro_state, line = entry.line }
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
                    local _, sites = require('codeoutline.analysis.cpp.cpp_macros').resolve(G, f, site.name, entry.line, macro_ctx, true)
                    ids = sites or {}
                    info = { reason = 'possible macro declaration; binding unconfirmed',
                        truncated = macro_ctx.cpp_macro_context and macro_ctx.cpp_macro_context.incomplete or false, scanned = 0 }
                    if #ids == 0 then
                        local truncated = info.truncated
                        ids, info = M.find(G, f, site, ctx)
                        info.truncated = info.truncated or truncated
                    end
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
