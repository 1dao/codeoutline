-- Fingerprint of how bin/xnet is built: the build scripts carry the runtime's
-- compile options (rpmalloc, LuaJIT, xproc...), which the submodule commit
-- alone does not. package.lua records it in build-info.json; release.lua
-- reuses a published runtime only when both the commit and this match.
--   local runtime_build = dofile(root .. '/tools/runtime_build.lua')(root)
return function(root)
    local parts = {}
    for _, name in ipairs({ 'build-runtime.ps1', 'build-runtime.sh' }) do
        local f = assert(io.open(root .. '/tools/' .. name, 'rb'), 'cannot read tools/' .. name)
        local data = f:read('a'); f:close()
        parts[#parts + 1] = name .. '\n' .. data:gsub('\r\n', '\n')
    end
    return xutils.sha256_hex(table.concat(parts, '\n'))
end
