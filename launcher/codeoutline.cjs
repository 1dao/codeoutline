#!/usr/bin/env node
// npm platform selection only. All commands and service logic live in Lua.
'use strict';
const { spawn } = require('node:child_process');
const { createRequire } = require('node:module');
const { join, dirname } = require('node:path');
const { readFileSync, existsSync } = require('node:fs');

try {
    const manifest = require('../package.json');
    const platform = `${process.platform}-${process.arch}`;
    const packageName = `codeoutline-${platform}`;
    if (!manifest.optionalDependencies?.[packageName]) {
        throw new Error(`Unsupported platform ${platform}. Use a native build; see README.md.`);
    }
    if (process.platform === 'linux' && !process.report.getReport().header.glibcVersionRuntime) {
        throw new Error('This Linux package requires glibc; musl is not supported. Use a native build.');
    }
    const resolve = createRequire(__filename);
    let packagePath;
    try { packagePath = resolve.resolve(`${packageName}/package.json`); }
    catch { throw new Error(`Missing ${packageName}@${manifest.version}. Install with optional dependencies enabled, or install that exact package alongside codeoutline.`); }
    const runtimeManifest = JSON.parse(readFileSync(packagePath, 'utf8'));
    if (runtimeManifest.version !== manifest.version) throw new Error(`Version mismatch: expected ${packageName}@${manifest.version}`);
    const root = dirname(packagePath);
    const executable = join(root, 'xnet2lua', 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet');
    if (!existsSync(executable)) throw new Error(`Runtime missing from ${packageName}; reinstall the package.`);
    const child = spawn(executable, [join(root, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', ...process.argv.slice(2)], {
        stdio: 'inherit', windowsHide: true,
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
