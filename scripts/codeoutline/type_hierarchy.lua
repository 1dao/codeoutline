-- Declared type relationships over resident headers, resolved only for this query.
local M = { MAX_CANDIDATES = 512, MAX_SCAN_NODES = 1000000, MAX_FILES = 128,
    MAX_BYTES = 8 * 1024 * 1024, MAX_BASES = 64, MAX_EDGES = 4096 }
local graph = require('codeoutline.graph')
local control = require('codeoutline.control')
local kinds = { class = true, interface = true, struct = true, record = true }
local languages = { csharp = true, java = true, kotlin = true, typescript = true, cpp = true }

function M.validate(query, opts)
    local budget = require('codeoutline.explore').validate(query, opts)
    opts = opts or {}
    for _, item in ipairs({ { 'depth', 8, 32 }, { 'max_nodes', 200, 2000 } }) do
        local value = opts[item[1]]
        if value == nil then value = item[2] end
        assert(type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= item[3],
            item[1] .. ' must be an integer between 1 and ' .. item[3])
    end
    assert(opts.direction == nil or opts.direction == 'ancestors' or opts.direction == 'descendants' or opts.direction == 'both',
        'direction must be ancestors, descendants or both')
    return budget
end

local function bases(n)
    local out = {}
    for _, value in ipairs(n.bases or {}) do out[#out + 1] = { written = value } end
    for _, value in ipairs(n.extends or {}) do out[#out + 1] = { written = value, kind = 'extends' } end
    for _, value in ipairs(n.implements or {}) do out[#out + 1] = { written = value, kind = 'implements' } end
    return out
end

local function run(G, idx, query, opts, retry)
    local budget = M.validate(query, opts)
    local depth, cap, direction = opts.depth or 8, opts.max_nodes or 200, opts.direction or 'both'
    local result = { targets = {}, ancestors = {}, descendants = {}, unresolved = {}, edges = {},
        depth = depth, direction = direction, node_limit_reached = false, depth_limit_reached = false,
        relationships_incomplete = false, cycle_detected = false,
        query_stats = { scanned_nodes = 0, candidates = 0, source_files = 0, source_bytes = 0, reverse_unresolved = 0 } }
    local stats, limited = result.query_stats, {}
    local ctx = require('codeoutline.js_resolution').context(G)
    ctx.include_paths = opts.include_paths
    local loaded, summaries, parents, issues = {}, {}, {}, {}
    local function source(f)
        if not loaded[f] then
            if stats.source_files >= M.MAX_FILES or stats.source_bytes + (G.files[f].size or 0) > M.MAX_BYTES then
                result.candidate_limit_reached = true; error(limited, 0)
            end
            loaded[f] = true
            stats.source_files = stats.source_files + 1
            stats.source_bytes = stats.source_bytes + (G.files[f].size or 0)
        end
        if idx then
            local path = G.files[f].path
            local raw, repaired = idx:query_source(path)
            if repaired then error(retry, 0) end
            assert(raw, 'cannot read source: ' .. path)
            return raw
        end
    end
    ctx.ordinary = require('codeoutline.ordinary_bindings').context(G, ctx,
        (idx or G.root) and function(f)
            if idx then return source(f) end
            source(f) -- enforce the same budget for direct graph embeddings
        end or nil)
    stats.ordinary = ctx.ordinary.stats
    local function guard(fn)
        local ok, value = pcall(fn)
        if ok then return value end
        if value ~= limited then error(value, 0) end
    end
    local function data(f)
        if not summaries[f] then
            if not idx and not G.root then source(f) end
            local d = ctx.ordinary.data(f)
            -- Share the source FIFO; retain only bounded declaration and alias summaries.
            local evidence = {}
            for i, n in ipairs(G.files[f].nodes) do
                if kinds[n.kind] then evidence[i] = (d.implementation_evidence or {})[i] end
            end
            summaries[f] = { evidence = evidence, aliases = d.cpp_aliases or {} }
        end
        return summaries[f]
    end
    local function describe(id)
        local n, f = G.nodes[id], G.node_file[id]
        return { id = id, name = n.qualified, kind = n.kind, language = G.files[f].language,
            file = G.files[f].path, line = n.line }
    end
    local function info(id)
        local f = G.node_file[id]
        return data(f).evidence[id - G.id_of[f][1] + 1]
    end
    local function supported(id)
        return kinds[G.nodes[id].kind] and languages[G.files[G.node_file[id]].language]
    end
    local function direct(id)
        if parents[id] then return parents[id] end
        local out, missing, seen = {}, {}, {}
        parents[id], issues[id] = out, missing
        local n, f = G.nodes[id], G.node_file[id]
        local language, declared = G.files[f].language, bases(n)
        local ok = guard(function()
            local evidence = info(id)
            -- Existing parsers erase generic arguments from resident base names.
            -- Never turn that erasure into a non-generic relationship.
            if #declared > 0 and (not evidence or not evidence.hierarchy_bases or evidence.generic or evidence.unsupported
                or language == 'typescript' and (n.parent or evidence.declare)) then
                for index, base in ipairs(declared) do
                    if index > M.MAX_BASES then result.candidate_limit_reached = true; break end
                    missing[#missing + 1] = { written = base.written, reason = 'unsupported declaration' }
                end
                return true
            end
            declared = evidence and evidence.hierarchy_bases or declared
            for index, base in ipairs(declared) do
                control.check()
                if index > M.MAX_BASES then
                    result.candidate_limit_reached = true
                    missing[#missing + 1] = { reason = 'base limit reached' }; break
                end
                local ids
                if language == 'cpp' then
                    ids = require('codeoutline.cpp_types').resolve(G, f, base.written, {
                        context = ctx, scope = n.qualified, at = evidence.at, accept = kinds,
                        undecorated = true, definitions = true, aliases = function(g) return data(g).aliases end })
                else
                    ids = require('codeoutline.implementations').types(G, f, base.written, ctx, n.qualified, evidence.at)
                end
                if #ids == 1 and supported(ids[1]) then
                    local parent = ids[1]
                    if not seen[parent] then
                        seen[parent] = true
                        local kind = base.kind or (G.nodes[parent].kind == 'interface'
                            and n.kind ~= 'interface' and 'implements' or 'extends')
                        out[#out + 1] = { source = id, target = parent, written = base.written,
                            kind = kind, file = G.files[f].path, line = n.line }
                    end
                else
                    missing[#missing + 1] = { written = base.written, reason = #ids > 1 and 'ambiguous type' or 'unresolved type' }
                end
            end
            return true
        end)
        if not ok then
            -- A resolver interrupted by a budget must not publish partial guesses.
            out = {}; parents[id] = out
            missing[#missing + 1] = { reason = 'source budget reached' }
        end
        if ctx.include_incomplete then
            result.candidate_limit_reached = true
            out = {}; parents[id] = out
            missing[#missing + 1] = { reason = 'include visibility budget reached' }
        end
        table.sort(out, function(a, b) return graph.before(G, a.target, b.target) end)
        return out
    end
    local ordered = {}
    for i, id in ipairs(G.by_qualified[query] or G.by_name[query] or {}) do
        if i % 256 == 0 then control.check() end
        if supported(id) and not G.nodes[id].decl then
            if #ordered >= cap then result.node_limit_reached = true; break end
            ordered[#ordered + 1] = id
        end
    end
    table.sort(ordered, function(a, b) return graph.before(G, a, b) end)
    local seeds, total, seed_names, seed_languages = {}, 0, {}, {}
    for _, id in ipairs(ordered) do
        if total >= cap then result.node_limit_reached = true; break end
        if guard(function() info(id); return true end) then
            seeds[#seeds + 1] = id; result.targets[#result.targets + 1] = describe(id); total = total + 1
            seed_names[G.nodes[id].name], seed_languages[G.files[G.node_file[id]].language] = true, true
        end
    end
    local reported, edge_seen = {}, {}
    local function report(id)
        if reported[id] then return end
        reported[id] = true
        for _, issue in ipairs(issues[id] or {}) do
            local entry = describe(id); entry.written, entry.reason = issue.written, issue.reason
            result.unresolved[#result.unresolved + 1] = entry
        end
    end
    local reverse
    local function descendants()
        if reverse then return reverse end
        reverse = {}
        -- No parallel resident index: scan compact declarations, never project source.
        -- Prefer literal base-name matches, then examine other declarations for aliases.
        local preferred, other, count, stop = {}, {}, 0, false
        for _, f in ipairs(G.file_order) do
            if stop then break end
            if seed_languages[G.files[f].language] then
                for _, id in ipairs(G.id_of[f]) do
                    stats.scanned_nodes = stats.scanned_nodes + 1
                    if stats.scanned_nodes % 1024 == 0 then control.check() end
                    if stats.scanned_nodes > M.MAX_SCAN_NODES then result.candidate_limit_reached = true; stop = true; break end
                    if supported(id) then
                        local list = bases(G.nodes[id])
                        if #list > 0 then
                            count = count + 1
                            local priority = false
                            for _, base in ipairs(list) do
                                if seed_names[base.written:match('([%w_$]+)$')] then priority = true end
                            end
                            local bucket = priority and preferred or other
                            if #bucket < M.MAX_CANDIDATES then bucket[#bucket + 1] = id end
                        end
                    end
                end
            end
        end
        if count > M.MAX_CANDIDATES then result.candidate_limit_reached = true end
        for _, bucket in ipairs({ preferred, other }) do
            for _, id in ipairs(bucket) do
                if stats.candidates >= M.MAX_CANDIDATES then break end
                control.check(); stats.candidates = stats.candidates + 1
                for _, edge in ipairs(direct(id)) do
                    reverse[edge.target] = reverse[edge.target] or {}
                    reverse[edge.target][#reverse[edge.target] + 1] = edge
                end
                if #issues[id] > 0 then stats.reverse_unresolved = stats.reverse_unresolved + 1 end
            end
        end
        for _, list in pairs(reverse) do table.sort(list, function(a, b) return graph.before(G, a.source, b.source) end) end
        return reverse
    end
    local function walk(up, entries)
        local seen, paths, frontier = {}, {}, {}
        for _, id in ipairs(seeds) do seen[id], paths[id] = true, { id }; frontier[#frontier + 1] = id end
        for level = 0, depth do
            local next_level = {}
            for _, id in ipairs(frontier) do
                control.check()
                local list = up and direct(id) or descendants()[id] or {}
                if up then report(id) end
                for _, edge in ipairs(list) do
                    local target = up and edge.target or edge.source
                    if not seen[target] then
                        if level == depth then result.depth_limit_reached = true
                        elseif total >= cap then result.node_limit_reached = true
                        elseif guard(function() info(target); return true end) then
                            seen[target], total = true, total + 1
                            local path = {}; for _, step in ipairs(paths[id]) do path[#path + 1] = step end
                            path[#path + 1] = target; paths[target] = path
                            local entry = describe(target); entry.depth, entry.path, entry.via = level + 1, {}, edge
                            for _, step in ipairs(path) do entry.path[#entry.path + 1] = describe(step) end
                            entries[#entries + 1] = entry; next_level[#next_level + 1] = target
                            if not up then report(target) end
                        end
                    end
                    if seen[target] then
                        local key = edge.source .. ':' .. edge.target
                        if not edge_seen[key] then
                            if #result.edges >= M.MAX_EDGES then result.candidate_limit_reached = true
                            else edge_seen[key] = true; result.edges[#result.edges + 1] = edge end
                        end
                    end
                end
            end
            frontier = next_level
            if #frontier == 0 then break end
        end
    end
    if #seeds > 0 then
        if direction ~= 'descendants' then walk(true, result.ancestors) end
        if direction ~= 'ancestors' then walk(false, result.descendants) end
    end
    -- Check only returned relationships; diamonds are not cycles.
    local adjacency, colors = {}, {}
    for _, edge in ipairs(result.edges) do
        adjacency[edge.source] = adjacency[edge.source] or {}; table.insert(adjacency[edge.source], edge.target)
    end
    local function visit(id)
        control.check()
        if colors[id] == 1 then result.cycle_detected = true; return end
        if colors[id] then return end
        colors[id] = 1
        for _, parent in ipairs(adjacency[id] or {}) do visit(parent) end
        colors[id] = 2
    end
    for id in pairs(adjacency) do visit(id) end
    result.relationships_incomplete = result.candidate_limit_reached or result.node_limit_reached or result.depth_limit_reached
        or result.cycle_detected or #result.unresolved > 0 or stats.reverse_unresolved > 0 or false
    local lines = { string.format('Matched %d type(s); %d ancestors, %d descendants.', #seeds, #result.ancestors, #result.descendants),
        'Declared type relationships only; no structural compatibility, runtime dispatch or implicit library bases are inferred.' }
    if #seeds == 0 then lines[#lines + 1] = 'No supported type matched; use an exact type name or qualified name (C#, Java, Kotlin, TS, C++).' end
    if #seeds > 1 then lines[#lines + 1] = 'Multiple declarations matched; relationships cover the listed targets.' end
    if result.node_limit_reached then lines[#lines + 1] = 'Node limit reached; some types were omitted.' end
    if result.depth_limit_reached then lines[#lines + 1] = 'Depth limit reached; deeper types were omitted.' end
    if result.candidate_limit_reached then lines[#lines + 1] = 'Candidate/source budget reached; relationships are incomplete.' end
    if result.cycle_detected then lines[#lines + 1] = 'Inheritance cycle detected; relationships are incomplete.' end
    if stats.reverse_unresolved > 0 then lines[#lines + 1] = string.format('%d reverse candidate(s) had unresolved/unsupported bases; descendants may be incomplete.', stats.reverse_unresolved) end
    for _, target in ipairs(result.targets) do lines[#lines + 1] = string.format('Target: %s (%s:%d)', target.name, target.file, target.line) end
    for _, group in ipairs({ { 'Ancestor', result.ancestors }, { 'Descendant', result.descendants } }) do
        for _, entry in ipairs(group[2]) do
            local path = {}; for _, step in ipairs(entry.path) do path[#path + 1] = step.name end
            local edge = entry.via
            lines[#lines + 1] = string.format('%s depth %d: %s (%s:%d); path %s; declared %s %s at %s:%d',
                group[1], entry.depth, entry.name, entry.file, entry.line, table.concat(path, ' -> '),
                edge.kind, edge.written, edge.file, edge.line)
        end
    end
    for _, entry in ipairs(result.unresolved) do
        lines[#lines + 1] = string.format('Unresolved: %s -> %s (%s:%d): %s', entry.name,
            entry.written or '?', entry.file, entry.line, entry.reason)
    end
    local output, cut = require('codeoutline.text').limit(table.concat(lines, '\n'), budget)
    result.truncated = cut
    return output, result
end

function M.run(G, idx, query, opts)
    M.validate(query, opts)
    local retry = {}
    local ok, output, result = pcall(run, G, idx, query, opts or {}, retry)
    if not ok then
        if output == retry then return nil, { encoding_retry = true } end
        error(output, 0)
    end
    return output, result
end

return M
