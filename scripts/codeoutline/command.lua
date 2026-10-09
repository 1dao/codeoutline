-- Unified CLI. Launch through codeoutline (npm/native) or xnet with LOG_STDERR=1.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
local install = assert(scripts:match('^(.*)/scripts$'))
package.path = scripts .. '/?.lua;' .. package.path
local version = require('codeoutline.version')
local help = [[CodeOutline - Lua code indexing for MCP and LSP

One shared background service serves every MCP client. A global npm install
starts it and registers it to start at login (codeoutline install does the same
for other installations); it keeps itself updated. Register its URL once:
  claude mcp add --transport http codeoutline --scope user http://127.0.0.1:19876/mcp

Usage:
  codeoutline install [--port PORT]
  codeoutline uninstall [--port PORT]
  codeoutline daemon [--port PORT]
  codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
  codeoutline lsp --stdio [--project PATH]
  codeoutline serve --http [--host HOST] [--port PORT] [--project PATH] [--allow-root PATH ...]
  codeoutline explore --project PATH --query QUERY [--budget BYTES]
  codeoutline status [--project PATH]
  codeoutline rebuild [--project PATH]
  codeoutline doctor [--project PATH]
  codeoutline update [--check] [--channel CHANNEL]
  codeoutline --version

HTTP options: --allow-host HOST, --allow-origin ORIGIN (repeatable).
install starts the background service and registers it at login; uninstall
stops it and removes that entry. daemon is the service itself.
Remote HTTP requires CODEOUTLINE_TOKEN (at least 16 bytes).
Local HTTP without --allow-root serves any project; stdio and remote HTTP
default to --project or the working directory.
Project defaults to the working directory for one-shot commands.
doctor reports JSON diagnostics and exits nonzero on a failed check.
]]

local function parse(args)
    local clean = {}
    for _, value in ipairs(args) do
        -- Runtime logging options (LOG_STDERR, LOG_LEVEL, LOG_FILE, LOG_DIR)
        -- are read by xnet itself; the launchers add them before user args.
        if not value:match('^LOG_[A-Z_]+=') then clean[#clean + 1] = value end
    end
    -- No command: an MCP client (redirected stdin) gets a stdio service, which
    -- keeps registrations from 0.1.7 working; a terminal gets help. Windows
    -- consoles are detected by the stdio service's first read.
    local command = clean[1]
    if not command then
        local terminal = package.config:sub(1, 1) ~= '\\' and os.execute('test -t 0')
        if terminal == true or terminal == 0 then command = '--help' else return 'serve', { stdio = true } end
    end
    if command == '--help' or command == '-h' or command == '--version' then
        assert(#clean <= 1, 'unexpected arguments after ' .. command)
        return command, {}
    end
    local allowed = {
        lsp = { stdio = true, project = true },
        serve = { stdio = true, http = true, project = true, host = true, port = true,
            ['allow-root'] = true, ['allow-host'] = true, ['allow-origin'] = true },
        daemon = { port = true }, install = { port = true, npm = true }, uninstall = { port = true },
        explore = { project = true, query = true, budget = true },
        update = { check = true, channel = true },
        status = { project = true }, rebuild = { project = true }, doctor = { project = true },
    }
    assert(allowed[command], 'unknown command: ' .. command)
    local options, i = {}, 2
    while i <= #clean do
        local name, value = clean[i]:match('^%-%-([%w-]+)=(.*)$')
        if not name then name = clean[i]:match('^%-%-([%w-]+)$') end
        assert(name and (allowed[command][name] or name == 'help'), 'unknown option: ' .. clean[i])
        local flag = name == 'check' or name == 'stdio' or name == 'http' or name == 'help' or name == 'npm'
        if flag then
            assert(value == nil, '--' .. name .. ' does not take a value')
            value = true
        elseif value == nil then
            i = i + 1
            value = clean[i]
            assert(value and not value:match('^%-%-'), 'missing value for --' .. name)
        end
        assert(value ~= '', 'empty value for --' .. name)
        if name:match('^allow-') then
            options[name] = options[name] or {}
            table.insert(options[name], value)
        else
            assert(options[name] == nil, 'duplicate option --' .. name)
            options[name] = value
        end
        i = i + 1
    end
    return command, options
end

local function doctor(root)
    local checks, healthy = {}, true
    local function check(name, fn)
        local ok, detail = pcall(fn)
        checks[#checks + 1] = { name = name, ok = ok, detail = tostring(detail) }
        healthy = healthy and ok
    end
    check('runtime', function()
        for _, name in ipairs({ 'realpath', 'temp_file', 'replace_file', 'read_stdin', 'random_bytes', 'sha256_hex', 'list_dir', 'to_utf8' }) do
            assert(type(xutils[name]) == 'function', 'rebuild xnet2lua: missing xutils.' .. name)
        end
        assert(cmsgpack and xcompress and xshared and xnet and xproc, 'rebuild xnet2lua with xproc and default modules')
        return 'xnet2lua / ' .. (jit and jit.version or _VERSION)
    end)
    -- A warning, not a failure: UTF-8 projects work without the GBK converter.
    check('gbk', function()
        if xutils.to_utf8('\214\208\206\196', 'gbk') == '中文' then return 'system converter available' end
        return 'unavailable: GBK sources cannot be decoded; install the system GBK converter'
            .. ' (glibc-gconv-extra on EL8/EL9)'
    end)
    check('scanner', function()
        return xscan and os.getenv('XSCAN_PURE_LUA') ~= '1' and 'native xscan' or 'pure Lua fallback'
    end)
    local idx
    check('project', function()
        idx = require('codeoutline.index').open(root)
        return idx.root
    end)
    check('enumerator', function()
        assert(idx, 'fix project path first')
        local files = idx:list_files()
        return idx.enumerator .. ': ' .. #files .. ' supported files'
    end)
    check('cache', function()
        assert(idx, 'fix project path first')
        local dir = assert(idx.cache_path:match('^(.*)/[^/]+$'))
        assert(xutils.mkdir_p(dir))
        local temp = assert(xutils.temp_file(dir))
        local ok, err = pcall(function()
            local f = assert(io.open(temp, 'wb'))
            local wrote, why = f:write('codeoutline doctor\n')
            local closed, close_error = f:close()
            assert(wrote, why); assert(closed, close_error)
        end)
        local removed, remove_error = os.remove(temp)
        assert(ok, err); assert(removed, remove_error)
        return dir
    end)
    io.write(xutils.json_pack({ ok = healthy, version = version, checks = checks }), '\n')
    return healthy and 0 or 1
end

local function run()
    local command, options = parse(arg or {})
    if command == '--help' or command == '-h' or options.help then io.write(help); return 0 end
    if command == '--version' then io.write(version, '\n'); return 0 end
    if command == 'update' then
        return require('codeoutline.updater').run(options.check and 'check' or 'update', options)
    end
    if command == 'daemon' or command == 'install' or command == 'uninstall' then
        local daemon = require('codeoutline.daemon')
        local port = tonumber(options.port or daemon.PORT)
        assert(port and port % 1 == 0 and port >= 1 and port <= 65535, 'invalid --port')
        if command == 'daemon' then
            arg = { 'HTTP=1', 'DAEMON=1', 'PORT=' .. port }
            return dofile(scripts .. '/codeoutline/main.lua')
        end
        -- npm runs install after every installation; only global ones start a
        -- service, and nothing here may fail the installation.
        local npm = options.npm
        if npm and (os.getenv('npm_config_global') ~= 'true' or os.getenv('CODEOUTLINE_AUTOSTART') == '0') then return 0 end
        local function say(text) io.write(text, '\n'); io.stdout:flush() end
        local status = 0
        local function attempt(fn, ...)
            local ok, err = pcall(fn, ...)
            if not ok then io.stderr:write('codeoutline: ', tostring(err), '\n'); status = npm and 0 or 1 end
            return ok and err
        end
        -- Launchers name the installation they belong to; unlike an installed
        -- update, it is never deleted, so the login entry points there.
        local root = install
        local initial = os.getenv('CODEOUTLINE_INITIAL')
        if initial and initial ~= '' then
            initial = initial:gsub('\\', '/'):gsub('/+$', '')
            if xutils.stat(initial .. '/scripts/codeoutline/command.lua').exists then root = initial end
        end
        local function finish(code) xthread.stop(code) end
        return {
            __init = function()
                assert(xnet.init()); xtimer.init(16)
                if command == 'uninstall' then
                    for _, removed in ipairs(attempt(daemon.unregister) or {}) do say('removed login entry ' .. removed) end
                    daemon.stop(port, 10000, function(stopped)
                        say(stopped and 'service on port ' .. port .. ' stopped' or 'service on port ' .. port .. ' is still running')
                        finish(stopped and status or 1)
                    end)
                    return
                end
                if os.getenv('CODEOUTLINE_AUTOSTART') ~= '0' then
                    local entry = attempt(function()
                        -- Only launchers before 0.1.8 leave root inside an update.
                        assert(not root:match('/versions/%x+/files$'),
                            'cannot register an installed update; run npm install -g codeoutline, or install from the native launcher')
                        return daemon.register(root, port)
                    end)
                    if entry then say('registered login entry ' .. entry) end
                end
                -- Replace a running service so this installation takes effect now.
                daemon.stop(port, 10000, function()
                    if not attempt(function() return assert(daemon.spawn(root, port), 'cannot start the service') end) then
                        finish(status); return
                    end
                    daemon.wait(port, 20000, function(listening)
                        if listening then say('service listening on http://127.0.0.1:' .. port .. '/mcp')
                        else io.stderr:write('codeoutline: the service did not start; see ', daemon.logs_dir(), '\n')
                            if not npm then status = 1 end end
                        finish(status)
                    end)
                end)
            end,
            __uninit = function() xnet.uninit() end,
            __thread_handle = function() end,
        }
    end
    if command == 'lsp' then
        assert(options.stdio, 'lsp requires --stdio')
        arg = { 'STDIO=1', 'LSP=1' }
        if options.project then arg[#arg + 1] = 'PROJECT=' .. options.project end
        return dofile(scripts .. '/codeoutline/main.lua')
    end
    if command == 'serve' then
        assert(not not options.stdio ~= not not options.http, 'serve requires exactly one of --stdio or --http')
        arg = { options.stdio and 'STDIO=1' or 'HTTP=1' }
        for _, name in ipairs({ 'project', 'host', 'port', 'allow-root', 'allow-host', 'allow-origin' }) do
            local value = options[name]
            if value then
                for _, item in ipairs(type(value) == 'table' and value or { value }) do
                    arg[#arg + 1] = name:upper():gsub('-', '_') .. '=' .. item
                end
            end
        end
        return dofile(scripts .. '/codeoutline/main.lua')
    end
    local root = options.project or '.'
    if command == 'doctor' then return doctor(root) end
    local svc = require('codeoutline.service')
    if command == 'explore' then
        assert(options.query, 'explore requires --query')
        local budget
        if options.budget then budget = assert(tonumber(options.budget), '--budget must be a number') end
        local text = svc.explore(root, options.query, { budget = budget })
        io.write(text, '\n')
    else
        io.write(xutils.json_pack(svc[command](root)), '\n')
    end
    return 0
end

-- Lease the installed update this process runs from, so installing a newer
-- one does not delete files it may still load (language parsers load lazily).
local lease = require('xupgate.client').lease(install)
local ok, result = pcall(run)
if not ok then io.stderr:write('codeoutline: ', tostring(result), '\n'); result = 1 end
if type(result) == 'table' then
    if lease then
        local uninit = result.__uninit
        result.__uninit = function(...)
            lease.release()
            if uninit then return uninit(...) end
        end
    end
    return result
end
if lease then lease.release() end
io.stdout:flush()
-- One-shot commands exchange no thread messages; the empty handler keeps the
-- runtime from warning that none is set.
return { __init = function() xthread.stop(result) end, __thread_handle = function() end }
