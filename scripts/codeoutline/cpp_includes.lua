-- Ordered C/C++ include lookup over indexed paths. Configuration is query-owned.
local M = { MAX_PATHS = 128, MAX_RULES = 128, MAX_CACHED_TARGETS = 8192 }
local paths = require('codeoutline.path')
local control = require('codeoutline.control')
local function absolute(path) return path:sub(1, 1) == '/' or path:match('^%a:/') ~= nil end
local function normalize(path)
    path = path:gsub('\\', '/')
    local prefix = path:match('^%a:/') or (path:sub(1, 2) == '//' and '//') or (path:sub(1, 1) == '/' and '/') or ''
    local parts, floor = {}, prefix == '//' and 2 or 0
    for part in path:sub(#prefix + 1):gmatch('[^/]+') do
        if part == '..' and #parts > floor and parts[#parts] ~= '..' then parts[#parts] = nil
        elseif part == '..' then if prefix == '' then parts[#parts + 1] = part end
        elseif part ~= '.' then parts[#parts + 1] = part end
    end
    return prefix .. table.concat(parts, '/')
end
local function join(root, path)
    path = path:gsub('\\', '/')
    return normalize(absolute(path) and path or (root ~= '' and root .. '/' or '') .. path)
end
local function array(value, label, cap)
    assert(type(value) == 'table' and #value <= cap, label .. ' must be an array with at most ' .. cap .. ' entries')
    for key in pairs(value) do
        assert(type(key) == 'number' and key >= 1 and key <= #value and key % 1 == 0, label .. ' must be an array')
    end
end
local function directory(value, label)
    assert(type(value) == 'string' and value ~= '' and #value <= 4096 and not value:find('[%z\r\n]'),
        label .. ' must contain non-empty directory strings of at most 4096 bytes')
    value = value:gsub('\\', '/')
    assert(not value:find(':', 1, true) or value:match('^%a:/'), label .. ' must not use drive-relative paths')
    return value
end

function M.context(G, client_paths)
    local config = require('codeoutline.rules').read(G.root)
    local root = normalize(G.root or '')
    local function directories(value, label)
        array(value, label, M.MAX_PATHS)
        local result = {}
        for _, dir in ipairs(value) do result[#result + 1] = join(root, directory(dir, label)) end
        return result
    end
    local C = { root = root, rules = {}, policies = {}, targets = {}, target_count = 0, configured = config.includePaths ~= nil }
    local defaults, client = config.includePaths, client_paths
    if defaults == nil then defaults = {} end
    if client == nil then client = {} end
    C.defaults = directories(defaults, 'includePaths')
    C.client = directories(client, 'includePaths')
    C.configured = C.configured or #C.client > 0
    local rules = config.includePathRules
    if rules == nil then rules = {} end
    array(rules, 'includePathRules', M.MAX_RULES)
    local seen = {}
    for _, rule in ipairs(rules) do
        control.check()
        assert(type(rule) == 'table', 'includePathRules entries must be objects')
        for key in pairs(rule) do assert(key == 'directory' or key == 'paths', 'unknown includePathRules field: ' .. tostring(key)) end
        local dir = directory(rule.directory, 'includePathRules.directory')
        assert(not absolute(dir), 'includePathRules.directory must be project-relative')
        dir = normalize(dir)
        assert(dir ~= '..' and dir:sub(1, 3) ~= '../', 'includePathRules.directory must stay inside the project')
        local key = paths.key(dir)
        assert(not seen[key], 'duplicate includePathRules.directory: ' .. dir); seen[key] = true
        C.rules[#C.rules + 1] = { directory = key, paths = directories(rule.paths, 'includePathRules.paths') }
    end
    table.sort(C.rules, function(a, b) return #a.directory > #b.directory end)
    return C
end

function M.policy(G, f, ctx)
    local C = ctx and ctx.cpp_includes
    if not C then
        C = M.context(G, ctx and ctx.include_paths)
        if ctx then ctx.cpp_includes = C end
    end
    local rel, rule = paths.key(G.files[f].path), nil
    for _, candidate in ipairs(C.rules) do
        if candidate.directory == '' or rel:sub(1, #candidate.directory + 1) == candidate.directory .. '/' then
            rule = candidate; break
        end
    end
    local key = rule and rule.directory or false
    if not C.policies[key] then
        local dirs, seen = {}, {}
        for _, list in ipairs({ rule and rule.paths or {}, C.defaults, C.client }) do
            for _, dir in ipairs(list) do
                local identity = paths.key(dir)
                if not seen[identity] then
                    assert(#dirs < M.MAX_PATHS, 'effective includePaths exceeds ' .. M.MAX_PATHS .. ' directories')
                    dirs[#dirs + 1], seen[identity] = dir, true
                end
            end
        end
        C.policies[key] = { paths = dirs, configured = C.configured or rule ~= nil, root = C.root }
    end
    return C.policies[key], C
end

-- `selected` distinguishes an ordered search (including a configured miss)
-- from the legacy suffix fallback. External selected headers are never indexed.
function M.resolve(G, f, imp, ctx)
    local policy, C = M.policy(G, f, ctx)
    local rec, written = G.files[f], imp.path:gsub('\\', '/')
    local function target(file)
        local old = C.targets[file]
        if old then return old[1], old[2] end
        control.check()
        local rel = file
        if policy.root ~= '' then
            if paths.contains(policy.root, file) then rel = file:sub(#policy.root + 2) else rel = nil end
        end
        local id = rel and (G.file_index[rel] or G.file_index[paths.key(rel)])
        local exists = id ~= nil
        if not exists and policy.root ~= '' then
            local stat = xutils.stat(file); exists = stat and stat.type == 'file' or false
            if exists then
                local real = xutils.realpath(file)
                real = real and paths.normalize(real)
                if real and paths.contains(policy.root, real) then id = G.file_index[real:sub(#policy.root + 2)] end
            end
        end
        if C.target_count < M.MAX_CACHED_TARGETS then
            C.targets[file] = { id, exists }; C.target_count = C.target_count + 1
        end
        return id, exists
    end
    local function find(file)
        local id, exists = target(file)
        if exists then return id and { id } or {}, true, file end
    end
    if absolute(written) then
        local ids, selected, file = find(normalize(written))
        return ids or {}, selected or true, file
    end
    if not imp.system then
        local here = rec.path:match('^(.*)/[^/]*$') or ''
        local ids, selected, file = find(join(join(policy.root, here), written))
        if selected then return ids, true, file end
    end
    for _, dir in ipairs(policy.paths) do
        local ids, selected, file = find(join(dir, written))
        if selected then return ids, true, file end
    end
    if policy.configured then return {}, true end
    local ids = {}
    local base = written:match('([^/]*)$')
    for i, id in ipairs(G.by_base[base] or G.by_base[paths.key(base)] or {}) do
        if i % 128 == 0 then control.check() end
        local path, name = paths.key(G.files[id].path), paths.key(written)
        if path == name or path:sub(-#name - 1) == '/' .. name then ids[#ids + 1] = id end
    end
    return ids, false
end

return M
