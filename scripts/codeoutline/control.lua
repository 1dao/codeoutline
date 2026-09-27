-- Per-Lua-state cancellation checkpoint installed only by the service worker.
local M = {}
function M.check() if M.callback then M.callback() end end
return M
