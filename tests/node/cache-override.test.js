import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, defaultRuntime } from './helpers.js';

test('cache override persists and reloads an isolated index before API and default cache paths', async () => {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-cache-'));
    const project = join(temp, 'project'), home = join(temp, 'home');
    const override = join(temp, 'override', 'cache.idx'), explicit = join(temp, 'explicit.idx');
    const runner = join(temp, 'run.lua');
    await mkdir(project); await mkdir(home);
    await writeFile(join(project, 'demo.lua'), 'function cache_example() end\n');
    await writeFile(runner, `package.path = os.getenv('CO_TEST_ROOT') .. '/scripts/?.lua;' .. package.path
local idx = require('codeoutline.indexing.index').open(os.getenv('CO_TEST_PROJECT'), {
    cache_path = os.getenv('CO_TEST_EXPLICIT'), lister = 'walk' })
local loaded = idx.cache_loaded
idx:refresh(); assert(idx:save())
io.write(xutils.json_pack({ path = idx.cache_path, loaded = loaded }), '\\n')
return { __init = function() xthread.stop(0) end }
`);
    const run = (value, withExplicit = true) => {
        const env = { ...process.env, HOME: home, USERPROFILE: home, CO_TEST_ROOT: root.replaceAll('\\', '/'), CO_TEST_PROJECT: project };
        if (value === undefined) delete env.CODEOUTLINE_MEMORY_CACHE;
        else env.CODEOUTLINE_MEMORY_CACHE = value;
        if (withExplicit) env.CO_TEST_EXPLICIT = explicit;
        else delete env.CO_TEST_EXPLICIT;
        const r = spawnSync(defaultRuntime, [runner, 'LOG_FILE=0', 'LOG_LEVEL=ERROR'], { cwd: temp, env, encoding: 'utf8', timeout: 15000 });
        assert.equal(r.status, 0, r.stdout + r.stderr);
        return JSON.parse(r.stdout);
    };
    try {
        assert.equal(run(override).path, override.replaceAll('\\', '/'));
        assert(existsSync(override)); assert(!existsSync(explicit));
        assert.equal(run(override).loaded, true, 'second process loads the overridden cache');
        assert.equal(run('').path, explicit.replaceAll('\\', '/'));
        assert(existsSync(explicit));
        assert.equal(run(undefined).path, explicit.replaceAll('\\', '/'));
        const normal = run(undefined, false);
        assert.match(normal.path, /\/\.codeoutline\/cache\/[a-f0-9]{64}\.idx$/);
        assert(existsSync(normal.path));
    } finally { await rm(temp, { recursive: true, force: true }); }
});
