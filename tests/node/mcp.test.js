import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { ListRootsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { LuaWorker, configurePaths, startHttp, main, defaultRuntime } from './helpers.js';

const client = () => new Client({ name: 'codeoutline-tests', version: '1.0.0' });
async function fixture() {
    const root = await mkdtemp(join(tmpdir(), 'codeoutline-test-'));
    const project = join(root, '中文 project');
    await mkdir(project);
    await writeFile(join(project, 'sample.lua'), 'function greet() return "你好世界" end\n');
    return { root, project, cleanup: () => rm(root, { recursive: true, force: true }) };
}

test('official SDK stdio: discovery, source, incremental refresh, rebuild and errors', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime, args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    let logs = '';
    transport.stderr?.on('data', (chunk) => { logs += chunk; });
    const c = client();
    try {
        await c.connect(transport);
        assert.equal((await c.listTools()).tools.length, 6);
        const query = (query) => c.callTool({ name: 'codeoutline_explore', arguments: { query } });
        const greeting = await query('greet');
        assert.match(greeting.content[0].text, /你好世界/);
        assert.equal(greeting.structuredContent.state, 'ok');
        assert.equal(greeting.structuredContent.operation, 'codeoutline_explore');
        assert.equal(greeting.structuredContent.coverage.scope, 'indexed_static_analysis');
        assert.equal(greeting.structuredContent.resolution.unresolved_sites, 0);
        assert.deepEqual(greeting.structuredContent.coverage.reasons, []);
        assert.equal(typeof greeting.structuredContent.generation, 'number');
        assert.equal(greeting.content.length, 1);
        assert.match((await query('lang:lua path:sample.lua greet')).content[0].text, /你好世界/);
        assert.match((await query('lang:python greet')).content[0].text, /No symbols matched/);
        await assert.rejects(query('lang:unknown greet'), /unsupported query language/);
        await writeFile(join(f.project, 'caller.lua'), 'function caller() greet() end\nfunction upper() caller() end\n');
        const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'greet', depth: 2 } });
        assert.notEqual(callers.isError, true);
        assert.match(callers.content[0].text, /Depth 2: upper/);
        const filteredCallers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'path:sample.lua lang:lua greet', depth: 2 } });
        assert.match(filteredCallers.content[0].text, /Depth 2: upper/);
        const affected = await c.callTool({ name: 'codeoutline_affected', arguments: { files: ['sample.lua'], depth: 2 } });
        assert.notEqual(affected.isError, true);
        assert.match(affected.content[0].text, /Depth 2: upper/);
        const batch = await c.callTool({ name: 'codeoutline_affected', arguments: { files: ['sample.lua', 'caller.lua', 'missing.lua'] } });
        assert.match(batch.content[0].text, /Changed 2 indexed file/);
        assert.match(batch.content[0].text, /Unresolved file.*missing.lua/);
        assert.equal(batch.structuredContent.state, 'partial');
        assert.ok(batch.structuredContent.coverage.reasons.includes('unresolved_files'));
        await assert.rejects(c.callTool({ name: 'codeoutline_affected', arguments: { files: [] } }), /files/);
        await assert.rejects(c.callTool({ name: 'codeoutline_affected', arguments: { files: ['../outside.lua'] } }), /inside the project/);
        await assert.rejects(c.callTool({ name: 'codeoutline_callers', arguments: { query: 'greet', depth: 0 } }), /depth/);
        await rm(join(f.project, 'caller.lua'));
        const status = JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text);
        assert.equal(status.files, 1);
        assert.equal(status.refresh.parsed, 0);
        await writeFile(join(f.project, 'sample.lua'), Buffer.concat([
            Buffer.from('function gbk()\n -- '), Buffer.from([0xd6, 0xd0, 0xce, 0xc4]),
            Buffer.from('\n return 42\nend\n'),
        ]));
        const decoded = await query('gbk');
        assert.notEqual(decoded.isError, true);
        assert.match(decoded.content[0].text, /2\t -- 中文/);
        await writeFile(join(f.project, 'sample.lua'), 'function changed() return 42 end\n');
        assert.match((await query('changed')).content[0].text, /return 42/);
        const rebuilt = JSON.parse((await c.callTool({ name: 'codeoutline_rebuild' })).content[0].text);
        assert.equal(rebuilt.refresh.parsed, 1);
        assert.equal(rebuilt.cacheLoaded, false);
        await assert.rejects(c.callTool({ name: 'missing' }), /Unknown tool/);
        await assert.rejects(c.callTool({ name: 'codeoutline_explore', arguments: { query: 'greet', budget: -1 } }), /budget/);
        const outside = await c.callTool({ name: 'codeoutline_status', arguments: { projectPath: f.root } });
        assert.equal(outside.isError, true);
        assert.match(outside.content[0].text, /outside allowed/);
        await rm(join(f.project, 'sample.lua'));
        assert.equal(JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text).files, 0);
        assert.match(logs, /loading main script/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK reports unsupported event syntax separately from output truncation', { timeout: 30000 }, async () => {
    const f = await fixture();
    await writeFile(join(f.project, 'bus.ts'), "import { EventEmitter } from 'events'; export const bus = new EventEmitter();\n");
    await writeFile(join(f.project, 'sub.ts'), "import { bus } from './bus'; bus.on('saved', () => {});\n");
    await writeFile(join(f.project, 'pub.ts'), "import { bus } from './bus'; export function publish() { bus.emit('saved'); }\n");
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    try {
        await c.connect(transport);
        const result = await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'publish' } });
        assert.notEqual(result.isError, true);
        assert.equal(result.structuredContent.state, 'partial');
        assert.equal(result.structuredContent.coverage.output_truncated, false);
        assert.ok(result.structuredContent.coverage.reasons.includes('shared_events.unsupported_syntax'));
        assert.doesNotMatch(result.content[0].text, /Results truncated|expansion limit reached/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK reports unresolved calls and excludes unrelated private Lua targets', { timeout: 30000 }, async () => {
    const f = await fixture();
    await writeFile(join(f.project, 'private.lua'), 'local function hidden_target() end\n');
    await writeFile(join(f.project, 'use.lua'), 'function unknown_entry() hidden_target() end\n');
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    try {
        await c.connect(transport);
        const result = await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'unknown_entry' } });
        assert.equal(result.structuredContent.state, 'partial');
        assert.equal(result.structuredContent.resolution.unresolved_sites, 1);
        assert.ok(result.structuredContent.coverage.reasons.includes('unresolved_calls'));
        assert.doesNotMatch(result.content[0].text, /calls: hidden_target/);
        const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'hidden_target' } });
        assert.match(callers.content[0].text, /0 potential callers/);
        await writeFile(join(f.project, 'use.lua'), 'local function leaf() end\nlocal handlers = { go = leaf }\n'
            + 'function unknown_entry(key) handlers[key]() end\n');
        const dynamic = await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'unknown_entry' } });
        assert.equal(dynamic.structuredContent.state, 'partial');
        assert.equal(dynamic.structuredContent.resolution.unresolved_sites, 1);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK explores unknown suffixes on demand without persisting their records', { timeout: 30000 }, async () => {
    const f = await fixture();
    await mkdir(join(f.project, 'parts'));
    await writeFile(join(f.project, 'parts', 'unicode.fragment'), '#include <stddef.h>\nstatic int DynamicUnknown() { return 712; }\n');
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    try {
        await c.connect(transport);
        const query = () => c.callTool({ name: 'codeoutline_explore', arguments: { query: 'parts/unicode.fragment DynamicUnknown' } });
        let result = await query(); assert.notEqual(result.isError, true);
        assert.match(result.content[0].text, /On-demand source: parts\/unicode.fragment \(c, syntax\)/);
        assert.match(result.content[0].text, /return 712/);
        let status = JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text);
        assert.equal(status.files, 1);
        await writeFile(join(f.project, 'parts', 'unicode.fragment'), 'local function DynamicUnknown() return 913 end\n');
        result = await query(); assert.match(result.content[0].text, /\(lua, syntax\)/); assert.match(result.content[0].text, /return 913/);
        await c.callTool({ name: 'codeoutline_rebuild' });
        status = JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text);
        assert.equal(status.files, 1);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK explore labels unconfirmed candidates without inventing callers', { timeout: 30000 }, async () => {
    const f = await fixture();
    for (const dir of ['one', 'two', 'use']) await mkdir(join(f.project, dir));
    for (const [dir, value] of [['one', 11], ['two', 22]]) {
        await writeFile(join(f.project, dir, 'api.c'), `int AgentSdkTarget() { return ${value}; }\n`);
    }
    await writeFile(join(f.project, 'use', 'entry.cpp'), 'void AgentSdkEntry() { AgentSdkTarget(); }\n');
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    try {
        await c.connect(transport);
        const query = () => c.callTool({ name: 'codeoutline_explore', arguments: { query: 'AgentSdkEntry' } });
        let result = await query();
        assert.notEqual(result.isError, true);
        assert.match(result.content[0].text, /## Unconfirmed definition candidates/);
        assert.match(result.content[0].text, /not call edges or verified bindings/);
        assert.match(result.content[0].text, /return 11/); assert.match(result.content[0].text, /return 22/);
        const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'AgentSdkTarget' } });
        assert.notEqual(callers.isError, true); assert.doesNotMatch(callers.content[0].text, /AgentSdkEntry/);
        await writeFile(join(f.project, '.codeoutline.json'), '{"includePaths":[]}');
        result = await query(); assert.doesNotMatch(result.content[0].text, /## Unconfirmed definition candidates/);
        await writeFile(join(f.project, '.codeoutline.json'), '{}');
        await writeFile(join(f.project, 'one', 'api.c'), 'int AgentSdkTarget() { return 99; }\n');
        result = await query(); assert.match(result.content[0].text, /return 99/); assert.doesNotMatch(result.content[0].text, /return 11/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK search ranking reloads config and preserves project coverage', { timeout: 30000 }, async () => {
    const f = await fixture();
    await mkdir(join(f.project, 'generated'));
    for (let i = 1; i <= 3; i++) await writeFile(join(f.project, 'generated', `${i}.lua`), `function ranked_save() return ${i} end\n`);
    await writeFile(join(f.project, 'z_app.lua'), 'function ranked_save() return 99 end\n');
    const transport = new StdioClientTransport({ command: defaultRuntime, args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    const query = (text) => c.callTool({ name: 'codeoutline_explore', arguments: { query: text } });
    try {
        await c.connect(transport);
        assert.doesNotMatch((await query('ranked_save')).content[0].text, /## z_app.lua/);
        await writeFile(join(f.project, '.codeoutline.json'), JSON.stringify({ deprioritize: ['generated/'] }));
        const ranked = await query('ranked_save');
        assert.notEqual(ranked.isError, true);
        assert.match(ranked.content[0].text, /## z_app.lua/);
        assert.match((await query('path:generated/ ranked_save')).content[0].text, /## generated\/1.lua/);
        const status = JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text);
        assert.equal(status.files, 5); assert.equal(status.refresh.parsed, 0);
        await writeFile(join(f.project, '.codeoutline.json'), '{"deprioritize":[]}');
        assert.doesNotMatch((await query('ranked_save')).content[0].text, /## z_app.lua/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK type hierarchy: aliases, directions, validation and incremental edits', { timeout: 30000 }, async () => {
    const f = await fixture();
    await writeFile(join(f.project, 'api.ts'), 'export interface Root {}\n');
    await writeFile(join(f.project, 'child.ts'), "import type { Root as R } from './api';\nexport class Child implements R {}\n");
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.resume();
    const c = client();
    try {
        await c.connect(transport);
        const query = (args) => c.callTool({ name: 'codeoutline_type_hierarchy', arguments: args });
        const before = await query({ query: 'Root', direction: 'descendants' });
        assert.notEqual(before.isError, true);
        assert.match(before.content[0].text, /Descendant depth 1: Child/);
        assert.match(before.content[0].text, /declared implements R at child.ts:2/);
        const upward = await query({ query: 'Child', direction: 'ancestors' });
        assert.match(upward.content[0].text, /Ancestor depth 1: Root/);
        assert.doesNotMatch(upward.content[0].text, /Descendant depth/);
        for (const args of [ { query: 'Root', direction: 'invalid' }, { query: 'Root', depth: 0 },
            { query: 'Root', max_nodes: 0 }, { query: 'Root', unknown: 1 } ]) {
            await assert.rejects(query(args));
        }
        await writeFile(join(f.project, 'child.ts'), 'export class Child {}\n');
        const after = await query({ query: 'Root' });
        assert.notEqual(after.isError, true);
        assert.match(after.content[0].text, /0 ancestors, 0 descendants/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK static registries: inferred flows, callers and registration edits', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.on('data', () => {});
    const c = client();
    try {
        const lua = 'local function registryLeaf() end\nlocal handlers = { go = registryLeaf }\nfunction registryRun() handlers["go"]() end\n';
        await writeFile(join(f.project, 'registry.lua'), lua);
        await writeFile(join(f.project, 'pointer.c'), 'struct Ops { void (*call)(void); };\nvoid pointerLeaf(void) {}\nstatic struct Ops ops = { pointerLeaf };\nvoid pointerRun(void) { ops.call(); }\n');
        await c.connect(transport);
        for (const [entry, leaf, relation] of [
            ['registryRun', 'registryLeaf', 'indirect:registry'],
            ['pointerRun', 'pointerLeaf', 'indirect:fn-pointer'],
        ]) {
            const flow = await c.callTool({ name: 'codeoutline_explore', arguments: { query: `${entry} ${leaf}` } });
            assert.notEqual(flow.isError, true);
            assert.ok(flow.content[0].text.includes(`${entry} -[${relation}]-> ${leaf}`));
            assert.match(flow.content[0].text, /registered at/);
            const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: leaf } });
            assert.notEqual(callers.isError, true);
            assert.ok(callers.content[0].text.includes(relation));
        }
        await writeFile(join(f.project, 'registry.lua'), lua.replace('go = registryLeaf', 'go = nil'));
        const after = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'registryLeaf' } });
        assert.notEqual(after.isError, true);
        assert.doesNotMatch(after.content[0].text, /Depth 1: registryRun/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK call-path breakpoints explain dynamic sites without adding callers', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.on('data', () => {});
    const c = client();
    try {
        const source = 'local function boundaryLeaf() end\nlocal handlers = { go = boundaryLeaf }\n'
            + 'function boundaryMiddle(key) handlers[key]() end\nfunction boundaryStart() boundaryMiddle(runtime_key) end\n';
        await writeFile(join(f.project, 'boundary.lua'), source);
        await c.connect(transport);
        const query = () => c.callTool({ name: 'codeoutline_explore', arguments: { query: 'boundaryStart boundaryLeaf' } });
        const result = await query();
        assert.notEqual(result.isError, true);
        assert.match(result.content[0].text, /## Call-path breakpoints/);
        assert.match(result.content[0].text, /boundaryStart \(boundary.lua:4\) -> boundaryMiddle \(boundary.lua:3\)/);
        assert.match(result.content[0].text, /dynamic registry key/);
        assert.doesNotMatch(result.content[0].text, /## Call paths\n/);
        const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'boundaryLeaf' } });
        assert.notEqual(callers.isError, true);
        assert.match(callers.content[0].text, /0 potential callers/);
        await writeFile(join(f.project, 'boundary.lua'), source.replace('handlers[key]()', 'handlers.go()'));
        const updated = await query();
        assert.notEqual(updated.isError, true);
        assert.match(updated.content[0].text, /boundaryStart -> boundaryMiddle -\[indirect:registry\]-> boundaryLeaf/);
        assert.doesNotMatch(updated.content[0].text, /## Call-path breakpoints/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK Lua registry aliases resolve callers and refresh after reassignment', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.on('data', () => {});
    const c = client();
    try {
        const source = 'local function aliasLeaf() end\nlocal callback = aliasLeaf\n'
            + 'local handlers = { go = callback }\nlocal active = handlers\nfunction aliasRun() active.go() end\n';
        await writeFile(join(f.project, 'aliases.lua'), source);
        await c.connect(transport);
        const flow = await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'aliasRun aliasLeaf' } });
        assert.notEqual(flow.isError, true);
        assert.match(flow.content[0].text, /aliasRun -\[indirect:registry\]-> aliasLeaf/);
        assert.match(flow.content[0].text, /registered at aliases.lua:3/);
        const query = () => c.callTool({ name: 'codeoutline_callers', arguments: { query: 'aliasLeaf' } });
        const callers = await query();
        assert.notEqual(callers.isError, true);
        assert.match(callers.content[0].text, /Depth 1: aliasRun/);
        await writeFile(join(f.project, 'aliases.lua'), source.replace('local active = handlers', 'local active = handlers\nactive = {}'));
        const changed = await query();
        assert.notEqual(changed.isError, true);
        assert.match(changed.content[0].text, /0 potential callers/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK unified rules follow multilingual aliases and refresh callbacks', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.on('data', () => {});
    const c = client();
    try {
        await writeFile(join(f.project, '.codeoutline.json'), JSON.stringify({ rules: [
            { kind: 'event', call: 'bus.emit', argument: 1, register: 'bus.on', keyArgument: 1, handlerArgument: 2 },
            { kind: 'callback', call: 'schedule', argument: 2 },
        ] }));
        await writeFile(join(f.project, 'aliases.lua'), 'local function luaAliasLeaf() end\nlocal api = require("bus")\n'
            + 'local cb = luaAliasLeaf\napi.on("tick", cb)\nfunction luaAliasRun() api.emit("tick") end\n');
        await writeFile(join(f.project, 'handler.ts'), 'export function tsAliasLeaf() {}');
        const ts = 'import {tsAliasLeaf as handler} from "./handler"; import {on as subscribe, emit as publish} from "bus";\n'
            + 'const cb = handler; subscribe("tick", cb); function tsAliasRun() { publish("tick"); }';
        await writeFile(join(f.project, 'aliases.ts'), ts);
        await writeFile(join(f.project, 'handler.py'), 'def pyAliasLeaf():\n    pass\n');
        await writeFile(join(f.project, 'aliases.py'), 'from handler import pyAliasLeaf as handler\nimport bus as api\n'
            + 'cb = handler\napi.on("tick", cb)\ndef pyAliasRun():\n    api.emit("tick")\n');
        await writeFile(join(f.project, 'aliases.c'), 'void cAliasLeaf(void) {}\n'
            + 'void cAliasRun(void) { void (*cb)(void) = &cAliasLeaf; schedule(1, cb); }');
        await c.connect(transport);
        for (const prefix of ['lua', 'ts', 'py', 'c']) {
            const result = await c.callTool({ name: 'codeoutline_explore', arguments: { query: `${prefix}AliasRun ${prefix}AliasLeaf` } });
            assert.notEqual(result.isError, true);
            const kind = prefix === 'c' ? 'indirect:callback#2' : 'indirect:event#1';
            assert.ok(result.content[0].text.includes(`${prefix}AliasRun -[${kind}]-> ${prefix}AliasLeaf`));
            const callers = await c.callTool({ name: 'codeoutline_callers', arguments: { query: `${prefix}AliasLeaf` } });
            assert.notEqual(callers.isError, true);
            assert.match(callers.content[0].text, new RegExp(`Depth 1: ${prefix}AliasRun`));
        }
        await writeFile(join(f.project, 'aliases.ts'), ts.replace('const cb = handler', 'const cb = unknown'));
        const changed = await c.callTool({ name: 'codeoutline_callers', arguments: { query: 'tsAliasLeaf' } });
        assert.notEqual(changed.isError, true);
        assert.match(changed.content[0].text, /0 potential callers/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK Kotlin: kt/kts discovery, aliased call paths and incremental edits', { timeout: 30000 }, async () => {
    const f = await fixture();
    const transport = new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `PROJECT=${f.project}`], cwd: tmpdir(), stderr: 'pipe' });
    transport.stderr?.on('data', () => {});
    const c = client();
    try {
        await writeFile(join(f.project, 'Service.kt'), 'package demo\nfun kotlinLeaf() = 7\n');
        await writeFile(join(f.project, 'Client.kts'), 'import demo.kotlinLeaf as invokeLeaf\nfun kotlinEntry() = invokeLeaf()\n');
        await c.connect(transport);
        const query = (query) => c.callTool({ name: 'codeoutline_explore', arguments: { query } });
        const flow = await query('kotlinEntry kotlinLeaf');
        assert.notEqual(flow.isError, true);
        assert.match(flow.content[0].text, /kotlinEntry -> kotlinLeaf/);
        assert.match(flow.content[0].text, /fun kotlinLeaf\(\) = 7/);
        const file = await query('Service.kt');
        assert.match(file.content[0].text, /kotlinLeaf/);
        await writeFile(join(f.project, 'Service.kt'), 'package demo\nfun kotlinUpdated() = 17\n');
        const edited = await query('kotlinUpdated');
        assert.match(edited.content[0].text, /return|= 17/);
        assert.match((await query('kotlinLeaf')).content[0].text, /No symbols matched/);
    } finally { await c.close(); await f.cleanup(); }
});

test('official SDK HTTP: sessions, concurrency, refresh, path aliases and perimeter', { timeout: 30000 }, async () => {
    const f = await fixture();
    const worker = new LuaWorker();
    const endpoint = await startHttp(worker, await configurePaths({ project: f.project }), { port: 0 });
    const c = client(), c2 = client();
    const transport = new StreamableHTTPClientTransport(new URL(endpoint.url));
    try {
        await c.connect(transport);
        await c2.connect(new StreamableHTTPClientTransport(new URL(endpoint.url)));
        assert.equal((await c.listTools()).tools.length, 6);
        const result = await Promise.all([c, c2].map((instance) => instance.callTool({ name: 'codeoutline_explore', arguments: { query: 'greet' } })));
        assert.ok(result.every((r) => /你好世界/.test(r.content[0].text)));
        const oldPid = endpoint.child.pid;
        await writeFile(join(f.project, 'sample.lua'), 'function changed_http() return 17 end\n');
        assert.match((await c.callTool({ name: 'codeoutline_explore', arguments: { query: 'changed_http' } })).content[0].text, /return 17/);
        assert.equal(endpoint.child.pid, oldPid, 'queries reuse the same process');
        const alias = join(f.root, 'alias');
        await symlink(f.project, alias, process.platform === 'win32' ? 'junction' : 'dir');
        assert.equal((await c.callTool({ name: 'codeoutline_status', arguments: { projectPath: alias } })).isError, false);
        const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json',
            'mcp-session-id': transport.sessionId, 'mcp-protocol-version': '2025-06-18' };
        const rpc = (body, extra = {}) => fetch(endpoint.url, { method: 'POST', headers: { ...headers, ...extra }, body: JSON.stringify(body) });
        assert.equal((await rpc({ jsonrpc: '2.0', id: 40, method: 'ping' }, { origin: 'https://evil.example' })).status, 403);
        const badHostStatus = await new Promise((resolve, reject) => {
            const req = http.request(endpoint.url, { headers: { host: 'evil.example' } }, (res) => { res.resume(); resolve(res.statusCode); });
            req.on('error', reject); req.end();
        });
        assert.equal(badHostStatus, 403);
        assert.equal((await rpc({ jsonrpc: '2.0', id: 42, method: 'ping' }, { 'mcp-protocol-version': '2099-01-01' })).status, 400);
        assert.equal((await rpc([], {})).status, 400);
        assert.equal((await fetch(endpoint.url)).status, 405);
        assert.equal((await rpc({ jsonrpc: '2.0', id: 43, method: 'ping' }, { 'mcp-session-id': 'missing' })).status, 404);
        assert.equal((await fetch(endpoint.url, { method: 'POST', headers, body: '{' })).status, 400);
        assert.equal((await fetch(endpoint.url, { method: 'POST', headers, body: 'x'.repeat(1024 * 1024 + 1) })).status, 413);
        const bad = await rpc({ jsonrpc: '2.0', id: 44, method: 'tools/call', params: { name: 'bad' } });
        assert.equal((await bad.json()).error.code, -32602);
        await transport.terminateSession();
    } finally { await c.close(); await c2.close(); await endpoint.close(); await worker.close(); await f.cleanup(); }
});

async function twoProjects() {
    const f = await fixture();
    const other = join(f.root, 'other');
    await mkdir(other);
    await writeFile(join(other, 'a.lua'), 'function a() end\n');
    await writeFile(join(other, 'b.lua'), 'function b() end\n');
    return { ...f, other };
}
function rootsClient(getRoot) {
    const c = new Client({ name: 'codeoutline-roots', version: '1.0.0' }, { capabilities: { roots: { listChanged: true } } });
    let calls = 0;
    c.setRequestHandler(ListRootsRequestSchema, async () => {
        calls += 1;
        const root = getRoot();
        return { roots: root ? [{ uri: pathToFileURL(root).href, name: 'workspace' }] : [] };
    });
    return { c, calls: () => calls };
}
const files = async (c) => JSON.parse((await c.callTool({ name: 'codeoutline_status' })).content[0].text).files;

test('stdio without PROJECT defaults to client roots, then the working directory', { timeout: 30000 }, async () => {
    const f = await twoProjects();
    const stdio = () => new StdioClientTransport({ command: defaultRuntime,
        args: [main, 'STDIO=1', `ALLOW_ROOT=${f.root}`], cwd: f.project, stderr: 'ignore' });
    const plain = client();
    let root = f.other;
    const withRoots = rootsClient(() => root);
    try {
        await plain.connect(stdio());
        assert.equal(await files(plain), 1, 'no roots capability uses the startup directory');
        await withRoots.c.connect(stdio());
        assert.equal(await files(withRoots.c), 2, 'first client root wins over the startup directory');
        assert.equal(await files(withRoots.c), 2);
        assert.equal(withRoots.calls(), 1, 'roots are cached per session');
        root = undefined;
        await withRoots.c.sendRootsListChanged();
        assert.equal(await files(withRoots.c), 1, 'empty roots fall back to the startup directory');
        assert.equal(withRoots.calls(), 2);
        root = f.other;
        await withRoots.c.sendRootsListChanged();
        const explicit = await withRoots.c.callTool({ name: 'codeoutline_status', arguments: { projectPath: f.project } });
        assert.equal(JSON.parse(explicit.content[0].text).files, 1, 'explicit projectPath wins');
        assert.equal(withRoots.calls(), 2, 'explicit projectPath skips roots/list');
    } finally { await plain.close(); await withRoots.c.close(); await f.cleanup(); }
});

test('HTTP without PROJECT requests client roots over the response stream', { timeout: 30000 }, async () => {
    const f = await twoProjects();
    const worker = new LuaWorker();
    const endpoint = await startHttp(worker, await configurePaths({ allowedRoots: [f.root] }), { port: 0 });
    const plain = client();
    const withRoots = rootsClient(() => f.other);
    try {
        await plain.connect(new StreamableHTTPClientTransport(new URL(endpoint.url)));
        const missing = await plain.callTool({ name: 'codeoutline_status' });
        assert.equal(missing.isError, true);
        assert.match(missing.content[0].text, /projectPath is required/);
        await withRoots.c.connect(new StreamableHTTPClientTransport(new URL(endpoint.url)));
        assert.deepEqual(await Promise.all([files(withRoots.c), files(withRoots.c)]), [2, 2]);
        assert.equal(withRoots.calls(), 1, 'concurrent calls share one roots/list request');
    } finally { await plain.close(); await withRoots.c.close(); await endpoint.close(); await worker.close(); await f.cleanup(); }
});

test('loopback HTTP without ALLOW_ROOT serves any project; an unavailable root only warns', { timeout: 30000 }, async () => {
    const f = await twoProjects();
    const worker = new LuaWorker();
    const status = async (c, projectPath) => c.callTool({ name: 'codeoutline_status', arguments: { projectPath } });
    // Realpath first: a later mkdir must produce the exact spelling of the kept root.
    const later = join(await realpath(f.root), 'mounted later');
    const open = await startHttp(worker, { roots: [] }, { port: 0 });
    const limited = await startHttp(worker, { roots: [f.project, later] }, { port: 0 });
    const a = client(), b = client();
    try {
        await a.connect(new StreamableHTTPClientTransport(new URL(open.url)));
        assert.equal(JSON.parse((await status(a, f.project)).content[0].text).files, 1);
        assert.equal(JSON.parse((await status(a, f.other)).content[0].text).files, 2);
        assert.match(limited.logs(), /allowed root .*mounted later is unavailable/);
        await b.connect(new StreamableHTTPClientTransport(new URL(limited.url)));
        assert.equal((await status(b, f.project)).isError, false);
        assert.match((await status(b, f.other)).content[0].text, /outside allowed/);
        await mkdir(later);
        assert.equal((await status(b, later)).isError, false, 'the kept root matches once it exists');
    } finally {
        await a.close(); await b.close(); await open.close(); await limited.close(); await worker.close(); await f.cleanup();
    }
});

test('remote bind requires auth and explicit allowed host', async () => {
    const w = new LuaWorker();
    const config = await configurePaths();
    await assert.rejects(startHttp(w, config, { host: '0.0.0.0', port: 0, token: '' }), /requires/);
    const endpoint = await startHttp(w, config, { host: '0.0.0.0', port: 0, token: 'test-token-123456789', allowedHosts: ['127.0.0.1'] });
    try {
        const url = `http://127.0.0.1:${endpoint.server.address().port}/mcp`;
        assert.equal((await fetch(url)).status, 401);
        assert.equal((await fetch(url, { headers: { authorization: 'Bearer test-token-123456789' } })).status, 405);
    } finally { await endpoint.close(); await w.close(); }
});

test('stdio emits only JSON messages and exits cleanly on EOF', { timeout: 10000 }, async () => {
    const child = spawn(defaultRuntime, [main, 'STDIO=1'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.stderr.resume();
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'raw-test', version: '1' },
    } }) + '\n');
    await once(child.stdout, 'data');
    const exited = once(child, 'exit');
    child.stdin.end();
    const [code] = await exited;
    assert.equal(code, 0);
    const messages = out.trim().split('\n').map(JSON.parse);
    assert.equal(messages[0].result.protocolVersion, '2025-06-18');
});

test('stdio rejects malformed JSON, missing initialization and partial EOF frames', { timeout: 10000 }, async () => {
    const child = spawn(defaultRuntime, [main, 'STDIO=1'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.resume();
    child.stdin.write('broken\n' + JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n');
    while (output.split('\n').filter(Boolean).length < 2) await once(child.stdout, 'data');
    const exited = once(child, 'exit');
    child.stdin.end('{');
    assert.equal((await exited)[0], 1);
    const messages = output.trim().split('\n').map(JSON.parse);
    assert.equal(messages[0].error.code, -32700);
    assert.equal(messages[1].error.code, -32600);
    assert.equal(messages[2].error.code, -32700);
});
