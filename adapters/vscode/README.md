# CodeOutline for VS Code and Cursor

A thin language client for the Lua CodeOutline server. The same VSIX works in
VS Code and Cursor. The extension contains no indexer or server runtime.

## Local preview

Install `codeoutline.vsix` with the editor's **Extensions: Install from VSIX**
command. This Windows source preview includes the following local settings in
its manifest's `codeoutlineInstallationDefaults`. On first activation after
installation, it writes them automatically to the editor's global user settings.
It applies them once per editor profile; later restarts retain your edits.
The preset targets `C:/source/ops/codeoutline` and is not a portable runtime
installation. The VSIX installer itself does not run extension code: open the
editor after installing to apply the settings.

Released CodeOutline 0.1.9 has no LSP command yet. For another checkout or platform,
use a built source checkout in your user settings:

```json
{
  "codeoutline.serverPath": "C:/source/ops/codeoutline/bin/xnet.exe",
  "codeoutline.serverArguments": [
    "C:/source/ops/codeoutline/scripts/codeoutline/command.lua",
    "LOG_STDERR=1", "LOG_FILE=0", "lsp", "--stdio"
  ],
  "codeoutline.mode": "navigation"
}
```

On Linux/macOS use the absolute `bin/xnet` path. A compatible `codeoutline`
command on PATH works with the default arguments. Commands are executed directly,
without a shell. Windows npm `.cmd` launchers are not native executables: use
the native runtime and its Lua command script as above.

The default `auxiliary` mode enables workspace symbols only, to avoid adding
duplicate navigation providers beside an existing language server. Use
`navigation` to enable symbols, definition, hover, references, call hierarchy
and completion. Override individual capabilities with `codeoutline.features`,
for example `{ "definition": true }` to use project `.codeoutline.json` rules
in auxiliary mode. Existing language servers are never disabled automatically.

Use `codeoutline.languages` to select language IDs and `codeoutline.includePaths`
to add C/C++ system header directories. Config changes restart the server;
project definition rules are read live by the server. Multiple workspace roots
share one client/server process and each root keeps its own rules. Local file
documents are supported; unsaved changes are synchronized in full.

**CodeOutline: Restart Language Server** reloads server code after changes.
**CodeOutline: Show Language Server Log** opens the output channel; use
`codeoutline.trace.server` for protocol tracing. Opening an untrusted workspace
does not launch the server.

This preview uses an independent stdio process, matching the current Zed client.
Shared MCP/TCP startup and automatic runtime downloads require a compatible
server release and are not implemented in this preview. No marketplace publish
is performed by the build commands.

## Build

```sh
cd adapters/vscode
npm ci
npm run check
npm run package
```

Client dependencies are isolated here. `npm run package` bundles the client and
produces `codeoutline.vsix`. Indexing, LSP and navigation remain in Lua.

Build tooling requires Node.js 22 or newer. To test the packaged VSIX in an
isolated editor profile (without changing your settings or installed extensions):

```powershell
$env:CODEOUTLINE_EDITOR_PATH = 'C:/software/Microsoft VS Code/Code.exe'
npm run test:editor
$env:CODEOUTLINE_EDITOR_PATH = 'C:/software/cursor/Cursor.exe'
npm run test:editor
Remove-Item Env:CODEOUTLINE_EDITOR_PATH
```

Without that variable, the test runner downloads VS Code. The smoke test needs
the repository runtime in `bin/` and Python for extracting the VSIX. It checks
two workspace roots, custom definition rules, document symbols, unsaved edits,
restart and capability changes through actual editor provider commands.

The packaged extension was verified on Windows in VS Code 1.125.1 and Cursor
2.3.34, including hover, references, incoming/outgoing calls and member completion.
Chinese and space-containing package/workspace paths passed. Linux CI runs the
VS Code smoke test; local Linux/macOS and other editor versions remain unverified.
