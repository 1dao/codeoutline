import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { ListRootsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { root, defaultRuntime } from './helpers.js';

async function freePort() {
    const probe = net.createServer();
    await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
    const { port } = probe.address();
    await new Promise((resolve) => probe.close(resolve));
    return port;
}

// PID listening on the port, or null.
function listener(port) {
    try {
        if (process.platform === 'win32') {
            const line = execFileSync('netstat', ['-ano', '-p', 'TCP'], { encoding: 'utf8' }).split('\n')
                .find((l) => /LISTENING/.test(l) && l.includes(`127.0.0.1:${port} `));
            return line ? Number(line.trim().split(/\s+/).pop()) : null;
        }
        return Number(execFileSync('lsof', ['-t', `-iTCP:${port}`, '-sTCP:LISTEN'], { encoding: 'utf8' }).trim().split('\n')[0]) || null;
    } catch { return null; }
}

function stop(pid) {
    if (!pid) return;
    try { process.kill(pid); } catch {}
}

async function waitFor(check, ms = 10000) {
    const end = Date.now() + ms;
    while (Date.now() < end) { const value = check(); if (value) return value; await new Promise((r) => setTimeout(r, 100)); }
    return check();
}

test('connect starts one shared HTTP service, forwards roots and survives its restart', { timeout: 90000 }, async () => {
    const home = await mkdtemp(join(tmpdir(), 'codeoutline-connect-'));
    const project = join(home, 'project');
    await mkdir(project);
    await writeFile(join(project, 'sample.lua'), 'function greet() return helper() end\nfunction helper() return 1 end\n');
    const port = await freePort();
    // The service writes its logs and index cache under this home; an
    // unreachable update server keeps it from updating and exiting mid-test.
    const env = { ...process.env, USERPROFILE: home, HOME: home, CODEOUTLINE_UPDATE_DIR: join(home, 'updates'),
        CODEOUTLINE_UPDATE_URL: 'https://127.0.0.1:1' };
    const connect = async () => {
        const transport = new StdioClientTransport({ command: defaultRuntime, env, cwd: tmpdir(), stderr: 'pipe',
            args: [join(root, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=WARN', 'connect', '--port', String(port)] });
        let logs = '';
        transport.stderr?.on('data', (chunk) => { logs += chunk; });
        const client = new Client({ name: 'connect-test', version: '1.0.0' }, { capabilities: { roots: {} } });
        client.setRequestHandler(ListRootsRequestSchema, async () => ({ roots: [{ uri: pathToFileURL(project).href, name: 'project' }] }));
        await client.connect(transport);
        return { client, logs: () => logs };
    };
    const explore = (c) => c.client.callTool({ name: 'codeoutline_explore', arguments: { query: 'greet' } });
    let service = null;
    const first = await connect();
    try {
        assert.equal((await first.client.listTools()).tools.length, 3);
        // No projectPath: the service asks the client for roots through the proxy.
        assert.match((await explore(first)).content[0].text, /calls: helper/, first.logs());
        service = await waitFor(() => listener(port));
        assert.ok(service, 'connect did not start the service');

        const second = await connect();
        try {
            assert.match((await explore(second)).content[0].text, /greet/);
            assert.equal(listener(port), service, 'a second session started another service');
        } finally { await second.client.close(); }

        // A restart (an installed update) costs the session; the proxy restores it.
        stop(service);
        await waitFor(() => !listener(port));
        assert.match((await explore(first)).content[0].text, /calls: helper/, first.logs());
        const restarted = await waitFor(() => listener(port));
        assert.ok(restarted && restarted !== service, 'service was not restarted');
        service = restarted;
    } finally {
        await first.client.close();
        stop(service ?? listener(port));
        await waitFor(() => !listener(port));
        await rm(home, { recursive: true, force: true }).catch(() => {});
    }
});
