$ErrorActionPreference = 'Stop'
$runtimeRoot = Join-Path $PSScriptRoot '../xnet2lua'
$previousCompilerTail = $env:_CL_
Push-Location $runtimeRoot
try {
    # build.bat defaults to /MD. MSVC appends _CL_ after command-line options;
    # /MT embeds the CRT so the distributed executable needs no VC redist install.
    $env:_CL_ = '/MT'
    # build.bat reuses an existing LuaJIT library; drop it so the release
    # always gets one built with this CRT and the 5.2 compatibility flag.
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $runtimeRoot '3rd/luajit/src/lua51.lib')
    # norpmalloc: the CRT heap indexes as fast, and rpmalloc keeps each exited
    # parse thread's pages committed (about 6 GB after an 8-thread rebuild).
    & .\build.bat release xnet xproc mpscq luajit norpmalloc
    if ($LASTEXITCODE -ne 0) { throw 'Runtime build failed' }
    # Tests, tools and docs run the copy in the repository-level bin/.
    $binDir = Join-Path $PSScriptRoot '../bin'
    New-Item -ItemType Directory -Force $binDir | Out-Null
    Copy-Item -Force (Join-Path $runtimeRoot 'bin/xnet.exe') $binDir
} finally {
    $env:_CL_ = $previousCompilerTail
    Pop-Location
}
