import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { defaultRuntime, root } from './helpers.js';

// Re-enable once `lsp --stdio` runs on the shared index worker; see docs/LSP.md.
const moving = 'lsp --stdio is moving onto the shared index worker';

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
    assert.equal(result.capabilities.definitionProvider, undefined);
    client.notify('initialized');
};

test('LSP stdio handles drafts, UTF-16 ranges, cancellation and close restoration', { timeout: 30000, skip: moving }, async (t) => {
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

test('LSP indexing accepts split frames and deduplicates nested workspace roots', { timeout: 30000, skip: moving }, async (t) => {
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

test('LSP returns JSON null for shutdown and ignores late initialized notifications', { timeout: 30000, skip: moving }, async (t) => {
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

test('LSP reports indexing progress and refreshes saved files without a query-triggered scan', { timeout: 30000, skip: moving }, async (t) => {
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

test('LSP answers local queries while a real background index is still running', { timeout: 30000, skip: moving }, async (t) => {
    const client = await start(t);
    const source = Array.from({ length: 6000 }, (_, i) => `function background_${i}() return ${i} end\n`).join('');
    for (let i = 0; i < 24; i++) await writeFile(join(client.project, `large_${i}.lua`), source);
    await initialize(client, [client.project]);
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
    timings.sort((a, b) => a - b);
    t.diagnostic(`24 files / 144000 functions: documentSymbol p95=${timings[18]}ms, max=${timings[19]}ms`);
});
