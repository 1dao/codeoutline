import * as path from 'path';
import { existsSync } from 'fs';

export interface Launch {
    command: string;
    args: string[];
    env?: Record<string, string>;
}

export interface Host {
    platform: NodeJS.Platform;
    env: NodeJS.ProcessEnv;
    exists(file: string): boolean;
    execPath: string;
}

const currentHost: Host = { platform: process.platform, env: process.env, exists: existsSync, execPath: process.execPath };

// Language clients spawn the server without a shell, and Windows cannot run
// npm's codeoutline.cmd that way. For the default command, find the global npm
// install that shim belongs to and run its launcher with Node, as the shim
// does: node.exe beside the shim, then on PATH, then the editor's own runtime
// in Node mode. The launcher still selects installed updates. Elsewhere, and
// for any other configured command, the command runs as given.
export function resolveServer(command: string, args: string[], host: Host = currentHost): Launch {
    if (host.platform !== 'win32' || command !== 'codeoutline') return { command, args };
    const win = path.win32;
    const dirs = (host.env.PATH ?? host.env.Path ?? '').split(';')
        .map(dir => dir.trim().replace(/^"(.*)"$/, '$1')).filter(Boolean);
    // npm's default global prefix, in case the editor's PATH lacks it.
    if (host.env.APPDATA) dirs.push(win.join(host.env.APPDATA, 'npm'));
    for (const dir of dirs) {
        const launcher = win.join(dir, 'node_modules', 'codeoutline', 'launcher', 'codeoutline.cjs');
        if (!host.exists(win.join(dir, 'codeoutline.cmd')) || !host.exists(launcher)) continue;
        const node = [dir, ...dirs].map(candidate => win.join(candidate, 'node.exe')).find(host.exists);
        if (node) return { command: node, args: [launcher, ...args] };
        return { command: host.execPath, args: [launcher, ...args], env: { ELECTRON_RUN_AS_NODE: '1' } };
    }
    return { command, args };
}

export function missingServerHint(launch: Launch, host: Pick<Host, 'platform'> = currentHost): string | undefined {
    if (host.platform !== 'win32' || launch.command !== 'codeoutline') return undefined;
    return 'CodeOutline was not found. Install it with "npm install -g codeoutline" (0.2.0 or newer), '
        + 'or set codeoutline.serverPath to a CodeOutline runtime.';
}
