local M = {}
M.windows = package.config:sub(1, 1) == '\\'

function M.normalize(p)
    p = p:gsub('\\', '/')
    if p ~= '/' and not p:match('^%a:/$') then p = p:gsub('/+$', '') end
    return p
end

function M.canonical(root)
    if type(root) ~= 'string' or root == '' or root:find('%z') then
        return nil, 'project path must be a non-empty string without NUL'
    end
    if not (xutils and xutils.realpath and xutils.stat) then
        return nil, 'runtime requires xutils.realpath and stat; rebuild the bundled xnet2lua runtime'
    end
    local resolved, err = xutils.realpath(root)
    if not resolved then return nil, 'cannot resolve project path: ' .. tostring(err) end
    resolved = M.normalize(resolved)
    local st = xutils.stat(resolved)
    if not st or st.type ~= 'directory' then return nil, 'project path is not a directory: ' .. root end
    return resolved
end

function M.key(root)
    root = M.normalize(root)
    return M.windows and root:lower() or root
end

function M.contains(root, candidate)
    root, candidate = M.key(root), M.key(candidate)
    local prefix = root:sub(-1) == '/' and root or root .. '/'
    return candidate == root or candidate:sub(1, #prefix) == prefix
end

-- `roots == false` is the unrestricted access of a loopback HTTP service
-- started without ALLOW_ROOT; otherwise the candidate must sit under a root.
function M.allowed(roots, candidate)
    if roots == false then return true end
    for _, root in ipairs(roots) do
        if M.contains(root, candidate) then return true end
    end
    return false
end

return M
