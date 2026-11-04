import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { root, defaultRuntime } from './helpers.js';

test('agent installer merges all profiles, keeps unrelated settings, backs up and removes only its entry', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-agents-中文 '));
    const paths = {
        claude: join(temp, 'claude/.claude.json'), cursor: join(temp, '.cursor/mcp.json'),
        codex: join(temp, 'codex/config.toml'), gemini: join(temp, '.gemini/settings.json'),
        opencode: join(temp, 'xdg/opencode/opencode.jsonc'), hermes: join(temp, 'hermes/config.yaml'),
        kiro: join(temp, '.kiro/settings/mcp.json'), antigravity: join(temp, '.gemini/config/mcp_config.json'),
        'copilot-vscode': process.platform === 'win32' ? join(temp, 'app/Code/User/mcp.json')
            : process.platform === 'darwin' ? join(temp, 'Library/Application Support/Code/User/mcp.json') : join(temp, 'xdg/Code/User/mcp.json'),
        'copilot-cli': join(temp, 'copilot/mcp-config.json'),
        'copilot-jetbrains': process.platform === 'win32' ? join(temp, 'local/github-copilot/intellij/mcp.json') : join(temp, 'xdg/github-copilot/intellij/mcp.json'),
    };
    const original = {};
    for (const [id, path] of Object.entries(paths)) {
        await mkdir(dirname(path), { recursive: true });
        original[id] = id === 'codex' ? '# keep TOML\nmodel = "demo"\nprompt = """\n[mcp_servers.codeoutline]\nnot a real table\n"""\n[mcp_servers.other]\nurl = "https://example.test/mcp"\n'
            : id === 'hermes' ? '# keep YAML\nmodel: demo\nmcp_servers:\n  other:\n    url: "https://example.test/mcp"\nsettings:\n  keep: true\n'
            : id === 'opencode' ? '{\n // keep JSONC\n "mcp": {"servers": {"other": {"type": "remote", "url": "https://example.test/mcp"},}},\n "keep": [1, true, null],\n}\n'
            : '{\n  "keep": [1,true,null],\n  "mcpServers": {"other": {"command":"other"}},\n  "servers": {"other": {"command":"other"}}\n}\n';
        await writeFile(path, original[id]);
    }
    const env = { ...process.env, USERPROFILE: temp, HOME: temp, XDG_CONFIG_HOME: join(temp, 'xdg'),
        CODEX_HOME: join(temp, 'codex'), CLAUDE_CONFIG_DIR: join(temp, 'claude'), HERMES_HOME: join(temp, 'hermes'),
        COPILOT_HOME: join(temp, 'copilot'), APPDATA: join(temp, 'app'), LOCALAPPDATA: join(temp, 'local'),
        CODEOUTLINE_AGENTS: '', CODEOUTLINE_EDITORS: 'none', CODEOUTLINE_INTERACTIVE: '0',
        CODEOUTLINE_AUTOSTART: '0', npm_config_global: 'true' };
    const run = (args, extra = {}, input) => spawnSync(defaultRuntime,
        [join(root, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', 'LOG_LEVEL=ERROR', 'LOG_FILE=0', ...args],
        { cwd: temp, env: { ...env, ...extra }, input, encoding: 'utf8', timeout: 15000 });
    const success = (args, extra, input) => { const r = run(args, extra, input); assert.equal(r.status, 0, r.stderr); return r.stdout; };
    try {
        assert.match(success(['agents', '--list']), /codex: detected/);
        assert.match(success(['agents', '--print', 'cursor']), /mcpServers/);
        assert.match(success(['install', '--print-config=codex']), /mcp_servers.codeoutline/);
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), original[id]);
        // Explicit opt-out leaves profiles untouched even in background npm setup.
        success(['install', '--npm'], { CODEOUTLINE_AGENTS: 'none' });
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), original[id]);
        success(['agents', '--yes', '--port=21987']);
        const installed = {};
        for (const [id, path] of Object.entries(paths)) {
            installed[id] = await readFile(path, 'utf8');
            assert.match(installed[id], /127\.0\.0\.1:21987\/mcp/);
            assert.equal(await readFile(path + '.codeoutline.bak', 'utf8'), original[id]);
            if (id !== 'hermes' && id !== 'codex') assert.match(installed[id], /"other"/);
        }
        assert.match(installed.opencode, /keep JSONC/);
        assert.match(installed.codex, /not a real table/);
        assert.match(installed.hermes, /settings:\n  keep: true/);
        assert.equal(JSON.parse(installed.gemini).mcpServers.codeoutline.httpUrl, 'http://127.0.0.1:21987/mcp');
        assert.equal(JSON.parse(installed.antigravity).mcpServers.codeoutline.serverUrl, 'http://127.0.0.1:21987/mcp');
        assert.equal(JSON.parse(installed['copilot-vscode']).servers.codeoutline.type, 'http');
        success(['agents', '--yes', '--port=21987']);
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), installed[id]);
        const conflict = run(['agents', '--target=cursor,codex', '--port=21988']);
        assert.notEqual(conflict.status, 0); assert.match(conflict.stderr, /--force/);
        assert.equal(await readFile(paths.cursor, 'utf8'), installed.cursor);
        success(['agents', '--target=cursor,codex', '--port=21988', '--force']);
        assert.match(await readFile(paths.codex, 'utf8'), /21988/);
        success(['agents', '--yes', '--remove']);
        for (const [id, path] of Object.entries(paths)) {
            const raw = await readFile(path, 'utf8');
            assert.doesNotMatch(raw, /127\.0\.0\.1/);
            if (id === 'codex') assert.equal(raw, original.codex + '\n');
            if (id === 'hermes') assert.match(raw, /other:\n    url: "https:\/\/example.test\/mcp"/);
            if (id !== 'hermes' && id !== 'codex' && id !== 'opencode') assert.deepEqual(JSON.parse(raw), JSON.parse(original[id]));
        }
        // Invalid input is checked for every selected agent before writing any.
        await writeFile(paths.gemini, '{ broken');
        const before = await readFile(paths.cursor, 'utf8');
        const invalid = run(['agents', '--target=cursor,gemini']);
        assert.notEqual(invalid.status, 0);
        assert.equal(await readFile(paths.cursor, 'utf8'), before);
        await writeFile(paths.gemini, original.gemini);
        const project = join(temp, 'project');
        await mkdir(project);
        success(['agents', '--target=cursor', '--location=local', '--project', project]);
        assert.match(await readFile(join(project, '.cursor/mcp.json'), 'utf8'), /19876/);
        assert.equal(await readFile(paths.cursor, 'utf8'), before);
        // Explicit global npm selections work independently of daemon autostart.
        success(['install', '--npm'], { CODEOUTLINE_AGENTS: 'claude' });
        assert.match(await readFile(paths.claude, 'utf8'), /19876/);
        success(['agents', '--target=claude', '--remove']);
        success(['agents'], { CODEOUTLINE_INTERACTIVE: '1' }, 'y\n' + 'n\n'.repeat(10));
        assert.match(await readFile(paths.claude, 'utf8'), /19876/);
        success(['agents', '--remove'], { CODEOUTLINE_INTERACTIVE: '1' }, '\n'.repeat(11));
        assert.match(await readFile(paths.claude, 'utf8'), /19876/, 'interactive removal must default to no');
        assert.notEqual(run(['agents', '--target=typo']).status, 0);
        assert.notEqual(run(['agents', '--location=typo']).status, 0);
        assert.notEqual(run(['agents', '--port=99999']).status, 0);
        // Existing empty files are valid starting points, just like missing files.
        for (const path of Object.values(paths)) await writeFile(path, '');
        success(['agents', '--yes']);
        const fromEmpty = {};
        for (const [id, path] of Object.entries(paths)) {
            fromEmpty[id] = await readFile(path, 'utf8');
            assert.match(fromEmpty[id], /127\.0\.0\.1:19876\/mcp/);
        }
        success(['agents', '--yes']);
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), fromEmpty[id]);
        // Read failures must still reject the complete plan without editing peers.
        await rm(paths.gemini);
        await mkdir(paths.gemini);
        const unreadable = run(['agents', '--target=cursor,gemini', '--port=21989', '--force']);
        assert.notEqual(unreadable.status, 0);
        assert.match(unreadable.stderr, /cannot read config/);
        assert(unreadable.stderr.includes(paths.gemini.replaceAll('\\', '/')));
        assert.equal(await readFile(paths.cursor, 'utf8'), fromEmpty.cursor);
    } finally { await rm(temp, { recursive: true, force: true }); }
});

test('agent instructions archive CodeGraph blocks and restore them only while its CLI exists', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-instructions-'));
    const bin = join(temp, 'bin'), project = join(temp, 'project');
    const win = process.platform === 'win32';
    const graphCli = join(bin, win ? 'codegraph.cmd' : 'codegraph');
    const paths = { claude: join(temp, 'claude/CLAUDE.md'), codex: join(temp, 'codex/AGENTS.md'),
        gemini: join(temp, '.gemini/GEMINI.md'), opencode: join(temp, 'xdg/opencode/AGENTS.md') };
    const blocks = {}, originals = {};
    for (const dir of [bin, project, ...Object.values(paths).map(dirname)]) await mkdir(dir, { recursive: true });
    await writeFile(graphCli, 'fixture command marker');
    for (const [id, path] of Object.entries(paths)) {
        const eol = id === 'codex' ? '\r\n' : '\n';
        blocks[id] = ['<!-- CODEGRAPH_START -->', '## CodeGraph', 'Use codegraph first.', '<!-- CODEGRAPH_END -->'].join(eol);
        originals[id] = (id === 'codex' ? '\ufeff' : '') + `User rules${eol}${blocks[id]}${eol}Keep these rules.${eol}`;
        await writeFile(path, originals[id]);
    }
    const env = { ...process.env, USERPROFILE: temp, HOME: temp, CODEX_HOME: join(temp, 'codex'),
        CLAUDE_CONFIG_DIR: join(temp, 'claude'), XDG_CONFIG_HOME: join(temp, 'xdg'),
        APPDATA: join(temp, 'app'), LOCALAPPDATA: join(temp, 'local'),
        HERMES_HOME: join(temp, 'hermes'), COPILOT_HOME: join(temp, 'copilot'),
        CODEOUTLINE_AGENTS: '', PATH: bin + (win ? '' : ':/usr/bin:/bin') };
    const run = (...args) => spawnSync(defaultRuntime, [join(root, 'scripts/codeoutline/command.lua'),
        'LOG_LEVEL=ERROR', 'LOG_FILE=0', 'agents', ...args], { cwd: project, env, encoding: 'utf8', timeout: 15000 });
    const success = (...args) => { const r = run(...args); assert.equal(r.status, 0, r.stdout + r.stderr); return r; };
    const targets = '--target=claude,codex,gemini,opencode';
    try {
        success(targets);
        const installed = {};
        for (const [id, path] of Object.entries(paths)) {
            installed[id] = await readFile(path, 'utf8');
            assert.doesNotMatch(installed[id], /CODEGRAPH_START/);
            assert.match(installed[id], /CODEOUTLINE_START/);
            assert.match(installed[id], /codeoutline_explore/);
            assert.match(installed[id], /Keep these rules/);
            assert.equal(await readFile(join(dirname(path), 'codegraph.md'), 'utf8'), blocks[id]);
        }
        success(targets);
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), installed[id]);
        success(targets, '--remove');
        for (const [id, path] of Object.entries(paths)) assert.equal(await readFile(path, 'utf8'), originals[id]);
        success(targets);
        await rm(graphCli);
        success(targets, '--remove');
        for (const [id, path] of Object.entries(paths)) {
            assert.equal(await readFile(path, 'utf8'), originals[id].replace(blocks[id], ''));
            assert.equal(await readFile(join(dirname(path), 'codegraph.md'), 'utf8'), blocks[id]);
        }
        // Unknown backup content must not be overwritten, even with --force.
        await writeFile(paths.codex, originals.codex);
        const backup = join(dirname(paths.codex), 'codegraph.md');
        await writeFile(backup, 'User-owned Markdown file');
        const mcp = join(temp, 'codex/config.toml');
        const beforeMcp = await readFile(mcp, 'utf8');
        const conflict = run('--target=codex', '--port=21990', '--force');
        assert.notEqual(conflict.status, 0);
        assert.match(conflict.stderr, /backup conflict/);
        assert.equal(await readFile(backup, 'utf8'), 'User-owned Markdown file');
        assert.equal(await readFile(paths.codex, 'utf8'), originals.codex);
        assert.equal(await readFile(mcp, 'utf8'), beforeMcp);
        await writeFile(backup, blocks.codex);
        await writeFile(paths.codex, '<!-- CODEGRAPH_START --> incomplete');
        const malformed = run('--target=codex');
        assert.notEqual(malformed.status, 0); assert.match(malformed.stderr, /incomplete CODEGRAPH/);
        assert.equal(await readFile(mcp, 'utf8'), beforeMcp);
        // Project-local Codex and OpenCode share AGENTS.md, and Gemini shares
        // its directory. Identical backups must serve both without collisions.
        await writeFile(graphCli, 'fixture command marker');
        const sharedBlock = blocks.gemini;
        for (const name of ['AGENTS.md', 'GEMINI.md']) await writeFile(join(project, name), `Before\n${sharedBlock}\nAfter\n`);
        success('--target=codex,opencode,gemini', '--location=local');
        assert.equal(await readFile(join(project, 'codegraph.md'), 'utf8'), sharedBlock);
        success('--target=codex,opencode,gemini', '--location=local', '--remove');
        for (const name of ['AGENTS.md', 'GEMINI.md']) assert.equal(await readFile(join(project, name), 'utf8'), `Before\n${sharedBlock}\nAfter\n`);
        // A shared backup belongs only to files that originally supplied a
        // CodeGraph block, including after repeated setup or stale backups.
        await writeFile(join(project, 'GEMINI.md'), 'Gemini user rules\n');
        success('--target=codex,opencode,gemini', '--location=local');
        success('--target=codex,opencode,gemini', '--location=local');
        success('--target=codex,opencode,gemini', '--location=local', '--remove');
        assert.equal(await readFile(join(project, 'AGENTS.md'), 'utf8'), `Before\n${sharedBlock}\nAfter\n`);
        assert.doesNotMatch(await readFile(join(project, 'GEMINI.md'), 'utf8'), /CODEGRAPH|CODEOUTLINE/);
        assert.match(await readFile(join(project, 'GEMINI.md'), 'utf8'), /^Gemini user rules\n/);
        await writeFile(join(project, 'AGENTS.md'), 'Codex user rules\n');
        success('--target=codex', '--location=local');
        success('--target=codex', '--location=local', '--remove');
        assert.doesNotMatch(await readFile(join(project, 'AGENTS.md'), 'utf8'), /CODEGRAPH|CODEOUTLINE/);
    } finally { await rm(temp, { recursive: true, force: true }); }
});

test('config edits preserve JSONC strings/comments and TOML/YAML section boundaries', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-agent-config-'));
    const input = join(temp, 'cases.json'), runner = join(temp, 'run.lua');
    const url = 'http://127.0.0.1:19876/mcp';
    const cases = [
        ['json', '{"mcpServers":{"codeoutline":{"url":"old"},"other":{"url":"https://host/a//b"}}}', ['mcpServers', 'codeoutline'], {}, true, false],
        ['json', '{"mcpServers":{"other":{"url":"https://host/a//b"}, /* keep */ "codeoutline":{"url":"old"}}}', ['mcpServers', 'codeoutline'], {}, true, false],
        ['json', '\ufeff{\r\n// keep\r\n"mcpServers":{},"quoted":"a\\\"b"\r\n}', ['mcpServers', 'codeoutline'], { url }, false, false],
        ['json', '{"mcpServers":null}', ['mcpServers', 'codeoutline'], { url }, false, false],
        ['json', '{"a":1,"a":2}', ['mcpServers', 'codeoutline'], { url }, false, false],
        ['toml', `[mcp_servers.codeoutline]\nurl = "old"\n[[other]]\nkeep = true\n`, url, true, false],
        ['toml', `["mcp_servers.codeoutline"]\nkeep = true\n`, url, false, false],
        ['toml', `[mcp_servers."codeoutline"]\nurl = "old"\n[mcp_servers.other]\nkeep = true\n`, url, true, false],
        ['yaml', 'model: demo\nmcp_servers: {} # keep\nnext: true\n', url, false, false],
        ['yaml', 'mcp_servers:\n  codeoutline:\n    url: old\n  other:\n    url: keep\nnext: true\n', url, true, false],
        ['yaml', 'mcp_servers: {other: {url: keep}}\n', url, false, false],
    ];
    await writeFile(input, JSON.stringify(cases));
    await writeFile(runner, `package.path = os.getenv('CO_TEST_ROOT') .. '/scripts/?.lua;' .. package.path
local config = require('codeoutline.agent_config')
local f = assert(io.open(os.getenv('CO_TEST_INPUT'), 'rb'))
local cases = xutils.json_unpack(f:read('a')); f:close()
local out = {}
for _, case in ipairs(cases) do
    local fn = table.remove(case, 1)
    local ok, result = pcall(config[fn], unpack(case))
    out[#out + 1] = { ok = ok, result = tostring(result) }
end
io.write(xutils.json_pack(out), '\\n')
return { __init = function() xthread.stop(0) end }
`);
    try {
        const r = spawnSync(defaultRuntime, [runner, 'LOG_LEVEL=ERROR', 'LOG_FILE=0'], {
            env: { ...process.env, CO_TEST_ROOT: root.replaceAll('\\', '/'), CO_TEST_INPUT: input }, encoding: 'utf8', timeout: 15000,
        });
        assert.equal(r.status, 0, r.stderr);
        const result = JSON.parse(r.stdout);
        assert.deepEqual(JSON.parse(result[0].result), { mcpServers: { other: { url: 'https://host/a//b' } } });
        assert.match(result[1].result, /\/\* keep \*\//);
        assert.doesNotMatch(result[1].result, /codeoutline/);
        assert.equal(JSON.parse(result[2].result.replace(/^\ufeff/, '').replace('// keep', '')).mcpServers.codeoutline.url, url);
        assert.equal(result[3].ok, false); assert.equal(result[4].ok, false);
        assert.equal(result[5].result, '[[other]]\nkeep = true\n');
        assert.match(result[6].result, /^\["mcp_servers.codeoutline"\]\nkeep = true/);
        assert.match(result[6].result, /\n\[mcp_servers.codeoutline\]/);
        assert.equal(result[7].result, '[mcp_servers.other]\nkeep = true\n');
        assert.match(result[8].result, /mcp_servers: # keep\n  codeoutline:/);
        assert.match(result[8].result, /next: true/);
        assert.equal(result[9].result, 'mcp_servers:\n  other:\n    url: keep\nnext: true\n');
        assert.equal(result[10].ok, false);
    } finally { await rm(temp, { recursive: true, force: true }); }
});
