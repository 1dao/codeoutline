# Build platform-independent clients for tools/package.lua.
param([switch]$SkipVscode)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$assetRoot = Join-Path $repoRoot 'dist/editor-assets'
New-Item -ItemType Directory -Force -Path "$assetRoot/zed" | Out-Null
if (-not $SkipVscode) {
    Push-Location "$repoRoot/adapters/vscode"
    try {
        npm ci
        if ($LASTEXITCODE -ne 0) { throw 'VS Code dependencies failed' }
        npm run package
        if ($LASTEXITCODE -ne 0) { throw 'VSIX packaging failed' }
        Copy-Item -LiteralPath 'codeoutline.vsix' -Destination "$assetRoot/codeoutline.vsix"
    } finally { Pop-Location }
}
Push-Location "$repoRoot/adapters/zed"
try {
    rustup target add wasm32-wasip2
    if ($LASTEXITCODE -ne 0) { throw 'WASM target installation failed' }
    cargo build --release --target wasm32-wasip2
    if ($LASTEXITCODE -ne 0) { throw 'Zed build failed' }
    Copy-Item -LiteralPath 'target/wasm32-wasip2/release/codeoutline_zed.wasm' -Destination "$assetRoot/zed/extension.wasm"
    $manifest = Get-Content -Raw -LiteralPath 'extension.toml'
    $manifest += "`n[lib]`nkind = `"Rust`"`nversion = `"0.7.0`"`n"
    [System.IO.File]::WriteAllText("$assetRoot/zed/extension.toml", $manifest, [System.Text.UTF8Encoding]::new($false))
} finally { Pop-Location }
