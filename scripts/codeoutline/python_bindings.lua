-- Explicit Python imports and lexical barriers, shared by graph and navigation.
-- No sys.path execution or project-wide suffix guesses.
local M = {}
local aliases = require('codeoutline.dispatch_aliases')
local control = require('codeoutline.control')

function M.collect(r, T)
    if r.language ~= 'python' then return end
    local imports = aliases.imports(r, T)
    local expand = aliases.prepare(r, T)
    r.python_imports = {}
    for _, imp in ipairs(imports) do
        local nested = false
        for _, n in ipairs(r.nodes) do
            if n.ti <= imp.token and imp.token <= n.tj then nested = true; break end
        end
        if not nested then
            local value = expand({ symbol = imp.name }, T.n)
            r.python_imports[#r.python_imports + 1] = {
                name = imp.name, path = imp.path, imported = imp.imported,
                blocked = not value or not value.import or nil,
            }
        end
    end
    for i, ref in ipairs(r.refs) do
        if i % 128 == 0 then control.check() end
        if (ref.kind == 'call' or ref.kind == 'member_call') and ref.recv ~= 'self' and ref.recv ~= 'cls' then
            local symbol, first = ref.name, ref.tok
            while T:text(first - 1) == '.' and T.k[first - 2] == 'id' do
                symbol = T:text(first - 2) .. '.' .. symbol; first = first - 2
            end
            local value = expand({ symbol = symbol }, ref.tok)
            if value == false or ref.kind == 'member_call' and first == ref.tok then ref.binding = 'py:?'
            elseif value and value.import then
                ref.binding = 'py:import:' .. value.import.path .. '\0' .. value.member
            elseif value and value.node and not ref.recv then ref.binding = 'py:node:' .. value.node end
        end
    end
end

local function directory(path) return path:match('^(.*)/[^/]*$') or '' end
local function module(G, f, path)
    local dots = path:match('^(%.+)')
    local base = ''
    if dots then
        base = directory(G.files[f].path)
        for _ = 2, #dots do
            if base == '' then return nil end
            base = directory(base)
        end
        path = path:sub(#dots + 1)
    end
    local rel = (base ~= '' and base .. '/' or '') .. path:gsub('%.', '/')
    rel = rel:gsub('/$', '')
    for _, candidate in ipairs({ rel .. '.py', rel .. '/__init__.py' }) do
        local id = G.file_index[candidate]
        if id then return id end
    end
end

local function exported(G, f, member, seen, depth, ctx)
    control.check()
    if depth > 8 then return {} end
    local key = f .. '\0' .. member
    if seen[key] then return {} end
    seen[key] = true
    local result = {}
    for _, id in ipairs(G.id_of[f]) do
        local node = G.nodes[id]
        if not node.parent and node.name == member then result[#result + 1] = id end
    end
    if #result > 0 then return result end
    local head, tail = member:match('^([^.]+)%.(.*)$')
    head = head or member
    local rec = ctx and ctx.ordinary and ctx.ordinary.data(f) or G.files[f]
    for _, imp in ipairs(rec.python_imports or {}) do
        if imp.name == head then
            if imp.blocked then return {} end
            local target = module(G, f, imp.path)
            local want = imp.imported == '*' and (tail or '') or imp.imported .. (tail and '.' .. tail or '')
            if target then
                for _, id in ipairs(exported(G, target, want, seen, depth + 1, ctx)) do result[#result + 1] = id end
            end
        end
    end
    -- A package may expose a submodule without re-exporting its declarations.
    if head and tail and G.files[f].path:match('/__init__%.py$') then
        local sub = G.file_index[directory(G.files[f].path) .. '/' .. head .. '.py']
            or G.file_index[directory(G.files[f].path) .. '/' .. head .. '/__init__.py']
        if sub then
            for _, id in ipairs(exported(G, sub, tail, seen, depth + 1, ctx)) do result[#result + 1] = id end
        end
    end
    return result
end

function M.resolve(G, f, evidence, ctx)
    if G.files[f].language ~= 'python' or not evidence or evidence:sub(1, 3) ~= 'py:' then return nil end
    local node = evidence:match('^py:node:(%d+)$')
    if node then return { G.id_of[f][tonumber(node)] } end
    local path, member = evidence:match('^py:import:(.-)%z(.*)$')
    if not path then return {} end
    local target = module(G, f, path)
    return target and exported(G, target, member, {}, 0, ctx) or {}
end
M.module = module
function M.imported(G, f, path, name, ctx)
    local target = module(G, f, path)
    return target and exported(G, target, name, {}, 0, ctx) or {}
end

return M
