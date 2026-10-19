-- JS/TS module and receiver evidence; deliberately not a type checker.
local M = {}
local control = require('codeoutline.control')
local function js(rec) return rec and (rec.language == 'javascript' or rec.language == 'typescript') end
local function dir(p) return p:match('^(.*)/[^/]*$') or '' end
local function norm(p)
    local parts = {}
    for s in p:gsub('\\', '/'):gmatch('[^/]+') do
        if s == '..' and #parts > 0 and parts[#parts] ~= '..' then parts[#parts] = nil
        elseif s ~= '.' then parts[#parts + 1] = s end
    end
    return (p:sub(1, 1) == '/' and '/' or '') .. table.concat(parts, '/')
end

-- JSONC is tokenized, never executed. Token-aware comma removal preserves strings.
local function config(path, seen, depth)
    path = norm(path)
    if seen[path] or depth > 8 then return {} end
    seen[path] = true
    local f = io.open(path, 'rb')
    if not f then return {} end
    local raw = f:read(1048577); f:close()
    assert(#raw <= 1048576, 'JS project configuration exceeds 1 MiB: ' .. path)
    local T = require('codeoutline.lang.js').lang:tokenize(raw)
    local parts = {}
    for i = 1, T.n do
        local s, next = T:text(i), T:text(i + 1)
        if not (s == ',' and (next == '}' or next == ']')) then parts[#parts + 1] = s end
    end
    local ok, data = pcall(xutils.json_unpack, table.concat(parts, ' '))
    assert(ok and type(data) == 'table', 'invalid JS project configuration: ' .. path)
    local base = dir(path)
    local effective = {}
    if type(data.extends) == 'string' and data.extends:sub(1, 1) == '.' then
        local parent = norm(base .. '/' .. data.extends)
        if not parent:match('%.json$') then parent = parent .. '.json' end
        effective = config(parent, seen, depth + 1)
    end
    local co = data.compilerOptions or {}
    if type(co.baseUrl) == 'string' then effective.base = norm(base .. '/' .. co.baseUrl) end
    if type(co.paths) == 'table' then effective.paths, effective.origin = co.paths, base end
    return effective
end

function M.context(G)
    local ctx = { modules = {}, exports = {} }
    if G.root then
        for _, name in ipairs({ 'tsconfig.json', 'jsconfig.json', 'tsconfig.base.json' }) do
            local opts = config(G.root .. '/' .. name, {}, 0)
            if opts.paths then
                ctx.base, ctx.patterns = opts.base or opts.origin, {}
                for pattern, targets in pairs(opts.paths) do
                    if type(pattern) == 'string' and type(targets) == 'table' then
                        local pre, post = pattern:match('^(.-)%*(.-)$')
                        ctx.patterns[#ctx.patterns + 1] = { pattern = pattern, pre = pre, post = post, targets = targets }
                    end
                end
                table.sort(ctx.patterns, function(a, b)
                    local ap, bp = a.pre or a.pattern, b.pre or b.pattern
                    if #ap ~= #bp then return #ap > #bp end
                    if (a.pre == nil) ~= (b.pre == nil) then return a.pre == nil end
                    return a.pattern < b.pattern
                end)
                break
            end
        end
    end
    return ctx
end

local extensions = { '', '.ts', '.tsx', '.js', '.jsx', '.mts', '.cts', '.mjs', '.cjs',
    '/index.ts', '/index.tsx', '/index.js', '/index.jsx', '/index.mts', '/index.mjs' }
function M.module(G, f, spec, ctx)
    ctx = ctx or M.context(G)
    local key = f .. '\0' .. spec
    if ctx.modules[key] ~= nil then return ctx.modules[key] or nil end
    local bases = {}
    if spec:sub(1, 1) == '.' then bases[1] = norm(dir(G.files[f].path) .. '/' .. spec):gsub('^/', '')
    else
        for _, p in ipairs(ctx.patterns or {}) do
            local capture
            if not p.pre and spec == p.pattern then capture = ''
            elseif p.pre and spec:sub(1, #p.pre) == p.pre and (#p.post == 0 or spec:sub(-#p.post) == p.post)
                and #spec >= #p.pre + #p.post then capture = spec:sub(#p.pre + 1, #spec - #p.post) end
            if capture then
                for _, target in ipairs(p.targets) do
                    if type(target) == 'string' then
                        local absolute = norm(ctx.base .. '/' .. target:gsub('%*', function() return capture end))
                        local root = norm(G.root)
                        if absolute:sub(1, #root + 1) == root .. '/' then bases[#bases + 1] = absolute:sub(#root + 2) end
                    end
                end
                break
            end
        end
    end
    for _, base in ipairs(bases) do
        local candidates = { base }
        if base:match('%.js$') then candidates[#candidates + 1] = base:gsub('%.js$', '.ts'); candidates[#candidates + 1] = base:gsub('%.js$', '.tsx') end
        for _, ext in ipairs(extensions) do candidates[#candidates + 1] = base .. ext end
        for _, candidate in ipairs(candidates) do
            local target = G.file_index[candidate]
            if target and js(G.files[target]) then ctx.modules[key] = target; return target end
        end
    end
    ctx.modules[key] = false
end

local function exported(G, f, name, ctx, seen, depth)
    control.check()
    if depth > 8 then return {} end
    local key = f .. '\0' .. name
    if depth == 0 and ctx.exports[key] then return ctx.exports[key] end
    if seen[key] then return {} end
    seen[key] = true
    local result, unique = {}, {}
    local function add(ids) for _, id in ipairs(ids) do if not unique[id] then unique[id] = true; result[#result + 1] = id end end end
    local rec = G.files[f]
    local entries = rec.js_exports or {}
    local explicit = false
    for _, e in ipairs(entries) do if e.name == name then explicit = true end end
    for _, e in ipairs(entries) do
        if e.name == name or (not explicit and e.name == '*' and name ~= 'default') then
            local want = e.local_name == '*' and name or e.local_name
            if e.path then
                local target = M.module(G, f, e.path, ctx)
                if target then add(exported(G, target, want, ctx, seen, depth + 1)) end
            else
                for _, id in ipairs(G.id_of[f]) do
                    local n = G.nodes[id]
                    if not n.parent and n.name == want then add({ id }) end
                end
                for _, b in ipairs(rec.js_imports or {}) do
                    if b.local_name == want then
                        local target = M.module(G, f, b.path, ctx)
                        if target then add(exported(G, target, b.imported, ctx, seen, depth + 1)) end
                    end
                end
            end
        end
    end
    if depth == 0 then ctx.exports[key] = result end
    return result
end

-- Shared named/namespace import lookup for query-owned callback aliases.
function M.imported(G, f, path, name, ctx)
    ctx = ctx or M.context(G)
    local target = M.module(G, f, path, ctx)
    return target and name ~= '' and exported(G, target, name, ctx, {}, 0) or {}
end

function M.resolve(G, f, name, kind, recv, evidence, ctx)
    local rec = G.files[f]
    if not js(rec) then return nil end
    ctx = ctx or M.context(G)
    local function binding(local_name, member)
        for _, b in ipairs(rec.js_imports or {}) do
            if b.local_name == local_name then
                local target = M.module(G, f, b.path, ctx)
                if not target then return {} end
                if b.imported == '*' then return member and exported(G, target, member, ctx, {}, 0) or {} end
                return exported(G, target, b.imported, ctx, {}, 0)
            end
        end
    end
    if evidence == false then return {} end
    if evidence then
        local node = evidence:match('^node:(%d+)$')
        if node then return { G.id_of[f][tonumber(node)] } end
        local head, tail = evidence:match('^([%w_$]+)%.([%w_$]+)$')
        local classes = binding(head or evidence, tail)
        if classes == nil then
            classes = {}
            for _, id in ipairs(G.id_of[f]) do
                local n = G.nodes[id]
                if not n.parent and n.name == evidence and (n.kind == 'class' or n.kind == 'interface') then classes[#classes + 1] = id end
            end
        end
        local result = {}
        for _, cls in ipairs(classes) do
            if G.nodes[cls].kind == 'class' or G.nodes[cls].kind == 'interface' then
                for _, id in ipairs(G.by_name[name] or {}) do
                    local n = G.nodes[id]
                    if n.parent and G.id_of[G.node_file[id]][n.parent] == cls then result[#result + 1] = id end
                end
            end
        end
        return result
    end
    if recv then
        for _, b in ipairs(rec.js_imports or {}) do
            if b.local_name == recv then
                if b.imported == '*' then return binding(recv, name) end
                local result = {}
                for _, cls in ipairs(binding(recv) or {}) do
                    for _, id in ipairs(G.by_name[name] or {}) do
                        local n = G.nodes[id]
                        if n.parent and G.id_of[G.node_file[id]][n.parent] == cls then result[#result + 1] = id end
                    end
                end
                return result
            end
        end
    else return binding(name) end
end

return M
