-- Query-owned local Go module lookup. No go command, module cache or network.
local M = { MAX_CONFIGS = 1024, MAX_CONFIG_BYTES = 1048576, MAX_TOTAL_BYTES = 8388608,
    MAX_MODULES = 256, MAX_FILES = 512, MAX_NODES = 8192, MAX_RESULTS = 64, MAX_DIRECTORIES = 4096 }
local control = require('codeoutline.control')
local paths = require('codeoutline.path')
local function dir(p) return p:match('^(.*)/[^/]+$') or '' end
local function join(a, b) return a == '' and b or b == '' and a or a .. '/' .. b end
local function valid(p)
    if type(p) ~= 'string' or p == '' or p:find('[\\:%s%z]') or p:sub(1, 1) == '/' then return false end
    for s in (p .. '/'):gmatch('(.-)/') do if s == '' or s == '.' or s == '..' then return false end end
    return true
end
local function relative(base, p)
    if p:find('[\\:%z]') or p:sub(1, 1) == '/' then error('Go local path is outside the indexed project or unsupported', 0) end
    local parts = {}
    for s in join(base, p):gmatch('[^/]+') do
        if s == '..' then
            if #parts == 0 then error('Go local path escapes the indexed project', 0) end
            parts[#parts] = nil
        elseif s ~= '.' then parts[#parts + 1] = s end
    end
    return table.concat(parts, '/')
end

local function tokens(line)
    local out, i = {}, 1
    while i <= #line do
        local c = line:sub(i, i)
        if c:match('%s') then i = i + 1
        elseif line:sub(i, i + 1) == '//' then break
        elseif c == '"' then
            local start, escaped, last = i, false, nil
            for j = i + 1, #line do
                local z = line:sub(j, j)
                if z == '"' and not escaped then last = j; break end
                escaped = z == '\\' and not escaped
            end
            local ok, value = pcall(xutils.json_unpack, last and line:sub(start, last) or '')
            if not ok or type(value) ~= 'string' then error('unsupported Go configuration string', 0) end
            out[#out + 1] = value; i = last + 1
        else
            local value = line:match('^([^%s]+)', i)
            out[#out + 1] = value; i = i + #value
        end
    end
    return out
end

local function parse(raw, root, work)
    local C = { root = root, requires = {}, replaces = {}, uses = {} }
    local block
    for line in (raw .. '\n'):gmatch('(.-)\r?\n') do
        control.check()
        local t = tokens(line)
        if #t > 0 then
            if t[1] == ')' then
                if not block or #t ~= 1 then error('invalid Go configuration block', 0) end
                block = nil
            else
                local directive = block or table.remove(t, 1)
                if not block and t[1] == '(' then
                    if #t ~= 1 then error('unsupported Go configuration block', 0) end
                    block = directive
                elseif directive == 'module' then
                    if work or #t ~= 1 or not valid(t[1]) or C.name then error('invalid Go module directive', 0) end
                    C.name = t[1]
                elseif directive == 'use' and work then
                    if #t ~= 1 then error('invalid Go workspace use directive', 0) end
                    C.uses[#C.uses + 1] = relative(root, t[1])
                    if #C.uses > M.MAX_MODULES then error('Go workspace module limit reached', 0) end
                elseif directive == 'require' and not work then
                    if #t ~= 2 or not valid(t[1]) or C.requires[t[1]] then error('invalid Go require directive', 0) end
                    C.requires[t[1]] = t[2]
                elseif directive == 'replace' then
                    local arrow = t[2] == '=>' and 2 or t[3] == '=>' and 3
                    if not arrow or not valid(t[1]) or #t < arrow + 1 or #t > arrow + 2 then
                        error('invalid Go replace directive', 0)
                    end
                    local replacement = { name = t[1], version = arrow == 3 and t[2] or '',
                        target = t[arrow + 1], target_version = t[arrow + 2] }
                    if #t == arrow + 1 then
                        local target = replacement.target
                        if target ~= '.' and target ~= '..' and not target:match('^%./') and not target:match('^%.%./') then
                            error('unsupported Go replacement: local targets must use ./ or ../', 0)
                        end
                        replacement.root = relative(root, target)
                    end
                    local key = replacement.name .. '\0' .. replacement.version
                    if C.replaces[key] then error('duplicate Go replace directive', 0) end
                    C.replaces[key] = replacement
                end
            end
        end
    end
    if block or not work and not C.name then error('invalid or missing Go module directive', 0) end
    return C
end

local function context(G, ctx)
    if ctx.go_context then return ctx.go_context end
    local C = { configs = {}, owners = {}, environments = {}, modules = {}, aliases = {}, probes = 0, bytes = 0,
        stats = ctx.go_stats or { reads = 0, bytes = 0, modules = 0 } }
    ctx.go_context, ctx.go_stats = C, C.stats
    function C.read(rel)
        if C.configs[rel] ~= nil then return C.configs[rel] or nil end
        control.check(); C.probes = C.probes + 1
        if C.probes > M.MAX_CONFIGS then error('Go configuration probe limit reached', 0) end
        local absolute = join(G.root, rel)
        local real = xutils.realpath(absolute)
        if not real then C.configs[rel] = false; return nil end
        if not paths.contains(G.root, real) then error('Go configuration escapes the indexed project', 0) end
        local f = io.open(absolute, 'rb')
        if not f then C.configs[rel] = false; return nil end
        local raw = f:read(M.MAX_CONFIG_BYTES + 1); f:close()
        C.bytes = C.bytes + #raw
        if #raw > M.MAX_CONFIG_BYTES or C.bytes > M.MAX_TOTAL_BYTES then error('Go configuration size limit reached', 0) end
        C.stats.reads, C.stats.bytes = C.stats.reads + 1, C.bytes
        local value = parse(raw, dir(rel), rel:match('go%.work$'))
        C.configs[rel] = value; return value
    end
    function C.owner(directory)
        if C.owners[directory] ~= nil then return C.owners[directory] or nil end
        local current = directory
        while true do
            local mod = C.read(join(current, 'go.mod'))
            if mod then C.owners[directory] = mod; return mod end
            if current == '' then break end
            current = dir(current)
        end
        C.owners[directory] = false
    end
    function C.environment(directory)
        if C.environments[directory] then return C.environments[directory] end
        local owner, current, work = C.owner(directory), directory
        while true do
            work = C.read(join(current, 'go.work'))
            if work or current == '' then break end
            current = dir(current)
        end
        local env = { owner = owner, work = work, mains = {}, names = {}, requires = {}, replaces = {} }
        local function add(mod)
            if #env.mains >= M.MAX_MODULES then error('Go workspace module limit reached', 0) end
            if env.names[mod.name] then error('ambiguous Go workspace module: ' .. mod.name, 0) end
            env.names[mod.name] = mod; env.mains[#env.mains + 1] = mod
        end
        if work then
            local seen = {}
            for _, root in ipairs(work.uses) do
                if not seen[root] then
                    local mod = C.read(join(root, 'go.mod'))
                    if not mod then error('Go workspace module has no go.mod: ' .. root, 0) end
                    add(mod); seen[root] = true
                end
            end
        elseif owner then add(owner) end
        env.active = not work or owner and env.names[owner.name] == owner
        for _, mod in ipairs(env.mains) do
            for name, version in pairs(mod.requires) do
                if env.requires[name] and env.requires[name] ~= version then env.requires[name] = false
                elseif env.requires[name] == nil then env.requires[name] = version end
            end
            for key, r in pairs(mod.replaces) do
                local old = env.replaces[key]
                if old and (old.root ~= r.root or not old.root
                    and (old.target ~= r.target or old.target_version ~= r.target_version)) then env.replaces[key] = false
                elseif old == nil then env.replaces[key] = r end
            end
        end
        C.stats.modules = math.max(C.stats.modules, #env.mains)
        C.environments[directory] = env; return env
    end
    return C
end

-- Exact directory lookup, including unsaved new files. Nested modules are barriers.
local function package_files(G, directory, C, owner, external, package)
    local result, seen, name = {}, {}, package
    local function add(g)
        if seen[g] then return end
        seen[g] = true
        local rec = G.files[g]
        if rec.language ~= 'go' or external and rec.path:match('_test%.go$') then return end
        if dir(rec.path) ~= directory or package and rec.package ~= package then return end
        if name and name ~= rec.package then error('ambiguous Go package directory: ' .. directory, 0) end
        name = rec.package
        if #result >= M.MAX_FILES then error('Go package file limit reached', 0) end
        result[#result + 1] = g
    end
    if C and owner and C.owner(directory) ~= owner then return {}, 'Go nested module boundary' end
    for _, g in ipairs(G.dir_files[directory] or {}) do control.check(); add(g) end
    for _, g in ipairs(G.new_files or {}) do add(g) end
    return result
end

local function legacy(G, spec)
    local last, suffix = spec:match('([^/]+)$'), spec
    if #(G.dir_by_base[last] or {}) > M.MAX_DIRECTORIES then error('Go legacy directory limit reached', 0) end
    while suffix do
        local found
        for _, directory in ipairs(G.dir_by_base[last] or {}) do
            control.check()
            if directory == suffix or directory:sub(-#suffix - 1) == '/' .. suffix then
                local files = package_files(G, directory, nil, nil, true)
                if #files > 0 then
                    if found then return {}, 'ambiguous legacy Go import: ' .. spec end
                    found = files
                end
            end
        end
        if found then return found end
        suffix = suffix:match('^[^/]+/(.+)$')
    end
    return {}
end

local function locate(G, f, spec, ctx)
    if not valid(spec) then return {}, 'invalid Go import path' end
    if not G.root then return legacy(G, spec) end
    local C = context(G, ctx)
    local key = G.files[f].path .. '\0' .. spec
    if C.modules[key] then return table.unpack(C.modules[key]) end
    local env = C.environment(dir(G.files[f].path))
    if not env.owner and not env.work then return legacy(G, spec) end
    if not env.active then return {}, 'Go importer is not in the active workspace' end
    local candidates, reason = {}, nil
    local function add(name, root, owner)
        if spec == name or spec:sub(1, #name + 1) == name .. '/' then
            local files, why = package_files(G, join(root, spec:sub(#name + 2)), C, owner, true)
            if #files > 0 then candidates[#candidates + 1] = files else reason = why end
        end
    end
    for name, mod in pairs(env.names) do add(name, mod.root, mod) end
    for name, version in pairs(env.requires) do
        if not env.names[name] and (spec == name or spec:sub(1, #name + 1) == name .. '/') then
            local wildcard, key = name .. '\0', name .. '\0' .. (version or '')
            local replacements = env.work and env.work.replaces or {}
            local r = replacements[key] or replacements[wildcard]
            if r == nil then
                if env.replaces[key] == false or env.replaces[wildcard] == false then
                    return {}, 'conflicting Go module replacements: ' .. name
                end
                r = env.replaces[key] or env.replaces[wildcard]
            end
            if r and (r.version == '' or version) then
                if not r.root then reason = 'Go replacement requires an external module: ' .. name
                else
                    local mod = C.read(join(r.root, 'go.mod'))
                    if mod and mod.name == name then add(name, r.root, mod)
                    else reason = 'Go replacement has no matching module declaration: ' .. name end
                end
            elseif version == false then reason = 'Go dependency version selection is not modeled: ' .. name end
        end
    end
    local files
    if #candidates > 1 then files, reason = {}, 'ambiguous Go package import: ' .. spec
    else files = candidates[1] or {} end
    reason = reason or (#files == 0 and 'Go module package is not indexed: ' .. spec or nil)
    C.modules[key] = { files, reason }; return files, reason
end

local function guarded(ctx, fn, ...)
    if ctx.go_error then return {}, ctx.go_error end
    local ok, result, reason = pcall(fn, ...)
    if ok then return result, reason end
    if control.is_interrupted(result) then error(result, 0) end
    ctx.go_incomplete, ctx.go_error = true, tostring(result)
    return {}, ctx.go_error
end

function M.files(G, f, spec, ctx)
    ctx = ctx or {}
    return guarded(ctx, locate, G, f, spec, ctx)
end

function M.peers(G, f, ctx)
    ctx = ctx or {}
    return guarded(ctx, package_files, G, dir(G.files[f].path), nil, nil,
        not G.files[f].path:match('_test%.go$'), G.files[f].package)
end

function M.aliases(G, f, ctx)
    ctx = ctx or {}
    local C = G.root and context(G, ctx)
    local key = G.files[f].path
    if C and C.aliases[key] then return C.aliases[key] end
    local out = {}
    for _, imp in ipairs(G.files[f].imports) do
        local files, reason = M.files(G, f, imp.path, ctx)
        local alias = imp.alias or (#files > 0 and G.files[files[1]].package) or imp.path:match('([^/]+)$')
        if alias ~= '_' then
            local entry = { path = imp.path, kind = 'import', files = files, reason = reason }
            if out[alias] then out[alias] = { files = {}, reason = 'ambiguous Go package alias: ' .. alias }
            else out[alias] = entry end
        end
    end
    if C then C.aliases[key] = out end
    return out
end

function M.resolve(G, f, name, recv, ctx)
    ctx = ctx or {}
    local aliases, files, reason, exported = M.aliases(G, f, ctx)
    if recv then
        local alias = aliases[recv]
        if not alias then return nil end
        files, reason, exported = alias.files, alias.reason, true
    else files = M.peers(G, f, ctx) end
    local function collect()
        local ids, count = {}, 0
        for _, g in ipairs(files) do
            for _, id in ipairs(G.id_of[g]) do
                control.check(); count = count + 1
                if count > M.MAX_NODES then error('Go package node limit reached', 0) end
                local node = G.nodes[id]
                if node.name == name and not node.parent and node.kind ~= 'method'
                    and (not exported or name:match('^%u')) then
                    if #ids >= M.MAX_RESULTS then error('Go package result limit reached', 0) end
                    ids[#ids + 1] = id
                end
            end
        end
        return ids
    end
    local ids, why = guarded(ctx, collect)
    -- Dot imports are deliberately not inferred; local declarations take priority.
    return ids, why or reason or (#ids == 0 and 'Go package binding unresolved' or nil)
end

return M
