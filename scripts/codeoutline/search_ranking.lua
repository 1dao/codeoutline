-- Per-query search policy. Directory penalties never change graph visibility.
local rules = require('codeoutline.rules')
local text = require('codeoutline.text')
local M = { MAX_DIRECTORIES = 32, MAX_PATH_BYTES = 1024, PENALTY = 6 }
local defaults = { '/3rd/', '^3rd/', '/third_party/', '^third_party/', '/thirdparty/',
    '/vendor/', '^vendor/', '/node_modules/', '/external/', '^external/', '/deps/', '^deps/' }

local function directory(value)
    assert(type(value) == 'string' and value:find('%S') and #value <= M.MAX_PATH_BYTES
        and not value:find('[%z\r\n]') and text.valid(value) == value,
        'deprioritize must contain non-empty UTF-8 directory paths up to 1024 bytes without NUL or newlines')
    value = value:gsub('\\', '/')
    assert(value:sub(1, 1) ~= '/' and not value:find(':', 1, true) and not value:find('[%*%?]'),
        'deprioritize requires project-relative directory prefixes, not absolute paths or globs')
    local parts = {}
    for part in value:gmatch('[^/]+') do
        assert(part ~= '..', 'deprioritize directories must stay inside the project')
        if part ~= '.' then parts[#parts + 1] = part end
    end
    assert(#parts > 0, 'deprioritize must name a directory, not the project root')
    return table.concat(parts, '/') .. '/'
end

function M.policy(root)
    local value = rules.read(root).deprioritize
    local prefixes, seen = {}, {}
    local configured = value ~= nil
    if configured then
        assert(type(value) == 'table' and #value <= M.MAX_DIRECTORIES,
            'deprioritize must be an array of at most 32 directory paths')
        local count = 0
        for k in pairs(value) do
            assert(type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= #value, 'deprioritize must be an array')
            count = count + 1
        end
        assert(count == #value, 'deprioritize must be an array')
        for _, path in ipairs(value) do
            local prefix = directory(path)
            if not seen[prefix] then prefixes[#prefixes + 1] = prefix; seen[prefix] = true end
        end
    end
    local cache = {}
    local P = { configured = configured, stats = { configured = configured,
        rules = configured and #prefixes or #defaults, checked_files = 0, matched_files = 0 } }
    function P.penalty(path, explicit, node)
        -- Exact qualified requests bypass both configured and default hints.
        if explicit then return 0 end
        local amount = cache[path]
        if amount == nil then
            amount = 0
            if configured then
                for _, prefix in ipairs(prefixes) do
                    if path:sub(1, #prefix) == prefix then amount = M.PENALTY; break end
                end
            else
                for _, pattern in ipairs(defaults) do
                    if path:find(pattern) then amount = M.PENALTY; break end
                end
                local lower = '/' .. path:lower()
                if lower:match('%.min%.[cm]?js$') or lower:match('%.bundle%.js$') then amount = math.max(amount, 18) end
                if lower:find('/builtins/', 1, true) or lower:find('/typings/', 1, true)
                    or lower:match('%.d%.[cm]?ts$') then amount = math.max(amount, 10) end
            end
            cache[path] = amount
            P.stats.checked_files = P.stats.checked_files + 1
            if amount > 0 then P.stats.matched_files = P.stats.matched_files + 1 end
        end
        return amount + (not configured and node and (node.decl or node.kind == 'prototype') and 4 or 0)
    end
    return P
end

return M
