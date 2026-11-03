-- Optional editor clients. Detection, selection and installation stay in Lua.
local M = {}
local windows = package.config:sub(1, 1) == '\\'
local function exists(path) return path and xutils.stat(path).exists end
local function home() return os.getenv('USERPROFILE') or os.getenv('HOME') or '.' end
local function platform()
    if windows then return 'windows' end
    local p = assert(io.popen('uname -s'))
    local name = p:read('a'); p:close()
    return name:match('Darwin') and 'darwin' or 'linux'
end
local function quote(value)
    assert(not value:find('%z') and not value:find('[\r\n]'), 'unsupported control character in path')
    if windows then
        -- cmd expands these even inside quotes. Refuse rather than execute them.
        assert(not value:find('[%%"!%^&|<>]'), 'unsupported shell character in path')
        return '"' .. value:gsub('/', '\\') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end
local function first(paths)
    for _, path in ipairs(paths) do if exists(path) then return path end end
end
local function on_path(name)
    local separator = windows and ';' or ':'
    for dir in ((os.getenv('PATH') or '') .. separator):gmatch('(.-)' .. separator) do
        dir = dir:gsub('^"(.*)"$', '%1')
        if dir ~= '' then
            local found = first(windows and { dir .. '/' .. name .. '.cmd', dir .. '/' .. name .. '.exe' }
                or { dir .. '/' .. name })
            if found then return found end
        end
    end
end

function M.detect()
    local kind, h = platform(), home()
    local vscode, cursor, zed = on_path('code'), on_path('cursor'), on_path('zed') or on_path('zeditor')
    local zed_data
    if kind == 'windows' then
        local local_app = os.getenv('LOCALAPPDATA') or h .. '/AppData/Local'
        local program = os.getenv('ProgramFiles') or 'C:/Program Files'
        vscode = vscode or first({ local_app .. '/Programs/Microsoft VS Code/bin/code.cmd', program .. '/Microsoft VS Code/bin/code.cmd' })
        cursor = cursor or first({ local_app .. '/Programs/cursor/resources/app/bin/cursor.cmd', program .. '/cursor/resources/app/bin/cursor.cmd' })
        zed = zed or first({ local_app .. '/Programs/Zed/bin/zed.exe', local_app .. '/Programs/Zed/zed.exe',
            program .. '/Zed/bin/zed.exe', program .. '/Zed/zed.exe' })
        zed_data = local_app .. '/Zed'
    elseif kind == 'darwin' then
        for _, dir in ipairs({ '/Applications', h .. '/Applications' }) do
            vscode = vscode or first({ dir .. '/Visual Studio Code.app/Contents/Resources/app/bin/code' })
            cursor = cursor or first({ dir .. '/Cursor.app/Contents/Resources/app/bin/cursor' })
            zed = zed or first({ dir .. '/Zed.app/Contents/MacOS/zed' })
        end
        zed_data = h .. '/Library/Application Support/Zed'
    else
        vscode = vscode or first({ '/usr/share/code/bin/code', '/snap/bin/code' })
        cursor = cursor or first({ '/opt/Cursor/resources/app/bin/cursor', h .. '/.local/bin/cursor' })
        zed = zed or first({ h .. '/.local/bin/zed' })
        zed_data = (os.getenv('XDG_DATA_HOME') or h .. '/.local/share') .. '/zed'
    end
    return {
        { id = 'vscode', name = 'VS Code', command = vscode, detected = vscode ~= nil, extensions = h .. '/.vscode/extensions' },
        { id = 'cursor', name = 'Cursor', command = cursor, detected = cursor ~= nil, extensions = h .. '/.cursor/extensions' },
        { id = 'zed', name = 'Zed', command = zed, data = zed_data, detected = zed ~= nil },
    }
end

local function say(message) io.write(message, '\n'); io.stdout:flush() end
local function read(path)
    local f = assert(io.open(path, 'rb'), 'missing editor asset ' .. path .. '; use a packaged release or build the editor clients')
    local data = f:read('a'); assert(f:close()); return data
end
local function write(path, data)
    assert(xutils.mkdir_p(assert(path:match('^(.*)/[^/]+$'))))
    local f = assert(io.open(path, 'wb')); assert(f:write(data)); assert(f:close())
end

-- Parse before any writes so a typo cannot cause a partial selection.
function M.select(value, detected)
    value = value:lower():gsub('%s+', '')
    if value == 'y' or value == 'yes' then value = 'all' end
    if value == 'n' or value == 'no' then value = 'none' end
    if value == 'none' or value == '' then return {} end
    local wanted = {}
    if value ~= 'all' then
        assert(not value:match('^,') and not value:match(',$') and not value:find(',,', 1, true), 'invalid editor selection')
        for id in value:gmatch('[^,]+') do
            assert(id == 'vscode' or id == 'cursor' or id == 'zed', 'unknown editor: ' .. id)
            wanted[id] = true
        end
    end
    local selected = {}
    for _, editor in ipairs(detected) do
        if value == 'all' and editor.detected or wanted[editor.id] then
            assert(editor.detected, editor.name .. ' not detected; add its CLI to PATH and retry')
            selected[#selected + 1] = editor
        end
    end
    return selected
end

function M.run(root, options)
    options = options or {}
    local value = options.editors or os.getenv('CODEOUTLINE_EDITORS')
    if value == '' then value = nil end
    -- Opting out should work even on machines without editor CLIs.
    if value and value:lower() == 'none' and not options.list then return 0 end
    local editors = M.detect()
    if options.list then
        for _, editor in ipairs(editors) do
            say(editor.id .. ': ' .. (editor.detected and ('detected (' .. (editor.command or editor.data) .. ')') or 'not detected'))
        end
        return 0
    end
    if not value then
        if os.getenv('CODEOUTLINE_INTERACTIVE') ~= '1' then
            say('Optional LSP clients: run codeoutline editors to choose, or codeoutline editors --editors all.')
            return 0
        end
        local available = {}
        for _, editor in ipairs(editors) do
            if editor.detected then available[#available + 1] = editor end
        end
        if #available == 0 then say('No supported editors detected. Add the editor CLI to PATH and retry.'); return 0 end
        say('Detected editors: ' .. #available .. '. Confirm each editor; Enter installs it.')
        local chosen = {}
        for _, editor in ipairs(available) do
            local answer = require('codeoutline.install_prompt').confirm('Install CodeOutline LSP for ' .. editor.name .. ' (' .. editor.id .. ')?', true)
            if answer == nil then break end
            if answer then chosen[#chosen + 1] = editor.id end
        end
        value = #chosen > 0 and table.concat(chosen, ',') or 'none'
    end
    local selected = M.select(value, editors)
    local status = 0
    for _, editor in ipairs(selected) do
        local ok, err = pcall(function()
            if editor.id == 'zed' then
                -- Read both assets before touching the installed extension.
                local manifest = read(root .. '/editors/zed/extension.toml')
                local wasm = read(root .. '/editors/zed/extension.wasm')
                local target = editor.data .. '/extensions/installed/codeoutline'
                assert(not exists(editor.data .. '/extensions/development/codeoutline'), 'Zed dev extension exists; remove it before installing the packaged client')
                if exists(target) then
                    local actual = assert(xutils.realpath(target)):gsub('\\', '/'):gsub('/+$', '')
                    local expected = assert(xutils.realpath(editor.data .. '/extensions/installed')):gsub('\\', '/'):gsub('/+$', '') .. '/codeoutline'
                    if windows then actual, expected = actual:lower(), expected:lower() end
                    assert(actual == expected, 'Zed extension is linked to another directory; remove the dev extension before installing the packaged client')
                end
                write(target .. '/extension.wasm', wasm)
                write(target .. '/extension.toml', manifest)
                say('Installed CodeOutline for Zed. Restart Zed to load the client.')
            else
                local vsix = root .. '/editors/codeoutline.vsix'
                assert(exists(vsix), 'missing editor asset ' .. vsix .. '; use a packaged release or build the editor clients')
                local command = quote(editor.command) .. ' --install-extension ' .. quote(vsix) .. ' --force'
                if windows then command = '"' .. command .. '"' end
                local result = os.execute(command)
                assert(result == true or result == 0, editor.name .. ' extension installation failed')
                say('Installed CodeOutline for ' .. editor.name .. '. Reload the editor window if it is open.')
            end
        end)
        if not ok then io.stderr:write('codeoutline: ', tostring(err), '\n'); status = 1 end
    end
    return status
end

-- Remove only our extension, including Zed's per-extension downloaded runtime.
-- Continue with other editors when one editor is unavailable or reports errors.
function M.remove()
    local status = 0
    local function remove_directory(target, parent)
        if not exists(target) then return end
        local actual = assert(xutils.realpath(target)):gsub('\\', '/'):gsub('/+$', '')
        local expected = assert(xutils.realpath(parent)):gsub('\\', '/'):gsub('/+$', '') .. '/' .. assert(target:match('([^/]+)$'))
        if windows then actual, expected = actual:lower(), expected:lower() end
        assert(actual == expected, 'refusing to remove linked extension: ' .. target)
        assert(xutils.rmtree(target), 'cannot remove ' .. target .. '; close the editor and retry')
        assert(not exists(target), 'extension directory remains: ' .. target)
    end
    for _, editor in ipairs(M.detect()) do
        local ok, err = pcall(function()
            if editor.id == 'zed' then
                for _, kind in ipairs({ 'installed', 'work', 'staging' }) do
                    local parent = editor.data .. '/extensions/' .. kind
                    local target = parent .. '/codeoutline'
                    remove_directory(target, parent)
                end
                -- This is Zed's generated extension registry, not user settings.
                local index = editor.data .. '/extensions/index.json'
                if exists(index) then
                    local before = read(index)
                    local after, changed = require('codeoutline.agent_config').json(before,
                        { 'extensions', 'codeoutline' }, {}, true, false)
                    if changed then
                        local temp = assert(xutils.temp_file(editor.data .. '/extensions'))
                        write(temp, after)
                        assert(read(index) == before, 'Zed extension registry changed; close Zed and retry')
                        assert(xutils.replace_file(temp, index), 'cannot update Zed extension registry')
                    end
                end
                say('CodeOutline removed from Zed. Restart Zed if it is open.')
            elseif editor.detected then
                local function command(args)
                    local text = quote(editor.command) .. ' ' .. args
                    return windows and ('"' .. text .. '"') or text
                end
                local function installed()
                    local pipe = assert(io.popen(command('--list-extensions')))
                    local output = pipe:read('a'); local closed = pipe:close()
                    assert(closed, editor.name .. ' extension listing failed')
                    for line in output:gmatch('[^\r\n]+') do
                        if line:lower():match('^%s*1dao%.codeoutline%s*$') then return true end
                    end
                    return false
                end
                if installed() then
                    local result = os.execute(command('--uninstall-extension 1dao.codeoutline'))
                    assert(result == true or result == 0, editor.name .. ' extension removal failed')
                    assert(not installed(), editor.name .. ' still lists CodeOutline')
                end
                -- The editor CLI may only mark old versions obsolete until its
                -- next start. Remove those owned directories now or report locks.
                for _, entry in ipairs(xutils.list_dir(editor.extensions) or {}) do
                    if entry.dir and entry.name:lower():match('^1dao%.codeoutline%-%d') then
                        remove_directory(editor.extensions .. '/' .. entry.name, editor.extensions)
                    end
                end
                say('CodeOutline removed from ' .. editor.name .. '. Reload the editor if it is open.')
            else
                say(editor.name .. ' CLI not detected; check other editor profiles manually.')
            end
        end)
        if not ok then io.stderr:write('codeoutline: ', tostring(err), '\n'); status = 1 end
    end
    return status
end

return M
