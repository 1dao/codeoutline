# Build and installation previews

The runtime and all command behavior are Lua/native. The npm launcher only finds
the matching platform package, starts the runtime, and forwards signals and status.
The native archive does not require Node, npm, Lua, a compiler, or Git at runtime.

## Stage a Windows preview

From the repository root, build the Windows runtime with a static CRT, then stage:

```powershell
.\tools\build-runtime.ps1
.\xnet2lua\bin\xnet.exe tools/package.lua TARGET=win32-x64 OUTPUT=dist/win32-x64 LOG_STDERR=1
npm pack ./dist/win32-x64/native --pack-destination ./dist
npm pack ./dist/win32-x64/npm --pack-destination ./dist
```

Choose a fresh output directory for each build to avoid stale files. Each native
package contains `build-info.json` with source commits and SHA-256 file hashes.
The root development package stays private; only generated packages are staged.
`PLAN.md`, `AGENTS.md`, tests, caches, and development dependencies are excluded.

Install both generated tarballs in a fresh directory (use absolute paths):

```powershell
npm init -y
npm install --offline --ignore-scripts C:/build/codeoutline-0.1.0-dev.0.tgz C:/build/codeoutline-win32-x64-0.1.0-dev.0.tgz
.\node_modules\.bin\codeoutline.cmd doctor --project C:/src/project
.\node_modules\.bin\codeoutline.cmd serve --stdio --project C:/src/project
```

`pnpm add --offline --ignore-scripts <entry-tarball> <platform-tarball>` uses the
same package layout. Once packages are published, optional dependencies select
the matching binary; keep them enabled. The launcher reports missing or mismatched
packages explicitly. Neither installation path uses postinstall downloads.

For native use, extract the `native/` directory and run `codeoutline.cmd` on
Windows, or `./codeoutline` on Unix. On Unix, mark `codeoutline` and
`xnet2lua/bin/xnet` executable before packing or archiving.

## Platform validation and publication

Targets are Windows x64, Linux x64 (glibc), and macOS arm64. Only a platform
with a successful native build and installed-package smoke test is validated.
Linux builds currently target the CI host's glibc, not an older compatibility
baseline. Alpine/musl and other architectures are unsupported.

Preview packages intentionally block `npm publish` using `private: true`.
Before release: review THIRD_PARTY.md against build options, choose/verify public package names and
account permissions, align version numbers, validate each platform, and remove
the publication guard in the packaging tool. Publish platform packages first,
then the entry package at the identical version. Generate archive checksums.
Public publishing and repository pushes require an explicit release request.

The workflow in `.github/workflows/ci.yml` builds and tests all three targets and
uploads preview tarballs, native archives, and SHA-256 checksums. Adding the
workflow does not mean its remote runs have passed. Windows npm launchers forward
console signals; forcefully killing the Node process alone cannot forward a
signal. For supervised HTTP services on Windows, use the native launcher or stop
the process tree. Closing MCP stdin causes the native stdio service to exit.
