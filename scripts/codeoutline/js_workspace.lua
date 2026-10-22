-- Workspace package lookup is query-owned. Discover manifests from indexed
-- directories; never walk node_modules, execute package scripts, or guess src/.
local M = { MAX_CONFIG_BYTES = 1048576, MAX_TOTAL_BYTES = 8388608, MAX_CONFIGS = 1024,
    MAX_DIRECTORIES = 4096, MAX_PACKAGES = 512, MAX_PATTERNS = 256 }
local control = require('codeoutline.control')
local paths = require('codeoutline.path')
local function dir(p) return p:match('^(.*)/[^/]+$') or '' end
local function join(a, b) return a == '' and b or a .. '/' .. b end
local function object(t) return type(t) == 'table' and getmetatable(t) ~= xutils.json_array_mt end
local function safe(s)
    if type(s) ~= 'string' or s == '' or s:find('[\\%%:%z]') or s:sub(1, 1) == '/' then return false end
    for part in (s .. '/'):gmatch('(.-)/') do
        if part == '' or part == '.' or part == '..' or part == 'node_modules' then return false end
    end
    return true
end

-- Keep JSON property order for conditional exports. No source or tokens survive
-- the read, and no custom properties are inserted into the decoded manifest.
local function json(raw)
    local ok, data = pcall(xutils.json_unpack, raw)
    if not ok or not object(data) then error('invalid workspace package.json', 0) end
    local T = require('codeoutline.lang.js').lang:tokenize(raw)
    local order = {}
    local function visit(node, i, depth)
        if depth > 64 then error('workspace JSON nesting limit reached', 0) end
        if T:text(i) == '{' then
            local keys, seen, j = {}, {}, i + 1
            order[node] = keys
            while j < T.m[i] do
                local key = xutils.json_unpack(T:text(j))
                if seen[key] then error('duplicate workspace JSON key', 0) end
                seen[key] = true; keys[#keys + 1] = key
                j = visit(node[key], j + 2, depth + 1)
                if T:text(j) == ',' then j = j + 1 end
            end
            return T.m[i] + 1
        elseif T:text(i) == '[' then
            local j, k = i + 1, 1
            while j < T.m[i] do
                j = visit(node[k], j, depth + 1); k = k + 1
                if T:text(j) == ',' then j = j + 1 end
            end
            return T.m[i] + 1
        end
        return i + 1
    end
    visit(data, 1, 0)
    return { data = data, order = order }
end

local function patterns(value)
    if type(value) ~= 'table' or #value > M.MAX_PATTERNS then error('unsupported workspace patterns', 0) end
    for k in pairs(value) do
        if type(k) ~= 'number' or k < 1 or k > #value or k % 1 ~= 0 then error('unsupported workspace patterns', 0) end
    end
    local result = {}
    for _, pattern in ipairs(value) do
        if type(pattern) ~= 'string' or pattern:find('[{}%[%]\\%%:%z]') then error('unsupported workspace glob', 0) end
        local excluded = pattern:sub(1, 1) == '!'
        if excluded then pattern = pattern:sub(2) end
        local segments = {}
        if pattern:sub(1, 1) == '/' then error('workspace glob escapes project', 0) end
        for segment in pattern:gmatch('[^/]+') do
            if segment == '..' then error('workspace glob escapes project', 0)
            elseif segment ~= '.' then segments[#segments + 1] = segment end
        end
        if #segments > 64 then error('workspace glob depth limit reached', 0) end
        result[#result + 1] = { segments = segments, excluded = excluded }
    end
    return result
end

local function matches(segments, path)
    local parts, memo = {}, {}
    for part in path:gmatch('[^/]+') do parts[#parts + 1] = part end
    local function match(i, j)
        local key = i .. ':' .. j
        if memo[key] ~= nil then return memo[key] end
        local result = false
        if i > #segments then result = j > #parts
        elseif segments[i] == '**' then
            result = match(i + 1, j) or j <= #parts and parts[j]:sub(1, 1) ~= '.' and match(i, j + 1)
        elseif j <= #parts then
            local pattern = segments[i]
            if parts[j]:sub(1, 1) ~= '.' or pattern:sub(1, 1) == '.' then
                pattern = pattern:gsub('([^%w*?])', '%%%1'):gsub('%*', '.*'):gsub('%?', '.')
                result = parts[j]:match('^' .. pattern .. '$') ~= nil and match(i + 1, j + 1)
            end
        end
        memo[key] = result; return result
    end
    return match(1, 1)
end

-- A finite YAML subset: a block or JSON flow list of quoted/plain string globs.
-- Other settings are ignored; anchors, aliases and expressions in packages fail closed.
local function pnpm(raw)
    local list, active, seen = {}, false, false
    for line in (raw .. '\n'):gmatch('(.-)\r?\n') do
        local rest = line:match('^packages:%s*(.-)%s*$')
        if rest then
            if seen then error('duplicate pnpm packages field', 0) end
            active, seen = true, true
            rest = rest:gsub('%s+#.*$', '')
            if rest ~= '' and rest:sub(1, 1) ~= '#' then
                local ok, array = pcall(xutils.json_unpack, rest)
                if not ok or type(array) ~= 'table' or getmetatable(array) ~= xutils.json_array_mt then
                    error('unsupported pnpm packages list', 0)
                end
                list, active = array, false
            end
        elseif active and line:match('^%S') then active = false
        elseif active and not line:match('^%s*#') and not line:match('^%s*$') then
            local item = line:match('^%s+%-%s+(.+)%s*$')
            if not item then error('unsupported pnpm packages list', 0) end
            local quote = item:sub(1, 1)
            if quote == '"' then
                local last, escaped = nil, false
                for i = 2, #item do
                    local c = item:sub(i, i)
                    if c == '"' and not escaped then last = i; break end
                    escaped = c == '\\' and not escaped
                end
                local tail = last and item:sub(last + 1) or '?'
                if not tail:match('^%s*$') and not tail:match('^%s+#') then error('unsupported pnpm workspace glob', 0) end
                local ok, decoded = pcall(xutils.json_unpack, last and item:sub(1, last) or '')
                if not ok then error('unsupported pnpm workspace glob', 0) end
                item = decoded
            elseif quote == "'" then
                local decoded, tail = item:match("^'(.-)'(.*)$")
                if not tail or not tail:match('^%s*$') and not tail:match('^%s+#') then
                    error('unsupported pnpm workspace glob', 0)
                end
                item = decoded
            else
                item = item:gsub('%s+#.*$', ''):gsub('%s+$', '')
                if item:find('[&|>{}%[%]]') or item:sub(1, 1) == '*' then error('unsupported pnpm workspace glob', 0) end
            end
            list[#list + 1] = item
        end
    end
    return patterns(list)
end

local function context(G, ctx)
    if ctx.workspace then return ctx.workspace end
    local C = { configs = {}, workspaces = {}, owners = {}, probes = 0, bytes = 0 }
    local stats = ctx.workspace_stats
    local function fail(message) ctx.workspace_incomplete = true; error(message, 0) end
    function C.read(rel)
        if C.configs[rel] ~= nil then return C.configs[rel] or nil end
        control.check()
        C.probes = C.probes + 1
        if C.probes > M.MAX_CONFIGS then fail('workspace configuration limit reached') end
        local absolute = join(G.root, rel)
        local real = xutils.realpath(absolute)
        if not real then C.configs[rel] = false; return nil end
        if not paths.contains(G.root, paths.normalize(real)) then fail('workspace configuration escapes project') end
        local f = io.open(absolute, 'rb')
        if not f then C.configs[rel] = false; return nil end
        local raw = f:read(M.MAX_CONFIG_BYTES + 1); f:close()
        if #raw > M.MAX_CONFIG_BYTES then fail('workspace configuration exceeds size limit') end
        C.bytes = C.bytes + #raw; stats.reads = stats.reads + 1; stats.bytes = C.bytes
        if C.bytes > M.MAX_TOTAL_BYTES then fail('workspace configuration budget reached') end
        local value = rel:match('%.json$') and json(raw) or { patterns = pnpm(raw) }
        C.configs[rel] = value
        return value
    end
    function C.owner(file)
        local directory = dir(G.files[file].path)
        if C.owners[directory] ~= nil then return C.owners[directory] or nil end
        local current = directory
        while true do
            local yaml = C.read(join(current, 'pnpm-workspace.yaml'))
            local manifest = C.read(join(current, 'package.json'))
            if yaml or manifest and manifest.data.workspaces ~= nil then
                local spec = yaml and yaml.patterns
                if not spec then
                    local value = manifest.data.workspaces
                    spec = patterns(object(value) and value.packages or value)
                end
                local result = { root = current, patterns = spec }
                C.owners[directory] = result; return result
            end
            if current == '' then break end
            current = dir(current)
        end
        C.owners[directory] = false
    end
    function C.packages(workspace)
        if C.workspaces[workspace.root] then return C.workspaces[workspace.root] end
        local directories, count = { [workspace.root] = true }, 1
        local function add(directory)
            control.check()
            if ('/' .. directory .. '/'):find('/node_modules/', 1, true) then return end
            if workspace.root ~= '' and directory ~= workspace.root
                and directory:sub(1, #workspace.root + 1) ~= workspace.root .. '/' then return end
            while directory ~= '' do
                if directories[directory] then return end
                if count >= M.MAX_DIRECTORIES then fail('workspace directory limit reached') end
                directories[directory] = true; count = count + 1
                directory = dir(directory)
            end
        end
        for directory in pairs(G.dir_files) do add(directory) end
        for _, f in ipairs(G.new_files or {}) do add(dir(G.files[f].path)) end
        local ordered = {}
        for directory in pairs(directories) do ordered[#ordered + 1] = directory end
        table.sort(ordered)
        local packages, entries = {}, 0
        for _, directory in ipairs(ordered) do
            control.check()
            local relative = workspace.root == '' and directory
                or directory:sub(1, #workspace.root + 1) == workspace.root .. '/' and directory:sub(#workspace.root + 2)
            local include = directory == workspace.root
            if relative and relative ~= '' then
                local excluded = false
                for _, pattern in ipairs(workspace.patterns) do
                    if matches(pattern.segments, relative) then
                        if pattern.excluded then excluded = true else include = true end
                    end
                end
                include = include and not excluded
            end
            if include then
                local config = C.read(join(directory, 'package.json'))
                local name = config and config.data.name
                if type(name) == 'string' then
                    entries = entries + 1
                    if entries > M.MAX_PACKAGES then fail('workspace package limit reached') end
                    if packages[name] then packages[name] = false
                    elseif packages[name] == nil then packages[name] = { root = directory, config = config } end
                end
            end
        end
        stats.directories, stats.packages = count, entries
        C.workspaces[workspace.root] = packages; return packages
    end
    ctx.workspace = C
    return C
end

local function selected(value, order, conditions, depth)
    if depth > 16 then return nil, 'workspace export depth limit reached' end
    if type(value) == 'string' then return value end
    if value == xutils.json_null then return nil, 'workspace export is blocked' end
    if type(value) ~= 'table' then return nil, 'unsupported workspace export' end
    if not object(value) then
        -- Do not substitute a later target merely because the first is unindexed.
        if #value > 0 then return selected(value[1], order, conditions, depth + 1) end
        return nil, 'workspace export has no target'
    end
    for _, condition in ipairs(order[value] or {}) do
        if condition:sub(1, 1) == '.' then return nil, 'mixed workspace export map' end
        if conditions[condition] then
            local target, reason = selected(value[condition], order, conditions, depth + 1)
            if target or reason ~= 'workspace export has no supported condition' then return target, reason end
        end
    end
    return nil, 'workspace export has no supported condition'
end

function M.resolve(G, f, spec, ctx, mode, find)
    if not G.root or spec:sub(1, 1) == '.' or spec:find('[\\%%:%z]') then return nil end
    local package, subpath
    if spec:sub(1, 1) == '@' then package, subpath = spec:match('^(@[^/]+/[^/]+)(.*)$')
    else package, subpath = spec:match('^([^/]+)(.*)$') end
    if not package or not safe(package) or subpath ~= '' and not safe(subpath:sub(2)) then return nil end
    local C = context(G, ctx)
    local workspace = C.owner(f)
    if not workspace then return nil end
    local packages = C.packages(workspace)
    if packages[package] == false then return nil, 'ambiguous workspace package: ' .. package end
    local entry = packages[package]
    if not entry then return nil end
    local manifest, target, reason = entry.config.data
    if manifest.exports ~= nil then
        local value, capture = manifest.exports, nil
        local key = subpath == '' and '.' or '.' .. subpath
        if object(value) then
            local subpaths, conditions = false, false
            for name in pairs(value) do if name:sub(1, 1) == '.' then subpaths = true else conditions = true end end
            if subpaths and conditions then return nil, 'mixed workspace export map: ' .. package end
            if subpaths then
                if value[key] ~= nil then value = value[key]
                else
                    local best, suffix_length = nil, -1
                    for pattern in pairs(value) do
                        local pre, post = pattern:match('^(.-)%*(.-)$')
                        if pre and not post:find('*', 1, true) and key:sub(1, #pre) == pre
                            and (#post == 0 or key:sub(-#post) == post) and #key >= #pre + #post
                            and (not best or #pre > #best or #pre == #best and #post > suffix_length) then
                            best, suffix_length = pre, #post
                            capture, target = key:sub(#pre + 1, #key - #post), value[pattern]
                        end
                    end
                    value = target
                end
            elseif key ~= '.' then value = nil end
        elseif key ~= '.' then value = nil end
        if value == nil then return nil, 'workspace subpath is not exported: ' .. spec end
        local active = { default = true, node = true, import = mode ~= 'require', require = mode == 'require',
            types = G.files[f].language == 'typescript' or G.files[f].language == 'arkts' }
        target, reason = selected(value, entry.config.order, active, 0)
        if not target then return nil, (reason or 'workspace export unresolved') .. ': ' .. spec end
        if capture then
            if not safe(capture) then return nil, 'invalid workspace export capture: ' .. spec end
            target = target:gsub('%*', function() return capture end)
        elseif target:find('*', 1, true) then return nil, 'unsupported workspace export target: ' .. spec end
        if target:sub(1, 2) ~= './' then return nil, 'workspace export target must start with ./: ' .. spec end
    elseif subpath ~= '' then target = subpath:sub(2)
    else
        if G.files[f].language == 'typescript' or G.files[f].language == 'arkts' then target = manifest.types or manifest.typings end
        target = target or (mode ~= 'require' and manifest.module) or manifest.main or 'index'
    end
    if type(target) ~= 'string' then return nil, 'unsupported workspace package entry: ' .. spec end
    target = target:gsub('^%./', '')
    if not safe(target) then return nil, 'workspace target escapes package or is invalid: ' .. spec end
    local id = find(join(entry.root, target))
    if not id then return nil, 'workspace target is not indexed: ' .. spec end
    return id
end

return M
