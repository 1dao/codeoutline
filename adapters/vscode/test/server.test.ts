import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { Host, missingServerHint, resolveServer } from '../src/server';

const args = ['lsp', '--stdio'];
const editor = 'C:\\Programs\\Code\\Code.exe';
function windows(files: string[], env: NodeJS.ProcessEnv): Host {
    const present = new Set(files.map(file => file.toLowerCase()));
    return { platform: 'win32', env, execPath: editor, exists: file => present.has(file.toLowerCase()) };
}
const npm = 'C:\\Users\\me\\AppData\\Roaming\\npm';
const launcher = npm + '\\node_modules\\codeoutline\\launcher\\codeoutline.cjs';

test('runs the command as configured outside Windows', () => {
    const host: Host = { platform: 'linux', env: { PATH: '/usr/bin' }, execPath: '/usr/bin/code', exists: () => true };
    assert.deepEqual(resolveServer('codeoutline', args, host), { command: 'codeoutline', args });
});

test('leaves a configured runtime path untouched on Windows', () => {
    const host = windows([npm + '\\codeoutline.cmd', launcher], { PATH: npm });
    const xnet = 'C:\\src\\codeoutline\\bin\\xnet.exe';
    assert.deepEqual(resolveServer(xnet, ['command.lua', 'lsp', '--stdio'], host),
        { command: xnet, args: ['command.lua', 'lsp', '--stdio'] });
});

test('runs the npm launcher with node.exe found on PATH', () => {
    const node = 'C:\\Program Files\\nodejs\\node.exe';
    const host = windows([npm + '\\codeoutline.cmd', launcher, node], { PATH: `"C:\\Program Files\\nodejs";${npm}\\` });
    assert.deepEqual(resolveServer('codeoutline', args, host), { command: node, args: [launcher, ...args] });
});

test('prefers node.exe beside the npm shim, as the shim does', () => {
    const prefix = 'D:\\tools\\npm';
    const local = prefix + '\\node_modules\\codeoutline\\launcher\\codeoutline.cjs';
    const host = windows([prefix + '\\codeoutline.cmd', local, prefix + '\\node.exe', 'C:\\nodejs\\node.exe'],
        { Path: `C:\\nodejs;${prefix}` });
    assert.deepEqual(resolveServer('codeoutline', args, host), { command: prefix + '\\node.exe', args: [local, ...args] });
});

test('finds the default npm prefix when the editor PATH lacks it', () => {
    const host = windows([npm + '\\codeoutline.cmd', launcher, 'C:\\nodejs\\node.exe'],
        { PATH: 'C:\\nodejs', APPDATA: 'C:\\Users\\me\\AppData\\Roaming' });
    assert.deepEqual(resolveServer('codeoutline', args, host), { command: 'C:\\nodejs\\node.exe', args: [launcher, ...args] });
});

test("falls back to the editor's runtime in Node mode without node.exe", () => {
    const host = windows([npm + '\\codeoutline.cmd', launcher], { PATH: npm });
    assert.deepEqual(resolveServer('codeoutline', args, host),
        { command: editor, args: [launcher, ...args], env: { ELECTRON_RUN_AS_NODE: '1' } });
});

test('ignores a shim without the npm package and reports the missing server', () => {
    const host = windows(['C:\\native\\codeoutline.cmd', 'C:\\nodejs\\node.exe'], { PATH: 'C:\\native;C:\\nodejs' });
    const launch = resolveServer('codeoutline', args, host);
    assert.deepEqual(launch, { command: 'codeoutline', args });
    assert.match(missingServerHint(launch, host) ?? '', /npm install -g codeoutline/);
    assert.equal(missingServerHint({ command: 'codeoutline', args }, { platform: 'darwin' }), undefined);
});
