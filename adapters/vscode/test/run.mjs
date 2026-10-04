// Run the packaged VSIX in an isolated profile of VS Code or Cursor.
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { downloadAndUnzipVSCode } from '@vscode/test-electron';

const adapter = fileURLToPath(new URL('../', import.meta.url));
const repo = resolve(adapter, '../..');
const temp = await mkdtemp(join(tmpdir(), 'codeoutline-editor-中文 '));
try {
    const unpack = join(temp, 'package');
    await mkdir(unpack);
    // Python is a development-only zip extractor, never part of the extension.
    execFileSync(process.env.PYTHON || 'python', ['-c',
        'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
        join(adapter, 'codeoutline.vsix'), unpack]);
    const first = join(temp, 'first'), second = join(temp, 'second');
    await mkdir(first); await mkdir(second);
    await writeFile(join(first, 'send.lua'), "function sender()\n  xthread.post(MAIN_ID, 'done', false)\n  return helper()\nend\nfunction helper() return 1 end\n");
    await writeFile(join(first, 'completion.lua'), 'local obj = { width = 1 }\nobj.\n');
    await writeFile(join(first, 'receive.lua'), "xthread.register('done', function() end)\n");
    await writeFile(join(second, 'other.lua'), 'function other_root() end\n');
    await writeFile(join(first, '.codeoutline.json'), JSON.stringify({ definitionRules: [
        { call: 'xthread.post', argument: 2, target: 'xthread.register', targetArgument: 1 }
    ] }));
    const workspace = join(temp, 'smoke.code-workspace');
    await writeFile(workspace, JSON.stringify({ folders: [{ path: first }, { path: second }], settings: {
        'codeoutline.serverPath': join(repo, 'bin', process.platform === 'win32' ? 'xnet.exe' : 'xnet'),
        'codeoutline.serverArguments': [join(repo, 'scripts/codeoutline/command.lua'), 'LOG_STDERR=1', 'LOG_FILE=0', 'lsp', '--stdio'],
        'codeoutline.mode': 'navigation', 'codeoutline.languages': ['lua']
    } }));
    const executable = process.env.CODEOUTLINE_EDITOR_PATH || await downloadAndUnzipVSCode();
    const env = { ...process.env, CODEOUTLINE_AUTO_UPDATE: '0' };
    delete env.ELECTRON_RUN_AS_NODE;
    // Direct spawn preserves spaces/Unicode in paths on Windows too.
    const child = spawn(executable, [workspace, '--user-data-dir=' + join(temp, 'profile'),
            '--extensions-dir=' + join(temp, 'extensions'), '--disable-workspace-trust',
            '--extensionDevelopmentPath=' + join(unpack, 'extension'),
            '--extensionTestsPath=' + join(adapter, 'out/smoke.js'),
            '--skip-welcome', '--skip-release-notes', '--disable-updates', '--disable-gpu', '--no-sandbox'],
        { env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let passed = false;
    for (const stream of [child.stdout, child.stderr]) stream.on('data', data => {
        process.stdout.write(data);
        if (data.toString().includes('CODEOUTLINE_EDITOR_SMOKE_PASS:')) passed = true;
    });
    await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            if (process.platform === 'win32') execFileSync('taskkill', ['/PID', String(child.pid), '/T', '/F']);
            else child.kill();
            reject(new Error('Editor smoke test timed out'));
        }, 90000);
        child.on('error', error => { clearTimeout(timer); reject(error); });
        child.on('exit', code => {
            clearTimeout(timer);
            if (code === 0 && passed) resolve();
            else reject(new Error('Editor smoke test failed: exit ' + code));
        });
    });
} finally {
    await rm(temp, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
}
