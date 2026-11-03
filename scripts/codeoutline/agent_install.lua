-- Register the shared HTTP MCP service in supported agent configurations.
local config = require('codeoutline.agent_config')
local M = {}
local windows = package.config:sub(1, 1) == '\\'
local function exists(path) return path and xutils.stat(path).exists end
local function env(name, fallback)
    local value = os.getenv(name)
    return value and value:match('%S') and value:gsub('\\', '/') or fallback
end
local function read(path)
    if not exists(path) then return '' end
    local f = assert(io.open(path, 'rb'), 'cannot read config: ' .. path)
    local raw, err = f:read(4 * 1024 * 1024 + 1); f:close()
    assert(not err, 'cannot read config: ' .. path .. ': ' .. tostring(err))
    -- A numeric read returns nil at EOF for an existing zero-byte file.
    raw = raw or ''
    assert(#raw <= 4 * 1024 * 1024, 'config exceeds 4 MiB: ' .. path)
    return raw
end
local function write(path, raw)
    local dir = assert(path:match('^(.*)/[^/]+$'))
    assert(xutils.mkdir_p(dir))
    local temp = assert(xutils.temp_file(dir))
    local ok, err = pcall(function()
        local f = assert(io.open(temp, 'wb')); assert(f:write(raw)); assert(f:close())
        assert(xutils.replace_file(temp, path), 'cannot replace config')
    end)
    if not ok then os.remove(temp); error(err) end
end
local function on_path(name)
    local separator = windows and ';' or ':'
    for dir in (env('PATH', '') .. separator):gmatch('(.-)' .. separator) do
        dir = dir:gsub('^"(.*)"$', '%1')
        if dir ~= '' and (exists(dir .. '/' .. name) or windows and
            (exists(dir .. '/' .. name .. '.exe') or exists(dir .. '/' .. name .. '.cmd'))) then return true end
    end
    return false
end
local function platform()
    if windows then return 'windows' end
    local p = assert(io.popen('uname -s')); local value = p:read('a'); p:close()
    return value:match('Darwin') and 'darwin' or 'linux'
end

function M.detect(location, project)
    local h = env('USERPROFILE', env('HOME', '.'))
    local xdg = env('XDG_CONFIG_HOME', h .. '/.config')
    local codex = env('CODEX_HOME', h .. '/.codex')
    local claude = env('CLAUDE_CONFIG_DIR', h .. '/.claude')
    local claude_file = env('CLAUDE_CONFIG_DIR', h) .. '/.claude.json'
    local copilot = env('COPILOT_HOME', h .. '/.copilot')
    local kind = platform()
    local code_user = kind == 'windows' and env('APPDATA', h .. '/AppData/Roaming') .. '/Code/User'
        or kind == 'darwin' and h .. '/Library/Application Support/Code/User' or xdg .. '/Code/User'
    local jetbrains = kind == 'windows' and env('LOCALAPPDATA', h .. '/AppData/Local') .. '/github-copilot/intellij'
        or xdg .. '/github-copilot/intellij'
    local antigravity = h .. '/.gemini/config'
    if not exists(antigravity .. '/mcp_config.json') and not exists(antigravity .. '/.migrated') then
        antigravity = h .. '/.gemini/antigravity'
    end
    local opencode = xdg .. '/opencode'
    local function opencode_file(dir)
        if exists(dir .. '/opencode.jsonc') then return dir .. '/opencode.jsonc' end
        if exists(dir .. '/opencode.json') then return dir .. '/opencode.json' end
        return dir .. '/opencode.jsonc'
    end
    local targets = {
        { id = 'claude', name = 'Claude Code', path = claude_file, local_path = project .. '/.mcp.json', marker = claude, cli = 'claude' },
        { id = 'cursor', name = 'Cursor Agent', path = h .. '/.cursor/mcp.json', local_path = project .. '/.cursor/mcp.json', marker = h .. '/.cursor', cli = 'cursor' },
        { id = 'codex', name = 'Codex', path = codex .. '/config.toml', local_path = project .. '/.codex/config.toml', marker = codex, cli = 'codex', format = 'toml' },
        { id = 'gemini', name = 'Gemini CLI', path = h .. '/.gemini/settings.json', local_path = project .. '/.gemini/settings.json', marker = h .. '/.gemini', cli = 'gemini', entry = 'gemini' },
        { id = 'opencode', name = 'OpenCode', path = opencode_file(opencode), local_path = opencode_file(project), marker = opencode, cli = 'opencode', entry = 'opencode' },
        { id = 'hermes', name = 'Hermes Agent', path = env('HERMES_HOME', h .. '/.hermes') .. '/config.yaml', marker = env('HERMES_HOME', h .. '/.hermes'), cli = 'hermes', format = 'yaml' },
        { id = 'kiro', name = 'Kiro', path = h .. '/.kiro/settings/mcp.json', local_path = project .. '/.kiro/settings/mcp.json', marker = h .. '/.kiro', cli = 'kiro' },
        { id = 'antigravity', name = 'Antigravity IDE', path = antigravity .. '/mcp_config.json', marker = antigravity, cli = 'antigravity', entry = 'antigravity' },
        { id = 'copilot-vscode', name = 'GitHub Copilot in VS Code', path = code_user .. '/mcp.json', local_path = project .. '/.vscode/mcp.json', marker = code_user, wrapper = 'servers' },
        { id = 'copilot-cli', name = 'GitHub Copilot CLI', path = copilot .. '/mcp-config.json', marker = copilot, cli = 'copilot', entry = 'copilot' },
        { id = 'copilot-jetbrains', name = 'GitHub Copilot in JetBrains', path = jetbrains .. '/mcp.json', marker = jetbrains, wrapper = 'servers', entry = 'jetbrains' },
    }
    for _, target in ipairs(targets) do
        target.detected = exists(target.marker) or exists(target.path) or target.cli and on_path(target.cli) or false
        if location == 'local' then target.path = target.local_path end
    end
    return targets
end

local function select_targets(value, targets)
    local wanted, selected = {}, {}
    value = value:lower():gsub('%s+', '')
    if value == 'y' or value == 'yes' then value = 'all' end
    if value == 'n' or value == 'no' then value = 'none' end
    if value == 'none' or value == '' then return selected end
    for id in value:gmatch('[^,]+') do wanted[id] = true end
    assert(not value:find(',,', 1, true) and not value:match('^,') and not value:match(',$'), 'invalid target selection')
    for _, target in ipairs(targets) do
        if wanted[target.id] or (value == 'auto' or value == 'all') and target.detected and target.path then
            assert(target.path, target.name .. ' only supports --location global')
            selected[#selected + 1] = target
        end
        wanted[target.id] = nil
    end
    if value ~= 'all' and value ~= 'auto' then
        for id in pairs(wanted) do error('unknown agent target: ' .. id) end
    end
    return selected
end

local function render(target, raw, url, remove, force)
    if target.format == 'toml' then return config.toml(raw, url, remove, force) end
    if target.format == 'yaml' then return config.yaml(raw, url, remove, force) end
    local entry, path = { type = 'http', url = url }, { target.wrapper or 'mcpServers', 'codeoutline' }
    if target.id == 'cursor' or target.id == 'kiro' then entry = { url = url }
    elseif target.entry == 'gemini' then entry = { httpUrl = url }
    elseif target.entry == 'antigravity' then entry = { serverUrl = url }
    elseif target.entry == 'jetbrains' then entry = { url = url }
    elseif target.entry == 'copilot' then entry.tools = { '*' }
    elseif target.entry == 'opencode' then
        entry = { type = 'remote', url = url, enabled = true }
        path = { 'mcp', 'codeoutline' }
        -- Preserve the native OpenCode 2 wrapper when already in use.
        if config.has(raw, { 'mcp', 'servers' }) then
            path = { 'mcp', 'servers', 'codeoutline' }
            entry.enabled = nil; entry.disabled = false; entry.codemode = false
        end
    end
    return config.json(raw, path, entry, remove, force)
end

local function say(message) io.write(message, '\n'); io.stdout:flush() end
function M.run(options)
    options = options or {}
    local location = options.location or 'global'
    assert(location == 'global' or location == 'local', '--location must be global or local')
    local port = tonumber(options.port or 19876)
    assert(port and port % 1 == 0 and port >= 1 and port <= 65535, 'invalid --port')
    local url = 'http://127.0.0.1:' .. port .. '/mcp'
    local project = assert(xutils.realpath(options.project or '.')):gsub('\\', '/')
    local targets = M.detect(location, project)
    if options.list then
        for _, target in ipairs(targets) do
            say(target.id .. ': ' .. (target.detected and 'detected' or 'not detected') .. ' -> ' .. (target.path or 'global scope only'))
        end
        return 0
    end
    if options.print or options['print-config'] then
        local selected = select_targets(options.print or options['print-config'], targets)
        assert(#selected == 1, '--print-config requires one target id')
        local text = render(selected[1], '', url, false, true)
        say('# ' .. selected[1].path); say(text); return 0
    end
    local value = options.target or env('CODEOUTLINE_AGENTS')
    if not value and options.yes then value = 'auto' end
    if not value then
        if os.getenv('CODEOUTLINE_INTERACTIVE') ~= '1' then
            say('Optional agent MCP setup: run codeoutline agents, or codeoutline install --yes.'); return 0
        end
        local available = {}
        for _, target in ipairs(targets) do if target.detected and target.path then available[#available + 1] = target end end
        if #available == 0 then say('No supported AI tools detected; skipping MCP configuration.'); return 0 end
        say('Detected AI tools: ' .. #available .. '. Confirm each tool; Enter accepts the default.')
        local chosen = {}
        for _, target in ipairs(available) do
            local answer = require('codeoutline.install_prompt').confirm(
                (options.remove and 'Remove code_explore from ' or 'Install code_explore (MCP) for ') .. target.name .. ' (' .. target.id .. ')?',
                not options.remove)
            if answer == nil then break end
            if answer then chosen[#chosen + 1] = target.id end
        end
        value = #chosen > 0 and table.concat(chosen, ',') or 'none'
    end
    local selected = select_targets(value, targets)
    -- Plan every selected edit before making any writes. Broken configs and
    -- conflicts are reported without partially configuring the other agents.
    local plan = {}
    for _, target in ipairs(selected) do
        local raw = read(target.path)
        local next_raw, changed = render(target, raw, url, options.remove, options.force)
        plan[#plan + 1] = { target = target, before = raw, after = next_raw, changed = changed }
    end
    for _, item in ipairs(plan) do
        local path = item.target.path
        if item.changed then
            assert(read(path) == item.before, 'config changed during installation; retry: ' .. path)
            if item.before ~= '' and not exists(path .. '.codeoutline.bak') then write(path .. '.codeoutline.bak', item.before) end
            write(path, item.after)
        end
        say(item.target.name .. ': ' .. (item.changed and (options.remove and 'removed' or 'configured') or 'unchanged') .. ' ' .. path)
    end
    if #selected > 0 and not options.remove then
        say('Restart the selected agents to load codeoutline_explore and the other MCP tools.')
        say('Shared MCP endpoint: ' .. url)
        if not options.installing then say('LSP editor clients can be installed with codeoutline editors.') end
        if location == 'local' then say('Project configuration may require trusting the project in the agent.') end
    end
    return 0
end

function M.remove(options)
    options = options or {}
    local status = 0
    local project = assert(xutils.realpath(options.project or '.')):gsub('\\', '/')
    local locations = options.project and { 'global', 'local' } or { 'global' }
    for _, location in ipairs(locations) do
        for _, target in ipairs(M.detect(location, project)) do
            if target.path and exists(target.path) then
                local ok, result = pcall(M.run, { target = target.id, remove = true,
                    location = location, project = project, port = options.port })
                if not ok or result ~= 0 then
                    io.stderr:write('codeoutline: cannot remove ', target.id, ': ', tostring(result), '\n')
                    status = 1
                end
            end
        end
    end
    return status
end

return M
