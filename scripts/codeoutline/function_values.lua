-- Compact function-as-value sites. Resolution reuses query-owned bindings;
-- these are references, never proof of a callback being executed.
local M = {}
local supported = { javascript = true, typescript = true, arkts = true, python = true, java = true }
local callable = { ['function'] = true, method = true }
local before = { ['('] = true, [','] = true, ['='] = true, ['['] = true, [':'] = true }
local after = { [')'] = true, [','] = true, [';'] = true, [']'] = true, ['}'] = true }

function M.collect(r, T)
    if not supported[r.language] then return end
    -- The ordinary parser does not represent every anonymous scope. Do not
    -- borrow outer binding evidence where an unindexed parameter can shadow it.
    if r.language ~= 'java' then
        local headers = {}
        for _, n in ipairs(r.nodes) do
            if callable[n.kind] then
                for i = n.ti, n.tj do
                    local s = T:text(i)
                    if s == 'function' or s == '=>' then headers[i] = true end
                    if s == '{' then break end
                end
            end
        end
        for i = 1, T.n do
            if (T:text(i) == '=>' or T:text(i) == 'function') and not headers[i]
                or r.language == 'python' and T:text(i) == 'lambda' then return end
        end
    end
    local names, roots, seen = {}, {}, {}
    for _, n in ipairs(r.nodes) do if callable[n.kind] then names[n.name] = true end end
    if r.language ~= 'java' then
        for _, imp in ipairs(require('codeoutline.dispatch_aliases').imports(r, T)) do
            names[imp.name], roots[imp.name] = true, true
        end
    end
    for _, ref in ipairs(r.refs) do seen[ref.tok] = true end
    local aliases = {}
    for i = 2, T.n - 1 do
        if T:text(i) == '=' and T.k[i - 1] == 'id' and T.k[i + 1] == 'id'
            and (after[T:text(i + 2)] or T.k[i + 2] == 'nl') then
            aliases[#aliases + 1] = { T:text(i - 1), T:text(i + 1) }
        end
    end
    for _ = 1, 8 do
        local changed = false
        for _, alias in ipairs(aliases) do
            if names[alias[2]] and not names[alias[1]] then names[alias[1]], changed = true, true end
        end
        if not changed then break end
    end
    for i = 1, T.n do
        if i % 4096 == 0 then require('codeoutline.control').check() end
        if T.k[i] == 'id' and not seen[i] then
            local prev, next = T:text(i - 1), T:text(i + 1)
            local explicit = prev == '::' and r.language == 'java'
            local recv = (prev == '.' or explicit) and
                (T.k[i - 2] == 'id' or T:text(i - 2) == 'this' or T:text(i - 2) == 'self' or T:text(i - 2) == 'cls') and T:text(i - 2)
            local first = recv and i - 2 or i
            local simple = before[T:text(first - 1)] and
                (after[next] or T.k[i + 1] == 'nl' or i == T.n)
            if (explicit or r.language ~= 'java' and simple and (names[T:text(i)] or roots[recv]))
                and not (recv and (T:text(first - 1) == '.' or T:text(first - 1) == '?.')) then
                r.refs[#r.refs + 1] = { tok = i, name = T:text(i), kind = 'ref', recv = recv, line = T:line(i) }
            end
        end
    end
end

return M
