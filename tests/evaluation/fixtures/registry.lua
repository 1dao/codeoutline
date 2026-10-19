local function save() end
local function remove() end
local handlers = { save = save }

function registry_run()
    handlers.save()
end

function registry_shadow(handlers)
    handlers.save()
end

function registry_unknown(key)
    handlers[key]()
end

local replaced = { save = save }
replaced = external_handlers
function registry_replaced()
    replaced.save()
end

function direct_run()
    save()
end
