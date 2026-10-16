-- Language-neutral native exports. Adapters supply registration evidence and
-- guest parameters; implementation nodes retain their original host signature.
local M = {}

function M.register(rec, language, module, exports)
    rec.foreign_exports = rec.foreign_exports or {}
    rec.foreign_exports[language] = rec.foreign_exports[language] or {}
    rec.foreign_exports[language][module] = exports
end

function M.exports(rec, language, module)
    return rec.foreign_exports and rec.foreign_exports[language] and rec.foreign_exports[language][module]
end

function M.collect(rec, T)
    require('codeoutline.foreign_lua').collect(rec, T)
end

function M.modules(G, language, name, ctx)
    ctx = ctx or {}
    if not ctx.foreign then
        ctx.foreign = {}
        local seen = {}
        local function add(f)
            if seen[f] then return end
            seen[f] = true
            for lang, modules in pairs(G.files[f].foreign_exports or {}) do
                ctx.foreign[lang] = ctx.foreign[lang] or {}
                for module in pairs(modules) do
                    local names = ctx.foreign[lang]
                    names[module] = names[module] or {}
                    table.insert(names[module], f)
                end
            end
        end
        for _, f in ipairs(G.file_order or {}) do add(f) end
        for _, f in ipairs(G.new_files or {}) do add(f) end
    end
    return (ctx.foreign[language] or {})[name] or {}
end

-- Parameter labels are structured data, never reparsed as host-language code.
function M.signature(node, language, name)
    local contract = node.foreign_signatures and node.foreign_signatures[language]
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
    local contract = node.foreign_signatures and node.foreign_signatures[language]
    return contract and contract.returns or nil
end

return M
