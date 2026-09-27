// Test harness only: every protocol and indexing operation runs in Lua/xnet.
import net from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

export const root = fileURLToPath(new URL('../../', import.meta.url));
export const main = join(root, 'scripts/codeoutline/main.lua');
export const defaultRuntime = join(root, 'xnet2lua/bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
export async function configurePaths({ project, allowedRoots = [] } = {}) {
    return { project, roots: await Promise.all((allowedRoots.length ? allowedRoots : [project || root]).map((r) => realpath(r))) };
}

export class LuaWorker {
    constructor() { this.queue = []; this.closed = false; }
    async connect(request) {
        this.transport = new StdioClientTransport({ command: defaultRuntime,
            args: [main, 'STDIO=1', ...request.allowedRoots.map((r) => `ALLOW_ROOT=${r}`)], cwd: tmpdir(), stderr: 'pipe' });
        this.logs = '';
        this.transport.stderr?.on('data', (data) => { this.logs += data; });
        this.client = new Client({ name: 'worker-test', version: '1' });
        await this.client.connect(this.transport);
        this.child = { pid: this.transport.pid };
    }
    async run(request, signal) {
        if (signal?.aborted) throw new Error('Request cancelled');
        if (this.closed) throw new Error('Worker closed');
        this.starting ||= this.connect(request);
        await this.starting;
        if (signal?.aborted) throw new Error('Request cancelled');
        const args = { projectPath: request.projectPath };
        if (request.method === 'explore') { args.query = request.query; if (request.budget !== undefined) args.budget = request.budget; }
        const result = await this.client.callTool({ name: `codeoutline_${request.method}`, arguments: args }, undefined, { signal });
        if (result.isError) throw new Error(result.content[0].text);
        return request.method === 'explore' ? { text: result.content[0].text } : JSON.parse(result.content[0].text);
    }
    async close() { this.closed = true; if (this.starting) await this.starting.catch(() => {}); await this.client?.close(); }
}

export async function startHttp(_unused, config, options = {}) {
    const portProbe = net.createServer();
    await new Promise((resolve) => portProbe.listen(0, '127.0.0.1', resolve));
    const port = portProbe.address().port;
    await new Promise((resolve) => portProbe.close(resolve));
    const host = options.host || '127.0.0.1';
    const args = [main, 'HTTP=1', `HOST=${host}`, `PORT=${port}`, 'LOG_STDERR=1',
        ...(config.project ? [`PROJECT=${config.project}`] : []),
        ...config.roots.map((r) => `ALLOW_ROOT=${r}`),
        ...(options.allowedHosts || []).map((h) => `ALLOW_HOST=${h}`),
        ...(options.allowedOrigins || []).map((o) => `ALLOW_ORIGIN=${o}`)];
    const child = spawn(defaultRuntime, args, { cwd: tmpdir(), windowsHide: true,
        env: { ...process.env, CODEOUTLINE_TOKEN: options.token || '' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let logs = '';
    child.stdout.resume();
    await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { child.kill(); reject(new Error(logs || 'Startup timed out')); }, 10000);
        child.stderr.on('data', (chunk) => {
            logs += chunk;
            if (logs.includes('[codeoutline] listening')) { clearTimeout(timer); resolve(); }
        });
        child.once('error', (err) => { clearTimeout(timer); reject(err); });
        child.once('exit', () => { clearTimeout(timer); reject(new Error(logs)); });
    });
    return { child, url: `http://127.0.0.1:${port}/mcp`, server: { address: () => ({ port }) },
        async close() { if (child.exitCode === null) { const exited = once(child, 'exit'); child.kill(); await exited; } },
        logs: () => logs };
}
