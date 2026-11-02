'use strict';
const { openSync, closeSync } = require('node:fs');
const { isatty } = require('node:tty');

// npm pipes lifecycle stdio, but a terminal-launched installation may still
// have a controlling terminal. Reconnect only for global npm setup, never MCP.
module.exports = function installTerminal({ eligible, platform = process.platform, env = process.env,
    stdin = process.stdin, stdout = process.stdout, open = openSync, close = closeSync, isTTY = isatty } = {}) {
    const ci = env.CI && !['0', 'false'].includes(String(env.CI).toLowerCase());
    const fallback = { stdio: 'inherit', interactive: !ci && !!stdin.isTTY && !!stdout.isTTY, close() {} };
    if (!eligible || ci || fallback.interactive) return fallback;
    const descriptors = [];
    const release = () => {
        for (const fd of descriptors.splice(0)) { try { close(fd); } catch {} }
    };
    try {
        const input = open(platform === 'win32' ? '//./CONIN$' : '/dev/tty', 'r');
        descriptors.push(input);
        // GetConsoleMode/isatty needs read access to a Windows output handle.
        const output = open(platform === 'win32' ? '//./CONOUT$' : '/dev/tty', platform === 'win32' ? 'r+' : 'w');
        descriptors.push(output);
        if (!isTTY(input) || !isTTY(output)) { release(); return fallback; }
        return { stdio: [input, output, output], interactive: true, close: release };
    } catch { release(); return fallback; }
};
