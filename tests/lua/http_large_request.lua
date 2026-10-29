package.path = 'scripts/?.lua;' .. package.path
local http = require('xupgate.http_client')
local port = assert(arg[1])
return {
    __init = function()
        assert(xnet.init())
        xtimer.init(16)
        http.request({ url = 'https://127.0.0.1:' .. port .. '/upload', method = 'POST',
            body = string.rep('x', 10 * 1024 * 1024 + 100000), verify = false, timeout_ms = 30000 },
            function(err, response)
                if err or not response or response.status ~= 200 then
                    io.stderr:write(tostring(err or (response and response.status)), '\n')
                    xthread.stop(1)
                else
                    io.write('large HTTPS request accepted\n')
                    xthread.stop(0)
                end
            end)
    end,
    __thread_handle = function() end,
}
