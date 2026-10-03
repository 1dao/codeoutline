-- Interactive release orchestrator. No credentials are embedded in commands.
-- xnet tools/release.lua MODE=update|runtime|full [DRY_RUN=1]
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local root = assert(source:match('^(.*)/tools/[^/]+$'))
package.path = root .. '/scripts/?.lua;' .. package.path
local c, u = require('xupgate.common'), require('xutils')
local options = {}
for _, value in ipairs(arg or {}) do
    local k, v = value:match('^([A-Z_]+)=(.*)$'); if k then options[k] = v end
end
local mode = options.MODE or 'full'
assert(mode == 'update' or mode == 'full' or mode == 'runtime', 'MODE=update|runtime|full')
local dry = options.DRY_RUN == '1'
local windows = package.config:sub(1, 1) == '\\'
local runtime = root .. '/bin/' .. (windows and 'xnet.exe' or 'xnet')
local targets = { 'win32-x64', 'linux-x64', 'darwin-universal' }
local url = (options.URL or 'https://43.133.255.193:51215'):gsub('/+$', '')
assert(url:match('^https://'), 'HTTPS required')
local home = assert(os.getenv('USERPROFILE') or os.getenv('HOME')):gsub('\\', '/')
local key = options.KEY or home .. '/.codex/keys/xupgate/codeoutline.private.pem'
local credential = options.CREDENTIAL_FILE or root .. '/../xupgate/.test-output/server-admin.env'
local ca = options.CA_FILE or root .. '/keys/update-ca.crt'
local parent = options.RELEASE_DIR or (windows and 'C:/release' or root .. '/dist/releases')
local base = options.BASE or (windows and 'C:/release/0.1.3' or root .. '/dist/releases/0.1.3')
local proxy = options.PROXY or os.getenv('CODEOUTLINE_RELEASE_PROXY')
if proxy and proxy ~= '' then
    -- Resolve target hostnames through SOCKS, avoiding local DNS restrictions.
    proxy = proxy:gsub('^socks5://', 'socks5h://')
    assert(require('xupgate.proxy').parse(proxy), 'Invalid release proxy')
else proxy = nil end
local function quote(value)
    assert(not value:find('[\r\n"%!&|<>^$;()]') and not value:find(string.char(96), 1, true), 'unsafe shell argument')
    if windows then return '"' .. value .. '"' end
    assert(not value:find("'", 1, true), 'unsafe shell argument')
    return "'" .. value .. "'"
end
local function shell_command(text)
    if proxy then
        if text:match('^git ') then text = text:gsub('^git ', 'git -c ' .. quote('http.proxy=' .. proxy) .. ' ', 1) end
        if windows then
            local prefix = {}
            for _, name in ipairs({ 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'npm_config_https_proxy', 'npm_config_proxy' }) do
                prefix[#prefix + 1] = 'set ' .. quote(name .. '=' .. proxy)
            end
            text = table.concat(prefix, ' && ') .. ' && ' .. text
        else
            text = 'env HTTPS_PROXY=' .. quote(proxy) .. ' HTTP_PROXY=' .. quote(proxy)
                .. ' ALL_PROXY=' .. quote(proxy) .. ' npm_config_https_proxy=' .. quote(proxy)
                .. ' npm_config_proxy=' .. quote(proxy) .. ' ' .. text
        end
    end
    if windows and text:sub(1, 1) == '"' then text = '"' .. text .. '"' end
    return text
end
local function command(text, allow_failure)
    local pipe = assert(io.popen(shell_command(text) .. ' 2>&1'))
    local output = pipe:read('a'); local ok = pipe:close()
    if not ok and not allow_failure then error(output ~= '' and output or 'Command failed') end
    return output:gsub('%s+$', ''), ok
end
local npm_exists
local function publish_npm(file, name, version)
    if npm_exists(name, version) then
        local hash = assert(u.json_unpack(command('npm view ' .. quote(name .. '@' .. version) .. ' dist.shasum --json')))
        local local_hash = command('openssl dgst -sha1 ' .. quote(file)):match('([a-f0-9]+)%s*$')
        assert(local_hash and hash == local_hash, 'Published npm package differs: ' .. name)
        io.write('Already published ', name, '@', version, '\n'); return
    end
    io.write('Publish ', name, ' (npm authentication prompts remain interactive)...\n'); io.stdout:flush()
    local ok = os.execute(shell_command('npm publish ' .. quote(file) .. ' --access public'))
    assert(ok == true or ok == 0, 'npm publication failed; fix publishing authentication and retry RESUME=' .. version)
end
local function step(label, text)
    io.write(label, '\n'); io.stdout:flush()
    local output = command(text)
    if output ~= '' then io.write(output, '\n'); io.stdout:flush() end
end
local function version_parts(value)
    local a, b, d = value:match('^(%d+)%.(%d+)%.(%d+)$')
    if not a then return end
    a, b, d = tonumber(a), tonumber(b), tonumber(d)
    if string.format('%d.%d.%d', a, b, d) ~= value then return end
    return { a, b, d }
end
local function newer(a, b)
    for i = 1, 3 do if a[i] ~= b[i] then return a[i] > b[i] end end
    return false
end
npm_exists = function(name, version)
    local output, ok = command('npm view ' .. quote(name .. '@' .. version) .. ' version --json', true)
    if ok then return output ~= '' end
    assert(output:find('E404', 1, true), 'npm version check failed; fix registry access before releasing:\n' .. output)
    return false
end
local function tool(action, output, version, sequence, extra)
    local args = { quote(runtime), quote(root .. '/tools/update-release.lua'), quote('ACTION=' .. action),
        quote('OUTPUT=' .. output), quote('VERSION=' .. version), quote('SEQUENCE=' .. sequence),
        quote('URL=' .. url), quote('CA_FILE=' .. ca), quote('CREDENTIAL_FILE=' .. credential),
        'LOG_STDERR=1', 'LOG_FILE=0' }
    if proxy then args[#args + 1] = quote('PROXY=' .. proxy) end
    for _, item in ipairs(extra or {}) do args[#args + 1] = quote(item) end
    return table.concat(args, ' ')
end
local function resume_release(thread)
    local ok, err = coroutine.resume(thread)
    if not ok then
        io.stderr:write(tostring(err), '\nRelease stopped; completed external steps are not rolled back.\n')
        xthread.stop(1)
    end
end
local function finish_release(output, version, sequence)
    local baseline, bundles = output .. '/ci', output .. '/bundles'
    if mode == 'full' then
        for _, target in ipairs(targets) do
            publish_npm(baseline .. '/codeoutline-' .. target .. '/codua-codeoutline-' .. target .. '-' .. version .. '.tgz',
                '@codua/codeoutline-' .. target, version)
        end
        publish_npm(baseline .. '/codeoutline-win32-x64/codeoutline-' .. version .. '.tgz', 'codeoutline', version)
        local assets = {}
        for _, target in ipairs(targets) do assets[#assets + 1] = quote(baseline .. '/codeoutline-' .. target .. '/codeoutline-' .. target .. '.tar.gz') end
        local exists, ok = command('gh release view ' .. quote('v' .. version) .. ' --json tagName', true)
        if ok then
            assert(c.decode_json(exists).tagName == 'v' .. version, 'GitHub release mismatch')
            step('Update GitHub release assets...', 'gh release upload ' .. quote('v' .. version) .. ' --clobber ' .. table.concat(assets, ' '))
        else
            assert(exists:find('release not found', 1, true) or exists:find('Not Found', 1, true), 'GitHub release lookup failed: ' .. exists)
            step('Publish GitHub release...', 'gh release create ' .. quote('v' .. version) .. ' --verify-tag --title '
                .. quote('v' .. version) .. ' --generate-notes ' .. table.concat(assets, ' '))
        end
    end
    step('Publish all-platform stable update...', tool('publish', bundles, version, sequence))
    io.write('Release completed: ', version, '\n'); xthread.stop(0)
end
local function continue_release(project)
    local version = options.RESUME
    assert(c.version(version), 'RESUME must be a version such as 0.1.4')
    local output = parent .. '/' .. version
    local state = assert(c.decode_json(c.read(output .. '/release-state.json')), 'Release state missing')
    assert(state.version == version and state.mode == mode, 'Release state/mode mismatch')
    assert(command('git rev-list -n 1 ' .. quote('v' .. version)) == state.commit, 'Local release tag changed')
    local remote = command('git ls-remote --tags origin ' .. quote('refs/tags/v' .. version))
    assert(remote:match('^(%x+)') == state.commit, 'Remote release tag changed')
    local public = assert(c.read(root .. '/keys/update-public.pem'))
    for _, target in ipairs(targets) do
        if mode ~= 'update' then
            local folder = output .. '/ci/codeoutline-' .. target
            local sums = assert(c.read(folder .. '/SHA256SUMS')):gsub('^\239\187\191', '')
            for hash, file in sums:gmatch('([a-f0-9]+)%s+([^\r\n]+)') do
                assert(c.path(file) and u.sha256_hex(assert(c.read(folder .. '/' .. file))) == hash, 'CI file changed: ' .. file)
            end
            local info = assert(c.decode_json(c.read(folder .. '/native/package/build-info.json')))
            assert(info.sourceCommit == state.commit and info.version == version and info.updateSequence == state.sequence, 'CI identity mismatch')
        end
        local artifact = assert(c.decode_json(c.read(output .. '/bundles/xupgate/' .. target .. '.json')))
        local manifest = c.manifest(artifact.envelope, public)
        assert(manifest.project == 'codeoutline' and manifest.version == version and manifest.platform == target and manifest.sequence == state.sequence, 'Signed artifact mismatch')
        c.bundle(assert(u.base64_decode(artifact.package)), manifest)
        local existing = project.releases[version .. '/' .. target]
        if existing then assert(existing.manifest.sha256 == manifest.sha256 and existing.status ~= 'withdrawn', 'Remote artifact differs') end
    end
    io.write('Verified existing release ', version, '; continue without new commits, tags or builds.\n'); io.stdout:flush()
    if dry then io.write('DRY_RUN: resume validation passed; no publications changed.\n'); xthread.stop(0); return end
    step('Verify/upload existing drafts...', tool('upload', output .. '/bundles', version, state.sequence))
    finish_release(output, version, state.sequence)
end
local function release(project)
    if options.RESUME then continue_release(project); return end
    local current = require('codeoutline.version')
    if mode == 'update' and not options.BASE then
        local runtime_commit = command('git -C xnet2lua rev-parse HEAD')
        local directories, truncated = u.list_dir(parent, 10000)
        assert(not truncated, 'Too many release directories')
        local best_sequence = -1
        for _, directory in ipairs(directories or {}) do
            if directory.dir and c.version(directory.name) then
                for _, candidate in ipairs({ parent .. '/' .. directory.name .. '/ci', parent .. '/' .. directory.name }) do
                    local matches, candidate_sequence = true, nil
                    for _, target in ipairs(targets) do
                        local info = c.decode_json(c.read(candidate .. '/codeoutline-' .. target .. '/native/package/build-info.json'))
                        local published = info and project.releases[info.version .. '/' .. target]
                        if not info or not published or published.status ~= 'published' or published.manifest.kind == 'scripts'
                            or info.runtimeCommit ~= runtime_commit or info.target ~= target or not info.updateSequence
                            or (candidate_sequence and candidate_sequence ~= info.updateSequence) then matches = false; break end
                        candidate_sequence = info.updateSequence
                    end
                    if matches and candidate_sequence > best_sequence then base, best_sequence = candidate, candidate_sequence end
                end
            end
        end
    end
    local highest = assert(version_parts(current))
    local sequence = require('codeoutline.update_sequence')
    for _, item in pairs(project.releases) do
        sequence = math.max(sequence, item.manifest.sequence)
        local parts = version_parts(item.manifest.version)
        if parts and newer(parts, highest) then highest = parts end
    end
    local remote_tags = command('git ls-remote --tags origin')
    local local_tags = command('git tag --list')
    local version
    while true do
        if options.VERSION then version = options.VERSION
        else io.write('New version (for example 0.1.4): '); io.stdout:flush(); version = io.read('*l'); assert(version, 'Cancelled') end
        version = version:match('^%s*(.-)%s*$')
        local parts, reason = version_parts(version)
        if not parts then reason = 'Use a version such as 0.1.4.'
        elseif not newer(parts, highest) then reason = 'Version must be newer than the current and published versions.'
        elseif u.stat(parent .. '/' .. version).exists then reason = 'Release directory already exists.'
        else
            for tag in local_tags:gmatch('[^\r\n]+') do if tag == 'v' .. version then reason = 'Local tag already exists.' end end
            for tag in remote_tags:gmatch('refs/tags/([^%s]+)') do if tag == 'v' .. version or tag == 'v' .. version .. '^{}' then reason = 'Remote tag already exists.' end end
            for _, item in pairs(project.releases) do if item.manifest.version == version then reason = 'XUpgate version already exists (including drafts).' end end
            if not reason then
                for _, name in ipairs({ 'codeoutline', '@codua/codeoutline-win32-x64', '@codua/codeoutline-linux-x64', '@codua/codeoutline-darwin-universal' }) do
                    if npm_exists(name, version) then reason = 'npm version already exists: ' .. name; break end
                end
            end
        end
        if not reason then break end
        io.write(reason, ' Choose another version.\n'); io.stdout:flush()
        assert(not options.VERSION, reason)
    end
    sequence = sequence + 1
    local output = parent .. '/' .. version
    io.write('Version ', version, ', sequence ', sequence, ', mode ', mode, ', output ', output, '\n'); io.stdout:flush()
    if dry then io.write('DRY_RUN: checks passed; no files, commits, tags or publications changed.\n'); xthread.stop(0); return end
    -- The user commits feature changes first. Only version files are committed here.
    assert(command('git status --porcelain --untracked-files=normal --ignore-submodules=untracked') == '',
        'Commit project changes first; the release tool only commits version files')
    assert(command('git branch --show-current') == 'main', 'Release from main')
    assert(command('git rev-parse --show-toplevel'):gsub('\\', '/') == root, 'Run from repository root')
    local baseline
    if mode == 'update' then
        for _, target in ipairs(targets) do
            local directory = base .. '/codeoutline-' .. target .. '/native/package'
            local info = assert(c.decode_json(c.read(directory .. '/build-info.json')), 'Missing baseline: ' .. directory)
            assert(info.runtimeCommit == command('git -C xnet2lua rev-parse HEAD'), 'Runtime changed; use MODE=runtime or MODE=full')
            for path, hash in pairs(info.sha256) do assert(c.path(path) and u.sha256_hex(assert(c.read(directory .. '/' .. path))) == hash, 'Base file changed: ' .. path) end
        end
        baseline = base
    end
    local function spec(name, env)
        local text = quote(runtime) .. ' ' .. quote('tests/lua/' .. name .. '.lua') .. ' LOG_STDERR=1 LOG_FILE=0 LOG_LEVEL=ERROR'
        if env then text = (windows and 'set ' .. quote(env) .. ' && ' or 'env ' .. env .. ' ') .. text end
        return text
    end
    step('Verify Lua behavior...', spec('codeoutline_spec'))
    step('Verify Lua behavior (pure Lua scanner)...', spec('codeoutline_spec', 'XSCAN_PURE_LUA=1'))
    step('Verify Lua stability...', spec('stability_spec'))
    step('Verify update installation...', spec('update_spec'))
    -- Script updates ship no npm launcher; the SDK checks are opt-in there.
    if mode ~= 'update' or options.NODE_TESTS == '1' then
        step('Verify MCP SDK interoperability...', 'npm test')
        step('Verify installed packages...', 'npm run test:package')
    end
    local version_files = 'package.json package-lock.json scripts/codeoutline/version.lua scripts/codeoutline/update_sequence.lua'
    local previous = command('git rev-parse HEAD')
    local bundles = output .. '/bundles'
    local commit
    -- Script updates are built and installed locally before anything is
    -- pushed, so a failure here leaves no tag or upload behind.
    local built, failure = pcall(function()
        local package_manifest = assert(c.decode_json(c.read(root .. '/package.json')))
        local lock = assert(c.decode_json(c.read(root .. '/package-lock.json')))
        package_manifest.version, lock.version, lock.packages[''].version = version, version, version
        c.write(root .. '/package.json', assert(u.json_pack(package_manifest)) .. '\n')
        c.write(root .. '/package-lock.json', assert(u.json_pack(lock)) .. '\n')
        c.write(root .. '/scripts/codeoutline/version.lua', "return '" .. version .. "'\n")
        c.write(root .. '/scripts/codeoutline/update_sequence.lua', 'return ' .. sequence .. '\n')
        step('Commit release version...', 'git add -- ' .. version_files)
        step('Commit release version...', 'git commit -m ' .. quote('release: ' .. version))
        commit = command('git rev-parse HEAD')
        assert(u.mkdir_p(output))
        if mode == 'update' then
            step('Build signed all-platform updates...', tool('build', bundles, version, sequence,
                { 'BASE=' .. baseline, 'KEY=' .. key, 'CI=0', 'KIND=scripts' }))
            step('Install and run the local platform update...', tool('verify', bundles, version, sequence, { 'BASE=' .. baseline }))
        end
    end)
    if not built then
        -- Nothing left this machine yet; undo the local commit and output.
        command('git reset --keep ' .. quote(previous), true)
        command('git checkout -- ' .. version_files, true)
        if u.stat(output).exists then u.rmtree(output) end
        error(tostring(failure) .. '\nLocal release commit and output were removed; nothing was pushed or uploaded.', 0)
    end
    step('Create tag...', 'git tag ' .. quote('v' .. version))
    c.write(output .. '/release-state.json', assert(u.json_pack({ version = version, sequence = sequence, commit = commit, mode = mode })) .. '\n')
    step('Push commit and tag...', 'git push --atomic origin main ' .. quote('refs/tags/v' .. version))
    if mode ~= 'update' then
        -- GitHub CLI downloads the tested artifacts for exactly this tag/commit.
        local run_id
        for _ = 1, 20 do
            local runs = assert(c.decode_json(command('gh run list --workflow ci.yml --branch ' .. quote('v' .. version)
                .. ' --commit ' .. quote(commit) .. ' --event push --json databaseId --limit 1')))
            if runs[1] then run_id = runs[1].databaseId; break end
            local thread = coroutine.running()
            xtimer.add(3000, function() resume_release(thread) end, 1)
            coroutine.yield()
        end
        assert(run_id, 'CI run not found yet; commit/tag remain pushed; inspect GitHub Actions')
        step('Wait for all-platform CI...', 'gh run watch ' .. run_id .. ' --exit-status --interval 30')
        baseline = output .. '/ci'
        step('Download CI artifacts...', 'gh run download ' .. run_id .. ' --dir ' .. quote(baseline))
        for _, target in ipairs(targets) do
            local folder = baseline .. '/codeoutline-' .. target
            local sums = assert(c.read(folder .. '/SHA256SUMS')):gsub('^\239\187\191', '')
            for hash, path in sums:gmatch('([a-f0-9]+)%s+([^\r\n]+)') do
                assert(c.path(path) and u.sha256_hex(assert(c.read(folder .. '/' .. path))) == hash, 'CI checksum mismatch')
            end
            assert(u.mkdir_p(folder .. '/native'))
            step('Extract ' .. target .. '...', 'tar -xzf ' .. quote(folder .. '/codua-codeoutline-' .. target .. '-' .. version .. '.tgz') .. ' -C ' .. quote(folder .. '/native'))
            local info = assert(c.decode_json(c.read(folder .. '/native/package/build-info.json')))
            assert(info.sourceCommit == commit and info.version == version and info.updateSequence == sequence and info.releaseReady, 'CI artifact identity mismatch')
        end
        step('Build signed all-platform updates...', tool('build', bundles, version, sequence,
            { 'BASE=' .. baseline, 'KEY=' .. key, 'CI=1', 'KIND=full' }))
    end
    step('Upload all three drafts...', tool('upload', bundles, version, sequence))
    finish_release(output, version, sequence)
end
return {
    __init = function()
        assert(xnet.init()); xtimer.init(16)
        assert(command('git rev-parse --show-toplevel'):gsub('\\', '/') == root, 'Run from repository root')
        if not dry then
            assert(u.stat(key).exists, 'Signing key missing: configure KEY')
            command('openssl version')
            local signing_public = command('openssl pkey -in ' .. quote(key) .. ' -pubout')
            assert(signing_public:gsub('%s', '') == assert(c.read(root .. '/keys/update-public.pem')):gsub('%s', ''), 'Signing private key does not match project public key')
            if mode ~= 'update' then command('gh auth status') end
            if mode == 'full' then command('npm whoami') end
        end
        local token = os.getenv('XUPGATE_PUBLISH_TOKEN') or assert(c.read(credential), 'Configure CREDENTIAL_FILE'):match('^[%w_]+=(.-)%s*$')
        assert(token and not token:find('[\r\n]'), 'Invalid credential file')
        require('xupgate.http_client').request({ url = url .. '/api/admin/projects', verify = true, ca_file = ca,
            max_redirects = 0, timeout_ms = 30000, proxy = proxy, headers = { Authorization = 'Bearer ' .. token } }, function(err, response)
            local ok, failure = pcall(function()
                assert(not err, err); assert(response.status == 200, 'XUpgate authentication failed')
                local project = assert(c.decode_json(response.body).codeoutline, 'CodeOutline project missing')
                assert(project.enabled and project.publicKey:gsub('\r\n', '\n') == assert(c.read(root .. '/keys/update-public.pem')):gsub('\r\n', '\n'), 'XUpgate project/key mismatch')
                resume_release(coroutine.create(function() release(project) end))
            end)
            if not ok then io.stderr:write(tostring(failure), '\nRelease stopped; completed external steps are not rolled back.\n'); xthread.stop(1) end
        end)
    end,
    __uninit = function() xnet.uninit() end,
    __thread_handle = function() end,
}
