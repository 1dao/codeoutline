import { test } from 'node:test';
import assert from 'node:assert/strict';
import installTerminal from '../../launcher/install-terminal.cjs';

test('piped npm setup never reopens the console or enables unreadable prompts', () => {
    for (const platform of ['win32', 'linux']) {
        for (const [stdin, stdout] of [[{}, {}], [{}, { isTTY: true }], [{ isTTY: true }, {}]]) {
            const terminal = installTerminal({ eligible: true, platform, env: {}, stdin, stdout,
                open() { assert.fail('background setup must not reopen the controlling terminal'); }, isTTY: () => true });
            assert.equal(terminal.interactive, false);
            assert.equal(terminal.stdio, 'inherit');
            terminal.close();
        }
    }
});

test('only inherited terminal input and output enable prompts outside CI', () => {
    for (const [env, expected] of [[{}, true], [{ CI: 'true' }, false], [{ CI: '1' }, false],
        [{ CI: 'false' }, true], [{ CI: '0' }, true]]) {
        const terminal = installTerminal({ env, stdin: { isTTY: true }, stdout: { isTTY: true } });
        assert.equal(terminal.interactive, expected);
        assert.equal(terminal.stdio, 'inherit');
    }
});
