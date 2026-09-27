import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { LuaWorker, configurePaths, startHttp } from './helpers.js';

test('independent processes publish one intact shared cache and reuse it', { timeout: 20000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-concurrent-'));
    await writeFile(join(root, 'main.lua'), 'function concurrent_cache() return 9 end\n');
    const a = new LuaWorker(), b = new LuaWorker(), reader = new LuaWorker();
    let cache;
    try {
        const request = { method: 'rebuild', projectPath: root, allowedRoots: [root] };
        const results = await Promise.all([a.run(request), b.run(request)]);
        cache = results[0].cachePath;
        assert.equal(results[0].cachePath, results[1].cachePath);
        assert.ok(results.every((r) => r.refresh.cache_saved === true));
        assert.ok((await readFile(cache)).length > 0);
        const restored = await reader.run({ ...request, method: 'status' });
        assert.equal(restored.cacheLoaded, true);
        assert.equal(restored.refresh.parsed, 0);
        assert.equal(restored.symbols, 1);
    } finally {
        await Promise.all([a.close(), b.close(), reader.close()]);
        if (cache) await rm(cache, { force: true });
        await rm(root, { recursive: true, force: true });
    }
});

test('HTTP cancellation interrupts real indexing and keeps the Lua service responsive', { timeout: 30000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-cancel-'));
    const small = join(root, 'small'), large = join(root, 'large');
    await mkdir(small); await mkdir(large);
    await writeFile(join(small, 'small.lua'), 'function small() return 1 end\n');
    const source = Array.from({ length: 16000 }, (_, i) => `function fn_${i}() return ${i} end\n`).join('');
    for (let i = 0; i < 12; i++) await writeFile(join(large, `${i}.lua`), source);
    const worker = new LuaWorker();
    const endpoint = await startHttp(worker, await configurePaths({ project: small, allowedRoots: [root] }), { port: 0 });
    const client = new Client({ name: 'cancel-test', version: '1' });
    try {
        await client.connect(new StreamableHTTPClientTransport(new URL(endpoint.url)));
        await client.callTool({ name: 'codeoutline_status' });
        const pid = endpoint.child.pid;
        const controller = new AbortController();
        let complete = false, progress = 0;
        const running = client.callTool({ name: 'codeoutline_rebuild', arguments: { projectPath: large } }, undefined,
            { signal: controller.signal, onprogress: () => { progress++; } });
        running.then(() => { complete = true; }, () => { complete = true; });
        const rejected = assert.rejects(running, /cancel|abort/i);
        await delay(1250);
        assert.equal(complete, false, 'real indexing is still running');
        assert.ok(progress > 0, 'HTTP SSE progress arrived while indexing');
        const t0 = Date.now();
        await client.ping();
        assert.ok(Date.now() - t0 < 1000, 'ping is not blocked by Lua parsing');
        controller.abort(new Error('test cancelled'));
        await rejected;
        const next = await client.callTool({ name: 'codeoutline_status' });
        assert.equal(next.isError, false);
        assert.equal(JSON.parse(next.content[0].text).files, 1);
        assert.equal(endpoint.child.pid, pid, 'cancellation does not restart the native service');
    } finally { await client.close(); await endpoint.close(); await worker.close(); await rm(root, { recursive: true, force: true }); }
});

test('cancelling a queued request leaves the active request and worker intact', { timeout: 10000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-queue-'));
    await writeFile(join(root, 'file.lua'), 'function queued() end\n');
    const worker = new LuaWorker();
    const req = { method: 'status', projectPath: root, allowedRoots: [root] };
    try {
        const first = worker.run(req);
        const abort = new AbortController();
        const second = worker.run(req, abort.signal);
        abort.abort();
        await assert.rejects(second, /cancelled/);
        assert.equal((await first).files, 1);
        const pid = worker.child.pid;
        assert.equal((await worker.run(req)).files, 1);
        assert.equal(worker.child.pid, pid);
    } finally { await worker.close(); await rm(root, { recursive: true, force: true }); }
});

test('cancellation during startup closes the process and allows another request', { timeout: 10000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-startup-'));
    const worker = new LuaWorker();
    const request = { method: 'status', projectPath: root, allowedRoots: [root] };
    try {
        const abort = new AbortController();
        const pending = worker.run(request, abort.signal);
        abort.abort();
        await assert.rejects(pending, /cancelled/);
        assert.equal((await worker.run(request)).files, 0);
    } finally { await worker.close(); await rm(root, { recursive: true, force: true }); }
});
