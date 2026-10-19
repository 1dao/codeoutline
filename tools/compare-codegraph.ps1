#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Cases,
    [Parameter(Mandatory)][string]$Out,
    [string]$CodeGraph = 'codegraph',
    [int]$Limit = 2000,
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
# Invalidate a previous successful result before any checks can fail.
[IO.File]::WriteAllText($Out, '{"schema":1,"complete":false}', [Text.UTF8Encoding]::new($false))
$Root = (Resolve-Path -LiteralPath $Root).Path.Replace('\','/').TrimEnd('/')
if (-not (Test-Path -LiteralPath "$Root/.codegraph")) {
    throw 'No .codegraph index at this root. This tool never creates or rebuilds one.'
}
if ($Limit -lt 1 -or $TimeoutSeconds -lt 1) { throw 'Limit and TimeoutSeconds must be positive' }
$command = (Get-Command $CodeGraph -ErrorAction Stop).Source
$manifest = Get-Content -LiteralPath $Cases -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1 -or -not $manifest.cases.Count) { throw 'Invalid manifest' }
function Quote-PS([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
function Invoke-CodeGraph([string[]]$Arguments) {
    $invocation = '& ' + (Quote-PS $command) + ' ' + (($Arguments | ForEach-Object { Quote-PS $_ }) -join ' ') + '; exit $LASTEXITCODE'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Process -Id $PID).Path
    foreach ($item in @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded)) { $info.ArgumentList.Add($item) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = $p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { $p.Kill($true); $p.WaitForExit(); throw 'CodeGraph command timed out' }
        @{ stdout=$stdout.GetAwaiter().GetResult(); stderr=$stderr.GetAwaiter().GetResult(); exit=$p.ExitCode; ms=$timer.Elapsed.TotalMilliseconds }
    } finally { $p.Dispose() }
}
function Save-Report {
    [IO.File]::WriteAllText($Out, ($report | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}
$report = [ordered]@{
    schema=1; engine='codegraph'; root=$Root; created_utc=[DateTime]::UtcNow.ToString('o')
    manifest_sha256=(Get-FileHash -LiteralPath $Cases -Algorithm SHA256).Hash.ToLowerInvariant()
    timing_scope='CLI wall time including process startup; not comparable to CodeOutline in-process latency'
    index_policy='existing index only; source hashes do not prove CodeGraph index freshness'
    source_hashes=@{}; cases=@(); complete=$false
}
foreach ($case in $manifest.cases) {
    if ($case.mode -notin @('callers','callees')) { throw 'Unsupported mode' }
    foreach ($e in $case.evidence) {
        if ($e.file -match '(^/|\\|:|\.\.)') { throw 'Evidence requires a project-relative path' }
        $file = Join-Path $Root $e.file
        $report.source_hashes[$e.file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$report.version = Invoke-CodeGraph @('--version')
$report.status = Invoke-CodeGraph @('status', $Root)
Save-Report
foreach ($case in $manifest.cases) {
    $entry = [ordered]@{id=$case.id; query=$case.query; mode=$case.mode; runs=@()}
    $report.cases += $entry
    try {
        $lookup = Invoke-CodeGraph @('query', $case.query, '--path', $Root, '--limit', "$Limit", '--json')
        if ($lookup.exit -ne 0) { throw "Symbol lookup failed: $($lookup.stderr)" }
        $hits = @($lookup.stdout | ConvertFrom-Json)
        $matched = @($hits | Where-Object { $_.node.name -ceq $case.query -or $_.node.qualifiedName -ceq $case.query }).Count
        $entry.lookup = $lookup
        foreach ($round in 1..2) {
            $raw = Invoke-CodeGraph @($case.mode, $case.query, '--path', $Root, '--limit', "$Limit", '--json')
            $run = [ordered]@{round=$round; matched=$matched; nodes=@(); ms=$raw.ms; raw=$raw; incomplete=$false}
            $entry.runs += $run
            if ($raw.exit -ne 0) { $run.error = "CodeGraph exit $($raw.exit)"; continue }
            $parsed = $raw.stdout | ConvertFrom-Json
            $items = @($parsed.($case.mode))
            foreach ($n in $items) {
                if ($null -eq $n -or -not $n.filePath -or -not $n.name) { continue }
                $run.nodes += @{file=$n.filePath.Replace('\','/');name=$n.name;line=$n.startLine}
            }
            $run.output_bytes = [Text.Encoding]::UTF8.GetByteCount($raw.stdout)
            # A capped list or ambiguous CLI root cannot support an exhaustive verdict.
            $run.incomplete = $items.Count -ge $Limit -or $hits.Count -ge $Limit -or $matched -gt 1
        }
    } catch {
        $entry.runs += @{round=0;matched=0;nodes=@();error=$_.Exception.Message;incomplete=$true}
    }
    Save-Report
    Write-Host "CodeGraph: $($case.id)"
}
foreach ($file in $report.source_hashes.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $Root $file) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $report.source_hashes[$file]) {
        throw "Source changed during CodeGraph comparison: $file"
    }
}
$report.complete = $true
Save-Report
Write-Host "CodeGraph comparison saved: $Out"
