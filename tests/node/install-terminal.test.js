import { test } from 'node:test';
import assert from 'node:assert/strict';
import installTerminal from '../../launcher/install-terminal.cjs';

test('npm setup reconnects only a real controlling terminal and closes duplicated descriptors', () => {
    for (const platform of ['win32', 'linux']) {
        const opened = [], closed = [];
        const options = { eligible: true, platform, env: {}, stdin: {}, stdout: {},
            open(path, mode) { opened.push([path, mode]); return opened.length + 2; },
            close(fd) { closed.push(fd); }, isTTY: () => true };
        const terminal = installTerminal(options);
        assert.equal(terminal.interactive, true);
        assert.deepEqual(terminal.stdio, [3, 4, 4]);
        assert.deepEqual(opened, platform === 'win32' ? [['//./CONIN$', 'r'], ['//./CONOUT$', 'r+']]
            : [['/dev/tty', 'r'], ['/dev/tty', 'w']]);
        terminal.close(); terminal.close();
        assert.deepEqual(closed, [3, 4]);
        for (const overrides of [{ eligible: false }, { env: { CI: 'true' } }, { stdin: { isTTY: true }, stdout: { isTTY: true } }]) {
            const before = opened.length;
            assert.equal(installTerminal({ ...options, ...overrides }).stdio, 'inherit');
            assert.equal(opened.length, before, 'MCP, CI and inherited terminals must not be reopened');
        }
        let attempt = 0;
        const failed = installTerminal({ ...options, open() { if (++attempt === 2) throw new Error('no console'); return 8; } });
        assert.equal(failed.interactive, false);
        assert.equal(closed.at(-1), 8, 'partial acquisition must close the input descriptor');
        const detached = installTerminal({ ...options, isTTY: () => false });
        assert.equal(detached.interactive, false);
        assert.equal(detached.stdio, 'inherit');
    }
});
