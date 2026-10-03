-- The shared background HTTP service: one per user, started at login and by
-- installation. It runs the newest installed version and restarts itself into
-- an update, so MCP clients connect to one URL and nothing else stays running.
local u = require('xutils')
local M = {}
M.PORT = 19876
local windows = package.config:sub(1, 1) == '\\'
local LABEL = 'io.github.1dao.codeoutline'

local function home() return (os.getenv('USERPROFILE') or os.getenv('HOME') or '.'):gsub('\\', '/') end
function M.state_dir() return home() .. '/.codeoutline' end
function M.logs_dir() return M.state_dir() .. '/logs' end
-- Created to ask the service on that port to exit (uninstall, reinstall).
function M.stop_file(port) return M.state_dir() .. '/service-' .. port .. '.stop' end

local function read(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local data = f:read('a'); f:close(); return data
end
local function write(path, data)
    assert(u.mkdir_p(assert(path:match('^(.*)/[^/]+$'))))
    local f = assert(io.open(path, 'wb'))
    assert(f:write(data)); assert(f:close())
end
local function same_path(a, b)
    local function norm(p) p = p:gsub('\\', '/'):gsub('/+$', ''); return windows and p:lower() or p end
    return norm(a) == norm(b)
end
local function sequence(root)
    local info = u.json_unpack(read(root .. '/build-info.json') or '')
    return type(info) == 'table' and tonumber(info.updateSequence) or nil
end

-- Files root of the newest verified version: an installed update, or install
-- itself when it is newer (an npm upgrade) or nothing is installed. A source
-- checkout (no build-info.json) runs itself.
function M.current_root(install)
    local own = sequence(install)
    if not own then return install end
    local ok, current = pcall(function()
        return require('xupgate.client').open(require('codeoutline.updater').config()).current()
    end)
    if ok and current and current.sequence >= own then return current.root end
    return install
end
function M.is_current(install) return same_path(M.current_root(install), install) end

-- argv of the service run from root. Paths reach a shell, the registry or a
-- unit file, so characters that would need escaping there are refused.
local function argv(root, port)
    root = root:gsub('\\', '/'):gsub('/+$', '')
    local runtime = root .. (windows and '/bin/xnet.exe' or '/bin/xnet')
    local entry = root .. '/scripts/codeoutline/command.lua'
    local logs = M.logs_dir()
    for _, path in ipairs({ runtime, entry, logs }) do
        assert(not path:find('[%%"\'`$\\!&|<>^;\r\n]'), 'unsupported characters in path: ' .. path)
    end
    if windows then runtime = runtime:gsub('/', '\\') end
    return { runtime, entry, 'LOG_STDERR=0', 'LOG_LEVEL=WARN', 'LOG_DIR=' .. logs, 'daemon', '--port', tostring(port) }
end
local function quoted(args)
    local out = {}
    for i, a in ipairs(args) do out[i] = a:find('[%s=]') and '"' .. a .. '"' or a end
    return table.concat(out, ' ')
end
local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function command_ok(command) local ok = os.execute(command); return ok == true or ok == 0 end

-- Start the service from root, detached: it must outlive the process that
-- starts it and must not inherit its stdio. A second instance exits by itself.
function M.spawn(root, port)
    local args = argv(root, port or M.PORT)
    local logs = M.logs_dir()
    assert(u.mkdir_p(logs))
    if windows then
        -- Arguments travel through the environment, keeping the script ASCII.
        local list = {}
        for i = 2, #args do list[#list + 1] = "('\"'+$env:CO_ARG" .. i .. "+'\"')" end
        local script = "$ProgressPreference='SilentlyContinue';Start-Process -WindowStyle Hidden -WorkingDirectory $env:CO_LOGS "
            .. '-FilePath $env:CO_ARG1 -ArgumentList ' .. table.concat(list, ',')
        local encoded = {}
        for i = 1, #script do encoded[#encoded + 1] = script:sub(i, i) .. '\0' end
        local env = { 'set "CO_LOGS=' .. logs .. '"' }
        for i, a in ipairs(args) do env[#env + 1] = 'set "CO_ARG' .. i .. '=' .. a .. '"' end
        return command_ok(table.concat(env, ' && ') .. ' && powershell -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '
            .. u.base64_encode(table.concat(encoded)) .. ' >NUL 2>&1')
    end
    local parts = {}
    for i, a in ipairs(args) do parts[i] = sh_quote(a) end
    return command_ok('cd ' .. sh_quote(logs) .. ' && S=; command -v setsid >/dev/null 2>&1 && S=setsid; $S nohup '
        .. table.concat(parts, ' ') .. ' </dev/null >/dev/null 2>&1 &')
end

-- Login entries. Each runs the service once per login; it then keeps itself
-- current, so entries only change when the installation moves.
local function entry_paths()
    local h = home()
    return {
        darwin = h .. '/Library/LaunchAgents/' .. LABEL .. '.plist',
        systemd = (os.getenv('XDG_CONFIG_HOME') or h .. '/.config') .. '/systemd/user/codeoutline.service',
    }
end
local RUN_KEY = [[HKCU\Software\Microsoft\Windows\CurrentVersion\Run]]

-- The text of a login entry, by kind.
local function render(kind, args)
    if kind == 'windows' then
        -- conhost --headless gives the console runtime no window at all.
        return 'conhost.exe --headless ' .. quoted(args)
    elseif kind == 'darwin' then
        local items = {}
        for i, a in ipairs(args) do items[i] = '    <string>' .. a:gsub('&', '&amp;'):gsub('<', '&lt;') .. '</string>' end
        return table.concat({ '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0">', '<dict>', '  <key>Label</key><string>' .. LABEL .. '</string>',
            '  <key>ProgramArguments</key>', '  <array>', table.concat(items, '\n'), '  </array>',
            '  <key>RunAtLoad</key><true/>',
            -- The service restarts itself as a new process; keep that one alive.
            '  <key>AbandonProcessGroup</key><true/>', '</dict>', '</plist>', '' }, '\n')
    elseif kind == 'systemd' then
        return table.concat({ '[Unit]', 'Description=CodeOutline shared MCP service', '', '[Service]', 'Type=simple',
            'ExecStart=' .. quoted(args),
            -- The service restarts itself as a new process; stopping this unit's
            -- first process must not take the replacement with it.
            'KillMode=process', '', '[Install]', 'WantedBy=default.target', '' }, '\n')
    end
    error('unknown entry kind ' .. tostring(kind))
end

local function platform()
    if windows then return 'windows' end
    local p = io.popen('uname -s 2>/dev/null')
    local name = p and p:read('a') or ''
    if p then p:close() end
    return name:match('^Darwin') and 'darwin' or 'linux'
end

-- Register the login entry for the service run from root. Returns a description.
function M.register(root, port)
    port = port or M.PORT
    local args = argv(root, port)
    local kind = platform()
    if kind == 'windows' then
        local value = render('windows', args):gsub('"', '\\"')
        assert(command_ok('reg add "' .. RUN_KEY .. '" /v CodeOutline /t REG_SZ /d "' .. value .. '" /f >NUL 2>&1'),
            'cannot write ' .. RUN_KEY)
        kind = RUN_KEY .. '\\CodeOutline'
    elseif kind == 'darwin' then
        write(entry_paths().darwin, render('darwin', args))
        kind = entry_paths().darwin
    else
        -- Systems without a systemd user manager (WSL, containers) rarely run
        -- a login session that would start anything else either.
        assert(command_ok('systemctl --user show-environment >/dev/null 2>&1'),
            'no systemd user manager; start "codeoutline daemon" at login yourself')
        local path = entry_paths().systemd
        write(path, render('systemd', args))
        assert(command_ok('systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable codeoutline.service >/dev/null 2>&1'),
            'cannot enable ' .. path)
        kind = path
    end
    return kind
end

function M.unregister()
    local removed = {}
    if windows then
        if command_ok('reg query "' .. RUN_KEY .. '" /v CodeOutline >NUL 2>&1') then
            assert(command_ok('reg delete "' .. RUN_KEY .. '" /v CodeOutline /f >NUL 2>&1'), 'cannot remove ' .. RUN_KEY .. '\\CodeOutline')
            removed[#removed + 1] = RUN_KEY .. '\\CodeOutline'
        end
    else
        local paths = entry_paths()
        if u.stat(paths.systemd).exists then
            os.execute('systemctl --user disable codeoutline.service >/dev/null 2>&1')
            os.remove(paths.systemd)
            os.execute('systemctl --user daemon-reload >/dev/null 2>&1')
            removed[#removed + 1] = paths.systemd
        end
        if u.stat(paths.darwin).exists then os.remove(paths.darwin); removed[#removed + 1] = paths.darwin end
    end
    return removed
end

-- Calls done(true) once a connection to the port succeeds, done(false) when
-- refused. Needs an initialized xnet.
function M.probe(port, done)
    local connected, finished = false, false
    local function finish(value) if not finished then finished = true; done(value) end end
    local conn = xnet.connect('127.0.0.1', port, {
        on_connect = function(c) connected = true; c:close('probe') end,
        on_packet = function(_, data) return #data end,
        on_close = function() finish(connected) end,
    })
    if not conn then xtimer.add(1, function() finish(false) end, 1) end
end

-- Poll the port until it is listening (want true) or closed (want false), up
-- to timeout_ms; done(reached). Needs an initialized xnet and xtimer.
local function poll(port, want, timeout_ms, done)
    local deadline = xtimer.now_ms() + timeout_ms
    local function check()
        M.probe(port, function(listening)
            if listening == want then done(true)
            elseif xtimer.now_ms() >= deadline then done(false)
            else xtimer.add(200, check, 1) end
        end)
    end
    check()
end
function M.wait(port, timeout_ms, done) poll(port, true, timeout_ms, done) end

-- Ask the service on port to exit and wait up to timeout_ms for the port to
-- close; done(stopped). Needs an initialized xnet and xtimer.
function M.stop(port, timeout_ms, done)
    local path = M.stop_file(port)
    write(path, 'stop\n')
    poll(port, false, timeout_ms, function(stopped) os.remove(path); done(stopped) end)
end

return M
