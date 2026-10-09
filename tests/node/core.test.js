import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtemp, cp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { defaultRuntime } from './helpers.js';

const cwd = fileURLToPath(new URL('../../', import.meta.url));
test('signed script and runtime updates preserve integrity and rollback', {
    skip: spawnSync('openssl', ['version'], { windowsHide: true }).status !== 0,
}, () => {
    const result = spawnSync(defaultRuntime, ['tests/lua/update_spec.lua', 'LOG_STDERR=1', 'LOG_FILE=0', 'LOG_LEVEL=ERROR'],
        { cwd, encoding: 'utf8', timeout: 60000, windowsHide: true });
    assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /missing-runtime checks passed/);
});
for (const mode of ['native', 'lua']) {
    for (const script of ['codeoutline_spec', 'stability_spec', 'lsp_spec', 'parse_pool_spec']) {
        test(`${script}: ${mode} scanner`, () => {
            const env = { ...process.env };
            if (mode === 'lua') env.XSCAN_PURE_LUA = '1'; else delete env.XSCAN_PURE_LUA;
            const result = spawnSync(defaultRuntime, [`tests/lua/${script}.lua`], { cwd, env, encoding: 'utf8', timeout: 60000, windowsHide: true });
            assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
            assert.match(result.stdout, /0 failed/);
        });
    }
}

test('Lua CLI locates resources from a Chinese install path and unrelated cwd', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-cli-'));
    const install = join(temp, '中文 安装');
    const project = join(temp, '项目 空格');
    try {
        await mkdir(install); await mkdir(project);
        await cp(join(cwd, 'scripts'), join(install, 'scripts'), { recursive: true });
        await writeFile(join(project, '文件.lua'), 'function unicode_cli() return "你好" end\n');
        const result = spawnSync(defaultRuntime, [join(install, 'scripts/codeoutline/cli.lua'), `ROOT=${project}`, 'Q=unicode_cli'],
            { cwd: temp, encoding: 'utf8', timeout: 10000, windowsHide: true });
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /你好/);
    } finally { await rm(temp, { recursive: true, force: true }); }
});
