-- Parse thread for parse_pool.lua: reads and parses the files it is posted
-- and posts the results back to the thread that owns the index.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local index = require('codeoutline.index')
local shared = assert(xshared.dict('codeoutline_control'))

return {
    __thread_handle = function(_, op, owner, token, max_bytes, files)
        if op ~= 'parse' then return end
        local results = {}
        local ok, err = pcall(function()
            for i, f in ipairs(files) do
                -- An abandoned pass (cancelled, failed, shutting down) skips its rest.
                if shared:get('shutdown') or (shared:get('parse_abort') or 0) >= token then return end
                local res = index.load_file(f[2], f[1], max_bytes, f[3] or nil, f[4] or nil)
                res.rel = f[1]
                results[i] = res
            end
        end)
        xthread.post(owner, 'parsed', token, results, not ok and tostring(err) or nil)
    end,
}
