#!/usr/bin/env node
// npm platform selection only. All commands and service logic live in Lua.
'use strict';
const { spawn, spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');
const { join, dirname } = require('node:path');
const { readFileSync, existsSync, realpathSync, mkdtempSync, unlinkSync, rmdirSync } = require('node:fs');
const { tmpdir } = require('node:os');
const installTerminal = require('./install-terminal.cjs');

try {
    const manifest = require('../package.json');
    const platform = `${process.platform}-${process.arch}`;
    // Platforms served by another package, which declares their CPU so npm
    // installs it: Windows 11 on ARM emulates x64; macOS ships one universal binary.
    const shared = { 'win32-arm64': 'win32-x64', 'darwin-arm64': 'darwin-universal', 'darwin-x64': 'darwin-universal' };
    // Scoped: npm's spam filter rejects new unscoped "<name>-<platform>" names.
    const packageFor = (target) => `@codua/codeoutline-${target}`;
    let packageName = packageFor(platform);
    if (!manifest.optionalDependencies?.[packageName] && shared[platform]) {
        packageName = packageFor(shared[platform]);
    }
    if (!manifest.optionalDependencies?.[packageName]) {
        throw new Error(`Unsupported platform ${platform}. Use a native build; see README.md.`);
    }
    if (process.platform === 'linux') {
        const glibc = process.report.getReport().header.glibcVersionRuntime;
        if (!glibc) throw new Error('This Linux package requires glibc; musl is not supported. Use a native build.');
        // Matches the manylinux_2_28 build in CI; older systems fail in the dynamic linker.
        const [major, minor] = glibc.split('.').map(Number);
        if (major < 2 || (major === 2 && minor < 28)) {
            throw new Error(`This Linux package requires glibc 2.28 or newer (found ${glibc}). Use a native build.`);
        }
    }
    const resolve = createRequire(__filename);
    let packagePath;
    try { packagePath = resolve.resolve(`${packageName}/package.json`); }
    catch { throw new Error(`Missing ${packageName}@${manifest.version}. Install with optional dependencies enabled, or install that exact package alongside codeoutline.`); }
    const runtimeManifest = JSON.parse(readFileSync(packagePath, 'utf8'));
    if (runtimeManifest.version !== manifest.version) throw new Error(`Version mismatch: expected ${packageName}@${manifest.version}`);
    let root = dirname(packagePath);
    let executable = join(root, 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
    if (!existsSync(executable)) throw new Error(`Runtime missing from ${packageName}; reinstall the package.`);
    // Quiet, file-free runtime logs unless asked for: clients start the MCP
    // server in the user's project, which must not gain a logs/ directory.
    const { CODEOUTLINE_LOG_LEVEL: level, CODEOUTLINE_LOG_DIR: logDir } = process.env;
    const logArgs = ['LOG_STDERR=1', `LOG_LEVEL=${level || 'WARN'}`, logDir ? `LOG_DIR=${logDir}` : 'LOG_FILE=0'];
    // Lua verifies installed versions. Recovery uses the npm-installed updater.
    // Selection reads installed versions only; serve updates in a background thread.
    // Services update themselves; CODEOUTLINE_INITIAL names this installation,
    // which install registers at login because updates are deleted when unused.
    const service = ['serve', 'daemon', 'install'].includes(process.argv[2]);
    const env = { ...process.env, CODEOUTLINE_AUTO_UPDATE: process.env.CODEOUTLINE_AUTO_UPDATE ?? (service ? '1' : '0'), CODEOUTLINE_INITIAL: root,
        // Runtime owns editor selection; the launcher supplies terminal state.
        CODEOUTLINE_INTERACTIVE: process.stdin.isTTY && process.stdout.isTTY ? '1' : '0' };
    // Cleanup must run from the initial installation so update data can be purged.
    if (!['update', 'uninstall', 'remove'].includes(process.argv[2])) {
        const selection = spawnSync(executable, [join(root, 'scripts/codeoutline/updater.lua'), ...logArgs, 'ACTION=select'], {
            stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8', windowsHide: true, timeout: 30000, env,
        });
        if (selection.stderr) process.stderr.write(selection.stderr);
        if (selection.status === 0) {
            const selected = selection.stdout.trim();
            if (selected && existsSync(join(selected, 'scripts/codeoutline/command.lua'))) {
                root = selected;
                executable = join(root, 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
            }
        }
    }
    const terminal = installTerminal();
    env.CODEOUTLINE_INTERACTIVE = terminal.interactive ? '1' : '0';
    // npm package lifecycle only: Lua still parses options and owns cleanup.
    // An acknowledgement file prevents --help or invalid arguments from ever
    // removing a package. Wait for runtime close before npm touches its binary.
    let removal;
    const npmCommand = (args) => process.platform === 'win32'
        ? [process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `npm ${args.join(' ')}`]] : ['npm', args];
    if (process.argv[2] === 'remove') {
        const directory = mkdtempSync(join(tmpdir(), 'codeoutline-remove-'));
        removal = { directory, ready: join(directory, 'ready') };
        env.CODEOUTLINE_REMOVE_READY = removal.ready;
        delete env.CODEOUTLINE_REMOVE_ERROR;
        try {
            const query = (args) => {
                const [command, commandArgs] = npmCommand(args);
                const result = spawnSync(command, commandArgs, { encoding: 'utf8', windowsHide: true });
                if (result.error || result.status !== 0) throw new Error('Cannot locate npm global installation');
                return result.stdout.trim();
            };
            const globalRoot = realpathSync(join(query(['root', '-g']), 'codeoutline'));
            const ownRoot = realpathSync(join(__dirname, '..'));
            const normalize = (path) => process.platform === 'win32' ? path.toLowerCase() : path;
            if (normalize(globalRoot) !== normalize(ownRoot)) throw new Error('remove requires this package to be installed globally; use uninstall --purge for local/native cleanup');
            removal.prefix = query(['prefix', '-g']);
        } catch (err) { env.CODEOUTLINE_REMOVE_ERROR = err.message; }
    }
    const releaseRemoval = () => {
        if (removal) {
            try { unlinkSync(removal.ready); } catch {}
            try { rmdirSync(removal.directory); } catch {}
        }
    };
    let child;
    try {
        child = spawn(executable, [join(root, 'scripts/codeoutline/command.lua'), ...logArgs, ...process.argv.slice(2)], {
            stdio: terminal.stdio, windowsHide: true, env,
        });
    } finally { terminal.close(); }
    const handlers = new Map();
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
        const handler = () => child.kill(signal);
        handlers.set(signal, handler);
        process.on(signal, handler);
    }
    child.once('error', (err) => { console.error(`codeoutline: ${err.message}`); process.exitCode = 1; });
    const finish = (code, signal) => {
        releaseRemoval();
        for (const [name, handler] of handlers) process.removeListener(name, handler);
        if (signal && process.platform !== 'win32') process.kill(process.pid, signal);
        else process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1);
    };
    child.once('close', (code, signal) => {
        if (code === 0 && !signal && removal?.prefix && existsSync(removal.ready)) {
            releaseRemoval();
            const [command, commandArgs] = npmCommand(['uninstall', '-g', 'codeoutline']);
            child = spawn(command, commandArgs, { stdio: 'inherit', windowsHide: true,
                cwd: tmpdir(), env: { ...process.env, npm_config_prefix: removal.prefix, CODEOUTLINE_REMOVE_CLEANED: '1' } });
            child.once('error', (err) => { console.error(`codeoutline: npm removal failed: ${err.message}`); });
            child.once('close', finish);
        } else finish(code, signal);
    });
} catch (err) {
    console.error(`codeoutline: ${err.message}`);
    process.exitCode = 1;
}
