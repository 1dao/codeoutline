-- Language-neutral native exports. Adapters supply registration evidence and
-- guest parameters; implementation nodes retain their original host signature.
local M = {}
-- Side caches never mutate index records or nodes. Entries follow record identity
-- (including overlays) and share navigation's bounded full-parse cache.
local records, contracts, order = setmetatable({}, { __mode = 'k' }), setmetatable({}, { __mode = 'k' }), {}
local function load(G, f)
    local rec = G.files[f]
    if records[rec] ~= nil then return records[rec] or nil end
    local full = require('codeoutline.navigation').full(G, f, true)
    if not full then return nil end
    -- Node indices are stable only while the source still matches the index.
    for n, node in ipairs(rec.nodes) do
        local current = full.nodes[n]
        if not current or current.name ~= node.name or current.line ~= node.line then return nil end
    end
    if #full.nodes ~= #rec.nodes then return nil end
    local entry = full.foreign_exports or false
    records[rec] = entry
    if entry then
        for n, node in ipairs(rec.nodes) do contracts[node] = full.nodes[n].foreign_signatures end
    end
    order[#order + 1] = rec
    if #order > 64 then
        local old = table.remove(order, 1)
        records[old] = nil
        for _, node in ipairs(old.nodes) do contracts[node] = nil end
    end
    return entry or nil
end

-- Find candidate files from existing symbols without reading their sources.
local function candidates(G, ctx)
    if ctx.foreign_candidates then return ctx.foreign_candidates end
    local result, seen = {}, {}
    local function add(f)
        if seen[f] then return end
        seen[f] = true
        local rec = G.files[f]
        if rec.language ~= 'c' and rec.language ~= 'cpp' then return end
        for _, node in ipairs(rec.nodes) do
            local name = node.name:match('^luaopen_(.+)$')
            if name then
                result[name] = result[name] or {}
                result[name][#result[name] + 1] = f
            end
        end
    end
    for _, f in ipairs(G.file_order or {}) do add(f) end
    for _, f in ipairs(G.new_files or {}) do add(f) end
    ctx.foreign_candidates = result
    return result
end

function M.has_candidates(G, ctx) return next(candidates(G, ctx)) ~= nil end

function M.register(rec, language, module, exports)
    rec.foreign_exports = rec.foreign_exports or {}
    rec.foreign_exports[language] = rec.foreign_exports[language] or {}
    rec.foreign_exports[language][module] = exports
end

function M.exports(rec, language, module)
    local exports = records[rec] or rec.foreign_exports
    local modules = exports and exports[language]
    return modules and (modules[module] or language == 'lua' and type(module) == 'string'
        and modules[module:gsub('%.', '_')])
end

function M.collect(rec, T)
    require('codeoutline.foreign_lua').collect(rec, T)
end

function M.modules(G, language, name, ctx)
    ctx = ctx or {}
    if not name then return {} end
    local loader = language == 'lua' and name:gsub('%.', '_') or name
    ctx.foreign = ctx.foreign or {}
    ctx.foreign_loaded = ctx.foreign_loaded or {}
    for _, f in ipairs(candidates(G, ctx)[loader] or {}) do
        if not ctx.foreign_loaded[f] then
            local exports = load(G, f)
            -- Failed reads can be skipped within this query, but are never
            -- retained on the record across later query contexts.
            ctx.foreign_loaded[f] = true
            for lang, modules in pairs(exports or {}) do
                ctx.foreign[lang] = ctx.foreign[lang] or {}
                for module in pairs(modules) do
                    local names = ctx.foreign[lang]
                    names[module] = names[module] or {}
                    names[module][#names[module] + 1] = f
                end
            end
        end
    end
    local modules = ctx.foreign[language] or {}
    local files = modules[name] or modules[loader] or {}
    -- A long query may have evicted a previously used record.
    for _, f in ipairs(files) do load(G, f) end
    return files
end

-- Lua's C loader replaces dots in a module name when naming the entry point.
-- The indexed entry alone is sufficient for navigating the require string;
-- member bindings still require the separately verified registration table.
function M.lua_entrypoints(G, name)
    local result = {}
    local symbol = 'luaopen_' .. name:gsub('%.', '_')
    for _, id in ipairs(G.by_name[symbol] or {}) do
        local node, f = G.nodes[id], G.node_file[id]
        if node.kind == 'function' and not node.static and (G.files[f].language == 'c' or G.files[f].language == 'cpp') then
            result[#result + 1] = id
        end
    end
    return result
end

-- Parameter labels are structured data, never reparsed as host-language code.
function M.signature(node, language, name)
    local signatures = contracts[node] or node.foreign_signatures
    local contract = signatures and signatures[language]
    if not contract then return nil end
    local labels, parameters = {}, {}
    for i, p in ipairs(contract.parameters) do
        local label = (p.name or ('arg' .. i)) .. (p.optional and '?' or '') .. ':' .. (p.type or 'unknown')
        if p.default then label = label .. ' = ' .. p.default end
        labels[#labels + 1] = label
        parameters[#parameters + 1] = { label = label }
    end
    if contract.unknown_tail then
        labels[#labels + 1] = '...:unknown'
        parameters[#parameters + 1] = { label = '...:unknown' }
    end
    return { label = (name or node.name) .. '(' .. table.concat(labels, ', ') .. ')'
        .. (contract.returns and ' -> ' .. contract.returns or ''), parameters = parameters }
end

-- Guest-facing result type: the native metatable the implementation returns.
function M.returns(node, language)
    local signatures = contracts[node] or node.foreign_signatures
    local contract = signatures and signatures[language]
    return contract and contract.returns or nil
end

return M
