-- Declaration navigation in selected external headers. Never extend the index.
local M = { MAX_FILES = 64, MAX_PROJECT_FILES = 128, MAX_BYTES = 4 * 1024 * 1024,
    MAX_FILE_BYTES = 1024 * 1024, CACHE_FILES = 32, CACHE_BYTES = 8 * 1024 * 1024, TIME_MS = 500 }
local paths, control = require('codeoutline.path'), require('codeoutline.control')
local cache, order, cache_bytes, scanner = {}, {}, 0, nil
local function directory(file) return file:match('^(.*)/[^/]+$') end
local function existing(file)
    control.check()
    local stat = xutils.stat(file)
    if stat and stat.type == 'file' then
        local real = xutils.realpath(file)
        return real and paths.normalize(real)
    end
end
local function read(file, info)
    local stream = io.open(file, 'rb')
    if not stream then return nil end
    local raw = stream:read(M.MAX_FILE_BYTES + 1) or ''; stream:close()
    info.files, info.bytes = info.files + 1, info.bytes + #raw
    if #raw > M.MAX_FILE_BYTES or info.bytes > M.MAX_BYTES then info.truncated = true; return nil end
    local crc = xcompress and xcompress.crc32 and xcompress.crc32(raw) or xutils.sha256_hex(raw)
    local key, entry = paths.key(file), cache[paths.key(file)]
    if entry and entry.crc == crc and entry.size == #raw then return entry end
    if entry then
        cache_bytes = cache_bytes - entry.weight; cache[key] = nil
        for i, old in ipairs(order) do if old == key then table.remove(order, i); break end end
    end
    local source = xutils.to_utf8(raw)
    if not source then return nil end
    if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
    if not scanner then
        local config = {}; for k, v in pairs(require('codeoutline.lang.c').config) do config[k] = v end
        config.pp_first_branch = false
        scanner = require('codeoutline.xscan').lang(config)
    end
    local T = scanner:tokenize(source)
    local imports = {}
    for i = 1, T.n do
        if i % 4096 == 0 then control.check() end
        if T.k[i] == 'dir' then
            local text = T:text(i)
            local name = text:match('^#%s*include%s*[<"]([^>"]+)[>"]')
            if name then imports[#imports + 1] = { path = name, system = text:match('^#%s*include%s*<') ~= nil } end
        end
    end
    entry = { file = file, source = source, imports = imports, crc = crc, size = #raw,
        weight = #source * 2 + #imports * 128 + 256 }
    while #order > 0 and (#order >= M.CACHE_FILES or cache_bytes + entry.weight > M.CACHE_BYTES) do
        local old = table.remove(order, 1); cache_bytes = cache_bytes - cache[old].weight; cache[old] = nil
    end
    if entry.weight <= M.CACHE_BYTES then
        cache[key] = entry; order[#order + 1] = key; cache_bytes = cache_bytes + entry.weight
    end
    return entry
end
local function declarations(entry, name, type_site)
    local escaped = name:gsub('([^%w])', '%%%1')
    if not entry.source:find('%f[%w_$]' .. escaped .. '%f[^%w_$]') then return {} end
    if not entry.nodes then
        local rec = require('codeoutline.parse').parse(entry.file, entry.source, { type_uses = false, analysis = false })
        entry.nodes = rec and rec.nodes or {}
        local weight = #entry.nodes * 256
        if cache[paths.key(entry.file)] == entry then
            cache_bytes, entry.weight = cache_bytes + weight, entry.weight + weight
            while #order > 0 and cache_bytes > M.CACHE_BYTES do
                local old = table.remove(order, 1); cache_bytes = cache_bytes - cache[old].weight; cache[old] = nil
            end
        end
    end
    local result = {}
    for _, node in ipairs(entry.nodes) do
        if node.name == name and node.qualified == name and not node.parent and node.name_start
            and (type_site and require('codeoutline.type_references').kinds[node.kind]
                or not type_site and (node.kind == 'prototype' or node.kind == 'function')) then
            result[#result + 1] = { node = node, file = entry.file, source = entry.source,
                declaration = node.kind == 'prototype' or node.decl == true }
        end
    end
    return result
end

function M.find(G, f, site, ctx, system_directories)
    local info = { files = 0, bytes = 0, truncated = false }
    local type_site = site and site.kind == 'type' and site.reason == 'unresolved type'
        and not site.recv and site.evidence and site.evidence.written == site.name
        and not site.evidence.value_shadowed
    if not site or site.recv or not type_site and (site.kind ~= 'call'
        or not require('codeoutline.definition_candidates').allowed(site)) then return {}, info end
    local includes = require('codeoutline.cpp_includes')
    local headers, queued, projects, visited, project_queued = {}, {}, { f }, {}, { [f] = true }
    local defaults, started = nil, xtimer.now_ms()
    local function expired()
        control.check()
        if xtimer.now_ms() - started >= M.TIME_MS then info.truncated = true; return true end
        return false
    end
    local function dirs(owner)
        local policy = includes.policy(G, owner, ctx)
        local result = {}
        local function add_root(dir)
            control.check()
            local real = xutils.realpath(dir)
            if real then result[#result + 1] = paths.normalize(real) end
        end
        for _, dir in ipairs(policy.paths) do add_root(dir) end
        if not policy.configured then
            defaults = defaults or (type(system_directories) == 'function' and system_directories() or system_directories or {})
            for _, dir in ipairs(defaults) do add_root(dir) end
        end
        return result
    end
    local function add(file, roots)
        if file and not paths.contains(G.root, file) and not queued[paths.key(file)] then
            queued[paths.key(file)] = true; headers[#headers + 1] = { file = file, roots = roots }
        end
    end
    local function locate(imp, roots, parent)
        local written = imp.path:gsub('\\', '/')
        if written:find('[%z\r\n]') or written:match('^[/\\]') or written:match('^%a:') then return end
        if not imp.system and parent then
            local file = existing(directory(parent) .. '/' .. written)
            if file then
                for _, root in ipairs(roots) do if paths.contains(root, file) then return file end end
            end
        end
        for _, root in ipairs(roots) do
            local file = existing(root .. '/' .. written)
            if file and paths.contains(root, file) then return file end
        end
    end
    local pi = 1
    while pi <= #projects do
        if expired() then return {}, info end
        local owner = projects[pi]; pi = pi + 1
        if not visited[owner] then
            if pi > M.MAX_PROJECT_FILES + 1 then info.truncated = true; break end
            visited[owner] = true
            for _, imp in ipairs(G.files[owner].imports or {}) do
                if owner ~= f or not site.line or imp.line <= site.line then
                    local ids, selected, file = includes.resolve(G, owner, imp, ctx)
                    for _, id in ipairs(ids) do
                        if not project_queued[id] then
                            if #projects >= M.MAX_PROJECT_FILES then info.truncated = true
                            else project_queued[id] = true; projects[#projects + 1] = id end
                        end
                    end
                    if #ids == 0 then
                        local roots = dirs(owner)
                        if file then
                            file = existing(file)
                            if file and not paths.contains(G.root, file) then
                                roots[#roots + 1] = directory(file); add(file, roots)
                            end
                        elseif not selected then add(locate(imp, roots), roots) end
                    end
                end
            end
        end
    end
    local best, hi = {}, 1
    while hi <= #headers do
        if info.files >= M.MAX_FILES or expired() then info.truncated = true; break end
        local target = headers[hi]; hi = hi + 1
        local entry = read(target.file, info)
        if entry then
            local found = declarations(entry, site.name, type_site)
            for _, hit in ipairs(found) do
                if hit.declaration then return { hit }, info end
                if #best < 8 then best[#best + 1] = hit end
            end
            for _, imp in ipairs(entry.imports) do add(locate(imp, target.roots, target.file), target.roots) end
        end
    end
    return best, info
end
return M
