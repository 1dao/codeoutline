-- Native entry point: xnet main.lua STDIO=1 PROJECT=... or HTTP=1 PORT=19876.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local scripts = assert(source:match('^(.*)/codeoutline/[^/]+$'))
local install = assert(scripts:match('^(.*)/scripts$'))
package.path = scripts .. '/?.lua;' .. package.path
local paths = require('codeoutline.path')
local mcp = require('codeoutline.mcp')
local http = require('codeoutline.http')
local options = { ALLOW_ROOT = {}, ALLOW_HOST = {}, ALLOW_ORIGIN = {} }
for _, argument in ipairs(arg or {}) do
    local key, value = argument:match('^([A-Z_]+)=(.*)$')
    if key then
        if type(options[key]) == 'table' then table.insert(options[key], value) else options[key] = value end
    end
end
assert((options.STDIO == '1') ~= (options.HTTP == '1'), 'Specify exactly one of STDIO=1 or HTTP=1')
local config = { roots = {}, project = options.PROJECT and assert(paths.canonical(options.PROJECT)),
    host = options.HOST or '127.0.0.1', port = tonumber(options.PORT or '19876'),
    token = os.getenv('CODEOUTLINE_TOKEN'), hosts = options.ALLOW_HOST, origins = options.ALLOW_ORIGIN }
assert(config.port and config.port % 1 == 0 and config.port >= 1 and config.port <= 65535, 'Invalid PORT')
if config.token == '' then config.token = nil end
for _, root in ipairs(options.ALLOW_ROOT) do config.roots[#config.roots + 1] = assert(paths.canonical(root)) end
if #config.roots == 0 then config.roots[1] = config.project or assert(paths.canonical('.')) end
local shared = assert(xshared.create('codeoutline_control', 65536, 256))
local jobs, next_id, job_count, worker_ready = {}, 0, 0, false
local endpoint, stdio, input = nil, nil, ''
local startup = xtimer.now_ms()

local function submit(req, done)
    if job_count >= 64 then return nil, 'Request queue is full; retry later' end
    next_id = next_id + 1
    local id = tostring(next_id)
    req.deadline = xtimer.now_ms() + 120000
    jobs[id], job_count = { done = done, request = req }, job_count + 1
    if worker_ready then
        local ok, err = xthread.post(2, 'run', id, req)
        if not ok then jobs[id], job_count = nil, job_count - 1; return nil, tostring(err) end
    end
    return id
end
local function cancel(id) if id and jobs[id] then shared:set('cancel:' .. id, true) end end
local function send(response)
    if response then io.stdout:write(xutils.json_pack(response), '\n'); io.stdout:flush() end
end

return {
    __tick_ms = 5,
    __init = function()
        assert(xnet.init())
        assert(xthread.create_thread(2, 'INDEX', scripts .. '/codeoutline/index_worker.lua'))
        if options.STDIO == '1' then
            assert(xutils.read_stdin, 'Rebuild runtime for nonblocking stdin support')
            stdio = mcp.new(config, submit, cancel)
        else
            local runtime = options.RUNTIME_ROOT or install .. '/xnet2lua'
            local codec = dofile(runtime .. '/scripts/core/share/xhttp_codec.lua')
            endpoint = http.start(config, submit, cancel, codec)
            io.stderr:write(string.format('[codeoutline] listening http://%s:%d/mcp\n', config.host, config.port))
        end
    end,
    __thread_handle = function(_, op, id, ok, result)
        if op == 'worker_ready' then
            worker_ready = true
            for job_id, job in pairs(jobs) do
                local posted, err = xthread.post(2, 'run', job_id, job.request)
                if not posted then jobs[job_id], job_count = nil, job_count - 1; job.done(false, tostring(err)) end
            end
        elseif op == 'worker_result' then
            local job = jobs[id]
            if job then jobs[id], job_count = nil, job_count - 1; job.done(ok, result) end
        end
    end,
    __update = function()
        if not worker_ready and xtimer.now_ms() - startup > 10000 then error('Index worker failed to start') end
        if stdio then
            local data, err = xutils.read_stdin(65536)
            if not data then
                local incomplete = err == 'eof' and input:find('%S') ~= nil
                if incomplete then send(mcp.error(nil, -32700, 'EOF before message newline')) end
                if err ~= 'eof' then io.stderr:write(tostring(err) .. '\n') end
                stdio:close(); shared:set('shutdown', true); xthread.stop(err == 'eof' and not incomplete and 0 or 1); return
            end
            input = input .. data
            while true do
                local pos = input:find('\n', 1, true)
                if not pos then break end
                local line = input:sub(1, pos - 1)
                input = input:sub(pos + 1)
                if #line > 1048576 then send(mcp.error(nil, -32600, 'Message too large')); xthread.stop(1); return end
                local msg, decode_error = mcp.decode(line)
                if not msg then send(decode_error) else stdio:dispatch(msg, send) end
            end
            if #input > 1048576 then send(mcp.error(nil, -32600, 'Message too large')); xthread.stop(1); return end
            stdio:tick()
        else endpoint.tick() end
    end,
    __uninit = function()
        shared:set('shutdown', true)
        if stdio then stdio:close() end
        if endpoint then endpoint.close() end
        xthread.shutdown_thread(2)
        xnet.uninit()
    end,
}
