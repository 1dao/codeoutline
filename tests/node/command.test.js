import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, defaultRuntime, version } from './helpers.js';
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
        assert.equal(success('--version').trim(), version);
        assert.equal(JSON.parse(success('doctor')).ok, true);
        assert.equal(JSON.parse(success('status')).files, 1);
        assert.equal(JSON.parse(success('rebuild')).cacheLoaded, false);
        assert.match(success('explore', '--query=hello_world'), /return 7/);
        assert.match(success('explore', '--query=lang:lua path:"demo.lua" hello_world'), /return 7/);
        assert.match(success('explore', '--query=lang:python hello_world'), /No symbols matched/);
        await writeFile(join(project, 'caller.lua'), 'function invoke() hello_world() end\n');
        assert.match(success('callers', '--query=hello_world', '--depth=2'), /Depth 1: invoke/);
        assert.match(success('affected', '--file=demo.lua', '--file=caller.lua'), /Changed 2 indexed file/);
        assert.match(success('affected', '--file=demo.lua'), /Depth 1: invoke/);
        await writeFile(join(project, 'changes.txt'), 'demo.lua\r\nmissing.lua\r\n');
        assert.match(success('affected', '--files-from=changes.txt'), /Unresolved file.*missing.lua/);
        const piped = spawnSync(defaultRuntime, [command, 'LOG_STDERR=1', 'affected', '--files-from=-'], {
            cwd: project, encoding: 'utf8', timeout: 15000, input: 'demo.lua\n',
        });
        assert.equal(piped.status, 0, piped.stderr); assert.match(piped.stdout, /Depth 1: invoke/);
        await writeFile(join(project, '中文 source.lua'), 'function unicode_impact() end\n');
        const unicode = spawnSync(defaultRuntime, [command, 'LOG_STDERR=1', 'affected', '--files-from=-'], {
            cwd: project, encoding: 'utf8', timeout: 15000, input: '\uFEFF中文 source.lua\r\n',
        });
        assert.equal(unicode.status, 0, unicode.stderr); assert.match(unicode.stdout, /Changed: 中文 source.lua/);
        assert.notEqual(run('affected').status, 0);
        assert.notEqual(run('affected', '--file=../demo.lua').status, 0);
        assert.notEqual(run('affected', '--file=demo.lua', '--depth=0').status, 0);
        assert.notEqual(run('callers', '--query=hello_world', '--depth=0').status, 0);
        assert.notEqual(run('callers', '--query=hello_world', '--max-nodes=bad').status, 0);
        await writeFile(join(project, 'types.ts'), 'interface Root {} class Child implements Root {}\n');
        assert.match(success('type-hierarchy', '--query=Root', '--direction=descendants'), /Descendant depth 1: Child/);
        assert.notEqual(run('type-hierarchy', '--query=Root', '--direction=invalid').status, 0);
        assert.notEqual(run('type-hierarchy', '--query=Root', '--depth=33').status, 0);
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

test('CLI search ranking reads project directories without hiding exact file queries', async () => {
    const project = await mkdtemp(join(tmpdir(), 'codeoutline-ranking-cli-'));
    const command = join(root, 'scripts/codeoutline/command.lua');
    const run = (...args) => spawnSync(defaultRuntime, [command, 'LOG_STDERR=1', ...args], {
        cwd: project, encoding: 'utf8', timeout: 15000, windowsHide: true,
    });
    const query = (text) => { const r = run('explore', `--query=${text}`); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    try {
        await mkdir(join(project, 'generated'));
        for (let i = 1; i <= 3; i++) await writeFile(join(project, 'generated', `${i}.lua`), `function ranked_save() return ${i} end\n`);
        await writeFile(join(project, 'z_app.lua'), 'function ranked_save() return 99 end\n');
        assert.doesNotMatch(query('ranked_save'), /## z_app.lua/);
        await writeFile(join(project, '.codeoutline.json'), JSON.stringify({ deprioritize: ['generated/'] }));
        const ranked = query('ranked_save');
        assert.match(ranked, /## z_app.lua/);
        assert.ok(ranked.indexOf('## z_app.lua') < ranked.indexOf('## generated/'));
        assert.match(query('generated/1.lua'), /## generated\/1.lua \(outline\)/);
        assert.match(query('generated/1.lua'), /ranked_save/);
        await writeFile(join(project, '.codeoutline.json'), '{"deprioritize":[]}');
        assert.doesNotMatch(query('ranked_save'), /## z_app.lua/);
        await writeFile(join(project, '.codeoutline.json'), '{"deprioritize":["**/generated/**"]}');
        const invalid = run('explore', '--query=ranked_save');
        assert.notEqual(invalid.status, 0); assert.match(invalid.stderr, /deprioritize/);
    } finally { await rm(project, { recursive: true, force: true }); }
});
