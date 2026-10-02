#!/usr/bin/env node
// npm platform selection only. All commands and service logic live in Lua.
'use strict';
const { spawn, spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');
const { join, dirname } = require('node:path');
const { readFileSync, existsSync } = require('node:fs');

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
    const env = { ...process.env, CODEOUTLINE_AUTO_UPDATE: process.env.CODEOUTLINE_AUTO_UPDATE ?? (process.argv[2] === 'serve' ? '1' : '0') };
    if (process.argv[2] !== 'update') {
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
    const child = spawn(executable, [join(root, 'scripts/codeoutline/command.lua'), ...logArgs, ...process.argv.slice(2)], {
        stdio: 'inherit', windowsHide: true, env,
    });
    const handlers = new Map();
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
        const handler = () => child.kill(signal);
        handlers.set(signal, handler);
        process.on(signal, handler);
    }
    child.once('error', (err) => { console.error(`codeoutline: ${err.message}`); process.exitCode = 1; });
    child.once('exit', (code, signal) => {
        for (const [name, handler] of handlers) process.removeListener(name, handler);
        if (signal && process.platform !== 'win32') process.kill(process.pid, signal);
        else process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1);
    });
} catch (err) {
    console.error(`codeoutline: ${err.message}`);
    process.exitCode = 1;
}
