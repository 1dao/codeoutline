-- Per-Lua-state checkpoint for worker cancellation or cooperative indexing.
local M = {}
local error_mt = { __tostring = function(e) return e.message end }
function M.cancelled(message) return setmetatable({ code = 'cancelled', message = message or 'Request cancelled' }, error_mt) end
function M.deadline() return setmetatable({ code = 'deadline', message = 'Indexing deadline exceeded' }, error_mt) end
function M.is_interrupted(value) return getmetatable(value) == error_mt end
function M.check() if M.callback then M.callback() end end
return M
