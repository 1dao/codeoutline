-- Shared terminal confirmation for optional integrations. EOF skips the rest.
local M = {}
function M.confirm(message, default)
    while true do
        io.write(message, default and ' [Y/n]\n' or ' [y/N]\n'); io.stdout:flush()
        local answer = io.read('*l')
        if answer == nil then return nil end
        answer = answer:lower():gsub('^%s+', ''):gsub('%s+$', '')
        if answer == '' then return default end
        if answer == 'y' or answer == 'yes' then return true end
        if answer == 'n' or answer == 'no' then return false end
        io.write('Please enter y or n, or press Enter for the default.\n'); io.stdout:flush()
    end
end
return M
