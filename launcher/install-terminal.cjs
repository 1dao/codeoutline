'use strict';
// A controlling console handle does not establish ownership of terminal input.
// npm must hand off stdio with --foreground-scripts before we offer prompts.
module.exports = function installTerminal({ env = process.env,
    stdin = process.stdin, stdout = process.stdout } = {}) {
    const ci = env.CI && !['0', 'false'].includes(String(env.CI).toLowerCase());
    return { stdio: 'inherit', interactive: !ci && !!stdin.isTTY && !!stdout.isTTY, close() {} };
};
