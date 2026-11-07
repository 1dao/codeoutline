-- Decode Lua string syntax without evaluating source code.
local M = {}
function M.decode(raw)
    local eq, body = raw:match('^%[(=*)%[(.*)%]%1%]$')
    if eq then return body:gsub('^\r?\n', '', 1) end
    local quote = raw:sub(1, 1)
    if (quote ~= '"' and quote ~= "'") or raw:sub(-1) ~= quote then return nil end
    if not raw:find('\\', 1, true) then return raw:sub(2, -2) end
    local escaped = { a = '\a', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', v = '\v',
        ['\\'] = '\\', ['"'] = '"', ["'"] = "'", ['\n'] = '\n' }
    local out, i, stop = {}, 2, #raw - 1
    while i <= stop do
        local c = raw:sub(i, i)
        if c ~= '\\' then out[#out + 1] = c; i = i + 1
        else
            c = raw:sub(i + 1, i + 1); i = i + 2
            if escaped[c] then out[#out + 1] = escaped[c]
            elseif c == 'z' then
                while i <= stop and raw:sub(i, i):match('%s') do i = i + 1 end
            elseif c == '\r' then
                if raw:sub(i, i) == '\n' then i = i + 1 end
                out[#out + 1] = '\n'
            elseif c == 'x' then
                local hex = raw:sub(i, i + 1)
                if not hex:match('^%x%x$') then return nil end
                out[#out + 1] = string.char(tonumber(hex, 16)); i = i + 2
            elseif c:match('%d') then
                local digits = (c .. raw:sub(i, stop)):match('^%d%d?%d?')
                local n = tonumber(digits)
                if n > 255 then return nil end
                out[#out + 1] = string.char(n); i = i + #digits - 1
            else return nil end
        end
    end
    return table.concat(out)
end

return M
