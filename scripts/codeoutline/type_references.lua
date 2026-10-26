-- Query explicit type sites without a separate resident type-use graph.
local graph, control = require('codeoutline.graph'), require('codeoutline.control')
local M = { MAX_FILES = 16, MAX_BYTES = 8 * 1024 * 1024, MAX_NAMES = 32, MAX_SITES = 4096, TIME_MS = 600 }
M.kinds = { class = true, struct = true, union = true, interface = true, enum = true, record = true, typedef = true, annotation_type = true, trait = true }
local languages = require('codeoutline.type_uses').languages
function M.validate(query, opts)
    local budget = require('codeoutline.explore').validate(query, opts)
    assert(require('codeoutline.query_filters').parse(query).text ~= '', 'type references require an exact type name')
    local cap = opts and opts.max_nodes or 200
    assert(type(cap) == 'number' and cap % 1 == 0 and cap >= 1 and cap <= 2000, 'max_nodes must be an integer between 1 and 2000')
    return budget
end
function M.resolve(G, f, from, site, ctx, details)
    if site.value_shadowed and not site.elaborated then return {}, 'value binding' end
    local language, written = G.files[f].language, site.written
    local data, head = details or ctx.ordinary.data(f), written:match('^([%w_$]+)')
    for _, p in ipairs(data.type_parameters or {}) do
        if p.name == head and p.first <= site.at and site.at <= p.last then return {}, 'type parameter' end
    end
    local scope = from and from > 0 and G.nodes[from] and G.nodes[from].qualified or ''
    local ids
    if language == 'cpp' then
        ids = require('codeoutline.cpp_types').resolve(G, f, written, { context = ctx, scope = scope, at = site.at, accept = M.kinds, definitions = true })
    elseif language == 'c' then
        local visible = graph.visible_dependencies(G, f, ctx); ids = {}
        local own = {}
        for _, id in ipairs(G.by_name[written] or {}) do
            local cf = G.node_file[id]
            local kind = G.nodes[id].kind
            if (cf == f or visible[cf]) and (site.elaborated and kind == site.elaborated or not site.elaborated and kind == 'typedef')
                and (G.files[cf].language == 'c' or G.files[cf].language == 'cpp') then
                if cf == f and G.nodes[id].line <= site.line then own[#own + 1] = id
                elseif cf ~= f then ids[#ids + 1] = id end
            end
        end
        if #own > 0 then ids = own end
    elseif language == 'go' then ids = require('codeoutline.go_methods').context(G, ctx).types(f, written)
    elseif language == 'rust' then
        local resolver = require('codeoutline.rust_resolution')
        local entry = resolver.path(G, f, written, ctx, resolver.scope(G, f, from)); ids = entry and entry.ids or {}
        if not entry and not require('codeoutline.rust_packages').owner(G, f, ctx) then
            for _, id in ipairs(G.by_name[written] or {}) do
                if G.node_file[id] == f and G.nodes[id].qualified == written then ids[#ids + 1] = id end
            end
        end
    elseif language == 'typescript' or language == 'arkts' then
        ids = require('codeoutline.ts_implementations').types(G, f, written, ctx)
        if #ids == 0 then
            for _, imp in ipairs(G.files[f].js_imports or {}) do
                if imp.local_name == written and imp.imported ~= '*' then ids = require('codeoutline.js_resolution').imported(G, f, imp.path, imp.imported, ctx); break end
            end
            if #ids == 0 then
                for _, id in ipairs(G.by_name[written] or {}) do if G.node_file[id] == f and not G.nodes[id].parent then ids[#ids + 1] = id end end
            end
        end
    else ids = require('codeoutline.implementations').types(G, f, written, ctx, scope, site.at) end
    local result = {}
    for _, id in ipairs(ids or {}) do if M.kinds[G.nodes[id].kind] then result[#result + 1] = id end end
    return result, #result > 1 and 'ambiguous type' or #result == 0 and 'unresolved type' or nil
end
local function describe(G, id)
    return { id = id, name = G.nodes[id].qualified, file = G.files[G.node_file[id]].path, line = G.nodes[id].line }
end
function M.query(G, idx, targets, opts)
    opts = opts or {}
    local result = { targets = {}, references = {}, unresolved_sites = 0, ambiguous_sites = 0,
        query_stats = { scanned_files = 0, scanned_sites = 0, source_files = 0, source_bytes = 0, incomplete_reasons = {} } }
    local stats, deadline, stop = result.query_stats, xtimer.now_ms() + (opts.time_limit_ms or M.TIME_MS), {}
    if #targets > (opts.max_nodes or 200) then
        local selected = {}
        for i = 1, opts.max_nodes or 200 do selected[i] = targets[i] end
        targets = selected
        result.seed_limit_reached, result.relationships_incomplete = true, true
        stats.incomplete_reasons.type_reference_target_limit = true
    end
    local roots, root_files, names, name_count, loaded, positions = {}, {}, {}, 0, {}, {}
    local function limited(reason) stats.incomplete_reasons[reason], result.relationships_incomplete = true, true; error(stop, 0) end
    local function check()
        control.check()
        if xtimer.now_ms() >= deadline then result.time_limit_reached = true; limited('type_reference_time_limit') end
    end
    local function add_name(name)
        if names[name] then return end
        if name_count >= M.MAX_NAMES then limited('type_reference_alias_limit') end
        names[name], name_count = true, name_count + 1
    end
    if #targets == 0 then return result end
    local ctx = require('codeoutline.js_resolution').context(G); ctx.include_paths = opts.include_paths
    local function source(f)
        if not loaded[f] then
            if stats.source_files >= M.MAX_FILES then limited('type_reference_file_limit') end
            if stats.source_bytes + (G.files[f].size or 0) > M.MAX_BYTES then limited('type_reference_source_limit') end
            loaded[f] = true; stats.source_files = stats.source_files + 1; stats.source_bytes = stats.source_bytes + (G.files[f].size or 0)
        end
        if idx then
            local raw, repaired = idx:query_source(G.files[f].path)
            if repaired then error(opts.retry, 0) end
            return assert(raw, 'cannot read type reference source')
        end
    end
    ctx.ordinary = require('codeoutline.ordinary_bindings').context(G, ctx,
        (idx or G.root) and function(f) return source(f) end or nil, opts.cache and { cache = opts.cache } or nil)
    stats.ordinary = ctx.ordinary.stats
    local summaries, summary_bytes = {}, 0
    local function data(f)
        check()
        if summaries[f] then return summaries[f] end
        if not loaded[f] then source(f) end
        local full = ctx.ordinary.data(f)
        local count = 0; for _ in pairs(full.type_sites or {}) do count = count + 1 end
        local weight = count * 256 + #(full.type_parameters or {}) * 96
        if summary_bytes + weight > M.MAX_BYTES then limited('type_reference_evidence_limit') end
        summary_bytes = summary_bytes + weight; stats.evidence_bytes = summary_bytes
        summaries[f] = { type_sites = full.type_sites, type_parameters = full.type_parameters }
        return summaries[f]
    end
    local function matches(ids) for _, id in ipairs(ids) do if roots[id] then return roots[id] end end end
    local ok, err = pcall(function()
        for _, id in ipairs(targets) do roots[id] = id; root_files[G.node_file[id]] = true; add_name(G.nodes[id].name) end
        for _, id in ipairs(targets) do
            data(G.node_file[id])
            result.targets[#result.targets + 1] = describe(G, id)
        end
        for _, id in ipairs(targets) do
            if G.nodes[id].kind == 'typedef' then
                local f, n = G.node_file[id], id - G.id_of[G.node_file[id]][1] + 1
                for i, site in pairs(data(f).type_sites or {}) do
                    if G.files[f].refs.from[i] == n and site.role == 'alias' and site.alias_name then
                        local resolved = M.resolve(G, f, id, site, ctx, data(f))
                        if #resolved == 1 then roots[resolved[1]] = id; root_files[G.node_file[resolved[1]]] = true end
                    end
                end
            end
        end
        for round = 1, M.MAX_NAMES do
            local before = name_count
            for number, f in ipairs(G.file_order) do
                if number % 128 == 0 then check() end
                local rec = G.files[f]
                if languages[rec.language] then
                    for _, export in ipairs(rec.js_exports or {}) do
                        if export.local_name and names[export.local_name] and export.name ~= 'default' then add_name(export.name) end
                    end
                    for _, imp in ipairs(rec.js_imports or rec.imports or {}) do
                        local tail = (imp.imported or imp.path or ''):match('([%w_$]+)$')
                        local alias = imp.local_name or imp.alias
                        if alias and names[tail] then add_name(alias) end
                        for _, hint in ipairs(imp.type_aliases or {}) do if names[hint.name] then add_name(hint.alias) end end
                        if imp.imported == 'default' and alias then
                            local imported = require('codeoutline.js_resolution').imported(G, f, imp.path, imp.imported, ctx)
                            if matches(imported) then add_name(alias) end
                        end
                    end
                end
            end
            if before == name_count then break end
        end
        for pass = 1, M.MAX_NAMES do
            local before = name_count
            local eligible = {}
            local dirs, ordered, near, far = {}, {}, {}, {}
            for f in pairs(root_files) do dirs[G.file_dir[f]] = true end
            for _, f in ipairs(G.file_order) do
                if languages[G.files[f].language] then
                    local bucket = root_files[f] and ordered or dirs[G.file_dir[f]] and near or far
                    bucket[#bucket + 1] = f
                end
            end
            for _, f in ipairs(near) do ordered[#ordered + 1] = f end
            for _, f in ipairs(far) do ordered[#ordered + 1] = f end
            for _, f in ipairs(ordered) do
                if languages[G.files[f].language] then
                    stats.scanned_files = stats.scanned_files + 1
                    if stats.scanned_files % 128 == 0 then check() end
                    local rec, refs = G.files[f], G.files[f].refs
                    for i, name in ipairs(refs.name) do
                        if i % 1024 == 0 then check() end
                        if refs.kind[i] == 'type' and names[name] then
                            if eligible[f] == nil then
                                eligible[f] = true
                                if rec.language == 'c' or rec.language == 'cpp' then
                                    eligible[f] = root_files[f] or false
                                    if not eligible[f] then
                                        local visible, paired = graph.visible_dependencies(G, f, ctx)
                                        for root in pairs(root_files) do if visible[root] or paired[root] then eligible[f] = true; break end end
                                    end
                                end
                            end
                            if not eligible[f] then break end
                            local key = f .. ':' .. i
                            if not positions[key] then
                                if stats.scanned_sites >= M.MAX_SITES then limited('type_reference_site_limit') end
                                positions[key] = true; stats.scanned_sites = stats.scanned_sites + 1
                                local site = (data(f).type_sites or {})[i]
                                if site then
                                    local from = refs.from[i] > 0 and G.id_of[f][refs.from[i]] or nil
                                    local ids, reason = M.resolve(G, f, from, site, ctx, data(f))
                                    if ctx.include_incomplete or ctx.workspace_incomplete or ctx.go_incomplete or ctx.go_methods_incomplete or ctx.rust_incomplete then limited('type_reference_binding_incomplete') end
                                    local target = matches(ids)
                                    if #ids == 1 and target then
                                        if #result.references >= (opts.max_nodes or 200) then result.node_limit_reached = true; limited('type_reference_result_limit') end
                                        result.references[#result.references + 1] = { file = rec.path, line = refs.line[i], first = site.first, last = site.last,
                                            role = site.role, written = site.written, target = target, source = from }
                                        local node = refs.from[i] > 0 and rec.nodes[refs.from[i]]
                                        if site.role == 'alias' and site.alias_name and node and node.kind == 'typedef' then
                                            roots[from] = target; root_files[f] = true; add_name(node.name)
                                        end
                                    elseif #ids > 1 then result.ambiguous_sites = result.ambiguous_sites + 1
                                    elseif reason ~= 'type parameter' and reason ~= 'value binding' then result.unresolved_sites = result.unresolved_sites + 1 end
                                end
                            end
                        end
                    end
                end
            end
            if before == name_count then break end
        end
    end)
    if not ok and err ~= stop then error(err, 0) end
    if ctx.include_incomplete or ctx.workspace_incomplete or ctx.go_incomplete or ctx.go_methods_incomplete or ctx.rust_incomplete then
        result.relationships_incomplete = true; stats.incomplete_reasons.type_reference_binding_incomplete = true
    end
    result.incomplete = result.relationships_incomplete or result.unresolved_sites > 0 or result.ambiguous_sites > 0
    table.sort(result.references, function(a, b) return a.file < b.file or a.file == b.file and a.first < b.first end)
    return result
end
local function run(G, idx, query, opts, retry)
    local budget = M.validate(query, opts)
    local filters = require('codeoutline.query_filters').parse(query)
    local ids = {}
    for number, id in ipairs(G.by_qualified[filters.text] or G.by_name[filters.text] or {}) do
        if number % 256 == 0 then control.check() end
        if M.kinds[G.nodes[id].kind] and languages[G.files[G.node_file[id]].language] and require('codeoutline.query_filters').id(filters, G, id) then
            ids[#ids + 1] = id
            if #ids > (opts.max_nodes or 200) then break end
        end
    end
    table.sort(ids, function(a, b) return graph.before(G, a, b) end)
    local options = {}; for key, value in pairs(opts or {}) do options[key] = value end; options.retry = retry
    local result = M.query(G, idx, ids, options)
    local lines = { string.format('Matched %d type(s); %d explicit type references.', #result.targets, #result.references),
        'Scope: indexed explicit type positions; no inference, runtime reflection or complete build coverage is claimed.' }
    for _, target in ipairs(result.targets) do lines[#lines + 1] = string.format('Target: %s (%s:%d)', target.name, target.file, target.line) end
    for _, ref in ipairs(result.references) do lines[#lines + 1] = string.format('- %s:%d [%s] %s', ref.file, ref.line, ref.role, ref.written) end
    if #ids == 0 then lines[#lines + 1] = 'No supported type matched; use an exact type name or qualified name.' end
    if result.incomplete then lines[#lines + 1] = string.format('Coverage incomplete; %d unresolved and %d ambiguous candidate sites.', result.unresolved_sites, result.ambiguous_sites) end
    local output, cut = require('codeoutline.text').limit(table.concat(lines, '\n'), budget, result.node_limit_reached)
    result.truncated = cut; return output, result
end
function M.run(G, idx, query, opts)
    local retry = {}
    local ok, output, info = pcall(run, G, idx, query, opts or {}, retry)
    if not ok and output == retry then return nil, { encoding_retry = true } end
    if not ok then error(output, 0) end
    return output, info
end
return M
