import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, chmod, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, defaultRuntime } from './helpers.js';

test('optional editor installation: detection, selection, offline assets and npm opt-out', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-editors-'));
    const win = process.platform === 'win32';
    const bin = join(temp, 'bin');
    const assets = join(temp, 'package 中文');
    const data = win ? join(temp, 'Zed') : process.platform === 'darwin'
        ? join(temp, 'Library/Application Support/Zed') : join(temp, 'zed');
    const log = join(temp, 'installed.txt');
    await mkdir(bin);
    await mkdir(join(assets, 'editors/zed'), { recursive: true });
    await writeFile(join(assets, 'editors/codeoutline.vsix'), 'fixture vsix');
    await writeFile(join(assets, 'editors/zed/extension.toml'), 'id = "codeoutline"\n');
    await writeFile(join(assets, 'editors/zed/extension.wasm'), 'fixture wasm');
    for (const name of ['code', 'cursor']) {
        const path = join(bin, name + (win ? '.cmd' : ''));
        const marker = join(temp, name + '.installed');
        await writeFile(path, win ? `@echo off\r\necho %*>>"${log}"\r\nif "%~1"=="--install-extension" echo installed>"${marker}"\r\nif "%~1"=="--uninstall-extension" del "${marker}"\r\nif "%~1"=="--list-extensions" if exist "${marker}" echo 1dao.codeoutline\r\nexit /b 0\r\n`
            : `#!/bin/sh\nprintf '%s\\n' "$@" >> '${log}'\ncase "$1" in\n--install-extension) touch '${marker}';;\n--uninstall-extension) rm -f '${marker}';;\n--list-extensions) if test -f '${marker}'; then echo 1dao.codeoutline; fi;;\nesac\nexit 0\n`);
        if (!win) await chmod(path, 0o755);
    }
    await writeFile(join(bin, win ? 'zed.exe' : 'zed'), '');
    const env = { ...process.env, PATH: bin, HOME: temp, USERPROFILE: temp, LOCALAPPDATA: temp,
        CODEX_HOME: join(temp, '.codex'), CLAUDE_CONFIG_DIR: join(temp, '.claude'),
        HERMES_HOME: join(temp, '.hermes'), COPILOT_HOME: join(temp, '.copilot'),
        APPDATA: join(temp, 'app'), XDG_CONFIG_HOME: join(temp, '.config'),
        XDG_DATA_HOME: temp, CODEOUTLINE_INITIAL: assets, CODEOUTLINE_INTERACTIVE: '0', CODEOUTLINE_EDITORS: '', CODEOUTLINE_AGENTS: 'none',
        CODEOUTLINE_AUTOSTART: '0', npm_config_global: 'true' };
    // uname is needed for Unix platform detection; retain only its system path.
    if (!win) env.PATH += ':/usr/bin:/bin';
    const run = (args, extra = {}, input) => spawnSync(defaultRuntime,
        [join(root, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', 'LOG_FILE=0', ...args],
        { cwd: temp, env: { ...env, ...extra }, encoding: 'utf8', input, timeout: 15000 });
    try {
        const listed = run(['editors', '--list']);
        assert.equal(listed.status, 0, listed.stderr);
        for (const name of ['vscode', 'cursor', 'zed']) assert.match(listed.stdout, new RegExp(`${name}: detected`));
        const skipped = run(['editors', '--editors=none']);
        assert.equal(skipped.status, 0, skipped.stderr);
        const unattended = run(['editors']);
        assert.equal(unattended.status, 0, unattended.stderr);
        assert.match(unattended.stdout, /run codeoutline editors/);
        const localInstall = run(['install', '--npm'], { CODEOUTLINE_EDITORS: 'all', npm_config_global: 'false' });
        assert.equal(localInstall.status, 0, localInstall.stderr);
        await assert.rejects(readFile(log));
        const invalid = run(['editors', '--editors=vscode,typo']);
        assert.notEqual(invalid.status, 0);
        await assert.rejects(readFile(log));
        const installed = run(['editors', '--editors=all']);
        assert.equal(installed.status, 0, installed.stderr);
        assert.match(await readFile(log, 'utf8'), /--install-extension/);
        assert.equal(await readFile(join(data, 'extensions/installed/codeoutline/extension.wasm'), 'utf8'), 'fixture wasm');
        const before = await readFile(log, 'utf8');
        const declined = run(['editors'], { CODEOUTLINE_EDITORS: 'none', CODEOUTLINE_INTERACTIVE: '1' }, '\n');
        assert.equal(declined.status, 0, declined.stderr);
        assert.equal(await readFile(log, 'utf8'), before);
        const prompt = run(['editors'], { CODEOUTLINE_EDITORS: '', CODEOUTLINE_INTERACTIVE: '1' }, 'n\ny\nn\n');
        assert.equal(prompt.status, 0, prompt.stderr);
        assert.match(prompt.stdout, /Detected editors/);
        const afterPrompt = await readFile(log, 'utf8');
        const eof = run(['editors'], { CODEOUTLINE_INTERACTIVE: '1' }, '');
        assert.equal(eof.status, 0, eof.stderr);
        assert.equal(await readFile(log, 'utf8'), afterPrompt);
        const npm = run(['install', '--npm'], { CODEOUTLINE_EDITORS: 'zed' });
        assert.equal(npm.status, 0, npm.stderr);
        assert.match(npm.stdout, /Installed CodeOutline for Zed/);
        await rm(join(assets, 'editors/zed/extension.wasm'));
        const missing = run(['editors', '--editors=zed']);
        assert.notEqual(missing.status, 0);
        assert.match(missing.stderr, /missing editor asset/);
        // Missing payload must not overwrite an existing installation.
        assert.equal(await readFile(join(data, 'extensions/installed/codeoutline/extension.toml'), 'utf8'), 'id = "codeoutline"\n');
        const bestEffort = run(['install', '--npm'], { CODEOUTLINE_EDITORS: 'zed' });
        assert.equal(bestEffort.status, 0, bestEffort.stderr);
        // Full cleanup runs with service/registry operations isolated from the host.
        const runner = join(temp, 'cleanup.lua');
        await writeFile(runner, `package.preload['codeoutline.daemon'] = function()
    return { PORT = 19876, unregister = function() io.write('TEST_UNREGISTER\\n'); return {} end,
        state_dir = function() return os.getenv('USERPROFILE') .. '/.codeoutline' end,
        stop = function(_, _, done) done(true) end }
end
return dofile(os.getenv('CO_TEST_COMMAND'))
`);
        const cleanup = (...args) => spawnSync(defaultRuntime, [runner, 'LOG_LEVEL=ERROR', 'LOG_FILE=0', 'uninstall', ...args],
            { cwd: temp, env: { ...env, CO_TEST_COMMAND: join(root, 'scripts/codeoutline/command.lua') }, encoding: 'utf8', timeout: 15000 });
        const config = win ? env.APPDATA : process.platform === 'darwin'
            ? join(temp, 'Library/Application Support') : env.XDG_CONFIG_HOME;
        const settings = [join(config, 'Code/User/settings.json'), join(config, 'Cursor/User/settings.json'),
            join(config, 'Cursor/User/profiles/work/settings.json')];
        const originalSettings = '\ufeff{\r\n  // keep this comment\r\n  "editor.fontSize": 15,\r\n'
            + '  "codeoutline.serverPath": "C:/source/old/bin/xnet.exe",\r\n'
            + '  "codeoutline.serverArguments": ["old.lua", "lsp"],\r\n'
            + '  "[lua][cpp]": {"codeoutline.enabled": false, "editor.tabSize": 4},\r\n'
            + '  "other": {"codeoutline.enabled": "keep nested data"},\r\n'
            + '  "codeoutline.features": {"definition": false},\r\n}\r\n';
        const expectedSettings = '\ufeff{\r\n  // keep this comment\r\n  "editor.fontSize": 15,\r\n'
            + '  \r\n  \r\n  "[lua][cpp]": { "editor.tabSize": 4},\r\n'
            + '  "other": {"codeoutline.enabled": "keep nested data"},\r\n  \r\n}\r\n';
        for (const path of settings) {
            await mkdir(join(path, '..'), { recursive: true });
            await writeFile(path, originalSettings);
        }
        const mcp = join(temp, '.cursor/mcp.json');
        await mkdir(join(temp, '.cursor'), { recursive: true });
        await writeFile(mcp, JSON.stringify({ keep: true, mcpServers: { other: { command: 'keep' }, codeoutline: { url: 'http://127.0.0.1:19876/mcp' } } }));
        await mkdir(join(data, 'extensions/work/codeoutline'), { recursive: true });
        await writeFile(join(data, 'extensions/work/codeoutline/runtime'), 'downloaded server');
        await writeFile(join(data, 'extensions/index.json'), JSON.stringify({ extensions: { codeoutline: {}, other: { keep: true } } }));
        await mkdir(join(temp, '.codeoutline/cache'), { recursive: true });
        await writeFile(join(temp, '.codeoutline/cache/test.idx'), 'cached index');
        await mkdir(join(temp, '.vscode/extensions/1dao.codeoutline-0.1.0'), { recursive: true });
        await writeFile(join(temp, '.vscode/extensions/1dao.codeoutline-0.1.0/package.json'), '{}');
        await mkdir(join(temp, '.vscode/extensions/other.extension-1.0.0'), { recursive: true });
        await writeFile(join(temp, '.vscode/extensions/other.extension-1.0.0/package.json'), '{"keep":true}');
        const serviceOnly = cleanup('--service-only');
        assert.equal(serviceOnly.status, 0, serviceOnly.stderr);
        for (const path of settings) assert.equal(await readFile(path, 'utf8'), originalSettings);
        assert(JSON.parse(await readFile(mcp, 'utf8')).mcpServers.codeoutline);
        assert.equal(await readFile(join(data, 'extensions/work/codeoutline/runtime'), 'utf8'), 'downloaded server');
        const removed = cleanup('--purge');
        assert.equal(removed.status, 0, removed.stdout + removed.stderr);
        assert.match(removed.stdout, /Cleanup completed/);
        for (const path of settings) assert.equal(await readFile(path, 'utf8'), expectedSettings);
        const remaining = JSON.parse(await readFile(mcp, 'utf8'));
        assert.equal(remaining.keep, true);
        assert.equal(remaining.mcpServers.codeoutline, undefined);
        assert.equal(remaining.mcpServers.other.command, 'keep');
        for (const file of [join(data, 'extensions/installed/codeoutline'), join(data, 'extensions/work/codeoutline'),
            join(temp, '.codeoutline'), join(temp, 'code.installed'), join(temp, 'cursor.installed')]) await assert.rejects(readFile(file));
        const registry = JSON.parse(await readFile(join(data, 'extensions/index.json'), 'utf8'));
        assert.equal(registry.extensions.codeoutline, undefined);
        assert.equal(registry.extensions.other.keep, true);
        await assert.rejects(readFile(join(temp, '.vscode/extensions/1dao.codeoutline-0.1.0/package.json')));
        assert.equal(JSON.parse(await readFile(join(temp, '.vscode/extensions/other.extension-1.0.0/package.json'), 'utf8')).keep, true);
        assert.match(await readFile(log, 'utf8'), /--uninstall-extension/);
        const repeated = cleanup('--purge');
        assert.equal(repeated.status, 0, repeated.stdout + repeated.stderr);
        for (const path of settings) assert.equal(await readFile(path, 'utf8'), expectedSettings);
        // Invalid JSONC remains intact, while other profiles still get cleaned.
        await writeFile(settings[0], '{ broken');
        await writeFile(settings[1], originalSettings);
        const brokenSettings = cleanup('--purge');
        assert.notEqual(brokenSettings.status, 0);
        assert.match(brokenSettings.stderr, /cannot clean .*settings.json/);
        assert.equal(await readFile(settings[0], 'utf8'), '{ broken');
        assert.equal(await readFile(settings[1], 'utf8'), expectedSettings);
        await writeFile(settings[0], '{}');
        // A broken agent profile is reported, peers are still cleaned, and
        // purge must not erase recovery data after an incomplete cleanup.
        await mkdir(join(temp, '.gemini'), { recursive: true });
        await writeFile(join(temp, '.gemini/settings.json'), '{ broken');
        await writeFile(mcp, JSON.stringify({ mcpServers: { codeoutline: { url: 'http://127.0.0.1:19876/mcp' } } }));
        await mkdir(join(temp, '.codeoutline/cache'), { recursive: true });
        await writeFile(join(temp, '.codeoutline/cache/keep.idx'), 'keep on failure');
        const partial = cleanup('--purge');
        assert.notEqual(partial.status, 0);
        assert.match(partial.stderr, /cannot remove gemini/);
        assert.doesNotMatch(partial.stdout, /Cleanup completed/);
        assert.equal(JSON.parse(await readFile(mcp, 'utf8')).mcpServers.codeoutline, undefined);
        assert.equal(await readFile(join(temp, '.codeoutline/cache/keep.idx'), 'utf8'), 'keep on failure');
        await writeFile(join(temp, '.gemini/settings.json'), '');
        const outside = join(temp, 'external-extension');
        await mkdir(outside);
        await writeFile(join(outside, 'keep.txt'), 'must not delete');
        await symlink(outside, join(data, 'extensions/work/codeoutline'), win ? 'junction' : 'dir');
        const linked = cleanup('--purge');
        assert.notEqual(linked.status, 0);
        assert.match(linked.stderr, /refusing to remove linked extension/);
        assert.equal(await readFile(join(outside, 'keep.txt'), 'utf8'), 'must not delete');
    } finally { await rm(temp, { recursive: true, force: true }); }
});
