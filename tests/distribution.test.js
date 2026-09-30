// Install actual tarballs outside the checkout; no SDK ships in the artifacts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { mkdtemp, mkdir, writeFile, readFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
    await mkdir(install); await mkdir(project);
    await writeFile(join(install, 'package.json'), '{"name":"install-smoke","private":true}\n');
    await writeFile(join(project, 'example.lua'), 'function packaged_symbol() return 42 end\n');
    const run = (command, args, cwd = temp) => {
        const r = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 60000 });
        assert.equal(r.status, 0, `${r.error || ''}\n${r.stderr}\n${r.stdout}`); return r.stdout;
    };
    const npm = (args, cwd) => run(process.execPath, [process.env.npm_execpath, ...args], cwd);
    run(defaultRuntime, [join(root, 'tools/package.lua'), `TARGET=${target}`, `OUTPUT=${stage}`, 'LOG_STDERR=1'], root);
    const native = join(stage, 'native');
    const nativeBin = join(native, 'xnet2lua/bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
    if (process.platform !== 'win32') { await chmod(nativeBin, 0o755); await chmod(join(native, 'codeoutline'), 0o755); }
    const info = JSON.parse(await readFile(join(native, 'build-info.json'), 'utf8'));
    for (const [path, hash] of Object.entries(info.sha256)) {
        assert.equal(createHash('sha256').update(await readFile(join(native, path))).digest('hex'), hash);
    }
    const archives = [];
    for (const folder of [native, join(stage, 'npm')]) {
        const [packed] = JSON.parse(npm(['pack', folder, '--json', '--pack-destination', temp]));
        for (const f of packed.files) assert(!/(^|\/)(AGENTS\.md|PLAN\.md|tests|node_modules|\.git)(\/|$)/.test(f.path), f.path);
        archives.push(join(temp, packed.filename));
    }
    npm(['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund', ...archives], install);
    const entry = join(install, 'node_modules/codeoutline/launcher/codeoutline.cjs');
    const invoke = (...args) => run(process.execPath, [entry, ...args], project);
    assert.equal(JSON.parse(invoke('doctor')).ok, true);
    assert.equal(JSON.parse(invoke('status')).files, 1);
    assert.match(invoke('explore', '--query', 'packaged_symbol'), /return 42/);
    assert.equal(JSON.parse(invoke('rebuild')).cacheLoaded, false);
    // Native runtime and launcher also work without Node or a source checkout.
    if (process.platform === 'win32') {
        assert.equal(run(process.env.ComSpec || 'cmd.exe', ['/d', '/c', join(native, 'codeoutline.cmd'), '--version'], project).trim(), version);
    } else assert.equal(run(join(native, 'codeoutline'), ['--version'], project).trim(), version);
    const transport = new StdioClientTransport({ command: process.execPath,
        args: [entry, 'serve', '--stdio', '--project', project], cwd: project, stderr: 'pipe' });
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
        cwd: project, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
    });
    child.stdout.resume();
    const httpClient = new Client({ name: 'installed-http-smoke', version: '1' });
    try {
        await new Promise((resolve, reject) => {
            let logs = '';
            const timer = setTimeout(() => reject(new Error(`HTTP startup timeout: ${logs}`)), 10000);
            child.stderr.on('data', (chunk) => {
                logs += chunk;
                if (logs.includes('[codeoutline] listening')) { clearTimeout(timer); resolve(); }
            });
            child.once('error', (err) => { clearTimeout(timer); reject(err); });
            child.once('exit', () => { clearTimeout(timer); reject(new Error(logs)); });
        });
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
    // Simulate optional dependencies disabled: fail explicitly, never fall back to a sibling runtime.
    const isolated = join(temp, 'missing-runtime'); await mkdir(isolated);
    await writeFile(join(isolated, 'package.json'), '{"name":"missing-smoke","private":true}\n');
    npm(['install', '--offline', '--omit=optional', '--ignore-scripts', '--no-audit', '--no-fund', archives[1]], isolated);
    const missing = spawnSync(process.execPath, [join(isolated, 'node_modules/codeoutline/launcher/codeoutline.cjs'), '--version'], { encoding: 'utf8' });
    assert.notEqual(missing.status, 0); assert.match(missing.stderr, /Missing @codua\/codeoutline-/);
    // Retain artifacts for inspection and an independent pnpm installation.
    console.log(`Distribution preview: ${temp}`);
});
