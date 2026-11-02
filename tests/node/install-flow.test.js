import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, defaultRuntime } from './helpers.js';

test('npm setup confirms each AI tool and editor, defaults to install, and starts the service', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-install-flow-'));
    const bin = join(temp, 'bin'), initial = join(temp, 'package');
    const runner = join(temp, 'run.lua'), cliLog = join(temp, 'editor.log');
    const win = process.platform === 'win32';
    for (const dir of [bin, join(initial, 'editors/zed'), join(initial, 'scripts/codeoutline'),
        join(temp, 'claude'), join(temp, 'codex'), join(temp, '.cursor')]) await mkdir(dir, { recursive: true });
    await writeFile(join(initial, 'scripts/codeoutline/command.lua'), '-- fixture installation marker\n');
    await writeFile(join(initial, 'editors/codeoutline.vsix'), 'fixture vsix');
    await writeFile(join(initial, 'editors/zed/extension.toml'), 'id = "codeoutline"\n');
    await writeFile(join(initial, 'editors/zed/extension.wasm'), 'fixture wasm');
    for (const name of ['code', 'cursor']) {
        const path = join(bin, name + (win ? '.cmd' : ''));
        await writeFile(path, win ? `@echo off\r\necho ${name}>>"${cliLog}"\r\nexit /b 0\r\n`
            : `#!/bin/sh\nprintf '${name}\\n' >> '${cliLog}'\n`);
        if (!win) await chmod(path, 0o755);
    }
    await writeFile(join(bin, win ? 'zed.exe' : 'zed'), '');
    // Exercise the real CLI lifecycle while replacing login/service operations
    // so the test never registers a task or starts a background service.
    await writeFile(runner, `package.preload['codeoutline.daemon'] = function()
    return { PORT = 19876, register = function() return 'test-login-entry' end,
        stop = function(_, _, done) done(true) end,
        spawn = function() io.write('TEST_SERVICE_STARTED\\n'); return true end,
        wait = function(_, _, done) done(true) end }
end
return dofile(os.getenv('CO_TEST_COMMAND'))
`);
    const env = { ...process.env, PATH: bin + (win ? '' : ':/usr/bin:/bin'), HOME: temp, USERPROFILE: temp,
        APPDATA: join(temp, 'app'), LOCALAPPDATA: join(temp, 'local'), XDG_CONFIG_HOME: join(temp, 'xdg'), XDG_DATA_HOME: temp,
        CODEX_HOME: join(temp, 'codex'), CLAUDE_CONFIG_DIR: join(temp, 'claude'), HERMES_HOME: join(temp, 'hermes'),
        COPILOT_HOME: join(temp, 'copilot'), CODEOUTLINE_INITIAL: initial, CODEOUTLINE_INTERACTIVE: '1',
        CODEOUTLINE_AGENTS: '', CODEOUTLINE_EDITORS: '', CODEOUTLINE_AUTOSTART: '1', npm_config_global: 'true',
        CO_TEST_COMMAND: join(root, 'scripts/codeoutline/command.lua') };
    const run = (input, extra = {}) => spawnSync(defaultRuntime, [runner, 'LOG_FILE=0', 'LOG_LEVEL=ERROR', 'install', '--npm'],
        { cwd: temp, env: { ...env, ...extra }, input, encoding: 'utf8', timeout: 15000 });
    try {
        const automatic = run('', { CODEOUTLINE_INTERACTIVE: '0' });
        assert.equal(automatic.status, 0, automatic.stdout + automatic.stderr);
        assert.match(automatic.stdout, /installing detected integrations by default/);
        assert.doesNotMatch(automatic.stdout, /\[Y\/n\]/);
        assert.match(automatic.stdout, /Claude Code: configured/);
        assert.match(automatic.stdout, /Installed CodeOutline for VS Code/);
        assert.match(automatic.stdout, /Installed CodeOutline for Cursor/);
        assert.match(automatic.stdout, /Installed CodeOutline for Zed/);
        assert.match(automatic.stdout, /TEST_SERVICE_STARTED/);
        const result = run('\n'.repeat(6));
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /Claude Code \(claude\)\? \[Y\/n\]/);
        assert.match(result.stdout, /Codex \(codex\)\? \[Y\/n\]/);
        for (const id of ['vscode', 'cursor', 'zed']) assert(result.stdout.includes(`(${id})? [Y/n]`));
        assert(result.stdout.indexOf('Step 1/2') < result.stdout.indexOf('Step 2/2'));
        assert(result.stdout.indexOf('Step 2/2') < result.stdout.indexOf('TEST_SERVICE_STARTED'));
        assert.match(result.stdout, /No additional codeoutline install command is needed/);
        assert.equal(JSON.parse(await readFile(join(temp, 'claude/.claude.json'), 'utf8')).mcpServers.codeoutline.url, 'http://127.0.0.1:19876/mcp');
        assert.equal(JSON.parse(await readFile(join(temp, '.cursor/mcp.json'), 'utf8')).mcpServers.codeoutline.url, 'http://127.0.0.1:19876/mcp');
        assert.match(await readFile(join(temp, 'codex/config.toml'), 'utf8'), /mcp_servers.codeoutline/);
        const calls = await readFile(cliLog, 'utf8');
        assert.match(calls, /code/); assert.match(calls, /cursor/);
        const zedData = win ? join(temp, 'local/Zed') : process.platform === 'darwin'
            ? join(temp, 'Library/Application Support/Zed') : join(temp, 'zed');
        assert.equal(await readFile(join(zedData, 'extensions/installed/codeoutline/extension.wasm'), 'utf8'), 'fixture wasm');
        const declined = run('n\nno\n'.repeat(3));
        assert.equal(declined.status, 0, declined.stderr);
        assert.equal(await readFile(cliLog, 'utf8'), calls, 'declining must not reinstall extensions');
        const selective = run('n\ny\nn\nn\ny\nn\n');
        assert.equal(selective.status, 0, selective.stderr);
        assert.doesNotMatch(selective.stdout, /Claude Code: (configured|unchanged)/);
        assert.doesNotMatch(selective.stdout, /Codex: (configured|unchanged)/);
        assert.match(selective.stdout, /Cursor Agent: unchanged/);
        assert.equal((await readFile(cliLog, 'utf8')).slice(calls.length).trim(), 'cursor');
        const repeated = run(' YES \n Y \n'.repeat(3));
        assert.equal(repeated.status, 0, repeated.stderr);
        assert.match(repeated.stdout, /Codex: unchanged/);
        const beforeEof = await readFile(cliLog, 'utf8');
        const optedOut = run('', { CODEOUTLINE_INTERACTIVE: '0', CODEOUTLINE_AGENTS: 'none', CODEOUTLINE_EDITORS: 'none' });
        assert.equal(optedOut.status, 0, optedOut.stderr);
        assert.doesNotMatch(optedOut.stdout, /Claude Code:|Installed CodeOutline for/);
        assert.equal(await readFile(cliLog, 'utf8'), beforeEof);
        const limited = run('', { CODEOUTLINE_INTERACTIVE: '0', CODEOUTLINE_AGENTS: 'cursor', CODEOUTLINE_EDITORS: 'cursor' });
        assert.equal(limited.status, 0, limited.stderr);
        assert.match(limited.stdout, /Cursor Agent: unchanged/);
        assert.doesNotMatch(limited.stdout, /Claude Code:|Codex:|Installed CodeOutline for (Zed|VS Code)/);
        const beforeEnd = await readFile(cliLog, 'utf8');
        const ended = run('');
        assert.equal(ended.status, 0, ended.stderr);
        assert.match(ended.stdout, /Setup complete/);
        assert.equal(await readFile(cliLog, 'utf8'), beforeEnd, 'EOF skips remaining editors instead of accepting their defaults');
        const invalid = run('maybe\nn\n' + 'n\n'.repeat(5));
        assert.equal(invalid.status, 0, invalid.stderr);
        assert.match(invalid.stdout, /Please enter y or n/);
    } finally { await rm(temp, { recursive: true, force: true }); }
});
