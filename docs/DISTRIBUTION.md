# Build and installation previews

The runtime and all command behavior are Lua/native. The npm launcher only finds
the matching platform package, starts the runtime, and forwards signals and status.
The native archive does not require Node, npm, Lua, a compiler, or Git at runtime.

## Stage a Windows preview

From the repository root, build the Windows runtime with a static CRT (copied to
`bin/`), then stage:

```powershell
.\tools\build-runtime.ps1
.\bin\xnet.exe tools/package.lua TARGET=win32-x64 OUTPUT=dist/win32-x64 LOG_STDERR=1
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
npm install --offline --ignore-scripts C:/build/codeoutline-0.1.0.tgz C:/build/codua-codeoutline-win32-x64-0.1.0.tgz
.\node_modules\.bin\codeoutline.cmd doctor --project C:/src/project
.\node_modules\.bin\codeoutline.cmd serve --stdio --project C:/src/project
```

`pnpm add --offline --ignore-scripts <entry-tarball> <platform-tarball>` uses the
same package layout. Once packages are published, optional dependencies select
the matching binary; keep them enabled. The launcher reports missing or mismatched
packages explicitly. Neither installation path uses postinstall downloads.

For native use, extract the `native/` directory and run `codeoutline.cmd` on
Windows, or `./codeoutline` on Unix. On Unix, mark `codeoutline` and
`bin/xnet` executable before packing or archiving. A package holds the runtime
as `bin/xnet` (`bin/xnet.exe`) and its HTTP codec as `lib/xhttp_codec.lua`.

## Platform validation and publication

Targets are Windows x64, Linux x64 (glibc 2.28+), and macOS universal
(`darwin-universal`: Apple Silicon and Intel, macOS 11+). Only a platform with
a successful native build and installed-package smoke test is validated.

On macOS, `tools/build-runtime.sh` builds an arm64 and an x86_64 slice with
`MACOSX_DEPLOYMENT_TARGET=11.0` and merges them with `lipo`; clang would
otherwise require the build machine's own macOS version. CI checks both slices
and their minimum version, and runs the specs natively and under Rosetta.
`XNET_MAC_ARCHS=arm64` builds a single slice for local work. CI builds the Linux runtime in the `manylinux_2_28` container
(AlmaLinux 8) and fails if the binary needs a newer glibc symbol, so one package
covers RHEL/Rocky/Alma 8 and 9, CentOS Stream 9, Debian 10+, and Ubuntu 20.04+;
the specs also run inside AlmaLinux 8 and CentOS Stream 9. The npm launcher
rejects older glibc with a clear message. A Linux runtime built locally with
`tools/build-runtime.sh` targets the build host's glibc instead. Alpine/musl
and other architectures are unsupported.

GBK source decoding on Linux uses glibc's iconv module, which minimal EL8/EL9
installs and container images omit (`dnf install glibc-gconv-extra`). Without it
UTF-8 projects work normally, `doctor` reports the `gbk` check as unavailable, and
a query touching a GBK file fails with that installation hint. CI runs the specs
on AlmaLinux 8 as shipped (GBK cases must skip) and on CentOS Stream 9 with
`glibc-gconv-extra` (GBK cases must run).

The Windows runtime is x64, links the C runtime statically, and loads only
system DLLs (`kernel32`, `advapi32`, `ws2_32`, `bcrypt`), so no Visual C++
redistributable is needed. Its newest Windows API is
`GetSystemTimePreciseAsFileTime`, which makes Windows 8 / Server 2012 the floor
for the native archive; the npm route follows Node's own support (Node 20+,
effectively Windows 10 / Server 2016 or newer). Windows 11 on ARM64 installs
and runs the x64 package under emulation; Windows 10 on ARM cannot emulate x64.
The binary is not code-signed, so a downloaded archive may trigger SmartScreen
or be blocked by application allow-listing.

Staged packages keep `private: true`, which blocks `npm publish`, unless the
packaging tool runs with `RELEASE=1`. A release build refuses to run from a
checkout with tracked changes, from a pre-release version such as `-dev`, or
when `TAG` does not equal `v<version>`. CI stages release packages only for tag
pushes (`RELEASE=1 TAG=<tag>`), so pushing `v0.1.0` from a commit whose
`scripts/codeoutline/version.lua` says `0.1.0` yields the publishable artifacts;
branch pushes keep producing private previews. Publish the platform packages
first, then the entry package at the identical version.

Platform packages are published under the `@codua` scope
(`@codua/codeoutline-win32-x64`, `-linux-x64`, `-darwin-universal`; `npm pack`
names their tarballs `codua-codeoutline-<target>-<version>.tgz`). npm's spam
filter rejects new unscoped `<name>-<platform>` names, and a scope keeps
look-alike packages out. Users still install the unscoped entry package
`codeoutline`. Every package declares `publishConfig.access = public`.

The workflow in `.github/workflows/ci.yml` builds and tests all three targets and
uploads preview tarballs, native archives, and SHA-256 checksums. Adding the
workflow does not mean its remote runs have passed. Windows npm launchers forward
console signals; forcefully killing the Node process alone cannot forward a
signal. For supervised HTTP services on Windows, use the native launcher or stop
the process tree. Closing MCP stdin causes the native stdio service to exit.

## Signed self-updates

Starting with 0.1.3, npm and native launchers can run signed versions stored in
`~/.codeoutline/updates` (the user profile on Windows). npm remains the initial
installation and recovery version. An older npm installation needs one npm upgrade
to acquire this updater. Updating does not change npm's recorded package version;
`codeoutline --version` reports the version actually running.

```sh
codeoutline update --check
codeoutline update
codeoutline update --rollback
```

`serve` checks for updates before starting. A verified update applies to that new
process; existing services keep running. Failed checks retain the local version.
Other commands select a verified installed version without requesting the network.
Set `CODEOUTLINE_AUTO_UPDATE=0` to disable automatic checks. Manual update still works.
Rollback switches between the two installed versions; after the first update it
returns to the initial installation. Accepted sequence numbers are retained, so a
rolled-back release is not immediately reinstalled by automatic checks.

The default endpoint is `https://43.133.255.193:51215`, project `codeoutline`,
channel `stable`. Packages pin the signing public key and the server's TLS CA in
`keys/`. Private signing keys stay outside the repository and update server.
`CODEOUTLINE_UPDATE_URL`, `CODEOUTLINE_UPDATE_PROJECT`,
`CODEOUTLINE_UPDATE_CHANNEL`, `CODEOUTLINE_UPDATE_DIR`,
`CODEOUTLINE_UPDATE_PUBLIC_KEY`, `CODEOUTLINE_UPDATE_CA`, and
`CODEOUTLINE_UPDATE_TARGET` override these settings for testing or private deployments.
Treat these overrides and the initial installation as trusted configuration.

To publish, stage a fresh native package for each target with
`UPDATE_SEQUENCE=N`; N must increase for every release (the 0.1.3 baseline is 3).
Use XUpgate's `tools/release.py` with the same version and sequence,
`--entry scripts/codeoutline/command.lua`, and
`--runtime bin/xnet.exe` for Windows or `--runtime bin/xnet` otherwise.
Sign the native directory with the project's offline private key, upload the signed
artifact in XUpgate, then publish its version to the desired channel. The updater
checks signatures, file hashes, platform, version, sequence and runtime health
before activating the directory. CI must produce each platform runtime; a Windows
package cannot update a Linux or macOS installation.

The opt-in deployed integration test needs Python, OpenSSL, a staged Windows
package, and the sibling XUpgate release builder:

```powershell
python tests/update-deployed.py --stage .update-test/final --credential-file C:/private/xupgate-admin.env
```

The credential file contains `ADMIN_TOKEN=...`. The test creates a separate project,
exercises manual and automatic updates, rollback and tamper rejection, and disables
the project on exit. It never publishes to the production CodeOutline channel.
