-- Unified CLI. Launch through codeoutline (npm/native) or xnet with LOG_STDERR=1.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
package.path = scripts .. '/?.lua;' .. package.path
local version = require('codeoutline.version')
local help = [[CodeOutline - Lua code indexing and MCP

Usage:
  codeoutline serve --stdio [--project PATH] [--allow-root PATH ...]
  codeoutline serve --http [--host HOST] [--port PORT] [--project PATH]
  codeoutline explore --project PATH --query QUERY [--budget BYTES]
  codeoutline status [--project PATH]
  codeoutline rebuild [--project PATH]
  codeoutline doctor [--project PATH]
  codeoutline --version

HTTP options: --allow-host HOST, --allow-origin ORIGIN (repeatable).
Remote HTTP requires CODEOUTLINE_TOKEN (at least 16 bytes).
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
    local command = clean[1] or '--help'
    if command == '--help' or command == '-h' or command == '--version' then
        assert(#clean <= 1, 'unexpected arguments after ' .. command)
        return command, {}
    end
    local allowed = {
        serve = { stdio = true, http = true, project = true, host = true, port = true,
            ['allow-root'] = true, ['allow-host'] = true, ['allow-origin'] = true },
        explore = { project = true, query = true, budget = true },
        status = { project = true }, rebuild = { project = true }, doctor = { project = true },
    }
    assert(allowed[command], 'unknown command: ' .. command)
    local options, i = {}, 2
    while i <= #clean do
        local name, value = clean[i]:match('^%-%-([%w-]+)=(.*)$')
        if not name then name = clean[i]:match('^%-%-([%w-]+)$') end
        assert(name and (allowed[command][name] or name == 'help'), 'unknown option: ' .. clean[i])
        local flag = name == 'stdio' or name == 'http' or name == 'help'
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

local ok, result = pcall(run)
if not ok then io.stderr:write('codeoutline: ', tostring(result), '\n'); result = 1 end
if type(result) == 'table' then return result end
io.stdout:flush()
-- One-shot commands exchange no thread messages; the empty handler keeps the
-- runtime from warning that none is set.
return { __init = function() xthread.stop(result) end, __thread_handle = function() end }
