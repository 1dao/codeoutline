import * as assert from 'node:assert/strict';
import * as vscode from 'vscode';

async function eventually<T>(get: () => Thenable<T>, accept: (value: T) => boolean): Promise<T> {
    const deadline = Date.now() + 20000;
    let last: T;
    do {
        last = await get();
        if (accept(last)) return last;
        await new Promise(resolve => setTimeout(resolve, 100));
    } while (Date.now() < deadline);
    throw new Error('Provider did not return the expected result: ' + JSON.stringify(last));
}

export async function run(): Promise<void> {
    const extension = vscode.extensions.getExtension<{ ready(): Promise<void> }>('1dao.codeoutline');
    assert.ok(extension, 'packaged extension loaded');
    const api = await extension.activate();
    await api.ready();
    const defaults = extension.packageJSON.codeoutlineInstallationDefaults;
    if (defaults.platform === process.platform) {
        const config = vscode.workspace.getConfiguration('codeoutline');
        for (const key of ['serverPath', 'serverArguments', 'mode']) {
            assert.deepEqual(config.inspect(key)?.globalValue, defaults[key], 'first activation writes global ' + key);
        }
    }
    const folder = vscode.workspace.workspaceFolders![0].uri;
    const uri = vscode.Uri.joinPath(folder, 'send.lua');
    const target = vscode.Uri.joinPath(folder, 'receive.lua');
    const document = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(document);
    const definitions = () => vscode.commands.executeCommand<vscode.Location[]>(
        'vscode.executeDefinitionProvider', uri, new vscode.Position(1, 25));
    let locations = await eventually(definitions, value => value?.some(loc => loc.uri.toString() === target.toString()));
    assert.equal(locations.length, 1);
    assert.equal(locations[0].range.start.line, 0);
    const symbols = await vscode.commands.executeCommand<vscode.DocumentSymbol[]>('vscode.executeDocumentSymbolProvider', uri);
    assert.ok(symbols.some(symbol => symbol.name === 'sender'));
    const hover = await vscode.commands.executeCommand<vscode.Hover[]>(
        'vscode.executeHoverProvider', uri, new vscode.Position(2, 10));
    assert.ok(hover.length > 0, 'hover is registered');
    const refs = await vscode.commands.executeCommand<vscode.Location[]>(
        'vscode.executeReferenceProvider', uri, new vscode.Position(4, 10));
    assert.ok(refs.some(loc => loc.range.start.line === 2), 'references reach the call');
    const hierarchy = await vscode.commands.executeCommand<vscode.CallHierarchyItem[]>(
        'vscode.prepareCallHierarchy', uri, new vscode.Position(4, 10));
    assert.equal(hierarchy[0].name, 'helper');
    const incoming = await vscode.commands.executeCommand<vscode.CallHierarchyIncomingCall[]>(
        'vscode.provideIncomingCalls', hierarchy[0]);
    assert.equal(incoming[0].from.name, 'sender');
    const outgoing = await vscode.commands.executeCommand<vscode.CallHierarchyOutgoingCall[]>(
        'vscode.provideOutgoingCalls', incoming[0].from);
    assert.ok(outgoing.some(call => call.to.name === 'helper'));
    const completionUri = vscode.Uri.joinPath(folder, 'completion.lua');
    await vscode.workspace.openTextDocument(completionUri);
    const completions = await vscode.commands.executeCommand<vscode.CompletionList>(
        'vscode.executeCompletionItemProvider', completionUri, new vscode.Position(1, 4), '.');
    assert.ok(completions.items.some(item => item.label === 'width'), 'member completion is registered');
    const other = await eventually(() => vscode.commands.executeCommand<vscode.SymbolInformation[]>(
        'vscode.executeWorkspaceSymbolProvider', 'other_root'), value => value?.some(symbol => symbol.name === 'other_root'));
    assert.ok(other.some(symbol => symbol.location.uri.path.includes('second')));
    const edit = new vscode.WorkspaceEdit();
    edit.insert(target, new vscode.Position(0, 0), '\n\n');
    await vscode.workspace.openTextDocument(target);
    assert.equal(await vscode.workspace.applyEdit(edit), true);
    locations = await eventually(definitions, value => value?.[0]?.range.start.line === 2);
    assert.equal(locations[0].range.start.line, 2);
    // Source drafts are re-sent when a new server starts.
    await vscode.commands.executeCommand('codeoutline.restart');
    locations = await eventually(definitions, value => value?.[0]?.range.start.line === 2);
    assert.equal(locations[0].range.start.line, 2);
    const config = vscode.workspace.getConfiguration('codeoutline');
    await config.update('features', { definition: false }, vscode.ConfigurationTarget.Workspace);
    await new Promise(resolve => setTimeout(resolve, 300));
    await api.ready();
    assert.deepEqual(await definitions(), [], 'disabled capability removes its provider');
    await config.update('features', {}, vscode.ConfigurationTarget.Workspace);
    await new Promise(resolve => setTimeout(resolve, 300));
    await api.ready();
    await eventually(definitions, value => value?.length === 1);
    // A missing executable must not prevent recovery after correcting settings.
    const serverPath = config.get<string>('serverPath')!;
    await config.update('serverPath', serverPath + '.missing', vscode.ConfigurationTarget.Workspace);
    await new Promise(resolve => setTimeout(resolve, 300));
    await api.ready();
    assert.deepEqual(await definitions(), []);
    await config.update('serverPath', serverPath, vscode.ConfigurationTarget.Workspace);
    await new Promise(resolve => setTimeout(resolve, 300));
    await api.ready();
    await eventually(definitions, value => value?.length === 1);
    await vscode.commands.executeCommand('codeoutline.showLog');
    console.log('CODEOUTLINE_EDITOR_SMOKE_PASS: ' + vscode.env.appName);
}
