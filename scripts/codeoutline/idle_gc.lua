-- One pending native timer per worker. Timer callbacks run on the same Lua
-- state: they advance one GC step only while foreground work is absent.
-- The owning worker initializes xtimer in __init before scheduling requests.
local M = {}

function M.new(opts)
    local timer = opts.timer or xtimer
    local handle, wanted, start_cycle, closed = nil, false, false, false
    local generation = 0
    local arm
    local function cancel()
        generation = generation + 1
        if handle then timer.del(handle); handle = nil end
    end
    arm = function()
        cancel()
        if closed or not wanted then return end
        local token = generation
        handle = timer.add(opts.delay_ms, function()
            if closed or token ~= generation then return end
            handle = nil
            -- A suspended foreground coroutine also owns its resident state.
            -- Its eventual reply will rearm us; do not poll while it waits.
            if opts.busy() then return end
            if start_cycle then opts.request(); start_cycle = false end
            wanted = opts.step()
            if wanted then arm() end
        end, 1)
    end
    local self = {}
    function self.schedule()
        if closed then return end
        wanted, start_cycle = true, true
        arm()
    end
    function self.suspend() cancel() end
    function self.pending() return wanted end
    function self.close()
        closed, wanted, start_cycle = true, false, false
        cancel()
    end
    return self
end

return M
