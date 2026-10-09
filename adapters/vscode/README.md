# CodeOutline for VS Code and Cursor

A thin language client for the Lua CodeOutline server. The same VSIX works in
VS Code and Cursor. The extension contains no indexer or server runtime.

## Install

The extension needs CodeOutline 0.2.0 or newer (`npm install -g codeoutline`),
which provides `codeoutline lsp --stdio`. It is not on a marketplace yet: build
`codeoutline.vsix` as below (CI also uploads it as the `codeoutline-vscode`
artifact) and install it with the editor's **Extensions: Install from VSIX**
command.

With the default settings, the extension uses the npm global install; no
server settings are needed. The client starts the server directly, without a
shell.

- **Linux and macOS**: the defaults (`codeoutline` with `lsp --stdio`) run the
  npm-installed command. If the editor does not see it on PATH, set
  `codeoutline.serverPath` to the output of `command -v codeoutline`.
- **Windows**: npm's `codeoutline.cmd` cannot start without a shell, so for the
  default command the extension looks for the npm install itself: the folder of
  `codeoutline.cmd` on PATH, then npm's default `%APPDATA%\npm`. It runs that
  install's launcher with the `node.exe` beside the shim or on PATH, or with the
  editor's own runtime when neither exists. If no install is found, the error
  message says so.
- **Native archive or source checkout**: run the runtime with the Lua command
  script (`bin/xnet` instead of `bin/xnet.exe` on Linux/macOS):

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

The server uses the newest installed CodeOutline version each time it starts;
a runtime started directly from an archive or checkout always runs that copy.

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

Each editor window runs an independent stdio server, as the Zed client does; it
does not connect to the shared MCP service. The extension does not download a
runtime, and the build commands publish nothing to a marketplace.

## Build

```sh
cd adapters/vscode
npm ci
npm run check
npm run test:unit
npm run package
```

Client dependencies are isolated here. `npm run package` bundles the client and
produces `codeoutline.vsix`. Indexing, LSP and navigation remain in Lua.
`npm run test:unit` covers how the server command is resolved, including the
Windows npm-install lookup, on any platform.

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
Chinese and space-containing package/workspace paths passed. With default
settings, the same smoke test passed against an npm global install in both
editors on Windows, with `node.exe` on PATH and with only the editor's runtime.
Linux CI runs the VS Code smoke test; local Linux/macOS and other editor versions
remain unverified.
