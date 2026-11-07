-- Finite, non-executing TOML reader for Cargo lookup. Reject unsupported values
-- in relevant tables; unrelated metadata and array-of-table targets are skipped.
local M = {}
local function parse_value(raw)
    local i, n = 1, #raw
    local value
    local function space() while i <= n and raw:sub(i, i):match('%s') do i = i + 1 end end
    local function string_value()
        local quote, first = raw:sub(i, i), i
        i = i + 1
        local escaped = false
        while i <= n do
            local c = raw:sub(i, i)
            if c == quote and not escaped then
                local text = raw:sub(first, i); i = i + 1
                if quote == "'" then return text:sub(2, -2) end
                local ok, decoded = pcall(xutils.json_unpack, text)
                if not ok then error('unsupported Cargo TOML string', 0) end
                return decoded
            end
            escaped = quote == '"' and c == '\\' and not escaped
            i = i + 1
        end
        error('unterminated Cargo TOML string', 0)
    end
    value = function(depth)
        if depth > 16 then error('Cargo TOML nesting limit reached', 0) end
        space()
        local c = raw:sub(i, i)
        if c == '"' or c == "'" then return string_value() end
        if c == '[' or c == '{' then
            local object, result = c == '{', {}; i = i + 1; space()
            local close = object and '}' or ']'
            while raw:sub(i, i) ~= close do
                if i > n then error('unterminated Cargo TOML collection', 0) end
                local key
                if object then
                    if raw:sub(i, i) == '"' or raw:sub(i, i) == "'" then key = string_value()
                    else key = raw:match('^([%w_-]+)', i); if key then i = i + #key end end
                    space()
                    if not key or raw:sub(i, i) ~= '=' then error('unsupported Cargo TOML key', 0) end
                    i = i + 1
                    if result[key] ~= nil then error('duplicate Cargo TOML key', 0) end
                end
                local item = value(depth + 1)
                if object then result[key] = item else result[#result + 1] = item end
                space()
                if raw:sub(i, i) == ',' then i = i + 1; space()
                elseif raw:sub(i, i) ~= close then error('unsupported Cargo TOML collection', 0) end
            end
            i = i + 1; return result
        end
        local word = raw:match('^([^,%s}%]]+)', i)
        if word == 'true' then i = i + 4; return true end
        if word == 'false' then i = i + 5; return false end
        if word and tonumber(word) then i = i + #word; return tonumber(word) end
        error('unsupported Cargo TOML value', 0)
    end
    local result = value(0); space()
    if i <= n then error('unsupported Cargo TOML value suffix', 0) end
    return result
end

local function clean(raw)
    local out, quote, escaped, comment = {}, nil, false, false
    for i = 1, #raw do
        local c = raw:sub(i, i)
        if comment then
            if c == '\n' then comment = false; out[#out + 1] = c end
        elseif quote then
            out[#out + 1] = c
            if c == quote and not escaped then quote = nil end
            escaped = quote == '"' and c == '\\' and not escaped
        elseif c == '#' then comment = true
        else
            out[#out + 1] = c
            if c == '"' or c == "'" then quote = c; escaped = false end
        end
    end
    return table.concat(out)
end

function M.parse(raw)
    local result, section, pending, balance, quote, escaped = {}, '', '', 0, nil, false
    local function relevant(s)
        return s == 'package' or s == 'lib' or s == 'workspace' or s == 'dependencies'
            or s == 'workspace.dependencies' or s:match('^dependencies%.') or s:match('^workspace%.dependencies%.')
    end
    local function statement(line)
        line = line:match('^%s*(.-)%s*$')
        if line == '' then return end
        if line:sub(1, 2) == '[[' then section = ''; return end
        if line:sub(1, 1) == '[' then
            section = line:match('^%[([%w_.-]+)%]$') or ''
            if relevant(section) then result[section] = result[section] or {} end
            return
        end
        if not relevant(section) then return end
        local key, raw_value = line:match('^([%w_.-]+)%s*=%s*(.+)$')
        if not key then error('unsupported Cargo TOML assignment', 0) end
        local entries = result[section]
        if entries[key] ~= nil then error('duplicate Cargo TOML assignment', 0) end
        entries[key] = parse_value(raw_value)
    end
    for line in (clean(raw) .. '\n'):gmatch('(.-)\r?\n') do
        if pending == '' and line:match('^%s*%[') then statement(line)
        else
            for i = 1, #line do
                local c = line:sub(i, i)
                if quote then
                    if c == quote and not escaped then quote = nil end
                    escaped = quote == '"' and c == '\\' and not escaped
                elseif c == '"' or c == "'" then quote = c; escaped = false
                elseif c == '[' or c == '{' then balance = balance + 1
                elseif c == ']' or c == '}' then balance = balance - 1 end
            end
            pending = pending .. line .. '\n'
            if balance == 0 and not quote then statement(pending); pending = '' end
        end
    end
    if pending:match('%S') or quote or balance ~= 0 then error('incomplete Cargo TOML value', 0) end
    return result
end

return M
