import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { defaultRuntime, root } from './helpers.js';

const frame = (message) => {
    const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message }));
    return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
};

async function start(t) {
    const temp = await mkdtemp(join(tmpdir(), 'codeoutline-lsp-'));
    const project = join(temp, 'workspace');
    await mkdir(project);
    await writeFile(join(project, 'sample.lua'), 'function saved() end\n');
    const child = spawn(defaultRuntime, [join(root, 'scripts/codeoutline/command.lua'),
        'LOG_STDERR=1', 'LOG_FILE=0', 'lsp', '--stdio'], { cwd: tmpdir(), windowsHide: true,
        stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, CODEOUTLINE_AUTO_UPDATE: '1' } });
    const pending = new Map(), notifications = [];
    let buffer = Buffer.alloc(0), nextId = 0, logs = '', failure;
    child.stderr.on('data', (chunk) => { logs += chunk; });
    const fail = (error) => {
        failure = error;
        for (const job of pending.values()) { clearTimeout(job.timer); job.reject(error); }
        pending.clear();
    };
    child.on('error', fail);
    child.on('exit', (code) => {
        if (pending.size) fail(new Error(`LSP exited ${code}: ${logs}`));
    });
    child.stdout.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        try {
            while (buffer.length) {
                const stop = buffer.indexOf('\r\n\r\n');
                if (stop < 0) return;
                const header = buffer.subarray(0, stop).toString('ascii');
                const match = /^Content-Length: (\d+)$/i.exec(header);
                assert.ok(match, `stdout contains a non-LSP header: ${header}`);
                const length = Number(match[1]);
                if (buffer.length < stop + 4 + length) return;
                const msg = JSON.parse(buffer.subarray(stop + 4, stop + 4 + length).toString('utf8'));
                buffer = buffer.subarray(stop + 4 + length);
                const job = pending.get(msg.id);
                if (msg.method === 'window/workDoneProgress/create') {
                    child.stdin.write(frame({ id: msg.id, result: null }));
                } else if (msg.method) notifications.push(msg);
                if (job && !msg.method) {
                    clearTimeout(job.timer); pending.delete(msg.id);
                    job.resolve(msg);
                }
            }
        } catch (error) { fail(error); }
    });
    const response = (id) => new Promise((resolve, reject) => {
        if (failure) { reject(failure); return; }
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`LSP request ${id} timed out: ${logs}`)); }, 10000);
        pending.set(id, { resolve, reject, timer });
    });
    const notify = (method, params = {}) => child.stdin.write(frame({ method, params }));
    const rawRequest = (method, params = {}) => {
        const id = ++nextId, promise = response(id);
        child.stdin.write(frame({ id, method, params }));
        return promise;
    };
    const request = async (method, params = {}) => {
        const msg = await rawRequest(method, params);
        assert.equal(msg.error, undefined, JSON.stringify(msg.error));
        return msg.result;
    };
    t.after(async () => {
        if (child.exitCode === null) {
            const exit = once(child, 'exit');
            const timer = setTimeout(() => child.kill(), 2000);
            try {
                await request('shutdown'); notify('exit'); await exit;
            } catch { child.kill(); await exit; }
            clearTimeout(timer);
        }
        await rm(temp, { recursive: true, force: true });
    });
    return { child, project, request, rawRequest, notify, response,
        notifications, id: () => ++nextId, logs: () => logs };
}

const initialize = async (client, folders) => {
    const result = await client.request('initialize', { processId: process.pid,
        workspaceFolders: folders.map((path) => ({ uri: pathToFileURL(path).href, name: 'workspace' })),
        capabilities: { window: { workDoneProgress: true },
            textDocument: { documentSymbol: { hierarchicalDocumentSymbolSupport: true } } } });
    assert.equal(result.serverInfo.name, 'codeoutline');
    assert.equal(result.capabilities.positionEncoding, 'utf-16');
    assert.equal(result.capabilities.textDocumentSync.change, 1);
    for (const name of ['definitionProvider', 'hoverProvider', 'referencesProvider', 'callHierarchyProvider']) {
        assert.equal(result.capabilities[name], true, name);
    }
    assert.deepEqual(result.capabilities.completionProvider.triggerCharacters, ['.', ':', '>']);
    assert.deepEqual(result.capabilities.signatureHelpProvider.triggerCharacters, ['(', ',']);
    client.notify('initialized');
};

const indexed = async (client) => {
    const deadline = Date.now() + 10000;
    while (!client.notifications.some((msg) => msg.params?.value?.kind === 'end') && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.ok(client.notifications.some((msg) => msg.params?.value?.kind === 'end'), client.logs());
};

test('LSP stdio navigates definitions, hover, references and calls over drafts', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await writeFile(join(client.project, 'util.h'), 'int helper(int x);\n');
    await writeFile(join(client.project, 'util.c'), '#include "util.h"\nint helper(int x) { return x + 1; }\n');
    await writeFile(join(client.project, 'main.c'), '#include "util.h"\nstatic int twice(int v) { return helper(helper(v)); }\n');
    await initialize(client, [client.project]);
    await indexed(client);
    const main = pathToFileURL(join(client.project, 'main.c')).href;
    const util = pathToFileURL(join(client.project, 'util.c')).href;
    const at = (uri, line, character) => ({ textDocument: { uri }, position: { line, character } });
    const definition = await client.request('textDocument/definition', at(main, 1, 35));
    assert.equal(definition.length, 1);
    assert.equal(definition[0].uri, util);
    assert.deepEqual(definition[0].range, { start: { line: 1, character: 4 }, end: { line: 1, character: 10 } });
    const hover = await client.request('textDocument/hover', at(main, 1, 35));
    assert.match(hover.contents.value, /int helper\(int x\)/);
    const references = await client.request('textDocument/references', { ...at(util, 1, 5), context: { includeDeclaration: false } });
    assert.deepEqual(references.map((loc) => loc.range.start.character), [33, 40]);
    const [item] = await client.request('textDocument/prepareCallHierarchy', at(util, 1, 5));
    const incoming = await client.request('callHierarchy/incomingCalls', { item });
    assert.equal(incoming[0].from.name, 'twice');
    assert.equal(incoming[0].fromRanges.length, 2);
    const outgoing = await client.request('callHierarchy/outgoingCalls', { item: incoming[0].from });
    assert.equal(outgoing[0].to.name, 'helper');
    assert.deepEqual(await client.request('callHierarchy/outgoingCalls', { item }), []);
    // An unsaved edit moves the definition; closing restores the disk view.
    const draft = '#include "util.h"\n\nint helper(int x) { return x; }\n';
    client.notify('textDocument/didOpen', { textDocument: { uri: util, languageId: 'c', version: 1, text: draft } });
    assert.equal((await client.request('textDocument/definition', at(main, 1, 35)))[0].range.start.line, 2);
    client.notify('textDocument/didChange', { textDocument: { uri: util, version: 2 }, contentChanges: [{ text: '\n\n\n' + draft }] });
    assert.equal((await client.request('textDocument/definition', at(main, 1, 35)))[0].range.start.line, 5);
    client.notify('textDocument/didClose', { textDocument: { uri: util } });
    assert.equal((await client.request('textDocument/definition', at(main, 1, 35)))[0].range.start.line, 1);
    assert.equal(await readFile(join(client.project, 'util.c'), 'utf8'), '#include "util.h"\nint helper(int x) { return x + 1; }\n');
});

test('LSP stdio follows configurable literal arguments and reloads rules', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const config = join(client.project, '.codeoutline.json');
    await writeFile(config, JSON.stringify({ definitionRules: [{ language: 'lua',
        call: 'xthread.post', argument: 2, target: 'xthread.register', targetArgument: 1 }] }));
    const source = "xthread.post(MAIN_ID, 'xmysql_business_done', false)\n";
    await writeFile(join(client.project, 'send.lua'), source);
    await writeFile(join(client.project, 'receive.lua'), "xthread.register('xmysql_business_done', function() end)\n");
    await initialize(client, [client.project]);
    await indexed(client);
    const uri = pathToFileURL(join(client.project, 'send.lua')).href;
    const target = pathToFileURL(join(client.project, 'receive.lua')).href;
    const params = { textDocument: { uri }, position: { line: 0, character: 25 } };
    const definition = await client.request('textDocument/definition', params);
    assert.equal(definition.length, 1);
    assert.equal(definition[0].uri, target);
    assert.deepEqual(definition[0].range, { start: { line: 0, character: 17 }, end: { line: 0, character: 39 } });
    client.notify('textDocument/didOpen', { textDocument: { uri: target, languageId: 'lua', version: 1,
        text: "\n\nxthread.register('xmysql_business_done', function() end)\n" } });
    assert.equal((await client.request('textDocument/definition', params))[0].range.start.line, 2);
    await writeFile(config, '{"definitionRules":[]}');
    assert.deepEqual(await client.request('textDocument/definition', params), []);
});

test('LSP stdio completes members, locals and draft edits', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await writeFile(join(client.project, 'shape.h'), 'struct Shape { int width; struct Shape *next; };\n');
    await writeFile(join(client.project, 'use.c'), '#include "shape.h"\nint area(struct Shape *s, int scale) {\n  int local = 1;\n  return s->;\n}\n');
    await initialize(client, [client.project]);
    await indexed(client);
    const uri = pathToFileURL(join(client.project, 'use.c')).href;
    const labels = (result) => result.items.map((item) => item.label).sort().join(',');
    const members = await client.request('textDocument/completion', { textDocument: { uri }, position: { line: 3, character: 12 },
        context: { triggerKind: 2, triggerCharacter: '>' } });
    assert.equal(labels(members), 'next,width');
    assert.equal(members.isIncomplete, false);
    const scope = await client.request('textDocument/completion', { textDocument: { uri }, position: { line: 3, character: 2 } });
    assert.equal(labels(scope), 'Shape,area,local,s,scale');
    const typed = await client.request('textDocument/completion', { textDocument: { uri }, position: { line: 3, character: 9 },
        context: { triggerKind: 2, triggerCharacter: '>' } });
    assert.deepEqual(typed.items, []);
    client.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'c', version: 1,
        text: '#include "shape.h"\nint area(struct Shape *s, int scale) {\n  return s->next->;\n}\n' } });
    const chained = await client.request('textDocument/completion', { textDocument: { uri }, position: { line: 2, character: 18 } });
    assert.equal(labels(chained), 'next,width');
});

test('LSP completes xhash header functions at the end of xrecord_bind', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    for (const name of ['xrecord.c', 'xrecord.h', 'xhash.h', 'xmacro.h']) {
        await writeFile(join(client.project, name), await readFile(join(root, 'xnet2lua', name)));
    }
    await initialize(client, [client.project]);
    await indexed(client);
    const source = await readFile(join(client.project, 'xrecord.c'), 'utf8');
    const functionStart = source.indexOf('xrecord_status xrecord_bind(');
    const insert = source.indexOf('    return XRECORD_OK;', functionStart);
    assert.ok(functionStart >= 0 && insert > functionStart);
    const prefix = source.slice(0, insert) + '    xhash';
    const uri = pathToFileURL(join(client.project, 'xrecord.c')).href;
    client.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'c', version: 1,
        text: prefix + '\n' + source.slice(insert) } });
    const lines = prefix.split('\n');
    const result = await client.request('textDocument/completion', { textDocument: { uri },
        position: { line: lines.length - 1, character: lines.at(-1).length } });
    const labels = result.items.map(item => item.label);
    for (const name of ['xhash_create', 'xhash_get_int', 'xhash_set_int', 'xhash_destroy']) {
        assert.ok(labels.includes(name), `Missing header completion: ${name}`);
    }
    const call = prefix + '_get_int(';
    client.notify('textDocument/didChange', { textDocument: { uri, version: 2 },
        contentChanges: [{ text: call + '\n' + source.slice(insert) }] });
    const signature = await client.request('textDocument/signatureHelp', { textDocument: { uri },
        position: { line: lines.length - 1, character: lines.at(-1).length + '_get_int('.length } });
    assert.match(signature.signatures[0].label, /xhash_get_int/);
    assert.equal(signature.signatures[0].parameters.length, 2);
});

test('LSP C completion includes transitive headers without leaking unrelated files or members', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const unrelated = Array.from({ length: 550 }, (_, i) => `int noise_${i}(void);`).join('\n');
    await writeFile(join(client.project, 'a.h'), unrelated + '\n#include "z.h"\n');
    await writeFile(join(client.project, 'z.h'), 'int xhash_visible(int value);\nstruct Detail { int xhash_field; };\n');
    await writeFile(join(client.project, 'z.c'), 'static int xhash_private(void) { return 0; }\n');
    await writeFile(join(client.project, 'other.h'), 'int xhash_unrelated(void);\n');
    await writeFile(join(client.project, 'main.c'), '#include "a.h"\nvoid run(void) { xhash\n}\n');
    await initialize(client, [client.project]);
    await indexed(client);
    const uri = pathToFileURL(join(client.project, 'main.c')).href;
    const result = await client.request('textDocument/completion', { textDocument: { uri },
        position: { line: 1, character: 'void run(void) { xhash'.length } });
    const names = result.items.map(item => item.label);
    assert.ok(names.includes('xhash_visible'));
    for (const name of ['xhash_field', 'xhash_private', 'xhash_unrelated']) assert.ok(!names.includes(name), name);
    assert.equal(result.isIncomplete, true);
    const header = pathToFileURL(join(client.project, 'z.h')).href;
    client.notify('textDocument/didOpen', { textDocument: { uri: header, languageId: 'c', version: 1,
        text: 'int xhash_updated(int value);\n' } });
    const draft = await client.request('textDocument/completion', { textDocument: { uri },
        position: { line: 1, character: 'void run(void) { xhash'.length } });
    assert.ok(draft.items.some(item => item.label === 'xhash_updated'));
    assert.ok(!draft.items.some(item => item.label === 'xhash_visible'));
});

test('LSP signature help reads C declarations through headers', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await writeFile(join(client.project, 'rpc.h'), 'int test_rpc_target(const char *name, void (*callback)(int, int));\n');
    await writeFile(join(client.project, 'rpc.c'), '#include "rpc.h"\nvoid run(void) { test_rpc_target(');
    await initialize(client, [client.project]);
    await indexed(client);
    const result = await client.request('textDocument/signatureHelp', {
        textDocument: { uri: pathToFileURL(join(client.project, 'rpc.c')).href },
        position: { line: 1, character: 33 } });
    assert.equal(result.signatures[0].parameters.length, 2);
    assert.match(result.signatures[0].parameters[1].label, /callback/);
});

test('LSP signature help follows incomplete calls and draft signatures', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const declaration = 'local function test_rpc_target(name, payload, callback) end\n';
    await writeFile(join(client.project, 'rpc.lua'), declaration);
    await initialize(client, [client.project]);
    await indexed(client);
    const uri = pathToFileURL(join(client.project, 'rpc.lua')).href;
    let version = 0;
    async function signature(call, header = declaration) {
        const text = header + call;
        if (++version === 1) client.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'lua', version, text } });
        else client.notify('textDocument/didChange', { textDocument: { uri, version }, contentChanges: [{ text }] });
        return client.request('textDocument/signatureHelp', { textDocument: { uri },
            position: { line: 1, character: call.length }, context: { triggerKind: 2, triggerCharacter: '(' } });
    }
    const first = await signature('test_rpc_target(');
    assert.match(first.signatures[0].label, /test_rpc_target\(name, payload, callback\)/);
    assert.deepEqual(first.signatures[0].parameters.map(p => p.label), ['name', 'payload', 'callback']);
    assert.equal(first.activeParameter, 0);
    assert.equal((await signature('test_rpc_target("a,b", {1, 2}, ')).activeParameter, 2);
    assert.equal((await signature('test_rpc_target(inner(1, 2), ')).activeParameter, 1);
    assert.equal(await signature('test_rpc_target()'), null);
    assert.equal(await signature('unknown('), null);
    const changed = await signature('test_rpc_target(', 'local function test_rpc_target(updated) end\n');
    assert.deepEqual(changed.signatures[0].parameters, [{ label: 'updated' }]);
    const empty = await signature('test_rpc_target(', 'local function test_rpc_target() end\n');
    assert.deepEqual(empty.signatures[0].parameters, []);
});

test('LSP stdio handles drafts, UTF-16 ranges, cancellation and close restoration', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const before = await client.rawRequest('workspace/symbol', { query: '' });
    assert.equal(before.error.code, -32002);
    await initialize(client, [client.project]);
    const uri = pathToFileURL(join(client.project, 'sample.lua')).href;
    const source = 'local marker = "中😀"; function draft() end\r\n';
    client.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'lua', version: 1, text: source } });
    const symbols = await client.request('textDocument/documentSymbol', { textDocument: { uri } });
    const draft = symbols.find((symbol) => symbol.name === 'draft');
    assert.equal(draft.selectionRange.start.character, source.indexOf('draft'));
    assert.equal(draft.selectionRange.end.character, source.indexOf('draft') + 'draft'.length);
    assert.deepEqual((await client.request('workspace/symbol', { query: 'saved' })), []);
    assert.equal((await client.request('workspace/symbol', { query: 'draft' }))[0].name, 'draft');
    assert.equal(await readFile(join(client.project, 'sample.lua'), 'utf8'), 'function saved() end\n');
    client.notify('textDocument/didChange', { textDocument: { uri, version: 2 }, contentChanges: [{ text: 'function renamed() end' }] });
    assert.equal((await client.request('textDocument/documentSymbol', { textDocument: { uri } }))[0].name, 'renamed');
    client.notify('textDocument/didChange', { textDocument: { uri, version: 1 }, contentChanges: [{ text: 'function stale() end' }] });
    assert.equal((await client.request('textDocument/documentSymbol', { textDocument: { uri } }))[0].name, 'renamed');
    const readyDeadline = Date.now() + 10000;
    while (!client.notifications.some((msg) => msg.params?.value?.kind === 'end') && Date.now() < readyDeadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.ok(client.notifications.some((msg) => msg.params?.value?.kind === 'end'));
    const id = client.id(), cancelled = client.response(id);
    client.child.stdin.write(Buffer.concat([frame({ id, method: 'workspace/symbol', params: { query: 'renamed' } }),
        frame({ method: '$/cancelRequest', params: { id } })]));
    assert.equal((await cancelled).error.code, -32800);
    assert.equal((await client.request('workspace/symbol', { query: 'renamed' })).length, 1);
    client.notify('textDocument/didClose', { textDocument: { uri } });
    assert.equal((await client.request('textDocument/documentSymbol', { textDocument: { uri } }))[0].name, 'saved');
    const newUri = pathToFileURL(join(client.project, 'missing.lua')).href;
    client.notify('textDocument/didOpen', { textDocument: { uri: newUri, languageId: 'lua', version: 1, text: 'function unsaved() end' } });
    assert.equal((await client.request('workspace/symbol', { query: 'unsaved' }))[0].name, 'unsaved');
});

test('LSP indexing accepts split frames and deduplicates nested workspace roots', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const sub = join(client.project, 'sub');
    await mkdir(sub);
    await writeFile(join(sub, 'nested.lua'), 'function nested_symbol() end\n');
    const id = client.id(), result = client.response(id);
    const message = frame({ id, method: 'initialize', params: { capabilities: {},
        workspaceFolders: [client.project, sub].map((path) => ({ uri: pathToFileURL(path).href, name: 'root' })) } });
    client.child.stdin.write(message.subarray(0, 7));
    await new Promise((resolve) => setTimeout(resolve, 20));
    client.child.stdin.write(message.subarray(7));
    assert.equal((await result).result.serverInfo.name, 'codeoutline');
    client.notify('initialized');
    let symbols = [];
    const deadline = Date.now() + 10000;
    while (!symbols.length && Date.now() < deadline) {
        symbols = await client.request('workspace/symbol', { query: 'nested_symbol' });
        if (!symbols.length) await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(symbols.length, 1, client.logs());
    assert.equal(symbols[0].location.uri, pathToFileURL(join(sub, 'nested.lua')).href);
    assert.equal(symbols[0].location.range.start.character, 9);
    client.notify('workspace/didChangeWorkspaceFolders', { event: { removed: [
        { uri: pathToFileURL(client.project).href }], added: [] } });
    assert.equal((await client.request('workspace/symbol', { query: 'saved' })).length, 0);
});

test('LSP returns JSON null for shutdown and ignores late initialized notifications', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await initialize(client, [client.project]);
    assert.equal(await client.request('shutdown'), null);
    client.notify('initialized');
    const after = await client.rawRequest('workspace/symbol', { query: '' });
    assert.equal(after.error.code, -32600);
    const exit = once(client.child, 'exit');
    client.notify('exit');
    assert.equal((await exit)[0], 0);
});

test('LSP accepts null params and answers invalid requests by id', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await initialize(client, [client.project]);
    // Array params are invalid; the error must carry the id, or the client waits forever.
    const invalid = await client.rawRequest('workspace/symbol', [{ query: '' }]);
    assert.equal(invalid.error.code, -32600);
    const shutdown = await client.rawRequest('shutdown', null);
    assert.equal(shutdown.error, undefined, JSON.stringify(shutdown.error));
    assert.equal(shutdown.result, null);
    const exit = once(client.child, 'exit');
    client.child.stdin.write(frame({ method: 'exit', params: null }));
    assert.equal((await exit)[0], 0);
});

test('LSP reports indexing progress and refreshes saved files without a query-triggered scan', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    await initialize(client, [client.project]);
    const deadline = Date.now() + 10000;
    while (!client.notifications.some((msg) => msg.method === '$/progress' && msg.params.value.kind === 'end')
        && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
    const progress = client.notifications.filter((msg) => msg.method === '$/progress');
    assert.deepEqual(progress.map((msg) => msg.params.value.kind), ['begin', 'end'], client.logs());
    assert.equal(progress[0].params.token, progress[1].params.token);
    assert.equal((await client.request('workspace/symbol', { query: 'saved' })).length, 1);
    await writeFile(join(client.project, 'sample.lua'), 'function external_change() end\n');
    client.notify('textDocument/didSave', { textDocument: { uri: pathToFileURL(join(client.project, 'sample.lua')).href } });
    let symbols = [];
    while (!symbols.length && Date.now() < deadline) {
        symbols = await client.request('workspace/symbol', { query: 'external_change' });
        if (!symbols.length) await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.equal(symbols.length, 1, client.logs());
    assert.equal((await client.request('workspace/symbol', { query: 'saved' })).length, 0);
    await writeFile(join(client.project, 'new.lua'), 'function watcher_created() end\n');
    const refreshDeadline = Date.now() + 10000;
    symbols = [];
    while (!symbols.length && Date.now() < refreshDeadline) {
        symbols = await client.request('workspace/symbol', { query: 'watcher_created' });
        if (!symbols.length) await new Promise((resolve) => setTimeout(resolve, 100));
    }
    assert.equal(symbols.length, 1, 'external creation refreshes without a client notification');
});

test('LSP answers local queries while a real background index is still running', { timeout: 30000 }, async (t) => {
    const client = await start(t);
    const source = Array.from({ length: 6000 }, (_, i) => `function background_${i}() return ${i} end\n`).join('');
    for (let i = 0; i < 24; i++) await writeFile(join(client.project, `large_${i}.lua`), source);
    await initialize(client, [client.project]);
    const draftUri = pathToFileURL(join(client.project, 'draft.lua')).href;
    client.notify('textDocument/didOpen', { textDocument: { uri: draftUri, languageId: 'lua', version: 1,
        text: 'function immediate_draft() end' } });
    const workspaceStart = Date.now();
    const early = await client.request('workspace/symbol', { query: 'immediate_draft' });
    assert.equal(early[0].name, 'immediate_draft');
    assert.ok(!client.notifications.some((msg) => msg.params?.value?.kind === 'end'),
        'workspace symbols must return drafts before the background index finishes');
    t.diagnostic(`workspace/symbol during indexing: ${Date.now() - workspaceStart}ms`);
    const uri = 'untitled:local-draft';
    client.notify('textDocument/didOpen', { textDocument: { uri, languageId: 'lua', version: 1, text: 'function interactive() end' } });
    const timings = [];
    let duringIndex = 0;
    for (let i = 0; i < 20; i++) {
        const before = Date.now();
        const result = await client.request('textDocument/documentSymbol', { textDocument: { uri } });
        timings.push(Date.now() - before);
        assert.equal(result[0].name, 'interactive');
        if (client.notifications.some((msg) => msg.params?.value?.kind === 'begin')
            && !client.notifications.some((msg) => msg.params?.value?.kind === 'end')) duringIndex++;
    }
    assert.ok(duringIndex > 0, 'document query completes before project indexing');
    assert.ok(Math.max(...timings) < 2000, 'local queries do not wait for the complete index');
    const deadline = Date.now() + 10000;
    while (!client.notifications.some((msg) => msg.params?.value?.kind === 'end') && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
    }
    const indexed = await client.request('workspace/symbol', { query: 'background_5999' });
    assert.equal(indexed.length, 24, 'the background job completes and publishes all files');
    assert.ok(client.notifications.some((msg) => msg.params?.value?.kind === 'end'));
    timings.sort((a, b) => a - b);
    t.diagnostic(`24 files / 144000 functions: documentSymbol p95=${timings[18]}ms, max=${timings[19]}ms`);
});


test('LSP exit without shutdown fails and truncated frames fail on EOF', { timeout: 30000 }, async (t) => {
    for (const mode of ['exit', 'partial']) {
        const client = await start(t);
        const exit = once(client.child, 'exit');
        if (mode === 'exit') client.notify('exit');
        else client.child.stdin.end('Content-Length: 100\r\n\r\n{');
        assert.equal((await exit)[0], 1);
    }
});
