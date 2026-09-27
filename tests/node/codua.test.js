import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LuaWorker, defaultRuntime, startHttp, configurePaths } from './helpers.js';

test('unmodified Codua MCP client and tool adapter over real HTTP', { skip: !process.env.CODEOUTLINE_CODUA_SCRIPTS, timeout: 20000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-codua-'));
    await writeFile(join(root, 'client.lua'), 'function before_edit() return 11 end\n');
    const worker = new LuaWorker();
    const endpoint = await startHttp(worker, await configurePaths({ project: root }), { port: 0 });
    try {
        const child = spawn(defaultRuntime, [fileURLToPath(new URL('../lua/codua_http.lua', import.meta.url))], {
            cwd: fileURLToPath(new URL('../../xnet2lua/', import.meta.url)),
            windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
            env: { ...process.env, CODEOUTLINE_TEST_PROJECT: root, CODEOUTLINE_TEST_URL: endpoint.url },
        });
        let output = '';
        child.stdout.on('data', (chunk) => { output += chunk; });
        child.stderr.on('data', (chunk) => { output += chunk; });
        const [code] = await once(child, 'exit');
        assert.equal(code, 0, output);
        assert.match(output, /CODUA_HTTP_OK/);
    } finally { await endpoint.close(); await worker.close(); await rm(root, { recursive: true, force: true }); }
});
