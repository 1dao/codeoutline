-- Build and publish all-platform XUpgate releases using existing runtimes.
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local root = assert(source:match('^(.*)/tools/[^/]+$'))
package.path = root .. '/scripts/?.lua;' .. package.path
local c, u = require('xupgate.common'), require('xutils')
local options = {}
for _, value in ipairs(arg or {}) do
    local k, v = value:match('^([A-Z_]+)=(.*)$')
    if k then options[k] = v end
end
local action = options.ACTION or 'build'
local kind = options.KIND or 'full'
assert(kind == 'full' or kind == 'scripts', 'KIND=full|scripts')
assert(action == 'build' or action == 'upload' or action == 'publish', 'ACTION=build|upload|publish')
local version = assert(options.VERSION, 'VERSION is required')
local sequence = assert(tonumber(options.SEQUENCE), 'SEQUENCE is required')
assert(c.version(version) and sequence > 0 and sequence % 1 == 0, 'invalid version/sequence')
local output = assert(options.OUTPUT, 'OUTPUT is required'):gsub('\\', '/')
local targets = { 'win32-x64', 'linux-x64', 'darwin-universal' }
local public_key = assert(c.read(root .. '/keys/update-public.pem'))
local function json(value) return assert(u.json_pack(value)) end
local function read(path) return assert(c.read(path), 'cannot read ' .. path) end
local function quote(path)
    assert(not path:find('[\r\n"%!&|<>^$;()]') and not path:find(string.char(96), 1, true), 'unsafe shell path')
    if package.config:sub(1, 1) == '\\' then return '"' .. path .. '"' end
    assert(not path:find("'", 1, true), 'unsafe shell path')
    return "'" .. path .. "'"
end
local function git(command)
    local pipe = assert(io.popen(command))
    local data = pipe:read('a'); assert(pipe:close(), 'Git command failed')
    return data:gsub('%s+$', '')
end
local function walk(directory, callback, prefix)
    local entries, truncated = u.list_dir(directory, 10000)
    assert(entries and not truncated, 'cannot enumerate ' .. directory)
    table.sort(entries, function(a, b) return a.name < b.name end)
    for _, entry in ipairs(entries) do
        local relative = (prefix or '') .. entry.name
        assert(c.path(relative), 'unsupported package path: ' .. relative)
        if entry.dir then walk(directory .. '/' .. entry.name, callback, relative .. '/')
        else callback(relative, directory .. '/' .. entry.name) end
    end
end
local function artifact_path(target) return output .. '/xupgate/' .. target .. '.json' end
local function load_artifact(target)
    local artifact = assert(c.decode_json(read(artifact_path(target))))
    local manifest = c.manifest(artifact.envelope, public_key)
    assert(manifest.project == 'codeoutline' and manifest.platform == target
        and manifest.version == version and manifest.sequence == sequence, 'artifact identity mismatch')
    c.bundle(assert(u.base64_decode(artifact.package)), manifest)
    return artifact, manifest
end
local function build()
    local base = assert(options.BASE, 'BASE is required'):gsub('\\', '/')
    local key = assert(options.KEY, 'KEY is required; private key stays outside release directories')
    assert(not u.stat(output).exists, 'OUTPUT exists; use a fresh directory')
    assert(u.stat(key).exists, 'private key missing')
    local commit = git('git rev-parse HEAD')
    local dirty = git('git status --porcelain --untracked-files=normal --ignore-submodules=untracked') ~= ''
    -- Check every platform before creating output.
    for _, target in ipairs(targets) do
        local original = base .. '/codeoutline-' .. target .. '/native/package'
        local info = assert(c.decode_json(read(original .. '/build-info.json')))
        assert(info.target == target and (options.CI == '1'
            and info.version == version and info.updateSequence == sequence and info.releaseReady and not info.sourceDirty
            or options.CI ~= '1' and info.version ~= version and sequence > (info.updateSequence or 0)), 'invalid base version/sequence: ' .. target)
        for path, hash in pairs(info.sha256) do
            assert(c.path(path) and u.sha256_hex(read(original .. '/' .. path)) == hash, 'base file changed: ' .. path)
        end
        assert(read(original .. '/keys/update-public.pem'):gsub('\r\n', '\n') == public_key:gsub('\r\n', '\n'), 'base signing key differs')
    end
    for _, target in ipairs(targets) do
        local original = base .. '/codeoutline-' .. target .. '/native/package'
        local directory = output .. '/native/' .. target
        walk(original, function(path, file)
            if options.CI == '1' or (not path:match('^scripts/codeoutline/') and not path:match('^scripts/xupgate/')) then
                c.write(directory .. '/' .. path, read(file))
            end
        end)
        if options.CI ~= '1' then
        for _, module in ipairs({ 'codeoutline', 'xupgate' }) do
            walk(root .. '/scripts/' .. module, function(path, file)
                if path:match('%.lua$') then c.write(directory .. '/scripts/' .. module .. '/' .. path, read(file)) end
            end)
        end
        c.write(directory .. '/scripts/codeoutline/version.lua', "return '" .. version .. "'\n")
        for _, launcher in ipairs({ 'codeoutline', 'codeoutline.cmd' }) do
            c.write(directory .. '/' .. launcher, read(root .. '/launcher/' .. launcher))
        end
        c.write(directory .. '/DISTRIBUTION.md', read(root .. '/docs/DISTRIBUTION.md'))
        local package_manifest = assert(c.decode_json(read(directory .. '/package.json')))
        package_manifest.version = version
        c.write(directory .. '/package.json', json(package_manifest) .. '\n')
        local info = assert(c.decode_json(read(directory .. '/build-info.json')))
        local base_version = info.version
        info.version, info.updateSequence, info.sourceCommit = version, sequence, commit
        info.sourceDirty, info.releaseReady = dirty, false
        info.note = 'Manual script update using the ' .. base_version .. ' platform runtime; see runtimeCommit'
        info.sha256 = {}
        walk(directory, function(path, file)
            if path ~= 'build-info.json' then info.sha256[path] = u.sha256_hex(read(file)) end
        end)
        c.write(directory .. '/build-info.json', json(info) .. '\n')
        end
        local files = {}
        local runtime_files = {}
        walk(directory, function(path, file)
            local bytes = read(file)
            if kind == 'scripts' and (path:match('^bin/') or path:match('^lib/') or path:match('^licenses/')) then
                runtime_files[path] = u.sha256_hex(bytes)
            else
                files[#files + 1] = { path = path, data = u.base64_encode(bytes),
                    executable = path:match('^bin/') ~= nil or path == 'codeoutline' }
            end
        end)
        local bundle = json({ schema = 1, files = files })
        assert(#bundle <= 50331648, 'package exceeds 48 MiB')
        local manifest = { schema = 1, project = 'codeoutline', version = version, sequence = sequence,
            platform = target, minUpdater = kind == 'scripts' and 2 or 1, kind = kind, entry = 'scripts/codeoutline/command.lua',
            runtime = target == 'win32-x64' and 'bin/xnet.exe' or 'bin/xnet',
            size = #bundle, sha256 = u.sha256_hex(bundle), notes = options.NOTES or '' }
        if kind == 'scripts' then
            manifest.runtimeFiles = runtime_files
            -- Pin the already published full artifact so clients that skipped it
            -- can fetch its runtime without activating an intermediate version.
            for _, candidate in ipairs({ base .. '/xupgate/' .. target .. '.json', base .. '/../bundles/xupgate/' .. target .. '.json' }) do
                local existing = c.decode_json(c.read(candidate))
                if existing then
                    local full = c.manifest(existing.envelope, public_key)
                    if full.kind ~= 'scripts' and full.project == 'codeoutline' and full.platform == target and full.sequence < sequence then
                        local reference_files = {}
                        for _, file in ipairs(c.bundle(assert(u.base64_decode(existing.package)), full)) do reference_files[file.path] = file.data end
                        local matches = true
                        for path, hash in pairs(runtime_files) do
                            if not reference_files[path] or u.sha256_hex(reference_files[path]) ~= hash then matches = false; break end
                        end
                        if matches then
                            manifest.runtimeRelease = { version = full.version, sequence = full.sequence, sha256 = full.sha256 }
                            break
                        end
                    end
                end
            end
        end
        local payload = json(manifest)
        local message, signature = output .. '/xupgate/' .. target .. '.payload', output .. '/xupgate/' .. target .. '.sig'
        c.write(message, payload)
        local ok, err = pcall(function()
            local result = os.execute('openssl dgst -sha256 -sign ' .. quote(key)
                .. ' -out ' .. quote(signature) .. ' ' .. quote(message))
            assert(result == true or result == 0, 'OpenSSL signing failed')
            local envelope = { payload = payload, signature = u.base64_encode(read(signature)) }
            c.manifest(envelope, public_key) -- Reject the wrong private key before writing the artifact.
            c.bundle(bundle, manifest)
            c.write(artifact_path(target), json({ envelope = envelope, package = u.base64_encode(bundle) }))
        end)
        os.remove(message); os.remove(signature)
        assert(ok, err)
        io.write('Built and verified ', artifact_path(target), '\n'); io.stdout:flush()
    end
end
if action == 'build' then
    build()
    return { __init = function() xthread.stop(0) end }
end
-- Validate all local bundles before making any remote changes.
local artifacts, manifests = {}, {}
for _, target in ipairs(targets) do artifacts[target], manifests[target] = load_artifact(target) end
local url = (options.URL or 'https://43.133.255.193:51215'):gsub('/+$', '')
assert(url:match('^https://'), 'HTTPS required')
local channel = options.CHANNEL or 'stable'; assert(c.id(channel), 'invalid channel')
local token = os.getenv('XUPGATE_PUBLISH_TOKEN')
if not token and options.CREDENTIAL_FILE then
    token = read(options.CREDENTIAL_FILE):match('^[%w_]+=(.-)%s*$')
end
assert(token and token ~= '' and not token:find('[\r\n]'), 'set XUPGATE_PUBLISH_TOKEN or CREDENTIAL_FILE')
local http = require('xupgate.http_client')
local proxy = options.PROXY or os.getenv('CODEOUTLINE_RELEASE_PROXY')
if proxy and proxy ~= '' then
    proxy = proxy:gsub('^socks5://', 'socks5h://')
    assert(require('xupgate.proxy').parse(proxy), 'Invalid release proxy')
else proxy = nil end
local function request(path, body, callback)
    http.request({ url = url .. path, method = body and 'POST' or 'GET',
        headers = { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. token },
        body = body and json(body), timeout_ms = 150000, max_redirects = 0, verify = true,
        ca_file = options.CA_FILE or root .. '/keys/update-ca.crt', proxy = proxy }, function(err, response)
        if err or response.status < 200 or response.status >= 300 then
            io.stderr:write('Release request failed: ', err or ('HTTP ' .. response.status), '\n')
            xthread.stop(1); return
        end
        local ok, failure = pcall(function()
            callback(assert(c.decode_json(response.body), 'invalid server response'))
        end)
        if not ok then io.stderr:write(tostring(failure), '\n'); xthread.stop(1) end
    end)
end
return {
    __init = function()
        assert(xnet.init()); xtimer.init(16)
        -- Administrator credentials allow safe retries and all-platform publication checks.
        request('/api/admin/projects', nil, function(projects)
            local project = assert(projects.codeoutline, 'CodeOutline project missing')
            assert(project.enabled and project.publicKey:gsub('\r\n', '\n') == public_key:gsub('\r\n', '\n'), 'server project/key mismatch')
            if action == 'publish' then
                for _, target in ipairs(targets) do
                    local release = assert(project.releases[version .. '/' .. target], 'upload every platform before publishing')
                    assert(release.manifest.sha256 == manifests[target].sha256 and release.status ~= 'withdrawn', 'remote release mismatch')
                end
                request('/api/admin/projects/codeoutline/publish', { version = version, channel = channel }, function()
                    io.write('Published ', version, ' on ', channel, ' for all three platforms\n'); xthread.stop(0)
                end)
                return
            end
            local index = 0
            local function next_upload()
                index = index + 1
                local target = targets[index]
                if not target then io.write('All three drafts uploaded; use ACTION=publish when ready\n'); xthread.stop(0); return end
                local existing = project.releases[version .. '/' .. target]
                if existing then
                    assert(existing.manifest.sha256 == manifests[target].sha256, 'immutable remote release differs: ' .. target)
                    io.write('Already uploaded ', target, '\n'); next_upload(); return
                end
                request('/api/admin/projects/codeoutline/releases', artifacts[target], function()
                    io.write('Uploaded draft ', target, '\n'); io.stdout:flush(); next_upload()
                end)
            end
            next_upload()
        end)
    end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
