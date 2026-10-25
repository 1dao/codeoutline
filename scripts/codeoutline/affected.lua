-- File changes seed one shared reverse traversal; no persistent impact graph.
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local callers = require('codeoutline.callers')
local text = require('codeoutline.text')
local M = { MAX_FILES = 128, TIME_LIMIT_MS = 700 }

local function checked(path)
    assert(type(path) == 'string' and #path > 0 and #path <= 4096
        and not path:find('[%z\r\n]'), 'files must contain non-empty paths without NUL or newlines (up to 4096 bytes)')
    return paths.normalize(path)
end

local function relative(path, root)
    path = checked(path)
    if path:match('^%a:') or path:sub(1, 1) == '/' then
        assert(root and paths.contains(root, path), 'file must be inside the project: ' .. path)
        path = path:sub(#paths.normalize(root) + (root:sub(-1) == '/' and 1 or 2))
    end
    local parts = {}
    for part in path:gmatch('[^/]+') do
        if part == '..' then
            assert(#parts > 0, 'file must be inside the project: ' .. path)
            parts[#parts] = nil
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    assert(#parts > 0, 'file must name a project file')
    return table.concat(parts, '/')
end

function M.validate(files, opts)
    assert(type(files) == 'table' and #files >= 1 and #files <= M.MAX_FILES,
        'files must be an array of 1 to ' .. M.MAX_FILES .. ' paths')
    local count = 0
    for k, path in pairs(files) do
        count = count + 1
        assert(type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= #files, 'files must be an array')
        -- Absolute paths are checked against the canonical root during execution.
        local normalized = checked(path)
        if not normalized:match('^%a:') and normalized:sub(1, 1) ~= '/' then relative(normalized) end
    end
    assert(count == #files, 'files must be an array')
    callers.validate('affected', opts)
end

local function test_file(path)
    local lower = path:lower()
    local base = lower:match('[^/]+$') or lower
    return ('/' .. lower):find('/tests?[/]') or ('/' .. lower):find('/spec[/]')
        or base:match('^test[_%.]') or base:match('[_%.]test%.')
        or base:match('[_%.]spec%.') or base:match('tests?%.cs$')
        or base:match('tests?%.java$') or base:match('tests?%.kt$')
end

function M.run(symbols, idx, files, opts)
    M.validate(files, opts)
    opts = opts or {}
    local normalized, seen, ordered, matched, unresolved, empty = {}, {}, {}, {}, {}, {}
    for _, path in ipairs(files) do
        local rel = relative(path, idx.root)
        local key = paths.key(rel)
        if not seen[key] then normalized[#normalized + 1] = rel; seen[key] = true end
    end
    table.sort(normalized)
    local lookup = {}
    -- Case folding is only needed on Windows; preserve actual indexed spelling.
    if paths.windows then
        local need_lookup = false
        for _, rel in ipairs(normalized) do if not symbols.file_index[rel] then need_lookup = true; break end end
        if need_lookup then
            for rel, f in pairs(symbols.file_index) do lookup[paths.key(rel)] = f end
        end
    end
    local cap, limited = opts.max_nodes or 200, false
    for _, rel in ipairs(normalized) do
        control.check()
        local f = symbols.file_index[rel] or lookup[paths.key(rel)]
        if not f then unresolved[#unresolved + 1] = rel
        else
            local rec = symbols.files[f]
            matched[#matched + 1] = rec.path
            if #rec.nodes == 0 then empty[#empty + 1] = rec.path end
            for _, id in ipairs(symbols.id_of[f]) do
                if #ordered < cap then ordered[#ordered + 1] = id else limited = true; break end
            end
        end
    end
    local run_opts = {}
    for k, v in pairs(opts) do run_opts[k] = v end
    run_opts.time_limit_ms = M.TIME_LIMIT_MS
    local result = callers.from_targets(symbols, idx, ordered, run_opts)
    if result.encoding_retry then return nil, result end
    result.changed_files, result.unresolved_files, result.files_without_symbols = matched, unresolved, empty
    result.seed_limit_reached = limited
    result.incomplete = limited or result.node_limit_reached or result.depth_limit_reached
        or result.relationships_incomplete or result.time_limit_reached or #unresolved > 0 or #empty > 0
    local affected, tests = {}, {}
    for _, path in ipairs(matched) do affected[path] = true end
    for _, path in ipairs(result.files) do affected[path] = true end
    result.files = {}
    for path in pairs(affected) do
        result.files[#result.files + 1] = path
        if test_file(path) then tests[#tests + 1] = path end
    end
    table.sort(result.files); table.sort(tests); result.tests = tests
    local lines = { string.format('Changed %d indexed file(s); %d starting symbols; %d potential affected symbols in %d files.',
        #matched, #result.targets, #result.callers, #result.files),
        'Static potential impact from indexed symbol relationships; not complete import, type, build or runtime coverage.',
        'Each affected symbol has one shortest path to one changed starting symbol. Test candidates use file naming only; unlisted tests are not safe to skip.' }
    if result.incomplete then
        local reasons = {}
        for _, item in ipairs({ { limited, 'seeds' }, { result.node_limit_reached, 'nodes' },
            { result.depth_limit_reached, 'depth' }, { result.time_limit_reached, 'time' },
            { result.relationships_incomplete, 'relationships' }, { #unresolved > 0, 'unresolved files' },
            { #empty > 0, 'files without symbols' } }) do
            if item[1] then reasons[#reasons + 1] = item[2] end
        end
        table.insert(lines, 2, 'Coverage incomplete: ' .. table.concat(reasons, ', ') .. '.')
    end
    for _, path in ipairs(matched) do lines[#lines + 1] = 'Changed: ' .. path end
    for _, path in ipairs(unresolved) do lines[#lines + 1] = 'Unresolved file (deleted, renamed, ignored, unsupported or not indexed): ' .. path end
    for _, path in ipairs(empty) do lines[#lines + 1] = 'No indexed symbols: ' .. path end
    if limited then lines[#lines + 1] = 'Seed limit reached; starting symbols were omitted.' end
    if result.node_limit_reached then lines[#lines + 1] = 'Node limit reached; affected symbols were omitted.' end
    if result.depth_limit_reached then lines[#lines + 1] = 'Depth limit reached; deeper relationships were not checked.' end
    if result.time_limit_reached then lines[#lines + 1] = 'Time limit reached; verified paths from the scanned portion are returned.' end
    if result.relationships_incomplete then lines[#lines + 1] = 'Relationships incomplete: '
        .. table.concat(require('codeoutline.coverage').relations(result), ', ') .. '.' end
    for _, entry in ipairs(result.callers) do
        local chain = {}
        for _, hop in ipairs(entry.path) do
            chain[#chain + 1] = string.format('%s (%s:%d)%s', hop.name, hop.file, hop.call_line or hop.line,
                hop.kind and ' [' .. hop.kind .. ']' or '')
        end
        lines[#lines + 1] = string.format('Depth %d: %s', entry.depth, table.concat(chain, ' -> '))
    end
    lines[#lines + 1] = 'Affected files:\n' .. table.concat(result.files, '\n')
    lines[#lines + 1] = 'Test candidates (naming heuristic):\n' .. (#tests > 0 and table.concat(tests, '\n') or '(none identified)')
    local output, cut = text.limit(table.concat(lines, '\n'), require('codeoutline.explore').validate('affected', opts),
        limited or result.node_limit_reached)
    result.truncated = cut
    return output, result
end

return M
