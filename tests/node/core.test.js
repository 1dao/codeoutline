import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import https from 'node:https';
import { fileURLToPath } from 'node:url';
import { mkdtemp, cp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { defaultRuntime } from './helpers.js';

const cwd = fileURLToPath(new URL('../../', import.meta.url));
test('HTTPS client sends requests larger than the default TLS queue', {
    skip: spawnSync('openssl', ['version'], { windowsHide: true }).status !== 0,
    timeout: 40000,
}, async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-http-'));
    let server;
    try {
        const key = join(temp, 'key.pem'), cert = join(temp, 'cert.pem');
        const generated = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost'], { windowsHide: true });
        assert.equal(generated.status, 0, String(generated.stderr));
        let received = 0;
        server = https.createServer({ key: await readFile(key), cert: await readFile(cert) }, (req, res) => {
            req.on('data', chunk => { received += chunk.length; });
            req.on('end', () => { res.writeHead(200); res.end('ok'); });
        });
        await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
        const child = spawn(defaultRuntime, ['tests/lua/http_large_request.lua', String(server.address().port),
            'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=ERROR'], { cwd, windowsHide: true });
        let output = '';
        child.stdout.on('data', data => { output += data; });
        child.stderr.on('data', data => { output += data; });
        const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
        assert.equal(code, 0, output);
        assert.equal(received, 10 * 1024 * 1024 + 100000);
        assert.match(output, /large HTTPS request accepted/);
    } finally {
        if (server) await new Promise(resolve => server.close(resolve));
        await rm(temp, { recursive: true, force: true });
    }
});
test('network workers leave other threads sockets usable after shutdown', () => {
    const result = spawnSync(defaultRuntime, ['tests/lua/xnet_thread_lifecycle_test.lua',
        'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=ERROR'], {
        cwd: join(cwd, 'xnet2lua'), encoding: 'utf8', timeout: 10000, windowsHide: true });
    assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /PASS network survives 3 worker shutdowns/);
});
test('signed script and runtime updates preserve integrity and rollback', {
    skip: spawnSync('openssl', ['version'], { windowsHide: true }).status !== 0,
}, () => {
    const result = spawnSync(defaultRuntime, ['tests/lua/update_spec.lua', 'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=ERROR'],
        { cwd, encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /missing-runtime checks passed/);
});
for (const mode of ['native', 'lua']) {
    for (const script of ['codeoutline_spec', 'type_references_spec', 'external_headers_spec', 'stability_spec', 'lsp_spec', 'parse_pool_spec']) {
        test(`${script}: ${mode} scanner`, () => {
            const env = { ...process.env };
            if (mode === 'lua') env.XSCAN_PURE_LUA = '1'; else delete env.XSCAN_PURE_LUA;
            const result = spawnSync(defaultRuntime, [`tests/lua/${script}.lua`], { cwd, env, encoding: 'utf8', timeout: 60000, windowsHide: true });
            assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
            assert.match(result.stdout, /0 failed/);
        });
    }
}

test('Lua CLI locates resources from a Chinese install path and unrelated cwd', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-cli-'));
    const install = join(temp, '中文 安装');
    const project = join(temp, '项目 空格');
    try {
        await mkdir(install); await mkdir(project);
        await cp(join(cwd, 'scripts'), join(install, 'scripts'), { recursive: true });
        await writeFile(join(project, '文件.lua'), 'function unicode_cli() return "你好" end\n');
        const result = spawnSync(defaultRuntime, [join(install, 'scripts/codeoutline/cli.lua'), `ROOT=${project}`, 'Q=unicode_cli'],
            { cwd: temp, encoding: 'utf8', timeout: 10000, windowsHide: true });
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /你好/);
    } finally { await rm(temp, { recursive: true, force: true }); }
});
