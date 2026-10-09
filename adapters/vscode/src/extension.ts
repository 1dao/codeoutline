import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';
import { missingServerHint, resolveServer } from './server';

const featureNames = ['documentSymbol', 'workspaceSymbol', 'definition', 'hover', 'references', 'callHierarchy', 'completion', 'signatureHelp'] as const;
let client: LanguageClient | undefined;
let output: vscode.OutputChannel;
let pending: Promise<void> = Promise.resolve();
let disposed = false;

async function restart(): Promise<void> {
    const previous = client;
    client = undefined;
    if (previous) await previous.dispose();
    const config = vscode.workspace.getConfiguration('codeoutline');
    if (disposed || !vscode.workspace.isTrusted || !vscode.workspace.workspaceFolders?.length
        || !config.get<boolean>('enabled', true)) return;
    const languages = config.get<string[]>('languages', []);
    if (!languages.length) return;
    const command = config.get<string>('serverPath', 'codeoutline').trim();
    if (!command) throw new Error('Set codeoutline.serverPath to the CodeOutline executable.');
    const features: Record<string, boolean> = {};
    const full = config.get<string>('mode') === 'navigation';
    for (const name of featureNames) features[name] = full || name === 'workspaceSymbol';
    Object.assign(features, config.get<Record<string, boolean>>('features', {}));
    const launch = resolveServer(command, config.get<string[]>('serverArguments', ['lsp', '--stdio']));
    const hint = missingServerHint(launch);
    if (hint) throw new Error(hint);
    const server: ServerOptions = {
        command: launch.command, args: launch.args,
        options: { env: { ...process.env, ...config.get<Record<string, string>>('serverEnvironment', {}), ...launch.env } }
    };
    const options: LanguageClientOptions = {
        documentSelector: languages.map(language => ({ scheme: 'file', language })),
        initializationOptions: { features, includePaths: config.get<string[]>('includePaths', []) },
        outputChannel: output,
        markdown: { isTrusted: false }
    };
    const next = new LanguageClient('codeoutline', 'CodeOutline', server, options);
    client = next;
    try {
        await next.start();
        output.appendLine('CodeOutline is ready. Mode: ' + config.get<string>('mode', 'auxiliary'));
    } catch (error) {
        client = undefined;
        // A failed spawn leaves languageclient in startFailed, where dispose may
        // throw too. Preserve the launch error so the user sees the real cause.
        try { await next.dispose(); } catch { /* launch error takes precedence */ }
        throw error;
    }
}

function scheduleRestart(): Promise<void> {
    pending = pending.then(restart).catch(async (error: unknown) => {
        const detail = error instanceof Error ? error.message : String(error);
        output.appendLine('CodeOutline failed to start: ' + detail);
        void vscode.window.showErrorMessage(
            'CodeOutline could not start. Check serverPath/serverArguments and use a server with LSP support. ' + detail,
            'Show Log').then(action => { if (action) output.show(); });
    });
    return pending;
}

export async function activate(context: vscode.ExtensionContext): Promise<{ ready: () => Promise<void> }> {
    disposed = false;
    output = vscode.window.createOutputChannel('CodeOutline');
    context.subscriptions.push(output);
    context.subscriptions.push(
        vscode.commands.registerCommand('codeoutline.restart', scheduleRestart),
        vscode.commands.registerCommand('codeoutline.showLog', () => output.show()),
        vscode.workspace.onDidChangeConfiguration(event => {
            if (event.affectsConfiguration('codeoutline')) void scheduleRestart();
        }),
        vscode.workspace.onDidChangeWorkspaceFolders(() => { void scheduleRestart(); }));
    void scheduleRestart();
    return { ready: () => pending };
}

export async function deactivate(): Promise<void> {
    disposed = true;
    await pending;
    if (client) await client.dispose();
    client = undefined;
}
