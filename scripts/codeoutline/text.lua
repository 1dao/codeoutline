local M = {}

-- Preserve valid UTF-8 at byte boundaries, and replace malformed source bytes
-- before emitting protocol text (source files are not necessarily UTF-8).
function M.valid(s)
    local out, i = {}, 1
    while i <= #s do
        local b = s:byte(i)
        local n = b < 128 and 1 or b >= 194 and b <= 223 and 2
            or b >= 224 and b <= 239 and 3 or b >= 240 and b <= 244 and 4 or 0
        local ok = n > 0 and i + n - 1 <= #s
        for j = 1, n - 1 do
            local c = s:byte(i + j)
            if not c or c < 128 or c > 191 then ok = false end
        end
        local c = s:byte(i + 1) or 0
        if (b == 224 and c < 160) or (b == 237 and c > 159)
            or (b == 240 and c < 144) or (b == 244 and c > 143) then ok = false end
        out[#out + 1] = ok and s:sub(i, i + n - 1) or '\239\191\189'
        i = i + (ok and n or 1)
    end
    return table.concat(out)
end

function M.prefix(s, limit)
    local last = math.min(#s, math.max(0, limit))
    if last < #s then
        while last > 0 and s:byte(last + 1) >= 128 and s:byte(last + 1) <= 191 do last = last - 1 end
    end
    return s:sub(1, last)
end

function M.limit(s, budget, omitted)
    s = M.valid(s)
    local truncated = #s > budget or omitted
    if truncated then
        local marker = '\n[Results truncated; narrow the query or increase budget.]'
        s = M.prefix(s, budget - #marker) .. marker
    end
    return s, truncated == true
end

return M
