-- explore.lua — answer "show me the code for X" in one call: find the
-- symbols a query names, connect them through the call graph, and return
-- their verbatim, line-numbered source within a byte budget.
--
--   local text, info = explore.run(G, idx, 'xtimer_poll xtimer_add', { budget = 16000 })
--
-- Output layout (the budget is spent top-down):
--   1. summary line + the call paths found between the named symbols
--   2. source of the named symbols, then of the symbols on those paths,
--      grouped by file, as `line<TAB>code` like the Read tool
--   3. callers / callees of the named symbols (locations only)
--   4. other matches that did not fit, as pointers
-- Big bodies are cut to head + tail; classes over the limit collapse to a
-- member outline; anything past the budget becomes a pointer line.

local graph = require('codeoutline.graph')
local text = require('codeoutline.text')
local control = require('codeoutline.control')

local M = {}

M.DEFAULT_BUDGET = 16000
M.MIN_BUDGET = 256
M.MAX_BUDGET = 262144

function M.validate(query, opts)
    assert(type(query) == 'string' and query:find('%S') and #query <= 4096 and not query:find('%z'),
        'query must contain 1-4096 bytes of non-empty text without NUL')
    assert(text.valid(query) == query, 'query must be valid UTF-8')
    require('codeoutline.query_filters').parse(query)
    assert(opts == nil or type(opts) == 'table', 'options must be a table')
    local budget = M.DEFAULT_BUDGET
    if opts and opts.budget ~= nil then budget = opts.budget end
    assert(type(budget) == 'number' and budget >= M.MIN_BUDGET and budget <= M.MAX_BUDGET and budget % 1 == 0,
        'budget must be an integer between 256 and 262144 bytes')
    return budget
end
M.MAX_SEEDS = 8
M.PATH_DEPTH = 4
M.SEED_FULL_LINES = 160       -- seeds up to this many lines are shown whole
M.SPINE_FULL_LINES = 60
M.CUT_HEAD, M.CUT_TAIL = 80, 15
M.LIST_CAP = 10
M.CONTEXT_SEED_LINES = 25     -- seeds shorter than this bring their same-file callees
M.CONTEXT_PER_SEED = 3

local KIND_WEIGHT = {
    ['function'] = 10, method = 10, constructor = 8, class = 9, interface = 9, record = 9,
    struct = 7, union = 6, enum = 6, typedef = 5, macro = 5, prototype = 3,
    variable = 3, field = 2, enum_member = 2,
}

-- Words that show up in questions but never name the code being asked about.
local STOP = {}
for w in ([[the a an and or of to in on for with from by is are was be how what where
    why when which who does do did can could should would this that these those it its
    show find explain code function method class file files call calls called caller
    callers flow work works use used using get set make new add list all into about
    return returns value values type types between through does]]):gmatch('%a+') do
    STOP[w] = true
end

-- Split camelCase / snake_case into lowercase segments.
local function segments(name)
    local out = {}
    for part in name:gsub('(%l)(%u)', '%1_%2'):gmatch('[%w]+') do
        out[#out + 1] = part:lower()
    end
    return out
end

local SOURCE_EXT = {}
for e in ('c h py pyi java kt kts lua cpp cc cxx hpp hh hxx'):gmatch('%a+') do SOURCE_EXT[e] = true end

-- Query -> candidate terms: qualified chains, identifiers, file names.
local function terms(query)
    local out, seen = {}, {}
    local function add(kind, text)
        local key = kind .. ':' .. text
        if not seen[key] then seen[key] = true; out[#out + 1] = { kind = kind, text = text } end
    end
    for chain in query:gmatch('[%a_][%w_]*[%.:%->]+[%a_][%w_%.:%->]*') do
        if chain:match('%.%a+$') and chain:match('^[%w_/%-]+%.%a+$') and not chain:find('::') then
            add('file', chain)
        end
        local parts = {}
        for p in chain:gmatch('[%a_][%w_]*') do parts[#parts + 1] = p end
        if #parts >= 2 then
            add('qualified', table.concat(parts, '.'))
            -- the chain speaks for its parts; `subprocess.run` must not also
            -- pull in every `run` in the project as a loose word
            for _, p in ipairs(parts) do seen['name:' .. p] = true; seen['word:' .. p] = true end
        end
    end
    for path in query:gmatch('[%w_%-%./]+%.%a%a?%a?%a?') do
        local ext = path:match('%.(%a+)$')
        if path:find('/') or (ext and SOURCE_EXT[ext:lower()]) then add('file', path) end
    end
    for word in query:gmatch('[%a_][%w_]*') do
        if #word >= 3 and not STOP[word:lower()] then
            -- "code-like" words (snake_case, camelCase, digits) name symbols;
            -- plain lowercase words are usually English from the question.
            local code = word:find('_') or word:find('%d') or word:find('%l%u') or word:find('^%u')
            add(code and 'name' or 'word', word)
        end
    end
    return out
end

local function find_seeds(G, query, filters, ranking)
    local predicate = require('codeoutline.query_filters')
    local function seed_score(id, exact, explicit)
        local s = (KIND_WEIGHT[G.nodes[id].kind] or 1) + (exact and 20 or 0)
        return s - ranking.penalty(G.files[G.node_file[id]].path, explicit)
    end
    local cands = {}          -- id -> score
    local files = {}          -- file indices named in the query
    local considered = 0
    local function consider(id, s)
        considered = considered + 1
        if considered % 128 == 0 then control.check() end
        if not predicate.id(filters, G, id) then return end
        if not cands[id] or cands[id] < s then cands[id] = s end
        return true
    end
    local list_terms = terms(query)
    local has_code = false
    for _, t in ipairs(list_terms) do
        if t.kind ~= 'word' then has_code = true end
    end
    for _, t in ipairs(list_terms) do
        control.check()
        if t.kind == 'word' then
            -- Plain words count only as exact names (no case folding or fuzzy
            -- matching, which is where English words pick up noise), and rank
            -- below code-like terms when the query has any.
            for _, id in ipairs(G.by_name[t.text] or {}) do
                consider(id, seed_score(id, true) - (has_code and 12 or 8))
            end
        elseif t.kind == 'file' then
            local want = t.text:gsub('\\', '/')
            for i, f in ipairs(G.file_order) do
                if i % 128 == 0 then control.check() end
                local rec = G.files[f]
                if (rec.path == want or rec.path:sub(-(#want + 1)) == '/' .. want) and predicate.file(filters, rec) then
                    for _, node in ipairs(rec.nodes) do
                        if predicate.node(filters, rec, node) then files[#files + 1] = f; break end
                    end
                end
            end
        elseif t.kind == 'qualified' then
            local last = t.text:match('([%w_]+)$')
            local first = t.text:match('^([%w_]+)')
            for i, id in ipairs(G.by_name[last] or {}) do
                if i % 128 == 0 then control.check() end
                local q = G.nodes[id].qualified:gsub('[:]+', '.')
                if q == t.text or q:sub(-(#t.text + 1)) == '.' .. t.text then
                    consider(id, seed_score(id, true, true) + 10)
                elseif select(2, t.text:gsub('%.', '')) == 1
                    and G.files[G.node_file[id]].path:match('([^/]+)%.[^./]+$') == first then
                    -- module.func where the module is the file: Lua's `local M`
                    -- tables and Python modules are named by their file
                    consider(id, seed_score(id, true, true) + 8)
                end
            end
        else
            local exact = G.by_name[t.text]
            if exact then
                -- a name defined in many places is generic; keep its best few
                for _, id in ipairs(exact) do consider(id, seed_score(id, true) - math.min(#exact, 20) * 0.2) end
            else
                local ci = G.by_lname[t.text:lower()]
                if ci then
                    for _, id in ipairs(ci) do consider(id, seed_score(id, true) - 2) end
                elseif #t.text >= 4 then
                    -- fuzzy: every query segment appears in the name's segments
                    local want = segments(t.text)
                    local hits, visited = 0, 0
                    for name, ids in pairs(G.by_name) do
                        visited = visited + 1
                        if visited % 128 == 0 then control.check() end
                        local lname = name:lower()
                        local ok = true
                        for _, w in ipairs(want) do
                            if not lname:find(w, 1, true) then ok = false; break end
                        end
                        if ok then
                            local accepted = false
                            for _, id in ipairs(ids) do
                                if consider(id, seed_score(id, false) - #name * 0.05) then accepted = true end
                            end
                            if accepted then hits = hits + 1 end
                            if hits > 200 then break end
                        end
                    end
                end
            end
        end
    end
    if query == '' then
        local count = 0
        -- With a configured policy, select the candidate window from preferred
        -- files first so an early generated directory cannot fill all 512 slots.
        for pass = 1, ranking.configured and 2 or 1 do
            for _, f in ipairs(G.file_order) do
                control.check()
                local rec = G.files[f]
                if predicate.file(filters, rec) and (not ranking.configured
                    or (ranking.penalty(rec.path) > 0) == (pass == 2)) then
                    for i, id in ipairs(G.id_of[f]) do
                        if i % 256 == 0 then control.check() end
                        if predicate.id(filters, G, id) then
                            if count >= 512 then filters.seed_limit_reached = true; break end
                            consider(id, seed_score(id, false)); count = count + 1
                        end
                    end
                end
                if filters.seed_limit_reached then break end
            end
            if filters.seed_limit_reached then break end
        end
    end
    local list = {}
    for id, s in pairs(cands) do
        if #list % 128 == 0 then control.check() end
        list[#list + 1] = { id = id, s = s }
    end
    table.sort(list, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return graph.before(G, a.id, b.id)
    end)
    return list, files
end

-- Shortest call path a -> b (out edges), up to depth; returns id list.
local function path_between(G, a, b, depth)
    local prev, frontier = { [a] = a }, { a }
    local expansion_limited = false
    for _ = 1, depth do
        local next_frontier = {}
        for _, x in ipairs(frontier) do
            control.check()
            local out = G.out[x]
            if out == nil and G.incomplete then expansion_limited = true end
            out = out or {}
            for i = 1, #out, graph.EDGE do
                if i % 128 == 1 then control.check() end
                local dst = out[i]
                if not prev[dst] then
                    prev[dst] = x
                    if dst == b then
                        local path, y = { b }, b
                        while y ~= a do y = prev[y]; table.insert(path, 1, y) end
                        return path
                    end
                    next_frontier[#next_frontier + 1] = dst
                end
            end
        end
        frontier = next_frontier
        if #frontier == 0 then return nil, false, prev, expansion_limited end
        if #frontier > 20000 then return nil, true, prev, expansion_limited end
    end
    return nil, #frontier > 0, prev, expansion_limited
end

local file_cache = {}
local function file_lines(idx, rel)
    local key = idx.root .. '/' .. rel
    local lines = file_cache[key]
    if lines then return lines end
    lines = {}
    local src = assert(idx:query_source(rel), 'cannot read source: ' .. rel)
    if src then
        for line in (src .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = (line:gsub('\r$', '')) end
    end
    file_cache[key] = lines
    return lines
end

local function render_range(lines, a, b, out)
    for i = a, math.min(b, #lines) do
        out[#out + 1] = string.format('%d\t%s', i, lines[i])
    end
end

-- Source block for one node, cut to `full` lines (head + tail beyond).
-- Classes/structs over the limit collapse to their member outline.
local function node_block(G, idx, id, full)
    local node = G.nodes[id]
    local lines = file_lines(idx, G.files[G.node_file[id]].path)
    local a, b = node.line, math.max(node.end_line, node.line)
    local out = {}
    local span = b - a + 1
    if span <= full then
        render_range(lines, a, b, out)
    else
        local kids = G.children[id]
        local container = node.kind == 'class' or node.kind == 'interface' or node.kind == 'record'
            or node.kind == 'struct' or node.kind == 'enum' or node.kind == 'union'
        if container and kids and #kids > 0 then
            render_range(lines, a, a, out)
            -- one outline row per line: `int a, b;` declares two fields on
            -- one line and the later signature covers both
            local rows, row_lines = {}, {}
            for _, k in ipairs(kids) do
                local kn = G.nodes[k]
                if not rows[kn.line] then row_lines[#row_lines + 1] = kn.line end
                rows[kn.line] = require('codeoutline.navigation').detail(G, G.node_file[k], kn).sig or kn.name
            end
            for _, ln in ipairs(row_lines) do
                out[#out + 1] = string.format('%d\t    %s', ln, rows[ln])
            end
            out[#out + 1] = string.format('\t... (%s body of %d lines outlined; explore a member for its source)', node.kind, span)
        else
            render_range(lines, a, a + M.CUT_HEAD - 1, out)
            out[#out + 1] = string.format('\t... (%d lines omitted) ...', span - M.CUT_HEAD - M.CUT_TAIL)
            render_range(lines, b - M.CUT_TAIL + 1, b, out)
        end
    end
    return table.concat(out, '\n'), span > full
end

local function label(G, id)
    local node = G.nodes[id]
    return string.format('%s %s (%s)', node.kind, node.qualified, graph.where(G, id))
end

local function candidate_text(G, idx, report, in_order)
    if #report.entries == 0 then return nil end
    local lines = { '\n## Unconfirmed definition candidates',
        'Suggestions for unresolved calls only, not call edges or verified bindings. Inspect the source before using them.' }
    local shown = {}
    for _, group in ipairs(report.entries) do
        lines[#lines + 1] = string.format('- Unresolved %s at %s:%d: %s', group.call, group.path, group.line, group.resolution_reason)
        for _, candidate in ipairs(group.candidates) do
            local id = candidate.id
            lines[#lines + 1] = '  Unconfirmed candidate: ' .. label(G, id) .. '; ' .. candidate.reason
            if not in_order[id] and not shown[id] then
                local node = G.nodes[id]
                render_range(file_lines(idx, candidate.path), node.line, math.min(node.end_line, node.line + 7), lines)
                if node.end_line > node.line + 7 then lines[#lines + 1] = '\t... (candidate snippet only; explore its file and name for more)' end
                shown[id] = true
            end
        end
    end
    if report.truncated then lines[#lines + 1] = 'Candidate lookup reached a site, source, evidence or result limit; more candidates may exist.' end
    return table.concat(lines, '\n')
end

-- Run a query over symbol tables (graph.build). Returns the text and a table
-- with what was selected; relationships resolve per query.
function M.run(G, idx, query, opts)
    control.check()
    opts = opts or {}
    local budget = M.validate(query, opts)
    local query_opts = {}
    for key, value in pairs(opts) do query_opts[key] = value end
    query_opts.explain = true
    local ranking = require('codeoutline.search_ranking').policy(G.root or idx.root)
    G = graph.query(G, query_opts)
    G.stats.ranking = ranking.stats
    file_cache = {}
    local filters = require('codeoutline.query_filters').parse(query)
    local ranked, named_files = find_seeds(G, filters.text, filters, ranking)

    -- Seeds: top-ranked, but at most 3 definitions per name so one generic
    -- name can't crowd out the others the query mentions.
    -- A prototype only earns a seed slot when its name has no definition
    -- among the matches (the definition's source is what the caller wants).
    local defined = {}
    for _, c in ipairs(ranked) do
        local node = G.nodes[c.id]
        if node.kind ~= 'prototype' and not node.decl then defined[node.name] = true end
    end
    local seeds, per_name = {}, {}
    for _, c in ipairs(ranked) do
        local node = G.nodes[c.id]
        local name = node.name
        if not ((node.kind == 'prototype' or node.decl) and defined[name]) then
            per_name[name] = (per_name[name] or 0) + 1
            if per_name[name] <= 3 and #seeds < M.MAX_SEEDS then seeds[#seeds + 1] = c.id end
        end
    end
    local is_seed = {}
    for _, id in ipairs(seeds) do is_seed[id] = true end

    -- Spine: nodes on call paths between seeds.
    local flows, spine, on_spine = {}, {}, {}
    local reports = require('codeoutline.query_report')
    local searches, missed, connected = {}, {}, {}
    local path_limited = false
    for _, a in ipairs(seeds) do
        for _, b in ipairs(seeds) do
            if a ~= b then
                local p, limited, prev, expansion_limited = path_between(G, a, b, M.PATH_DEPTH)
                path_limited = path_limited or limited or false
                if p then
                    connected[a] = connected[a] or {}
                    connected[a][b] = true
                    local names = {}
                    for _, id in ipairs(p) do
                        names[#names + 1] = G.nodes[id].name
                        if not is_seed[id] and not on_spine[id] then
                            on_spine[id] = true
                            spine[#spine + 1] = id
                        end
                    end
                    flows[#flows + 1] = table.concat(names, ' -> ')
                else
                    if not missed[a] then
                        missed[a] = { root = a, targets = {}, limited = limited, incomplete = expansion_limited,
                            sites = reports.capture_paths(G.report, prev, a) }
                        searches[#searches + 1] = missed[a]
                    end
                    missed[a].targets[#missed[a].targets + 1] = b
                end
            end
        end
    end

    local parts, used, omitted = {}, 0, false
    local function emit(s)
        parts[#parts + 1] = s
        used = used + #s + 1
    end
    local shown, files_shown, file_order = {}, {}, {}

    if #seeds == 0 and #named_files == 0 then
        return 'No symbols matched. Name functions, classes, or files (e.g. "xtimer_poll", "Session.save", "xpoll.c").', { seeds = {} }
    end

    -- Section 1: summary + flows.
    local nfiles = {}
    for _, id in ipairs(seeds) do nfiles[G.node_file[id]] = true end
    for _, id in ipairs(spine) do nfiles[G.node_file[id]] = true end
    local nf = 0
    for _ in pairs(nfiles) do nf = nf + 1 end
    emit(string.format('Matched %d symbols in %d files, %d more on call paths between them; short ones bring their callees. Source below is verbatim with line numbers; treat it as already Read.',
        #seeds, nf, #spine))
    if #flows > 0 then
        emit('\n## Call paths')
        for i = 1, math.min(#flows, M.LIST_CAP) do emit('  ' .. flows[i]) end
    end

    -- Section 2: source, grouped by file in first-appearance order.
    local order = {}
    for _, id in ipairs(seeds) do order[#order + 1] = { id = id, full = M.SEED_FULL_LINES } end
    for _, id in ipairs(spine) do order[#order + 1] = { id = id, full = M.SPINE_FULL_LINES } end
    -- One hop of context: a short named function is usually a wrapper, and
    -- the code the caller actually wants is what it calls. Same-file callees
    -- of short seeds ride along (budget permitting) so no follow-up is needed.
    local in_order = {}
    for _, item in ipairs(order) do in_order[item.id] = true end
    for _, id in ipairs(seeds) do
        local node = G.nodes[id]
        if node.end_line - node.line < M.CONTEXT_SEED_LINES then
            local added = 0
            local out = G.out[id] or {}
            for i = 1, #out, graph.EDGE do
                if added >= M.CONTEXT_PER_SEED then break end
                local dst = out[i]
                local k = G.nodes[dst].kind
                if not in_order[dst] and G.node_file[dst] == G.node_file[id] and (k == 'function' or k == 'method') then
                    in_order[dst] = true
                    order[#order + 1] = { id = dst, full = M.SPINE_FULL_LINES }
                    added = added + 1
                end
            end
        end
    end
    local by_file, pointers = {}, {}
    for _, item in ipairs(order) do
        local f = G.node_file[item.id]
        if not by_file[f] then by_file[f] = {}; file_order[#file_order + 1] = f end
        table.insert(by_file[f], item)
    end
    -- Files named directly: an outline of their top-level symbols.
    for _, f in ipairs(named_files) do
        if not by_file[f] then by_file[f] = {}; file_order[#file_order + 1] = f end
        by_file[f].outline = true
    end

    if G.load_incoming then G:load_incoming(seeds) end
    -- Neighbors below already require these scans. Run them before diagnostics,
    -- including for long seeds that did not take the short-wrapper context path.
    for _, id in ipairs(seeds) do local _ = G.out[id] end
    if #seeds == 1 then
        searches[1] = { root = seeds[1], targets = {}, single = true,
            sites = reports.capture_paths(G.report, { [seeds[1]] = seeds[1] }, seeds[1]) }
    end
    local breakpoints = reports.path_breakpoints(G.report, G, searches, connected)
    local candidates = G:definition_candidates()
    G.stats.definition_candidates = candidates.stats

    -- Confirm every file whose source or symbol labels this query can emit.
    -- GBK reparsing invalidates node IDs, so rebuild and select again before
    -- producing any output. Unrelated project files remain speculative.
    local selected, changed = {}, false
    for _, f in ipairs(file_order) do selected[f] = true end
    for _, c in ipairs(ranked) do selected[G.node_file[c.id]] = true end
    for _, id in ipairs(seeds) do
        for _, edges in ipairs({ G.inn[id] or {}, G.out[id] or {} }) do
            for i = 1, #edges, graph.EDGE do selected[G.node_file[edges[i]]] = true end
        end
    end
    for _, entry in ipairs(breakpoints.entries) do
        for _, id in ipairs(entry.path) do selected[G.node_file[id]] = true end
        if entry.goal then selected[G.node_file[entry.goal]] = true end
    end
    for _, group in ipairs(candidates.entries) do
        for _, candidate in ipairs(group.candidates) do selected[G.node_file[candidate.id]] = true end
    end
    for f in pairs(selected) do
        local path = G.files[f].path -- a decoding repair replaces this file ID
        local source, repaired = idx:query_source(path)
        assert(source, 'cannot read source: ' .. path)
        changed = repaired or changed
    end
    if changed then return nil, { encoding_retry = true } end

    local evidence_text = reports.render(G.report, G)
    local evidence_budget = math.min(4096, math.floor(budget / 4))
    local breakpoint_text = reports.render_breakpoints(breakpoints, G)
    local breakpoint_budget = breakpoint_text and math.floor(evidence_budget / 2) or 0
    evidence_budget = evidence_budget - breakpoint_budget
    local breakpoint_cut = breakpoint_text and (#breakpoint_text > breakpoint_budget or breakpoints.truncated) or false
    if breakpoint_budget >= 256 then emit(text.limit(breakpoint_text, breakpoint_budget, breakpoints.truncated))
    elseif breakpoint_text then breakpoint_cut = true end
    omitted = omitted or breakpoint_cut
    local evidence_cut = #evidence_text > evidence_budget
    if evidence_budget >= 256 then
        emit(text.limit(evidence_text, evidence_budget, G.report.truncated))
    else evidence_cut = #G.report.entries > 0 end
    omitted = omitted or evidence_cut or G.report.truncated or #flows > M.LIST_CAP

    local candidate_block = candidate_text(G, idx, candidates, in_order)
    local candidate_budget = math.min(3072, math.floor(budget / 5))
    local candidate_cut = candidate_block and (#candidate_block > candidate_budget or candidates.truncated) or candidates.truncated
    if candidate_block and candidate_budget >= 256 then emit(text.limit(candidate_block, candidate_budget, candidates.truncated))
    elseif candidate_block then candidate_cut = true end
    omitted = omitted or candidate_cut

    local reserve = math.floor(budget * 0.15)     -- keep room for sections 3-4
    for _, f in ipairs(file_order) do
        local rec = G.files[f]
        local header = '\n## ' .. rec.path
        local items = by_file[f]
        table.sort(items, function(a, b) return G.nodes[a.id].line < G.nodes[b.id].line end)
        local wrote_header = false
        if items.outline then
            local ol = {}
            for _, node in ipairs(rec.nodes) do
                if not node.parent and node.kind ~= 'macro' and require('codeoutline.query_filters').node(filters, rec, node) then
                    ol[#ol + 1] = string.format('%d\t%s %s', node.line, node.kind, require('codeoutline.navigation').detail(G, f, node).sig or node.name)
                end
                if #ol >= 60 then ol[#ol + 1] = '\t...'; break end
            end
            local block = header .. ' (outline)\n' .. table.concat(ol, '\n')
            if used + #block < budget - reserve then emit(block); wrote_header = true else omitted = true end
        end
        for _, item in ipairs(items) do
            if not shown[item.id] then
                local block, source_cut = node_block(G, idx, item.id, item.full)
                omitted = omitted or source_cut
                local need = #block + (wrote_header and 0 or #header + 1) + 1
                if used + need < budget - reserve then
                    if not wrote_header then emit(header); wrote_header = true end
                    emit(block)
                    shown[item.id] = true
                    files_shown[f] = true
                else
                    pointers[#pointers + 1] = item.id
                end
            end
        end
    end

    -- Section 3: neighbors of the named symbols.
    local rel = {}
    for _, id in ipairs(seeds) do
        local callers, callees = {}, {}
        local seen_in, seen_out = {}, {}
        local inn, out = G.inn[id] or {}, G.out[id] or {}
        for i = 1, #inn, graph.EDGE do
            local src = inn[i]
            if not seen_in[src] and #callers < M.LIST_CAP then
                seen_in[src] = true
                callers[#callers + 1] = string.format('%s (%s:%d)', G.nodes[src].name, G.files[G.node_file[src]].path, inn[i + 1])
                    .. (inn[i + 2]:match('^indirect:') and (' [' .. inn[i + 2] .. ']') or '')
            elseif not seen_in[src] then omitted = true
            end
        end
        for i = 1, #out, graph.EDGE do
            local dst = out[i]
            if not seen_out[dst] and #callees < M.LIST_CAP then
                seen_out[dst] = true
                callees[#callees + 1] = G.nodes[dst].name .. ' (' .. graph.where(G, dst) .. ')'
                    .. (out[i + 2]:match('^indirect:') and (' [' .. out[i + 2] .. ']') or '')
            elseif not seen_out[dst] then omitted = true
            end
        end
        if #callers > 0 or #callees > 0 then
            local nsites = math.floor(#inn / graph.EDGE)
            rel[#rel + 1] = string.format('%s:\n  called by%s: %s\n  calls: %s', G.nodes[id].qualified,
                nsites > #callers and string.format(' (%d call sites)', nsites) or '',
                #callers > 0 and table.concat(callers, ', ') or '-',
                #callees > 0 and table.concat(callees, ', ') or '-')
        end
    end
    if #rel > 0 then
        local block = '\n## Callers / callees\n' .. table.concat(rel, '\n')
        emit(block)
    end

    -- Section 4: pointers for everything that matched but was not shown.
    local more = {}
    for _, id in ipairs(pointers) do more[#more + 1] = '  ' .. label(G, id) end
    local extra = 0
    for _, c in ipairs(ranked) do
        if not shown[c.id] and not is_seed[c.id] then
            extra = extra + 1
            if #more < 15 then more[#more + 1] = '  ' .. label(G, c.id) end
        end
    end
    if #more > 0 then
        local block = '\n## Not shown (explore these by name for their source)\n' .. table.concat(more, '\n')
        if extra + #pointers > #more then block = block .. string.format('\n  ... %d more', extra + #pointers - #more) end
        if used + #block <= budget + 400 then emit(block) else omitted = true end
    end

    if G.incomplete then
        table.insert(parts, 1, 'Call-path expansion limit reached; relationships are incomplete.')
        omitted = true
    end
    if path_limited then
        table.insert(parts, 1, 'Call-path search reached its depth/frontier limit; no path found is not proof of no runtime connection.')
    end
    if evidence_cut or G.report.truncated then
        table.insert(parts, 1, 'Relationship explanations omitted due to evidence/output limits.')
    end
    if breakpoint_cut then
        table.insert(parts, 1, 'Call-path breakpoint explanations omitted due to site/evidence/output limits.')
    end
    if filters.seed_limit_reached then table.insert(parts, 1, 'Seed selection stopped after 512 matching candidates; narrow the query filters.') end
    if candidate_cut then table.insert(parts, 1, 'Unconfirmed definition candidates were limited or omitted; they are not call edges.') end
    local result, truncated = text.limit(table.concat(parts, '\n'), budget, omitted or #pointers > 0)
    return result, { seeds = seeds, spine = spine, shown = shown, flows = flows, truncated = truncated,
        relationships_incomplete = G.incomplete or false, query_stats = G.stats,
        seed_limit_reached = filters.seed_limit_reached or false,
        evidence = G.report.entries, evidence_truncated = evidence_cut or G.report.truncated,
        unresolved_candidates = candidates.entries, unresolved_candidates_truncated = candidate_cut or false,
        path_search_limited = path_limited, evidence_scope = G.report.scope,
        path_breakpoints = breakpoints.entries, path_breakpoints_truncated = breakpoint_cut }
end

return M
