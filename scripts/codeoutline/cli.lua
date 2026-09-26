-- codeoutline/cli.lua — try CodeExplore queries by hand. From the repo root:
--   .\xnet2lua\bin\xnet.exe scripts/codeoutline/cli.lua ROOT=C:/src/proj "Q=xtimer_poll xtimer_add"
-- Optional: BUDGET=16000, STATS=1 (index/graph numbers only).
package.path = 'scripts/?.lua;' .. package.path
local svc = require('codeoutline.service')
local explore = require('codeoutline.explore')

local argv = {}
if type(arg) == 'table' then
    for _, it in ipairs(arg) do
        local k, v = tostring(it):match('^([%w_]+)=(.*)$')
        if k then argv[k] = v end
    end
end

local root = argv.ROOT or '.'
local t0 = os.clock()
local idx, G, stats = svc.get(root)
print(string.format('[index] %d files, %d nodes, %d edges | refresh: parsed=%d unchanged=%d removed=%d skipped=%d | %.2fs%s',
    #G.files, #G.nodes, G.edge_count, stats.parsed, stats.unchanged, stats.removed, stats.skipped,
    os.clock() - t0, (xscan and os.getenv('XSCAN_PURE_LUA') ~= '1') and ' (native xscan)' or ''))

if argv.Q and argv.STATS ~= '1' then
    local t1 = os.clock()
    local text = explore.run(G, idx, argv.Q, { budget = tonumber(argv.BUDGET) })
    print(string.format('[explore] %d bytes in %.3fs', #text, os.clock() - t1))
    print(text)
end

return { __init = function() xthread.stop(0) end }
