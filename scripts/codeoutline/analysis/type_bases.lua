-- Query-only verification of base syntax: compact parser headers erase generics.
local M = {}

function M.collect(T, n, language)
    local ni
    for i = n.ti, n.tj do
        local s = T:text(i)
        if s == '<' or s == '>' then return nil end
        if T.k[i] == 'id' and s == n.name then ni = i; break end
        if s == '{' then return nil end
    end
    if not ni then return nil end
    local result, words, mode = {}, {}, nil
    local separator = language == 'cpp' and '::' or '.'
    local function flush()
        if #words == 0 then return false end
        local written = table.concat(words)
        local normalized = written:gsub('^::', '')
        if language == 'csharp' then normalized = normalized:gsub('^global::', '') end
        local pattern = separator == '.' and '^[%a_$][%w_$]*[%.%w_$]*$' or '^[%a_][%w_:]*$'
        if not normalized:match(pattern) or normalized:match('[%.:]$') then return false end
        result[#result + 1] = { written = written, kind = mode ~= 'base' and mode or nil }
        words = {}; return true
    end
    local i = ni + 1
    while i <= n.tj do
        local s = T:text(i)
        if s == '{' or s == ';' or s == 'where' or s == 'permits' then break end
        if s == '<' or s == '>' then return nil end
        if s == ':' and not mode then mode = 'base'
        elseif s == 'extends' or s == 'implements' then
            if #words > 0 and not flush() then return nil end
            mode = s
        elseif s == '(' and T.m[i] then
            if mode then
                if language ~= 'kotlin' or #words == 0 then return nil end
            elseif language ~= 'kotlin' and language ~= 'csharp' and not (language == 'java' and n.kind == 'record') then return nil end
            i = T.m[i]
        elseif mode then
            if s == ',' then
                if not flush() then return nil end
            elseif language == 'cpp' and (s == 'public' or s == 'protected' or s == 'private' or s == 'virtual') then
                if #words > 0 then return nil end
            elseif s == separator or language == 'csharp' and s == '::' then
                if #words == 0 and not (language == 'cpp' and s == '::') then return nil end
                words[#words + 1] = s
            elseif T.k[i] == 'id' then
                -- Adjacent names (TS factory expressions, Kotlin delegation, etc.)
                -- are not a named base. Never discard the intervening syntax.
                if #words > 0 and words[#words] ~= separator and words[#words] ~= '::' then return nil end
                words[#words + 1] = s
            else return nil end
        elseif s ~= 'final' and s ~= 'sealed' and s ~= 'constructor'
            and s ~= 'public' and s ~= 'private' and s ~= 'protected' and s ~= 'internal' then return nil end
        i = i + 1
    end
    if #words > 0 and not flush() then return nil end
    return result
end

return M
