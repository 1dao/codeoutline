$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot '../xnet2lua'
$previousCompilerTail = $env:_CL_
Push-Location $runtimeRoot
try {
    # build.bat defaults to /MD. MSVC appends _CL_ after command-line options;
    # /MT embeds the CRT so the distributed executable needs no VC redist install.
    $env:_CL_ = '/MT'
    & .\build.bat release xnet xproc
    if ($LASTEXITCODE -ne 0) { throw 'Runtime build failed' }
    # Tests, tools and docs run the copy in the repository-level bin/.
    $binDir = Join-Path $PSScriptRoot '../bin'
    New-Item -ItemType Directory -Force $binDir | Out-Null
    Copy-Item -Force (Join-Path $runtimeRoot 'bin/xnet.exe') $binDir
} finally {
    $env:_CL_ = $previousCompilerTail
    Pop-Location
}
