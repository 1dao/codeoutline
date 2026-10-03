import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { root, defaultRuntime } from './helpers.js';

async function freePort() {
    const probe = net.createServer();
    await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
    const { port } = probe.address();
    await new Promise((resolve) => probe.close(resolve));
    return port;
}

test('daemon: one background service per port, stopped by its stop file', { timeout: 60000 }, async () => {
    const home = await mkdtemp(join(tmpdir(), 'codeoutline-daemon-'));
    const project = join(home, 'project');
    await mkdir(project);
    await writeFile(join(project, 'sample.lua'), 'function greet() return helper() end\nfunction helper() return 1 end\n');
    const port = await freePort();
    // Logs, caches and the stop file live under this home; an unreachable
    // update server keeps the service from updating mid-test.
    const env = { ...process.env, USERPROFILE: home, HOME: home, CODEOUTLINE_UPDATE_DIR: join(home, 'updates'),
        CODEOUTLINE_UPDATE_URL: 'https://127.0.0.1:1' };
    const args = [join(root, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=WARN', 'daemon', '--port', String(port)];
    const first = spawn(defaultRuntime, args, { env, cwd: tmpdir(), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let logs = '';
    first.stdout.on('data', (chunk) => { logs += chunk; });
    first.stderr.on('data', (chunk) => { logs += chunk; });
    try {
        const deadline = Date.now() + 15000;
        while (!logs.includes('[codeoutline] listening') && first.exitCode === null && Date.now() < deadline) {
            await new Promise((r) => setTimeout(r, 100));
        }
        assert.match(logs, /listening/);

        // A second start finds the running service and leaves it alone; Windows
        // would otherwise let it bind the same port.
        const second = spawnSync(defaultRuntime, args, { env, cwd: tmpdir(), encoding: 'utf8', timeout: 15000, windowsHide: true });
        assert.equal(second.status, 0, second.stderr);
        assert.match(second.stdout, /already listens/);

        const client = new Client({ name: 'daemon-test', version: '1.0.0' });
        await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
        const result = await client.callTool({ name: 'codeoutline_explore', arguments: { projectPath: project, query: 'greet' } });
        assert.match(result.content[0].text, /calls: helper/);
        await client.close();

        const exited = once(first, 'exit');
        await writeFile(join(home, '.codeoutline', `service-${port}.stop`), 'stop\n');
        const [code] = await exited;
        assert.equal(code, 0, logs);
    } finally {
        if (first.exitCode === null) first.kill();
        await rm(home, { recursive: true, force: true }).catch(() => {});
    }
});
