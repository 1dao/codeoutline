import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, defaultRuntime } from './helpers.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

test('unified Lua CLI: commands, JSON output, failures and MCP startup', async () => {
    const project = await mkdtemp(join(tmpdir(), 'codeoutline-cli-'));
    const command = join(root, 'scripts/codeoutline/command.lua');
    const run = (...args) => spawnSync(defaultRuntime, [command, 'LOG_STDERR=1', ...args], {
        cwd: project, encoding: 'utf8', timeout: 15000,
    });
    const success = (...args) => {
        const r = run(...args); assert.equal(r.status, 0, r.stderr); return r.stdout;
    };
    try {
        await writeFile(join(project, 'demo.lua'), 'function hello_world() return 7 end\n');
        assert.match(success('--help'), /codeoutline doctor/);
        assert.match(success('--version'), /^0\.1\.0-dev\.0\r?\n$/);
        assert.equal(JSON.parse(success('doctor')).ok, true);
        assert.equal(JSON.parse(success('status')).files, 1);
        assert.equal(JSON.parse(success('rebuild')).cacheLoaded, false);
        assert.match(success('explore', '--query=hello_world'), /return 7/);
        for (const args of [ ['wat'], ['status', '--port', '12'], ['explore'],
            ['explore', '--query'], ['explore', '--query=x', '--budget=nan'],
            ['serve'], ['serve', '--stdio', '--http'], ['serve', '--stdio=1'],
            ['status', '--project=.', '--project=.'], ['doctor', '--project=missing'] ]) {
            const r = run(...args); assert.notEqual(r.status, 0, args.join(' '));
        }
        const transport = new StdioClientTransport({ command: defaultRuntime,
            args: [command, 'LOG_STDERR=1', 'serve', '--stdio', '--project', project], stderr: 'pipe', cwd: tmpdir() });
        transport.stderr?.resume();
        const client = new Client({ name: 'cli-smoke', version: '1' });
        try {
            await client.connect(transport);
            const result = await client.callTool({ name: 'codeoutline_explore', arguments: { query: 'hello_world' } });
            assert.notEqual(result.isError, true);
            assert.match(result.content[0].text, /return 7/);
        } finally { await client.close(); }
    } finally { await rm(project, { recursive: true, force: true }); }
});
