-- Real signatures and disk installations; no service or production release changes.
package.path = 'scripts/?.lua;' .. package.path
local c, u = require('xupgate.common'), require('xutils')
local scratch = '.update-test/update-spec-' .. os.time()
assert(not u.stat(scratch).exists, 'choose a fresh test directory')
assert(u.mkdir_p(scratch))
local function shell(command) local ok = os.execute(command); assert(ok == true or ok == 0, command) end
shell('openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ' .. scratch .. '/private.pem 2> ' .. scratch .. '/openssl.log')
shell('openssl pkey -in ' .. scratch .. '/private.pem -pubout -out ' .. scratch .. '/public.pem')
local key = assert(c.read(scratch .. '/public.pem'))
local initial = scratch .. '/initial'
c.write(initial .. '/bin/runtime', 'runtime-A')
c.write(initial .. '/lib/codec.lua', 'codec')
local function fixture(version, sequence, kind, runtime)
    local files = { { path = 'main.lua', data = u.base64_encode('version ' .. version) } }
    if kind == 'full' then
        files[#files + 1] = { path = 'bin/runtime', data = u.base64_encode(runtime), executable = true }
        files[#files + 1] = { path = 'lib/codec.lua', data = u.base64_encode('codec') }
    end
    local bundle = assert(u.json_pack({ schema = 1, files = files }))
    local m = { schema = 1, project = 'update-test', platform = 'win32-x64', version = version,
        sequence = sequence, minUpdater = kind == 'scripts' and 2 or 1, kind = kind,
        runtime = 'bin/runtime', entry = 'main.lua', size = #bundle, sha256 = u.sha256_hex(bundle) }
    if kind == 'scripts' then
        m.runtimeFiles = { ['bin/runtime'] = u.sha256_hex(runtime), ['lib/codec.lua'] = u.sha256_hex('codec') }
    end
    local payload = assert(u.json_pack(m))
    c.write(scratch .. '/payload', payload)
    shell('openssl dgst -sha256 -sign ' .. scratch .. '/private.pem -out ' .. scratch .. '/signature ' .. scratch .. '/payload')
    local envelope = { payload = payload, signature = u.base64_encode(assert(c.read(scratch .. '/signature'))) }
    c.manifest(envelope, key); c.bundle(bundle, m)
    return envelope, bundle, m
end
local api = require('xupgate.client').open({ project = 'update-test', platform = 'win32-x64',
    url = 'https://example.invalid', publicKey = key, directory = scratch .. '/installed', runtimeDirectory = initial })
local full1, bytes1 = fixture('1.0.0', 1, 'full', 'runtime-A')
assert(api.install(full1, bytes1).version == '1.0.0')
local scripts2, bytes2 = fixture('1.0.1', 2, 'scripts', 'runtime-A')
assert(not bytes2:find(u.base64_encode('runtime-A'), 1, true), 'script bundle embeds runtime bytes')
local installed = api.install(scripts2, bytes2)
assert(installed.kind == 'scripts' and c.read(installed.root .. '/bin/runtime') == 'runtime-A')
assert(api.rollback().version == '1.0.0')
assert(api.rollback().version == '1.0.1')
local full3, bytes3 = fixture('1.1.0', 3, 'full', 'runtime-B')
installed = api.install(full3, bytes3)
assert(c.read(installed.root .. '/bin/runtime') == 'runtime-B', 'runtime update did not activate')
local scripts4, bytes4 = fixture('1.1.1', 4, 'scripts', 'runtime-B')
installed = api.install(scripts4, bytes4)
assert(c.read(installed.root .. '/bin/runtime') == 'runtime-B', 'scripts did not reuse upgraded runtime')
local bad, bad_bytes = fixture('1.1.2', 5, 'scripts', 'unavailable-runtime')
assert(not pcall(api.install, bad, bad_bytes), 'runtime mismatch accepted')
assert(api.current().version == '1.1.1', 'failed update changed active version')
assert(not u.stat(scratch .. '/installed/update-test/update.lock').exists, 'failed install left lock')
assert(not pcall(api.install, scripts2, bytes2), 'replayed script update accepted')
assert(not pcall(api.install, { payload = scripts4.payload .. ' ', signature = scripts4.signature }, bytes4), 'tampered signature accepted')
c.write(installed.root .. '/bin/runtime', 'corrupted')
assert(not pcall(api.current), 'tampered reused runtime accepted')
assert(api.rollback().version == '1.1.0', 'runtime corruption prevented safe rollback')
local orphan = require('xupgate.client').open({ project = 'update-test', platform = 'win32-x64',
    url = 'https://example.invalid', publicKey = key, directory = scratch .. '/orphan' })
assert(not pcall(orphan.install, scripts2, bytes2), 'script update without a compatible runtime accepted')
io.write('Signed script updates, runtime reuse/replacement, rollback, replay, tamper and missing-runtime checks passed\n')
os.remove(scratch .. '/private.pem')
return { __init = function() xthread.stop(0) end }
