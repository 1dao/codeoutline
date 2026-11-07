-- Seed selection only. These predicates never restrict graph expansion.
local M = {}
local fields = { kind = 'kinds', lang = 'languages', language = 'languages', path = 'paths', name = 'names' }
local aliases = { js = 'javascript', ts = 'typescript', py = 'python', ['c++'] = 'cpp', ['c#'] = 'csharp', cs = 'csharp', kt = 'kotlin', rs = 'rust' }
local languages = { c = true, cpp = true, csharp = true, javascript = true, typescript = true,
    arkts = true, python = true, lua = true, kotlin = true, java = true, go = true, rust = true }

function M.parse(query)
    local out = { text = '', kinds = {}, languages = {}, paths = {}, names = {}, count = 0 }
    local words, at = {}, 1
    while at <= #query do
        local first = query:find('%S', at)
        if not first then break end
        local key, value_at = query:match('^([%a]+):()', first)
        local field = key and fields[key:lower()]
        if field then
            local value, last
            if query:sub(value_at, value_at) == '"' then
                last = assert(query:find('"', value_at + 1, true), 'unterminated quoted query filter')
                value = query:sub(value_at + 1, last - 1)
                assert(last == #query or query:sub(last + 1, last + 1):match('%s'), 'query filter must end at whitespace')
            else
                last = (query:find('%s', value_at) or #query + 1) - 1
                value = query:sub(value_at, last)
            end
            assert(value ~= '' and value:find('%S'), 'query filter value must not be empty')
            value = value:lower()
            if field == 'languages' then
                value = aliases[value] or value
                assert(languages[value], 'unsupported query language: ' .. value)
            elseif field == 'paths' then value = value:gsub('\\', '/') end
            out[field][#out[field] + 1] = value
            out.count = out.count + 1
            at = last + 1
        else
            local last = (query:find('%s', first) or #query + 1) - 1
            words[#words + 1] = query:sub(first, last); at = last + 1
        end
    end
    out.text = table.concat(words, ' ')
    return out
end

local function matches(values, value, exact)
    if #values == 0 then return true end
    value = value:lower()
    for _, wanted in ipairs(values) do
        if exact and value == wanted or not exact and value:find(wanted, 1, true) then return true end
    end
    return false
end

function M.file(filters, rec)
    return matches(filters.languages, rec.language, true) and matches(filters.paths, (rec.path:gsub('\\', '/')))
end

function M.node(filters, rec, node)
    return M.file(filters, rec) and matches(filters.kinds, node.kind, true) and matches(filters.names, node.qualified)
end

function M.id(filters, G, id)
    return filters.count == 0 or M.node(filters, G.files[G.node_file[id]], G.nodes[id])
end

return M
