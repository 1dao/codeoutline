-- Stage local npm/native artifacts; publishing is deliberately a separate step.
-- bin/xnet tools/package.lua TARGET=win32-x64 OUTPUT=dist/win32-x64 LOG_STDERR=1
local options = {}
for _, value in ipairs(arg or {}) do
    local k, v = value:match('^([A-Z_]+)=(.*)$')
    if k then options[k] = v end
end
local target = assert(options.TARGET, 'TARGET is required')
-- { os, cpus npm may install it on }. Windows 11 on ARM runs x64 binaries
-- under emulation, so the x64 package doubles as its arm64 build; macOS ships
-- one universal (arm64 + x86_64) binary for both CPUs.
local targets = { ['win32-x64'] = { 'win32', 'x64', 'arm64' }, ['linux-x64'] = { 'linux', 'x64' },
    ['darwin-universal'] = { 'darwin', 'arm64', 'x64' } }
local platform = assert(targets[target], 'unsupported TARGET')
local source = assert(xutils.realpath(debug.getinfo(1, 'S').source:sub(2))):gsub('\\', '/')
local root = assert(source:match('^(.*)/tools/[^/]+$'))
package.path = root .. '/scripts/?.lua;' .. package.path
local version = require('codeoutline.version')
local output = (options.OUTPUT or root .. '/dist/' .. target):gsub('\\', '/')
assert(not xutils.stat(output).exists, 'OUTPUT already exists; choose a fresh staging directory')
local function read(path)
    local f = assert(io.open(path, 'rb'), 'cannot read ' .. path)
    local data = f:read('a'); assert(f:close()); return data
end
local function write(path, data)
    assert(xutils.mkdir_p(assert(path:match('^(.*)/[^/]+$'))))
    local f = assert(io.open(path, 'wb'))
    assert(f:write(data)); assert(f:close())
end
local files = {}
local function copy(from, relative)
    local data = read(from)
    write(output .. '/native/' .. relative, data)
    files[relative] = xutils.sha256_hex(data)
end
local function copy_lua(relative)
    local entries, truncated = xutils.list_dir(root .. '/' .. relative, 10000)
    assert(entries and not truncated, 'cannot enumerate ' .. relative)
    for _, entry in ipairs(entries) do
        local path = relative .. '/' .. entry.name
        if entry.dir then copy_lua(path)
        elseif entry.name:match('%.lua$') then copy(root .. '/' .. path, path) end
    end
end
local function git(command)
    -- Only fixed read-only commands; no user input interpolated into the shell.
    local p = assert(io.popen(command))
    local value = p:read('a'); local ok = p:close()
    assert(ok, 'run this tool from the repository root with Git available')
    return value:gsub('%s+$', '')
end
local runtime_commit = git('git -C xnet2lua rev-parse HEAD')
assert(git('git -C xnet2lua diff --name-only') == '', 'runtime has uncommitted changes; commit upstream first')
local runtime_build = dofile(root .. '/tools/runtime_build.lua')(root)
local binary = platform[1] == 'win32' and 'xnet.exe' or 'xnet'
copy(options.RUNTIME or root .. '/bin/' .. binary, 'bin/' .. binary)
copy_lua('scripts/codeoutline')
copy_lua('scripts/xupgate')
copy(root .. '/keys/update-public.pem', 'keys/update-public.pem')
copy(root .. '/keys/update-ca.crt', 'keys/update-ca.crt')
copy(root .. '/xnet2lua/scripts/core/share/xhttp_codec.lua', 'lib/xhttp_codec.lua')
copy(root .. '/xnet2lua/LICENSE', 'licenses/xnet2lua.txt')
copy(root .. '/xnet2lua/3rd/libdeflate/COPYING', 'licenses/libdeflate.txt')
copy(root .. '/LICENSE', 'LICENSE')
-- This tool runs on the runtime it packages, so `jit` tells which Lua is linked in.
if jit then
    copy(root .. '/xnet2lua/3rd/luajit/COPYRIGHT', 'licenses/luajit.txt')
else
    copy(root .. '/licenses/lua-minilua.txt', 'licenses/lua-minilua.txt')
end
for _, name in ipairs({ 'lua-cmsgpack', 'mbedtls' }) do
    copy(root .. '/licenses/' .. name .. '.txt', 'licenses/' .. name .. '.txt')
end
local yyjson = read(root .. '/xnet2lua/3rd/yyjson.h'):match('^(.-)%*/')
write(output .. '/native/licenses/yyjson.txt', assert(yyjson) .. '*/\n')
copy(root .. '/README.md', 'README.md')
copy(root .. '/README.zh-CN.md', 'README.zh-CN.md')
copy(root .. '/docs/DISTRIBUTION.md', 'DISTRIBUTION.md')
copy(root .. '/docs/THIRD_PARTY.md', 'THIRD_PARTY.md')
-- RELEASE=1 stages publishable packages; anything else keeps `private: true`
-- so a preview cannot be published by accident. Untracked files inside the
-- submodule (its build output) do not count as a dirty checkout.
local release = options.RELEASE == '1'
local source_dirty = git('git status --porcelain --untracked-files=normal --ignore-submodules=untracked') ~= ''
if release then
    assert(not source_dirty, 'RELEASE=1 requires a clean checkout')
    assert(not version:find('-', 1, true), 'RELEASE=1 requires a final version, not ' .. version)
    assert(not options.TAG or options.TAG == 'v' .. version,
        'tag ' .. tostring(options.TAG) .. ' does not match version ' .. version)
end
local repository = { type = 'git', url = 'git+https://github.com/1dao/codeoutline.git' }
-- Platform packages are scoped: npm's spam filter rejects new unscoped
-- "<name>-<platform>" names, and a scope keeps look-alikes out. Scoped
-- packages default to restricted, so they declare public access.
local scope = '@codua/'
local public = { access = 'public' }
local manifest = { name = scope .. 'codeoutline-' .. target, version = version, private = not release or nil,
    repository = repository, publishConfig = public,
    description = 'CodeOutline native runtime and Lua implementation for ' .. target,
    os = { platform[1] }, cpu = { platform[2], platform[3] }, license = 'BSD-2-Clause',
    files = { 'bin/', 'lib/', 'keys/', 'scripts/', 'licenses/', 'LICENSE', 'codeoutline', 'codeoutline.cmd', 'build-info.json', '*.md' } }
if platform[1] == 'linux' then manifest.libc = { 'glibc' } end
write(output .. '/native/package.json', xutils.json_pack(manifest) .. '\n')
-- Native launchers pass the same log defaults as launcher/codeoutline.cjs:
-- warnings and errors on stderr, no log files unless CODEOUTLINE_LOG_DIR is set.
copy(root .. '/launcher/codeoutline.cmd', 'codeoutline.cmd')
copy(root .. '/launcher/codeoutline', 'codeoutline')
write(output .. '/native/build-info.json', xutils.json_pack({ version = version, target = target,
    updateSequence = tonumber(options.UPDATE_SEQUENCE) or require('codeoutline.update_sequence'), runtimeCommit = runtime_commit, runtimeBuild = runtime_build, lua = jit and jit.version or _VERSION, sourceCommit = git('git rev-parse HEAD'),
    sourceDirty = source_dirty, sha256 = files, releaseReady = release,
    note = release and 'Release build from a clean checkout'
        or 'Preview: stage with RELEASE=1 from a clean, tagged checkout to publish' }) .. '\n')
local dependencies = {}
for name in pairs(targets) do dependencies[scope .. 'codeoutline-' .. name] = version end
write(output .. '/npm/package.json', xutils.json_pack({ name = 'codeoutline', version = version,
    private = not release or nil, license = 'BSD-2-Clause',
    description = 'MCP server for code exploration: symbols, line-numbered source and call paths',
    keywords = { 'mcp', 'model-context-protocol', 'code-index', 'call-graph', 'lua' },
    repository = repository, homepage = 'https://github.com/1dao/codeoutline#readme', publishConfig = public,
    bugs = { url = 'https://github.com/1dao/codeoutline/issues' },
    bin = { codeoutline = 'launcher/codeoutline.cjs' }, engines = { node = '>=20' },
    -- A global installation starts the shared service and registers it at
    -- login (Lua decides; CODEOUTLINE_AUTOSTART=0 opts out). Never fails npm.
    scripts = { postinstall = 'node launcher/codeoutline.cjs install --npm || exit 0' },
    files = { 'launcher/', 'LICENSE', '*.md' }, optionalDependencies = dependencies }) .. '\n')
write(output .. '/npm/LICENSE', read(root .. '/LICENSE'))
write(output .. '/npm/launcher/codeoutline.cjs', read(root .. '/launcher/codeoutline.cjs'))
write(output .. '/npm/README.md', read(root .. '/README.md'))
write(output .. '/npm/README.zh-CN.md', read(root .. '/README.zh-CN.md'))
write(output .. '/npm/DISTRIBUTION.md', read(root .. '/docs/DISTRIBUTION.md'))
io.write(xutils.json_pack({ output = output, target = target, version = version, runtimeCommit = runtime_commit }), '\n')
return { __init = function() xthread.stop(0) end }
