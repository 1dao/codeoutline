-- Local Cargo package identity is configuration evidence owned by one query.
local M = { MAX_CONFIGS = 1024, MAX_CONFIG_BYTES = 1048576, MAX_TOTAL_BYTES = 8388608,
    MAX_DEPENDENCIES = 512, MAX_DEPTH = 32 }
local control, paths = require('codeoutline.control'), require('codeoutline.path')
local function dir(p) return p:match('^(.*)/[^/]+$') or '' end
local function join(a, b) return a == '' and b or b == '' and a or a .. '/' .. b end
local function relative(base, p)
    if type(p) ~= 'string' or p:find('[\\:%z]') or p:sub(1, 1) == '/' then error('unsupported or external Cargo path', 0) end
    local parts = {}
    for s in join(base, p):gmatch('[^/]+') do
        if s == '..' then
            if #parts == 0 then error('Cargo path escapes indexed project', 0) end
            parts[#parts] = nil
        elseif s ~= '.' then parts[#parts + 1] = s end
    end
    return table.concat(parts, '/')
end
local function crate_name(s) return type(s) == 'string' and s:gsub('-', '_') end
local function matches(pattern, value)
    if type(pattern) ~= 'string' or pattern:find('[{}%[%]\\%z]') or pattern:find('..', 1, true) then
        error('unsupported Cargo workspace glob', 0)
    end
    pattern = pattern:gsub('^%./', ''):gsub('/+$', '')
    local escaped = pattern:gsub('([^%w*?])', '%%%1'):gsub('%*', '[^/]*'):gsub('%?', '[^/]')
    return value:match('^' .. escaped .. '$') ~= nil
end

local function context(G, ctx)
    if ctx.rust_packages then return ctx.rust_packages end
    local C = { configs = {}, owners = {}, deps = {}, reaches = {}, probes = 0, bytes = 0 }
    ctx.rust_packages = C
    ctx.rust_stats = ctx.rust_stats or { reads = 0, bytes = 0, packages = 0 }
    function C.read(root)
        if C.configs[root] ~= nil then return C.configs[root] or nil end
        control.check(); C.probes = C.probes + 1
        if C.probes > M.MAX_CONFIGS then error('Cargo configuration probe limit reached', 0) end
        local abs = join(G.root, join(root, 'Cargo.toml'))
        local real = xutils.realpath(abs)
        if not real then C.configs[root] = false; return nil end
        if not paths.contains(G.root, real) then error('Cargo manifest escapes indexed project', 0) end
        local file = io.open(abs, 'rb')
        if not file then C.configs[root] = false; return nil end
        local raw = file:read(M.MAX_CONFIG_BYTES + 1); file:close()
        C.bytes = C.bytes + #raw
        if #raw > M.MAX_CONFIG_BYTES or C.bytes > M.MAX_TOTAL_BYTES then error('Cargo configuration size limit reached', 0) end
        local config = require('codeoutline.cargo_toml').parse(raw); config.root = root
        if config.package and (type(config.package.name) ~= 'string' or not config.package.name:match('^[%w_-]+$')) then
            error('invalid Cargo package name', 0)
        end
        local stat = ctx.rust_stats
        stat.reads, stat.bytes = stat.reads + 1, C.bytes
        if config.package then stat.packages = stat.packages + 1 end
        C.configs[root] = config; return config
    end
    function C.owner(file)
        local directory = dir(G.files[file].path)
        if C.owners[directory] ~= nil then return C.owners[directory] or nil end
        local current = directory
        while true do
            local config = C.read(current)
            if config then
                C.owners[directory] = config.package and config or false
                return config.package and config or nil
            end
            if current == '' then break end
            current = dir(current)
        end
        C.owners[directory] = false
    end
    function C.workspace(owner)
        local override = owner.package.workspace
        if override ~= nil then
            local config = C.read(relative(owner.root, override))
            if not config or not config.workspace then error('Cargo workspace root is unavailable', 0) end
            return config
        end
        local current = owner.root
        while true do
            local config = C.read(current)
            if config and config.workspace then return config end
            if current == '' then return nil end
            current = dir(current)
        end
    end
    function C.dependencies(owner)
        if C.deps[owner.root] then return C.deps[owner.root] end
        local dependencies, result, count = {}, {}, 0
        for key, value in pairs(owner.dependencies or {}) do
            local name, field = key:match('^([%w_-]+)%.([%w_-]+)$')
            if name then
                dependencies[name] = dependencies[name] or {}
                if type(dependencies[name]) ~= 'table' then error('conflicting Cargo dependency assignment', 0) end
                dependencies[name][field] = value
            else dependencies[key] = value end
        end
        for section, value in pairs(owner) do
            local name = section:match('^dependencies%.([%w_-]+)$')
            if name then
                if dependencies[name] then error('conflicting Cargo dependency table', 0) end
                dependencies[name] = value
            end
        end
        for key, value in pairs(dependencies) do
            control.check(); count = count + 1
            if count > M.MAX_DEPENDENCIES then error('Cargo dependency limit reached', 0) end
            local base, dependency = owner.root, value
            if type(value) == 'table' and value.workspace == true then
                local workspace = C.workspace(owner)
                if not workspace then error('Cargo inherited dependency has no workspace', 0) end
                local rel = owner.root == workspace.root and '' or workspace.root == '' and owner.root or owner.root:sub(#workspace.root + 2)
                for _, pattern in ipairs(workspace.workspace.exclude or {}) do
                    if matches(pattern, rel) then error('Cargo package is excluded from workspace', 0) end
                end
                dependency = (workspace['workspace.dependencies'] or {})[key] or workspace['workspace.dependencies.' .. key]
                if not dependency then error('Cargo inherited dependency is not declared: ' .. key, 0) end
                base = workspace.root
            end
            local descriptor = { alias = crate_name(key), source = dependency }
            if type(dependency) == 'table' and dependency.path ~= nil then
                local root = relative(base, dependency.path)
                local target = C.read(root)
                if target and target.package and type(target.package.name) == 'string'
                    and (dependency.package == nil or dependency.package == target.package.name) then
                    descriptor.package = target
                    if dependency.package == nil and target.package.name ~= key then descriptor.package = nil end
                    if descriptor.package and dependency.package == nil then
                        descriptor.alias = crate_name((target.lib or {}).name or target.package.name)
                    end
                end
            end
            if result[descriptor.alias] then error('ambiguous Cargo crate alias: ' .. descriptor.alias, 0) end
            result[descriptor.alias] = descriptor
        end
        C.deps[owner.root] = result; return result
    end
    return C
end

function M.guard(ctx, fn, ...)
    if ctx.rust_error then return nil, ctx.rust_error end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    if control.is_interrupted(a) then error(a, 0) end
    ctx.rust_incomplete, ctx.rust_error = true, tostring(a)
    return nil, ctx.rust_error
end
function M.owner(G, f, ctx)
    if not G.root then return nil end
    return M.guard(ctx, function() return context(G, ctx).owner(f) end)
end
function M.dependencies(G, f, ctx)
    return M.guard(ctx, function()
        local C = context(G, ctx); local owner = C.owner(f)
        return owner and C.dependencies(owner) or {}
    end) or {}
end
function M.entry(G, owner, ctx, file)
    return M.guard(ctx, function()
        local lib = owner.lib or {}
        local root = relative(owner.root, lib.path or 'src/lib.rs')
        if file and G.files[file].path == join(owner.root, 'src/main.rs') then root = G.files[file].path end
        if file and not lib.path and not G.file_index[root] then root = join(owner.root, 'src/main.rs') end
        local id = G.file_index[root]
        if not id or G.files[id].language ~= 'rust' then return nil, 'Cargo library target is not indexed' end
        if context(G, ctx).owner(id) ~= owner then return nil, 'Cargo target crosses a package boundary' end
        return id
    end)
end
function M.crates(G, f, ctx)
    local result = {}
    for alias, descriptor in pairs(M.dependencies(G, f, ctx)) do
        if descriptor.package then result[alias] = M.entry(G, descriptor.package, ctx) end
    end
    local owner = M.owner(G, f, ctx)
    if owner then
        local alias = crate_name((owner.lib or {}).name or owner.package.name)
        if alias and not result[alias] then result[alias] = M.entry(G, owner, ctx) end
    end
    return result
end
function M.reaches(G, f, target, ctx)
    local owner = M.owner(G, f, ctx)
    if not owner or not target then return false end
    return M.guard(ctx, function()
        local C, seen = context(G, ctx), {}
        local key = owner.root .. '\0' .. target.root
        if C.reaches[key] ~= nil then return C.reaches[key] end
        local function visit(package, depth)
            if package == target then return true end
            if seen[package.root] then return false end
            if depth > M.MAX_DEPTH then error('Cargo dependency traversal limit reached', 0) end
            seen[package.root] = true
            for _, descriptor in pairs(C.dependencies(package)) do
                control.check()
                if descriptor.package and visit(descriptor.package, depth + 1) then return true end
            end
            return false
        end
        local result = visit(owner, 0); C.reaches[key] = result; return result
    end) or false
end
M.dir, M.join, M.relative = dir, join, relative
return M
