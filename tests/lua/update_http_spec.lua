-- Opt-in deployed XUpgate protocol test; only an isolated project is published.
package.path = 'scripts/?.lua;' .. package.path
local c, u, http = require('xupgate.common'), require('xutils'), require('xupgate.http_client')
local options = {}
for _, argument in ipairs(arg or {}) do local k, v = argument:match('^([A-Z_]+)=(.*)$'); if k then options[k] = v end end
local url = options.URL or 'https://43.133.255.193:51215'
local ca = options.CA_FILE or 'keys/update-ca.crt'
local token = assert(c.read(options.CREDENTIAL_FILE or '../xupgate/.test-output/server-admin.env')):match('^[%w_]+=(.-)%s*$')
assert(token, 'invalid administrator credential file')
local project = 'protocol-test-' .. os.time() .. '-' .. math.random(999999)
local directory = '.update-test/' .. project
assert(u.mkdir_p(directory))
local function shell(command) local ok = os.execute(command); assert(ok == true or ok == 0, 'OpenSSL failed') end
shell('openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ' .. directory .. '/private.pem 2> ' .. directory .. '/openssl.log')
shell('openssl pkey -in ' .. directory .. '/private.pem -pubout -out ' .. directory .. '/public.pem')
local public = assert(c.read(directory .. '/public.pem'))
local runtime_reference
local function artifact(version, sequence, kind)
    local files = { { path = 'main.lua', data = u.base64_encode('version ' .. version) } }
    if kind == 'full' then files[#files + 1] = { path = 'bin/runtime', data = u.base64_encode('test-runtime') } end
    local bundle = assert(u.json_pack({ schema = 1, files = files }))
    local manifest = { schema = 1, project = project, platform = 'lua-any', version = version, sequence = sequence,
        minUpdater = kind == 'scripts' and 2 or 1, kind = kind, entry = 'main.lua', runtime = 'bin/runtime',
        size = #bundle, sha256 = u.sha256_hex(bundle) }
    if kind == 'scripts' then manifest.runtimeFiles = { ['bin/runtime'] = u.sha256_hex('test-runtime') } end
    if kind == 'scripts' then
        manifest.runtimeRelease = assert(runtime_reference)
    else runtime_reference = { version = version, sequence = sequence, sha256 = manifest.sha256 } end
    local payload = assert(u.json_pack(manifest)); c.write(directory .. '/payload', payload)
    shell('openssl dgst -sha256 -sign ' .. directory .. '/private.pem -out ' .. directory .. '/signature ' .. directory .. '/payload')
    return { envelope = { payload = payload, signature = u.base64_encode(assert(c.read(directory .. '/signature'))) }, package = u.base64_encode(bundle) }
end
local full, scripts = artifact('1.0.0', 1, 'full'), artifact('1.0.1', 2, 'scripts')
local thread
local function resume(...) local ok, err = coroutine.resume(thread, ...); if not ok then io.stderr:write(tostring(err), '\n'); xthread.stop(1) end end
local function await(start)
    local waiting, ready, saved = false, false, nil
    start(function(...) saved = { n = select('#', ...), ... }; ready = true; if waiting then resume(unpack(saved, 1, saved.n)) end end)
    if ready then return unpack(saved, 1, saved.n) end
    waiting = true; return coroutine.yield()
end
local function request(path, body, expected)
    local err, response = await(function(done)
        http.request({ url = url .. path, method = body and 'POST' or 'GET', body = body and assert(u.json_pack(body)),
            headers = { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. token },
            ca_file = ca, verify = true, max_redirects = 0, timeout_ms = 30000 }, done)
    end)
    assert(not err, err); assert(response.status == expected, 'HTTP ' .. response.status .. ' at ' .. path)
    return response
end
local function run()
    local created = false
    local ok, err = pcall(function()
        request('/api/admin/projects', { id = project, name = 'Protocol integration test', publicKey = public }, 201); created = true
        local prefix = '/api/admin/projects/' .. project
        local client = require('xupgate.client').open({ project = project, platform = 'lua-any', publicKey = public,
            directory = directory .. '/installed', url = url, caFile = ca, http = http })
        for index, fixture in ipairs({ full, scripts }) do
            request(prefix .. '/releases', fixture, 201)
            request('/api/v1/projects/' .. project .. '/releases/' .. (index == 1 and '1.0.0' or '1.0.1') .. '/lua-any', nil, 404)
            request(prefix .. '/publish', { version = index == 1 and '1.0.0' or '1.0.1', channel = 'stable' }, 200)
            local update_error, result = await(function(done) client.update(done) end)
            assert(not update_error, update_error); assert(result and result.version == (index == 1 and '1.0.0' or '1.0.1'))
            assert(c.read(result.root .. '/bin/runtime') == 'test-runtime')
            io.write('HTTPS install verified: ', result.version, ' ', result.kind, '\n'); io.stdout:flush()
        end
        local skipped = require('xupgate.client').open({ project = project, platform = 'lua-any', publicKey = public,
            directory = directory .. '/skipped-full', url = url, caFile = ca, http = http })
        local dependency_error, result = await(function(done) skipped.update(done) end)
        assert(not dependency_error, dependency_error)
        assert(result.version == '1.0.1' and c.read(result.root .. '/bin/runtime') == 'test-runtime', 'missing runtime was not fetched automatically')
        io.write('Skipped full release fetched without activating an intermediate version\n'); io.stdout:flush()
        assert(client.rollback().version == '1.0.0')
        local tampered = { envelope = { payload = scripts.envelope.payload .. ' ', signature = scripts.envelope.signature }, package = scripts.package }
        request(prefix .. '/releases', tampered, 400)
        request(prefix .. '/withdraw', { version = '1.0.1' }, 200)
        request('/api/v1/projects/' .. project .. '/channels/stable/lua-any', nil, 404)
    end)
    if created then request('/api/admin/projects/' .. project .. '/enabled', { enabled = false }, 200) end
    os.remove(directory .. '/private.pem')
    assert(ok, err)
    io.write('Real HTTPS script/full updates, signature rejection, rollback and withdrawal passed; test project disabled\n')
    xthread.stop(0)
end
return {
    __init = function() assert(xnet.init()); xtimer.init(16); thread = coroutine.create(run); resume() end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
