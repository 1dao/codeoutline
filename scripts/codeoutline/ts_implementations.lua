-- Conservative named TS contracts. All token evidence belongs to one query.
local M = {}
local control = require('codeoutline.control')

function M.collect(r, T)
    local evidence = {}
    local function annotation(a, b)
        if a > b then return nil end
        local text = T.src:sub(T.s[a], T.e[b]):gsub('%s+', '')
        if text:match('^[%a_$][%w_$.]*$') or text:match('^[%a_$][%w_$.]*%[%]$') then return text end
    end
    for index, n in ipairs(r.nodes) do
        if index % 128 == 0 then control.check() end
        if n.kind == 'class' or n.kind == 'interface' or n.kind == 'method' then
            local d = { at = T.s[n.ti] - 1 }
            local opening, ni
            for i = n.ti, n.tj do
                local s = T:text(i)
                if s == '{' then break end
                if s == '<' then d.generic = true end
                if s == 'static' or s == 'private' or s == 'protected' or s == 'abstract' or s == 'declare' then d[s] = true end
                if s == 'get' or s == 'set' then d.accessor = true end
                if n.kind == 'method' and s == n.name and T:text(i + 1) == '(' then ni, opening = i, i + 1; break end
            end
            if opening and T.m[opening] and not n.name:find('^#') then
                local close, params, valid = T.m[opening], {}, true
                local a = opening + 1
                for i = a, close do
                    if i == close or T:text(i) == ',' then
                        if a < i then
                            local ty = T.k[a] == 'id' and T:text(a + 1) == ':' and annotation(a + 2, i - 1)
                            if not ty then valid = false end
                            params[#params + 1] = ty or '?'; a = i + 1
                        elseif i ~= close or i > opening + 1 then valid = false end
                    end
                end
                if valid then d.params = params end
                local last = close + 1
                if T:text(last) == ':' then
                    local first = last + 1; last = first
                    while last <= n.tj and T:text(last) ~= '{' and T:text(last) ~= ';' do last = last + 1 end
                    d.returns = annotation(first, last - 1)
                end
                d.body = T:text(last) == '{'
                -- Optional names, accessors and arrow fields are not ordinary methods.
                if T:text(ni - 1) == '#' or d.accessor then d.params = nil end
            end
            evidence[index] = d
        end
    end
    r.implementation_evidence = evidence
end

function M.types(G, f, written, ctx)
    if not written:match('^[%a_$][%w_$.]*$') then return {} end
    local head, tail = written:match('^([%w_$]+)%.([%w_$]+)$')
    local ids
    for _, imp in ipairs(G.files[f].js_imports or {}) do
        if imp.local_name == (head or written) then
            if tail and imp.imported ~= '*' or not tail and imp.imported == '*' then return {} end
            ids = require('codeoutline.js_resolution').imported(G, f, imp.path, tail or imp.imported, ctx)
            break
        end
    end
    if not ids then
        ids = {}
        for _, id in ipairs(G.by_name[written] or {}) do
            local n = G.nodes[id]
            if G.node_file[id] == f and not n.parent then ids[#ids + 1] = id end
        end
    end
    -- A same-name alias/value is a barrier rather than a global-name fallback.
    if #ids ~= 1 then return {} end
    local n = G.nodes[ids[1]]
    if n.parent or (n.kind ~= 'class' and n.kind ~= 'interface')
        or G.files[G.node_file[ids[1]]].language ~= 'typescript' then return {} end
    return ids
end

return M
