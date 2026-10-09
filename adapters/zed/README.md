# CodeOutline for Zed

A thin Zed client: it locates and launches `codeoutline lsp --stdio`. Indexing,
protocol handling and resolution stay in the Lua server.

Requires Zed with LSP call hierarchy support (1.19.2 or later) for the call
hierarchy commands.

The server needs CodeOutline 0.2.0 or newer (`npm install -g codeoutline`). The
extension is not in Zed's extension registry yet; install it as a dev extension
(see Development).

## Binary lookup

1. `lsp.codeoutline.binary` in Zed settings (`path`, optional `arguments` and `env`;
   arguments default to `["lsp", "--stdio"]`).
2. `codeoutline` on PATH.

On Linux and macOS the npm-installed `codeoutline` is found on PATH. On Windows,
npm installs `codeoutline.cmd`, which is not a native executable; run the npm
launcher with Node instead (`npm root -g` prints the global folder):

```json
"lsp": {
  "codeoutline": {
    "binary": {
      "path": "node",
      "arguments": ["C:/Users/<you>/AppData/Roaming/npm/node_modules/codeoutline/launcher/codeoutline.cjs",
        "lsp", "--stdio"]
    }
  }
}
```

For a native archive or a source checkout, run the runtime with the Lua command
script (`bin/xnet` on Linux/macOS):

```json
"lsp": {
  "codeoutline": {
    "binary": {
      "path": "C:/source/ops/codeoutline/bin/xnet.exe",
      "arguments": ["C:/source/ops/codeoutline/scripts/codeoutline/command.lua",
        "LOG_STDERR=1", "LOG_FILE=0", "lsp", "--stdio"]
    }
  }
}
```

## Beside other language servers

Zed runs every enabled server for a language. To compare CodeOutline alone, order or
exclude servers per language, for example
`"languages": { "C": { "language_servers": ["codeoutline", "!clangd", "..."] } }`.
To keep another server for definitions and hover, disable those features here:

```json
"lsp": { "codeoutline": { "initialization_options": {
  "features": { "definition": false, "hover": false } } } }
```

Features: `documentSymbol`, `workspaceSymbol`, `definition`, `hover`, `signatureHelp`,
`references`, `callHierarchy`, `completion`.

`#include <...>` headers outside the project are found through the compiler or
Windows Kits/MSVC; add other directories with
`"initialization_options": { "includePaths": ["C:/sdk/include"] }`.

## Development

Install Rust through rustup, then in Zed run `zed: install dev extension` and select
this directory. Zed builds the WebAssembly module itself. Check `zed: open log` for
server start errors.

Without Rust on the editor machine, build anywhere (the module is platform
independent) and install the result by hand:

```sh
rustup target add wasm32-wasip2
cargo build --release --target wasm32-wasip2   # emits a WASM component
```

Copy `target/wasm32-wasip2/release/codeoutline_zed.wasm` as `extension.wasm`, next to
a copy of `extension.toml` with `[lib]` `kind = "Rust"` and `version = "0.7.0"` (the
`zed_extension_api` version), into Zed's `extensions/installed/codeoutline`
directory, then restart Zed.
