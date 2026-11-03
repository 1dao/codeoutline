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

Installed self-updates now use readable version directories, for example
`~/.codeoutline/updates/codeoutline/versions/0.3.1/files/`. npm's own package
installation directory is unchanged. Local `current.json` uses schema 2:
`current`/`previous` hold version numbers and their separate `currentIdentity`/
`previousIdentity` fields retain the signed manifest's SHA-256 identity.
Signatures, package/file checksums and anti-replay sequences remain enforced.
An existing version directory cannot be overwritten with a different signed
release; publish a new version number instead. Process leases and pruning use
version numbers too. Transport/package hashes and the temporary runtime cache
remain internal integrity identifiers.

When a new bootstrap finds former schema 1 state, it runs the initial npm/native
installation instead of activating hash-named cached code. It preserves the
highest accepted update sequence; the next successful update writes schema 2.
Startup does not rewrite the old state or remove old files and leases that
running processes may still use. Upgrade the initial installation with
`npm install -g codeoutline --foreground-scripts`; clearing the update cache is
not required. After stopping old processes, obsolete hash-named directories can
be removed manually from `~/.codeoutline/updates/codeoutline/versions`.
Keep project indexes and agent/editor configuration. Reinstalling registers
and starts the shared service again.
Newly generated signed releases require updater 3, so old updaters reject them
instead of installing a release with an incompatible on-disk state format.
Before uploading such a release, the XUpgate server's manifest validator must
also accept `minUpdater = 3` for full and script packages. A server still using
the updater-2 validator will reject these uploads; updating this repository does
not update the separately deployed XUpgate server.

```sh
codeoutline update --check
codeoutline update
```

Every command starts the newest verified installed version without requesting the
network. `serve` checks for updates in a background thread at startup and then
every hour while it runs, so an unreachable update server never delays startup or
requests; failed checks are reported on stderr. After installing an update, a
stdio service exits as soon as no request is in flight: MCP clients start it again
on the next request, now running the new version. The background service
(`codeoutline daemon`) likewise waits until idle, closes its port, starts the new
version detached from itself and exits, so exactly one service process remains.
A `serve --http` service keeps running and uses the update at its next start.
`CODEOUTLINE_EXIT_ON_UPDATE=1` or `0` overrides the stdio and `serve --http` defaults.
Set `CODEOUTLINE_AUTO_UPDATE=0` to disable automatic checks. Manual update still works.
Only the active update is kept. After installing, the updater deletes other
installed versions and the runtime cache, except versions a running process
still uses: each process started from an installed update holds a lease for as
long as it runs. On Windows the process keeps its lease file open; elsewhere the
file records its PID. Versions before 0.1.7 hold no lease, so they are
deleted only 7 days after cleanup first finds them inactive. There is no local
rollback: to return to the npm (or native) installation, delete
`~/.codeoutline/updates` and set `CODEOUTLINE_AUTO_UPDATE=0` so `serve` does not
reinstall the latest release.

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
Use `tools/update-release.lua` for a script-only change: it reuses the previous
platform runtimes, replaces Lua scripts and native launchers, and with `KIND=scripts`
produces signed script bundles for all three platforms. Runtime binaries, native
libraries and their license files are omitted from downloads; their hashes are
signed as runtime references and checked before copying them from a compatible
local installation. Upload these as drafts before publishing
the version to the desired channel. The updater
checks signatures, file hashes, platform, version, sequence and runtime health
before activating the directory. CI must produce each platform runtime; a Windows
package cannot update a Linux or macOS installation.

### Background service and login entry

Release native packages also include `editors/codeoutline.vsix` and the prebuilt
Zed WASM client under `editors/zed/`. CI builds both clients before packaging;
for local release staging, run `pwsh tools/build-editor-assets.ps1` first
(requires Node.js and Rust with `wasm32-wasip2`). `tools/package.lua` reads
`dist/editor-assets`, or `EDITOR_ASSETS=PATH`, and refuses release staging if any
client asset is missing. Preview builds can omit clients.

`codeoutline editors --list` detects editor CLIs on PATH and common installation
locations without changing anything. `codeoutline editors` offers a selection
when started through the npm launcher in a terminal. Use `--editors all`,
`--editors none`, or comma-separated `vscode,cursor,zed` for unattended use.
VS Code and Cursor receive the bundled VSIX through their CLI; Zed receives the
bundled manifest and WASM in its default `extensions/installed/codeoutline`
directory and needs a restart. Custom Zed user-data directories are not detected.
No editor settings are rewritten. Native launchers can use `--editors` directly.

A global npm installation runs `codeoutline install --npm` as its `postinstall`
script; local installs, `npx` and `--ignore-scripts` skip it, and it never fails the
installation. For interactive global npm setup, use `npm install -g codeoutline
--foreground-scripts`. The launcher only prompts with inherited terminal input
and output. It never reopens console devices while npm owns terminal input;
a valid console handle alone does not guarantee usable interactive input.
Default background lifecycle scripts and CI use noninteractive setup.
It first offers AI-tool MCP registration, then editor LSP installation. Each detected application gets
its own `[Y/n]` confirmation: Enter or `y`/`yes` installs it; `n`/`no` skips only
that application. EOF skips remaining applications. Interactive removal instead
defaults to `[y/N]`. Explicit target/editor IDs remain supported and bypass the
questions. When no AI tools are
detected, that step is skipped without consuming an answer. After the selections,
the same postinstall registers and starts the service; no second install command
is needed. Existing applications may need a restart to load the integrations.
Without a terminal, global npm setup installs all detected AI/editor integrations
automatically, so `npm install -g codeoutline` completes setup on its own.
Explicit `CODEOUTLINE_AGENTS` and `CODEOUTLINE_EDITORS` selections take priority;
set both to `none` to opt out of integration installation. Local npm installs
and `--ignore-scripts` still skip setup. `CODEOUTLINE_EDITORS=all|none|LIST`
selects clients explicitly, independently of `CODEOUTLINE_AUTOSTART=0`.
Agent MCP registration is a separate selection in that same postinstall:
`CODEOUTLINE_AGENTS=auto|all|none|IDS`, or an interactive choice when a terminal
is available. Ordinary unattended global npm installs select detected agents;
`codeoutline install --yes` detects agents and writes user-level MCP entries.
`--target` selects explicit IDs, `--location local --project PATH` selects
project scope where supported, and `--port` is shared by registration and daemon
startup. `codeoutline agents` provides the same registration without service
changes; `--list` and `--print ID` are read-only. `agents --target IDS --remove`
removes only the CodeOutline MCP entry. `codeoutline uninstall` removes detected
user-level MCP entries and editor clients along with the service; use
`--service-only` to preserve integrations, or `--project PATH` to also remove
project-scoped MCP entries. Unrelated configuration and original backups remain.

The installer writes loopback HTTP entries for Claude Code, Cursor, Codex,
Gemini CLI, OpenCode, Hermes, Kiro, Antigravity and Copilot (VS Code, CLI and
JetBrains). These all connect to the shared service. It does not change agent
instructions or tool-approval policy. JSONC comments and unrelated settings are
preserved; edits use temporary files and atomic replacement, and the original
nonempty config is backed up once as `<config>.codeoutline.bak`. It plans all
selected edits first, rejecting malformed configs and conflicting CodeOutline
entries before any config is changed. `--force` allows replacing a different
existing CodeOutline entry. Ambiguous inline/dotted TOML and flow-style YAML
MCP mappings require manual configuration. Generated entries assume an
unauthenticated local service; custom authentication must be configured manually.

`install` registers a login entry for the installation it belongs to
(launchers pass it as `CODEOUTLINE_INITIAL`; installed updates are deleted when
unused, the initial installation is not), stops a running service and starts
`codeoutline daemon` detached. Each login entry runs the daemon once per login:

- Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\CodeOutline`, run
  under `conhost.exe --headless` so the console runtime shows no window.
- macOS: `~/Library/LaunchAgents/io.github.1dao.codeoutline.plist` with
  `AbandonProcessGroup`, so launchd keeps the replacement the daemon starts.
- Linux: `~/.config/systemd/user/codeoutline.service` with `KillMode=process`.
  Without a systemd user manager (WSL, containers) `install` reports that the
  entry is missing; start `codeoutline daemon` at login another way.

The daemon starts the newest installed version (an installed update, or the
initial installation when an npm upgrade made it newer) and exits if a service
already answers on its port: Windows lets a second process bind a port the runtime
listens on. `codeoutline uninstall` removes the entry and asks the daemon to exit
by creating `~/.codeoutline/service-<port>.stop`, which it checks every second.
It then removes user-level Agent registrations and default-profile VS Code/Cursor
extensions, plus Zed's installed extension, work/staging directories and generated
registry entry. Each cleanup failure is reported and makes the command fail;
other integrations are still attempted. Reload/close editors to release active
LSP processes. `--purge` additionally removes the default `~/.codeoutline` state
directory only after all cleanup steps succeed; linked state/extension directories
are rejected. Custom data directories, other editor profiles, remote extensions
and project scopes not named with `--project` require separate cleanup.
Run this command before `npm uninstall -g codeoutline`: npm 7+ has no uninstall
lifecycle hooks, so a package cannot attach automatic cleanup to that command.
Services from 0.1.7 and earlier ignore that file; they exit after installing an
update. `CODEOUTLINE_AUTOSTART=0` skips the login entry; with `--npm` it also skips
starting the service.

### Make an all-platform script update with xnet

For automatic releases, commit the feature changes and the release tools first,
then run one command from a clean `main` checkout:

```powershell
.\bin\xnet.exe tools/release.lua LOG_STDERR=1 LOG_FILE=0
```

The tool prompts for a new version and rejects versions already present in local
or remote tags, any XUpgate release (including drafts), npm, or the output folder.
It assigns the next unused update sequence, runs local tests, updates the source
version and sequence files, commits only those files as `release: <version>`, and
pushes the commit and tag atomically. Full mode waits for the tagged GitHub Actions
CI, downloads and verifies artifacts for that exact commit, signs and uploads all
three XUpgate drafts, publishes the three npm platform packages then the entry
package, creates the GitHub release, and finally switches XUpgate stable.

Full mode requires Git, Node/npm, OpenSSL and GitHub CLI (`gh`) on PATH, a signed-in
GitHub account (`gh auth login`), and npm credentials usable for publishing. npm
may still ask for account-required authentication; configure appropriate publishing
credentials before attempting unattended releases. Private key and administrator
credential defaults match the local development setup; `KEY`, `CREDENTIAL_FILE`,
`URL`, `CA_FILE`, and `RELEASE_DIR` override them.

Pass `PROXY=socks5://127.0.0.1:1080` (or set `CODEOUTLINE_RELEASE_PROXY`) when
GitHub access requires a proxy. The tool uses SOCKS remote DNS (`socks5h`) and
applies the proxy to Git, GitHub CLI, npm, and XUpgate requests, including child
upload/publish commands. It changes neither global Git/npm configuration nor the
calling terminal's proxy environment.

For script changes that only need XUpgate, use `MODE=update`. Unless `BASE` is
explicitly provided, it selects the newest locally available, published full CI
release with all three platforms and the current runtime commit. It reuses baseline
runtimes, checks that their runtime commit matches the current submodule, and does
not require GitHub CLI or npm publishing authentication:

```powershell
.\bin\xnet.exe tools/release.lua MODE=update LOG_STDERR=1 LOG_FILE=0
```

Every mode first runs the Lua specs (`codeoutline_spec` with the native and pure
Lua scanners, `stability_spec`, `update_spec`). Runtime and full modes then run
the Node SDK and package tests; update mode skips them unless `NODE_TESTS=1`,
because script bundles ship no npm launcher.

Update mode commits the release version locally, builds the signed script
bundles, installs this machine's bundle through the real updater (including its
health check) and runs `explore` on a sample project with it. Only then does it
tag, push, upload and publish. If any of these local steps fail, the release
commit and output directory are removed; nothing is pushed or uploaded, and the
same version can be retried. CI runs on the pushed tag, but the local tool does
not wait for it or publish its npm/GitHub artifacts. npm read access remains
necessary for duplicate-version checks. The initial npm launcher is only
upgraded by full npm publication, not an XUpgate script bundle.

For native runtime/executable updates without publishing npm, use `MODE=runtime`:

```powershell
.\bin\xnet.exe tools/release.lua MODE=runtime PROXY=socks5://127.0.0.1:1080 LOG_STDERR=1 LOG_FILE=0
```

This waits for all-platform CI and publishes complete signed XUpgate bundles,
including the new executables. It requires GitHub CLI but does not publish npm or
create a GitHub Release. `MODE=full` retains the complete npm/GitHub/XUpgate workflow.
Both full bundles and script bundles install into immutable version directories;
active executables are never overwritten. `serve` installs in the background and
the next launch selects the verified scripts and matching executable.

New full and script bundles require protocol updater version 3 and use local
state schema 2 with version-number directories. Older initial bootstraps safely
reject these bundles. Upgrade the npm or native initial installation as described above;
an in-place self-update does not replace the initial bootstrap. After reinstalling,
both script and executable updates can be delivered solely through XUpgate.
A script bundle whose exact runtime hashes
are unavailable locally is rejected, preserving the active version; distribute
a compatible full update first. When a script package includes a signed reference
to that published full release, clients missing its runtime automatically download
and verify the referenced full package, cache only the required runtime files,
and activate the new script version after its health check. This does not activate
the intermediate full version. The server rejects references to unpublished full
releases; withdrawals and disabled projects are respected. If no full artifact is
available locally when building a manual script bundle, only local runtime reuse
is possible and missing compatible runtimes still cause a safe rejection.

Use `DRY_RUN=1` to exercise prompting and remote version checks without changing
files, commits, tags or publications. An explicit `VERSION` is also accepted; a
duplicate then stops instead of prompting. The default output is `C:/release/<version>`
on Windows and `dist/releases/<version>` elsewhere. Signed bundles are under
`<output>/bundles/xupgate`. Full mode stores the downloaded CI artifacts under
`<output>/ci`. `release-state.json` records the chosen version, sequence and commit.

Failures stop the release. Already-created commits/tags, immutable uploads and npm
versions are retained rather than reverted. Inspect the error before retrying;
after a partial release, use the recorded version and existing artifacts with the
individual upload/publish commands instead of rebuilding that version.

If a full release stops after CI downloads and signed bundles have been created,
resume the same artifacts with `RESUME=<version>`:

```powershell
.\bin\xnet.exe tools/release.lua RESUME=0.1.4 PROXY=socks5://127.0.0.1:1080 LOG_STDERR=1 LOG_FILE=0
```

Resume verifies the recorded commit, local/remote tag, CI checksums, signatures and
remote draft hashes. It does not create a new version, commit, tag or build.
Published npm packages are skipped only when their registry shasum matches the
local tarball. npm publishing inherits the terminal so required authentication
prompts remain usable. Fix npm publishing authentication before retrying; login
alone may not meet the package's 2FA policy. `DRY_RUN=1` validates resume without
publishing anything. Earlier failures that lack complete CI artifacts or bundles
still need the individual repair commands.

Run from the repository root. `BASE` contains the extracted CI packages under
`codeoutline-<target>/native/package`. `OUTPUT` must be a new directory.
Python is not required. OpenSSL must be on PATH for offline private-key signing;
the tool verifies each signature against the bundled public key before saving it.
It verifies the base packages' recorded hashes and preserves their runtime commits.
Manual bundles record the real source commit/dirty state and are not marked as CI
release builds. Review and test the staged files before uploading.

```powershell
.\bin\xnet.exe tools/update-release.lua ACTION=build KIND=scripts BASE=C:/release/0.1.3 OUTPUT=C:/release/0.1.5 VERSION=0.1.5 SEQUENCE=5 KEY=C:/private/codeoutline.private.pem LOG_STDERR=1 LOG_FILE=0
```

Native directories are written under `OUTPUT/native/<target>`. Uploadable signed
JSON files are under `OUTPUT/xupgate/<target>.json`. The private key is never
included. The version argument sets the staged version without editing the source
checkout; npm's Node launcher is outside these native bundles.

Use administrator credentials via `XUPGATE_PUBLISH_TOKEN` or an environment file
containing one `ADMIN_TOKEN=...` line. Credentials are read without printing them.
The upload step checks existing remote hashes, so an interrupted upload can be
retried with the same artifacts. Do not rebuild or overwrite an uploaded version.

```powershell
.\bin\xnet.exe tools/update-release.lua ACTION=upload OUTPUT=C:/release/0.1.5 VERSION=0.1.5 SEQUENCE=5 CREDENTIAL_FILE=C:/private/xupgate-admin.env LOG_STDERR=1 LOG_FILE=0
.\bin\xnet.exe tools/update-release.lua ACTION=publish OUTPUT=C:/release/0.1.5 VERSION=0.1.5 SEQUENCE=5 CHANNEL=stable CREDENTIAL_FILE=C:/private/xupgate-admin.env LOG_STDERR=1 LOG_FILE=0
```

`ACTION=publish` verifies that all three matching platform releases exist before
switching the channel. Both network actions default to the packaged HTTPS server
and pinned CA; `URL` and `CA_FILE` can override them for another deployment.
Existing services keep running; an installed update applies on the next launch.

The Lua updater regression runs with `npm test` when OpenSSL is available. An
opt-in real HTTPS protocol regression uses only xnet Lua and an isolated project:

```powershell
.\bin\xnet.exe tests/lua/update_http_spec.lua CREDENTIAL_FILE=C:/private/xupgate-admin.env LOG_STDERR=1 LOG_FILE=0
```

It tests full/script downloads, signature rejection, rollback and withdrawal,
then disables its test project. It never publishes a production CodeOutline version.

The opt-in deployed integration test needs Python, OpenSSL, a staged Windows
package, and the sibling XUpgate release builder:

```powershell
python tests/update-deployed.py --stage .update-test/final --credential-file C:/private/xupgate-admin.env
```

The credential file contains `ADMIN_TOKEN=...`. The test creates a separate project,
exercises manual and automatic updates, pruning and tamper rejection, and disables
the project on exit. It never publishes to the production CodeOutline channel.
