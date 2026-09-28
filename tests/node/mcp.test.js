import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import http from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { LuaWorker, configurePaths, startHttp, main, defaultRuntime } from './helpers.js';

const client = () => new Client({ name: 'codeoutline-tests', version: '1.0.0' });
async function fixture() {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-test-'));
    const project = join(root, '中文 project');
    await mkdir(project);
    await writeFile(join(project, 'sample.lua'), 'function greet() return "你好世界" end\n');
    return { root, project, cleanup: () => rm(root, { recursive: true, force: true }) };
}

test('official SDK stdio: discovery, source, incremental refresh, rebuild and errors', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime, args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    let logs = '';
    transport.stderr?.on('data', (chunk) => { logs += chunk; });
    const c = client();
    try {
        await c.connect(transport);
        assert.equal((await c.listTools()).tools.length, 3);
        const query = (query) => c.callTool({ name: 'codeoutline_explore', arguments: { query } });
        assert.match((await query('greet')).content[0].text, /你好世界/);
        const status = JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text);
        assert.equal(status.files, 1);
        assert.equal(status.refresh.parsed, 0);
        await writeFile(join(f.project, 'sample.lua'), Buffer.concat([
            Buffer.from('function gbk()\n -- '), Buffer.from([0xd6, 0xd0, 0xce, 0xc4]),
            Buffer.from('\n return 42\nend\n'),
        ]));
        const decoded = await query('gbk');
        assert.notEqual(decoded.isError, true);
        assert.match(decoded.content[0].text, /2\t -- 中文/);
        await writeFile(join(f.project, 'sample.lua'), 'function changed() return 42 end\n');
        assert.match((await query('changed')).content[0].text, /return 42/);
        const rebuilt = JSON.parse((await c.callTool({ name: 'codeoutline_rebuild' })).content[0].text);
        assert.equal(rebuilt.refresh.parsed, 1);
        assert.equal(rebuilt.cacheLoaded, false);
        await assert.rejects(c.callTool({ name: 'missing' }), /Unknown tool/);
        await assert.rejects(c.callTool({ name: 'codeoutline_explore', arguments: { query: 'greet', budget: -1 } }), /budget/);
        const outside = await c.callTool({ name: 'codeoutline_status', arguments: { projectPath: f.root } });
        assert.equal(outside.isError, true);
        assert.match(outside.content[0].text, /outside allowed/);
        await rm(join(f.project, 'sample.lua'));
        assert.equal(JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text).files, 0);
        assert.match(logs, /loading main script/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK HTTP: sessions, concurrency, refresh, path aliases and perimeter', { timeout: 30000 }, async () => {
    const f = await fixture();
    const worker = new LuaWorker();
    const endpoint = await startHttp(worker, await configurePaths({ project: f.project }), { port: 0 });
    const c = client(), c2 = client();
    const transport = new StreamableHTTPClientTransport(new URL(endpoint.url));
    try {
        await c.connect(transport);
        await c2.connect(new StreamableHTTPClientTransport(new URL(endpoint.url)));
        assert.equal((await c.listTools()).tools.length, 3);
        const result = await Promise.all([c, c2].map((instance) => instance.callTool({ name: 'codeoutline_explore', arguments: { query: 'greet' } })));
        assert.ok(result.every((r) => /你好世界/.test(r.content[0].text)));
        const oldPid = endpoint.child.pid;
        await writeFile(join(f.project, 'sample.lua'), 'function changed_http() return 17 end\n');
        assert.match((await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'changed_http' } })).content[0].text, /return 17/);
        assert.equal(endpoint.child.pid, oldPid, 'queries reuse the same process');
        const alias = join(f.root, 'alias');
        await symlink(f.project, alias, process.platform === 'win32' ? 'junction' : 'dir');
        assert.equal((await c.callTool({ name: 'codeoutline_status', arguments: { projectPath: alias } })).isError, false);
        const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json',
            'mcp-session-id': transport.sessionId, 'mcp-protocol-version': '2025-06-18' };
        const rpc = (body, extra = {}) => fetch(endpoint.url, { method: 'POST', headers: { ...headers, ...extra }, body: JSON.stringify(body) });
        assert.equal((await rpc({ jsonrpc: '2.0', id: 40, method: 'ping' }, { origin: 'https://evil.example' })).status, 403);
        const badHostStatus = await new Promise((resolve, reject) => {
            const req = http.request(endpoint.url, { headers: { host: 'evil.example' } }, (res) => { res.resume(); resolve(res.statusCode); });
            req.on('error', reject); req.end();
        });
        assert.equal(badHostStatus, 403);
        assert.equal((await rpc({ jsonrpc: '2.0', id: 42, method: 'ping' }, { 'mcp-protocol-version': '2099-01-01' })).status, 400);
        assert.equal((await rpc([], {})).status, 400);
        assert.equal((await fetch(endpoint.url)).status, 405);
        assert.equal((await rpc({ jsonrpc: '2.0', id: 43, method: 'ping' }, { 'mcp-session-id': 'missing' })).status, 404);
        assert.equal((await fetch(endpoint.url, { method: 'POST', headers, body: '{' })).status, 400);
        assert.equal((await fetch(endpoint.url, { method: 'POST', headers, body: 'x'.repeat(1024 * 1024 + 1) })).status, 413);
        const bad = await rpc({ jsonrpc: '2.0', id: 44, method: 'tools/call', params: { name: 'bad' } });
        assert.equal((await bad.json()).error.code, -32602);
        await transport.terminateSession();
    } finally { await c.close(); await c2.close(); await endpoint.close(); await worker.close(); await f.cleanup(); }
});

test('remote bind requires auth and explicit allowed host', async () => {
    const w = new LuaWorker();
    const config = await configurePaths();
    await assert.rejects(startHttp(w, config, { host: '0.0.0.0', port: 0, token: '' }), /requires/);
    const endpoint = await startHttp(w, config, { host: '0.0.0.0', port: 0, token: 'test-token-123456789', allowedHosts: ['127.0.0.1'] });
    try {
        const url = `http://127.0.0.1:${endpoint.server.address().port}/mcp`;
        assert.equal((await fetch(url)).status, 401);
        assert.equal((await fetch(url, { headers: { authorization: 'Bearer test-token-123456789' } })).status, 405);
    } finally { await endpoint.close(); await w.close(); }
});

test('stdio emits only JSON messages and exits cleanly on EOF', { timeout: 10000 }, async () => {
    const child = spawn(defaultRuntime, [main, 'STDIO=1'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.stderr.resume();
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'raw-test', version: '1' },
    } }) + '\n');
    await once(child.stdout, 'data');
    const exited = once(child, 'exit');
    child.stdin.end();
    const [code] = await exited;
    assert.equal(code, 0);
    const messages = out.trim().split('\n').map(JSON.parse);
    assert.equal(messages[0].result.protocolVersion, '2025-06-18');
});

test('stdio rejects malformed JSON, missing initialization and partial EOF frames', { timeout: 10000 }, async () => {
    const child = spawn(defaultRuntime, [main, 'STDIO=1'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.resume();
    child.stdin.write('broken\n' + JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n');
    while (output.split('\n').filter(Boolean).length < 2) await once(child.stdout, 'data');
    const exited = once(child, 'exit');
    child.stdin.end('{');
    assert.equal((await exited)[0], 1);
    const messages = output.trim().split('\n').map(JSON.parse);
    assert.equal(messages[0].error.code, -32700);
    assert.equal(messages[1].error.code, -32600);
    assert.equal(messages[2].error.code, -32700);
});
