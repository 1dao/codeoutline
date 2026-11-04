// Install actual tarballs outside the checkout; no SDK ships in the artifacts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, writeFile, readFile, chmod, rename } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { root, defaultRuntime, version } from './node/helpers.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

test('packed npm and native artifacts work outside the checkout', { timeout: 120000 }, async () => {
    assert(process.env.npm_execpath, 'run via npm run test:package');
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-dist-'));
    const target = process.platform === 'darwin' ? 'darwin-universal' : `${process.platform}-${process.arch}`;
    const stage = join(temp, 'stage');
    const install = join(temp, 'install 中文');
    const project = join(temp, 'project 中文');
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('CODEOUTLINE_')));
    env.CODEOUTLINE_UPDATE_DIR = join(temp, 'updates');
    env.CODEOUTLINE_AUTO_UPDATE = '0';
    await mkdir(install); await mkdir(project);
    await writeFile(join(install, 'package.json'), '{"name":"install-smoke","private":true}\n');
    await writeFile(join(project, 'example.lua'), 'function packaged_symbol() return 42 end\n');
    const run = (command, args, cwd = temp) => {
        const r = spawnSync(command, args, { cwd, env, encoding: 'utf8', timeout: 60000 });
        assert.equal(r.status, 0, `${r.error || ''}\n${r.stderr}\n${r.stdout}`); return r.stdout;
    };
    const npm = (args, cwd) => run(process.execPath, [process.env.npm_execpath, ...args], cwd);
    run(defaultRuntime, [join(root, 'tools/package.lua'), `TARGET=${target}`, `OUTPUT=${stage}`, 'LOG_STDERR=1'], root);
    const native = join(stage, 'native');
    const nativeBin = join(native, 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
    if (process.platform !== 'win32') { await chmod(nativeBin, 0o755); await chmod(join(native, 'codeoutline'), 0o755); }
    const info = JSON.parse(await readFile(join(native, 'build-info.json'), 'utf8'));
    for (const [path, hash] of Object.entries(info.sha256)) {
        assert.equal(createHash('sha256').update(await readFile(join(native, path))).digest('hex'), hash);
    }
    const archives = [];
    for (const folder of [native, join(stage, 'npm')]) {
        const [packed] = JSON.parse(npm(['pack', folder, '--json', '--pack-destination', temp]));
        for (const f of packed.files) assert(!/(^|\/)(AGENTS\.md|PLAN\.md|tests|node_modules|\.git)(\/|$)/.test(f.path), f.path);
        if (folder === native) {
            // Flat layout: the runtime and its HTTP codec, not the submodule's tree.
            const paths = packed.files.map((f) => f.path);
            assert(paths.includes(`bin/${process.platform === 'win32' ? 'xnet.exe' : 'xnet'}`), paths.join(' '));
            assert(paths.includes('lib/xhttp_codec.lua'), paths.join(' '));
            for (const asset of ['codeoutline.vsix', 'zed/extension.toml', 'zed/extension.wasm']) {
                if (existsSync(join(root, 'dist/editor-assets', asset))) {
                    assert(paths.includes(`editors/${asset}`), paths.join(' '));
                }
            }
            assert(!paths.some((p) => p.startsWith('xnet2lua/')), paths.join(' '));
        }
        archives.push(join(temp, packed.filename));
    }
    npm(['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', ...archives], install);
    const entry = join(install, 'node_modules/codeoutline/launcher/codeoutline.cjs');
    const installedManifest = JSON.parse(await readFile(join(install, 'node_modules/codeoutline/package.json'), 'utf8'));
    assert.equal(installedManifest.scripts.preuninstall, 'node launcher/codeoutline.cjs uninstall --npm || exit 0');
    const invoke = (...args) => run(process.execPath, [entry, ...args], project);
    // A new bootstrap can start over legacy state without loading hash-based
    // code, rewriting the state, or emitting the generic invalid-update error.
    const legacyRoot = join(env.CODEOUTLINE_UPDATE_DIR, 'codeoutline');
    const legacyState = JSON.stringify({ schema: 1, highSequence: 0, current: 'a'.repeat(64) });
    await mkdir(legacyRoot, { recursive: true });
    await writeFile(join(legacyRoot, 'current.json'), legacyState);
    const recovered = spawnSync(process.execPath, [entry, '--version'], { cwd: project, env, encoding: 'utf8', timeout: 15000 });
    assert.equal(recovered.status, 0, recovered.stderr);
    assert.equal(recovered.stdout.trim(), version);
    assert.doesNotMatch(recovered.stderr, /installed update invalid/);
    assert.equal(await readFile(join(legacyRoot, 'current.json'), 'utf8'), legacyState);
    await writeFile(join(legacyRoot, 'current.json'), '{ corrupt state');
    const cleanupHelp = spawnSync(process.execPath, [entry, 'uninstall', '--help'], { cwd: project, env, encoding: 'utf8', timeout: 15000 });
    assert.equal(cleanupHelp.status, 0, cleanupHelp.stderr);
    assert.doesNotMatch(cleanupHelp.stderr, /installed update invalid/);
    assert.match(cleanupHelp.stdout, /--purge/);
    await writeFile(join(legacyRoot, 'current.json'), legacyState);
    assert.equal(JSON.parse(invoke('doctor')).ok, true);
    assert.equal(JSON.parse(invoke('status')).files, 1);
    assert.match(invoke('explore', '--query', 'packaged_symbol'), /return 42/);
    assert.equal(JSON.parse(invoke('rebuild')).cacheLoaded, false);
    // Native runtime and launcher also work without Node or a source checkout.
    if (process.platform === 'win32') {
        assert.equal(run(process.env.ComSpec || 'cmd.exe', ['/d', '/c', join(native, 'codeoutline.cmd'), '--version'], project).trim(), version);
    } else assert.equal(run(join(native, 'codeoutline'), ['--version'], project).trim(), version);
    // Both launchers keep the runtime quiet and leave no log files behind.
    const nativeCommand = process.platform === 'win32'
        ? [process.env.ComSpec || 'cmd.exe', ['/d', '/c', join(native, 'codeoutline.cmd'), '--version']]
        : [join(native, 'codeoutline'), ['--version']];
    for (const [command, args] of [[process.execPath, [entry, '--version']], nativeCommand]) {
        const r = spawnSync(command, args, { cwd: project, env, encoding: 'utf8', timeout: 60000 });
        assert.equal(r.status, 0, r.stderr);
        assert.equal(r.stderr, '', `${command} ${args.join(' ')} wrote to stderr:\n${r.stderr}`);
    }
    assert(!existsSync(join(project, 'logs')), 'CLI commands created logs/ in the project');
    const transport = new StdioClientTransport({ command: process.execPath,
        args: [entry, 'serve', '--stdio', '--project', project], cwd: project, env, stderr: 'pipe' });
    transport.stderr?.resume();
    const client = new Client({ name: 'installed-package-smoke', version: '1' });
    try {
        await client.connect(transport);
        const result = await client.callTool({ name: 'codeoutline_explore', arguments: { query: 'packaged_symbol' } });
        assert.notEqual(result.isError, true); assert.match(result.content[0].text, /return 42/);
    } finally { await client.close(); }
    // Exercise the bundled HTTP codec, not the development checkout's copy.
    const probe = net.createServer();
    await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
    const port = probe.address().port;
    await new Promise((resolve) => probe.close(resolve));
    const child = spawn(process.execPath, [entry, 'serve', '--http', '--port', String(port), '--project', project], {
        cwd: project, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
    });
    const httpClient = new Client({ name: 'installed-http-smoke', version: '1' });
    let httpStderr = '';
    try {
        await new Promise((resolve, reject) => {
            let logs = '';
            const timer = setTimeout(() => reject(new Error(`HTTP startup timeout: ${logs}`)), 10000);
            child.stderr.on('data', (chunk) => { logs += chunk; httpStderr += chunk; });
            // The URL is a status line on stdout, not an [ERRR] record on stderr.
            child.stdout.on('data', (chunk) => {
                logs += chunk;
                if (logs.includes('[codeoutline] listening')) { clearTimeout(timer); resolve(); }
            });
            child.once('error', (err) => { clearTimeout(timer); reject(err); });
            child.once('exit', () => { clearTimeout(timer); reject(new Error(logs)); });
        });
        assert.equal(httpStderr, '', `serve --http wrote to stderr:\n${httpStderr}`);
        await httpClient.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
        const result = await httpClient.callTool({ name: 'codeoutline_status', arguments: {} });
        assert.notEqual(result.isError, true); assert.equal(JSON.parse(result.content[0].text).files, 1);
    } finally {
        await httpClient.close();
        // Windows kills a Node shim without delivering POSIX signals to it. Use
        // the installed native PID below for cleanup on that platform.
        if (process.platform === 'win32') run('taskkill.exe', ['/pid', String(child.pid), '/t', '/f']);
        else { const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited; }
    }
    // MCP clients start the server in the project root: it must stay clean too.
    assert(!existsSync(join(project, 'logs')), 'serve created logs/ in the project');
    // Simulate optional dependencies disabled: fail explicitly, never fall back to a sibling runtime.
    const isolated = join(temp, 'missing-runtime'); await mkdir(isolated);
    await writeFile(join(isolated, 'package.json'), '{"name":"missing-smoke","private":true}\n');
    npm(['install', '--offline', '--omit=optional', '--ignore-scripts', '--no-audit', '--no-fund', archives[1]], isolated);
    const missing = spawnSync(process.execPath, [join(isolated, 'node_modules/codeoutline/launcher/codeoutline.cjs'), '--version'], { env, encoding: 'utf8' });
    assert.notEqual(missing.status, 0); assert.match(missing.stderr, /Missing @codua\/codeoutline-/);
    // Exercise real global npm removal under a temporary prefix. Only service
    // and login operations are stubbed; Lua cleanup and npm uninstall are real.
    const prefix = join(temp, 'global 中文'), profile = join(temp, 'remove-profile');
    npm(['install', '-g', '--prefix', prefix, '--offline', '--ignore-scripts', '--no-audit', '--no-fund', ...archives]);
    const globalModules = process.platform === 'win32' ? join(prefix, 'node_modules') : join(prefix, 'lib/node_modules');
    const globalEntry = join(globalModules, 'codeoutline/launcher/codeoutline.cjs');
    const globalRequire = createRequire(globalEntry);
    let globalRuntime = dirname(globalRequire.resolve(`@codua/codeoutline-${target}/package.json`));
    const nestedRuntime = join(globalModules, 'codeoutline/node_modules/@codua', `codeoutline-${target}`);
    if (globalRuntime !== nestedRuntime) {
        await mkdir(dirname(nestedRuntime), { recursive: true });
        await rename(globalRuntime, nestedRuntime);
        globalRuntime = nestedRuntime;
    }
    await writeFile(join(globalRuntime, 'scripts/codeoutline/daemon.lua'), `local M = { PORT = 19876 }
function M.unregister() assert(not os.getenv('CO_TEST_CLEANUP_FAIL'), 'fixture cleanup failure'); return {} end
function M.stop(_, _, done) done(true) end
function M.state_dir() return os.getenv('USERPROFILE') .. '/.codeoutline' end
return M
`);
    const shim = join(temp, 'npm-shim'); await mkdir(shim);
    const npmShim = join(shim, process.platform === 'win32' ? 'npm.cmd' : 'npm');
    await writeFile(npmShim, process.platform === 'win32'
        ? '@echo off\r\nif "%~1"=="uninstall" if defined CO_TEST_NPM_REMOVE_FAIL exit /b 73\r\n"%CO_TEST_NODE%" "%CO_TEST_NPM%" %*\r\nexit /b %errorlevel%\r\n'
        : '#!/bin/sh\nif test "$1" = uninstall && test -n "$CO_TEST_NPM_REMOVE_FAIL"; then exit 73; fi\nexec "$CO_TEST_NODE" "$CO_TEST_NPM" "$@"\n');
    if (process.platform !== 'win32') await chmod(npmShim, 0o755);
    await mkdir(join(profile, '.cursor'), { recursive: true });
    const agentFile = join(profile, '.cursor/mcp.json');
    const agentConfig = { keep: true, mcpServers: { codeoutline: { url: 'http://127.0.0.1:19876/mcp' } } };
    await writeFile(agentFile, JSON.stringify(agentConfig));
    await mkdir(join(profile, '.codeoutline/cache'), { recursive: true });
    await writeFile(join(profile, '.codeoutline/cache/test.idx'), 'index');
    const removeEnv = { ...env, npm_config_prefix: prefix, USERPROFILE: profile, HOME: profile,
        CODEX_HOME: join(profile, '.codex'), CLAUDE_CONFIG_DIR: join(profile, '.claude'),
        HERMES_HOME: join(profile, '.hermes'), COPILOT_HOME: join(profile, '.copilot'),
        APPDATA: join(profile, 'app'), LOCALAPPDATA: join(profile, 'local'), ProgramFiles: join(profile, 'programs'),
        XDG_CONFIG_HOME: join(profile, '.config'), XDG_DATA_HOME: join(profile, '.local/share'),
        CO_TEST_NODE: process.execPath, CO_TEST_NPM: process.env.npm_execpath,
        PATH: [shim, dirname(process.execPath), ...(process.platform === 'win32'
            ? [join(process.env.SystemRoot, 'System32')] : ['/usr/bin', '/bin'])].join(process.platform === 'win32' ? ';' : ':') };
    const remove = (args, extra = {}, launcher = globalEntry) => spawnSync(process.execPath, [launcher, 'remove', ...args],
        { cwd: project, env: { ...removeEnv, ...extra }, encoding: 'utf8', timeout: 30000 });
    const hook = (extra = {}) => spawnSync(process.execPath, [globalEntry, 'uninstall', '--npm'],
        { cwd: project, env: { ...removeEnv, npm_config_global: 'true', npm_lifecycle_event: 'preuninstall',
            npm_command: 'uninstall', ...extra }, encoding: 'utf8', timeout: 30000 });
    for (const extra of [{ npm_command: 'install' }, { npm_command: 'update' }, { npm_config_global: 'false' },
        { npm_lifecycle_event: 'postinstall' }, { CODEOUTLINE_REMOVE_CLEANED: '1' },
        { npm_command: '', npm_config_argv: JSON.stringify({ original: ['install', '-g'] }) }]) {
        const skippedHook = hook(extra);
        assert.equal(skippedHook.status, 0, skippedHook.stdout + skippedHook.stderr);
        assert(JSON.parse(await readFile(agentFile, 'utf8')).mcpServers.codeoutline, 'non-uninstall lifecycle removed agent config');
    }
    const failedHook = hook({ CO_TEST_CLEANUP_FAIL: '1' });
    assert.notEqual(failedHook.status, 0, failedHook.stdout + failedHook.stderr);
    assert.doesNotMatch(failedHook.stdout, /Uninstall hook cleanup completed/);
    assert(existsSync(globalEntry), 'failed hook removed the npm package');
    await writeFile(agentFile, JSON.stringify(agentConfig));
    const hookCleanup = hook();
    assert.equal(hookCleanup.status, 0, hookCleanup.stdout + hookCleanup.stderr);
    assert.match(hookCleanup.stdout, /Uninstall hook cleanup completed/);
    assert.equal(JSON.parse(await readFile(agentFile, 'utf8')).mcpServers.codeoutline, undefined);
    assert(existsSync(globalEntry), 'hook recursively removed its own package');
    assert(existsSync(join(profile, '.codeoutline/cache/test.idx')), 'hook purged user data');
    await writeFile(agentFile, JSON.stringify(agentConfig));
    const legacyHook = hook({ npm_command: '', npm_config_argv: JSON.stringify({ original: ['uninstall', '-g', 'codeoutline'] }) });
    // An empty npm_command is equivalent to an absent value on some hosts.
    assert.equal(legacyHook.status, 0, legacyHook.stdout + legacyHook.stderr);
    assert.match(legacyHook.stdout, /Uninstall hook cleanup completed/);
    assert.equal(JSON.parse(await readFile(agentFile, 'utf8')).mcpServers.codeoutline, undefined);
    await writeFile(agentFile, JSON.stringify(agentConfig));
    const help = remove(['--help']);
    assert.equal(help.status, 0, help.stderr); assert(existsSync(globalEntry));
    const invalidRemove = remove(['--unknown']);
    assert.notEqual(invalidRemove.status, 0); assert(existsSync(globalEntry));
    const localRemove = remove([], {}, entry);
    assert.notEqual(localRemove.status, 0); assert(existsSync(globalEntry));
    assert.match(localRemove.stderr, /installed globally/);
    const failedRemove = remove([], { CO_TEST_CLEANUP_FAIL: '1' });
    assert.notEqual(failedRemove.status, 0, failedRemove.stdout + failedRemove.stderr);
    assert(existsSync(globalEntry), 'failed cleanup removed the npm package');
    assert(existsSync(join(profile, '.codeoutline/cache/test.idx')), 'failed cleanup purged recovery data');
    await writeFile(agentFile, JSON.stringify(agentConfig));
    const npmFailed = remove([], { CO_TEST_NPM_REMOVE_FAIL: '1' });
    assert.equal(npmFailed.status, 73, npmFailed.stdout + npmFailed.stderr);
    assert(existsSync(globalEntry), 'failed npm uninstall unexpectedly removed the package');
    // Use the actual global shim as well: on Windows the parent .cmd must not
    // keep either itself or the runtime locked while npm removes the package.
    const removed = process.platform === 'win32'
        ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/c', join(prefix, 'codeoutline.cmd'), 'remove'],
            { cwd: project, env: removeEnv, encoding: 'utf8', timeout: 30000 })
        : remove([]);
    assert.equal(removed.status, 0, removed.stdout + removed.stderr);
    assert.match(removed.stdout, /Cleanup completed/);
    assert(!existsSync(globalEntry), 'global npm package remains after remove');
    assert(!existsSync(globalRuntime), 'runtime remains after remove; it may still be locked');
    assert(!existsSync(join(profile, '.codeoutline')), 'remove did not purge user data');
    const remainingAgent = JSON.parse(await readFile(agentFile, 'utf8'));
    assert.equal(remainingAgent.keep, true); assert.equal(remainingAgent.mcpServers.codeoutline, undefined);
    // Retain artifacts for inspection and an independent pnpm installation.
    console.log(`Distribution preview: ${temp}`);
});
