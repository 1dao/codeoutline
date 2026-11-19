-- Parse thread for parse_pool.lua: reads and parses the files it is posted
-- and posts the results back to the thread that owns the index.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/runtime/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local index = require('codeoutline.indexing.index')
local shared = assert(xshared.dict('codeoutline_control'))

return {
    __thread_handle = function(_, op, owner, token, max_bytes, files)
        if op ~= 'parse' and op ~= 'bm25_collect' then return end
        local results = {}
        local abort_key = 'parse_abort:' .. owner
        local ok, err = pcall(function()
            local load = op == 'parse' and index.load_file or require('codeoutline.bm25.collect').file
            for i, f in ipairs(files) do
                -- An abandoned pass (cancelled, failed, shutting down) skips its rest.
                if shared:get('shutdown') or (shared:get(abort_key) or 0) >= token then return end
                local res
                if op == 'parse' then
                    res = load(f[2], f[1], max_bytes, f[3] or nil, f[4] or nil, f[5] or nil)
                else
                    res = load(f[2], f[1], f[3], f[4], f[5], f[6])
                end
                res.rel = f[1]
                results[i] = res
            end
        end)
        xthread.post(owner, 'parsed', token, results, not ok and tostring(err) or nil)
    end,
}
