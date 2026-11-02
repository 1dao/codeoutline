import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, chmod, rm } from 'node:fs/promises';
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
        await writeFile(path, win ? `@echo off\r\necho %*>>"${log}"\r\nexit /b 0\r\n`
            : `#!/bin/sh\nprintf '%s\\n' "$@" >> '${log}'\n`);
        if (!win) await chmod(path, 0o755);
    }
    await writeFile(join(bin, win ? 'zed.exe' : 'zed'), '');
    const env = { ...process.env, PATH: bin, HOME: temp, USERPROFILE: temp, LOCALAPPDATA: temp,
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
    } finally { await rm(temp, { recursive: true, force: true }); }
});
