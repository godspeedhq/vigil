#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: the Datadog and OTLP backends (SPECIFICATION.md 15.3)
    on Windows.
.DESCRIPTION
    Runs against mock-backend.py on this host. A run's metrics reach both
    with their credentials in headers, a failing backend keeps its events
    and backs off until it recovers, a rejected batch is dropped and
    counted, and no credential ever reaches a log, state, spool or metrics
    file. The twin of backends.sh.

    Needs Python.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-backends.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    param([string[]]$Arguments, [string]$InputText)
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $out = $InputText | & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    }
    else { $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1 }
    return @{ Code = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
}

# One supervisor tick, then wait (up to 60s) for the sender it may have
# started.
function Invoke-Tick {
    [void](Invoke-Vigil @('supervise', '--once'))
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -Filter 'vigil_sender.*' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
}

# Whether the mock's request log has a line containing every argument.
function Test-Received {
    param([string[]]$Parts)
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $root 'mock\requests.log'))) {
        $ok = $true
        foreach ($p in $Parts) { if ($l.IndexOf($p, [System.StringComparison]::Ordinal) -lt 0) { $ok = $false; break } }
        if ($ok) { return 'yes' }
    }
    return 'no'
}

function Get-Queued {
    param([string]$Backend)
    $q = Join-Path $root "spool\backends\$Backend"
    if (-not (Test-Path -LiteralPath $q)) { return '0' }
    return [string]@(Get-ChildItem -LiteralPath $q -Filter '*.events').Count
}

function Get-StateValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

function Test-Prom {
    param([string]$Pattern)
    $f = Join-Path $root 'metrics\vigil.prom'
    if (-not (Test-Path -LiteralPath $f)) { return 'no' }
    if ([System.IO.File]::ReadAllText($f) -cmatch $Pattern) { return 'yes' }
    return 'no'
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
# The first Python that runs: python3 may be only a placeholder.
$python = $null
foreach ($p in @('python3', 'python', 'py')) {
    if (Get-Command $p -CommandType Application -ErrorAction SilentlyContinue) {
        & $p -c 'import http.server' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $python = (Get-Command $p -CommandType Application | Select-Object -First 1).Source; break }
    }
}
if (-not $python) { Write-Host 'needs Python'; exit 1 }
foreach ($d in @('config', 'scripts', 'mock')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
$root = (Resolve-Path -LiteralPath $root).ProviderPath
$mock = $null

try {
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-backend.py`"", "`"$root\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$root\mock\stderr"
    $portFile = Join-Path $root 'mock\port'
    # A cold Python can take a while to start on a busy CI machine.
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $port = if (Test-Path -LiteralPath $portFile) { [System.IO.File]::ReadAllText($portFile).Trim() } else { '' }
    Test-Equal 'mock started' 'True' ([string][bool]$port)
    if (-not $port) {
        Write-Host 'the mock did not start:'
        Get-Content -LiteralPath "$root\mock\stderr"
        throw 'the mock did not start'
    }
    [System.IO.File]::WriteAllText("$root\mock\requests.log", '')

    $ddKey = "dd-it-key-$PID"
    $otelToken = "otel-it-token-$PID"
    $env:VIGIL_IT_DD_KEY = $ddKey

    Set-Content -LiteralPath (Join-Path $root 'scripts\emit.cmd') -Value @('@echo off', 'echo metric answer 42')
    Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = bk

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

[backend.datadog]
endpoint = http://127.0.0.1:$port
api_key  = env:VIGIL_IT_DD_KEY
timeout  = 5s

[backend.otel]
endpoint = http://127.0.0.1:$port/v1/metrics
api_key  = secret:OTEL_TOKEN
timeout  = 5s

[job.emit]
file      = scripts\emit.cmd
run_every = 3650d
"@
    [void](Invoke-Vigil @('secret', 'set', 'OTEL_TOKEN', '--stdin') $otelToken)

    # Delivered to both, the credential in its header.
    [void](Invoke-Vigil @('run', 'emit'))
    Invoke-Tick
    Test-Equal 'datadog: series API' 'yes' (Test-Received @('"path": "/api/v2/series"', "`"DD-API-KEY`": `"$ddKey`"", '\"metric\":\"emit.answer\",\"type\":3', '\"value\":42'))
    Test-Equal 'datadog: host as a resource' 'yes' (Test-Received @('"path": "/api/v2/series"', '\"type\":\"host\"', '\"instance:bk\"', '\"job:emit\"'))
    Test-Equal 'otel: OTLP receiver' 'yes' (Test-Received @('"path": "/v1/metrics"', "`"Authorization`": `"Bearer $otelToken`"", '\"name\":\"emit.answer\",\"gauge\"', '\"asDouble\":42'))
    Test-Equal 'otel: counts as delta sums' 'yes' (Test-Received @('"path": "/v1/metrics"', '\"name\":\"emit.runs\",\"sum\":{\"aggregationTemporality\":1'))
    Test-Equal 'datadog queue drained' '0' (Get-Queued 'datadog')
    Test-Equal 'otel queue drained' '0' (Get-Queued 'otel')
    Test-Equal 'sender succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\vigil_sender.state') 'status')

    # A failing backend keeps its events and backs off.
    [System.IO.File]::WriteAllText("$root\mock\status", '503')
    [void](Invoke-Vigil @('run', 'emit'))
    Invoke-Tick
    Test-Equal 'failing: datadog events kept' 'True' ([string]([int](Get-Queued 'datadog') -gt 0))
    Test-Equal 'failing: otel events kept' 'True' ([string]([int](Get-Queued 'otel') -gt 0))
    Test-Equal 'failing: backoff recorded' 'True' ([string]((Test-Path -LiteralPath "$root\state\backends\datadog.state") -and (Test-Path -LiteralPath "$root\state\backends\otel.state")))
    $log = (Get-ChildItem -LiteralPath "$root\logs\jobs\vigil_sender" -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    Test-Equal 'failing: reason logged' 'True' ([string]($log.Contains("datadog (HTTP 503 from 127.0.0.1:$port)")))
    Test-Equal 'failing: first failure counted' '1' (Get-StateValue "$root\state\backends\datadog.state" 'failures')

    # Recovered: the kept events go after the backoff, and the failures are counted.
    Remove-Item -LiteralPath "$root\mock\status"
    Start-Sleep -Seconds 6
    Invoke-Tick
    Test-Equal 'recovered: datadog queue drained' '0' (Get-Queued 'datadog')
    Test-Equal 'recovered: otel queue drained' '0' (Get-Queued 'otel')
    Test-Equal 'recovered: backoff cleared' 'False' ([string](Test-Path -LiteralPath "$root\state\backends\datadog.state"))
    Invoke-Tick
    Test-Equal 'recovered: failures counted' 'yes' (Test-Prom '(?m)^vigil_backend_failures_total\{backend="datadog"')

    # Rejected as malformed: dropped and counted, never retried.
    [System.IO.File]::WriteAllText("$root\mock\status", '400')
    [void](Invoke-Vigil @('run', 'emit'))
    Invoke-Tick
    Test-Equal 'rejected: datadog queue drained' '0' (Get-Queued 'datadog')
    Remove-Item -LiteralPath "$root\mock\status"
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'rejected: drop counted' 'yes' (Test-Prom '(?m)^vigil_spool_dropped_total\{backend="datadog".*reason="rejected"')

    # The credentials are only ever in headers: never on disk outside the
    # secret store, and never in a URL.
    $leaks = foreach ($d in @('logs', 'state', 'spool', 'metrics')) {
        Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $t = [System.IO.File]::ReadAllText($_.FullName)
            $t.Contains($ddKey) -or $t.Contains($otelToken)
        } | ForEach-Object { $_.FullName }
    }
    Test-Equal 'no credential in logs, state, spool or metrics' '' ($leaks -join ' ')
    $paths = [regex]::Matches([System.IO.File]::ReadAllText("$root\mock\requests.log"), '"path": "([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
    Test-Equal 'no credential in a URL' '' (@($paths | Where-Object { $_.Contains($ddKey) -or $_.Contains($otelToken) }) -join ' ')

    if ($script:fail -gt 0) {
        Write-Host "`nmock stderr:"
        Get-Content -LiteralPath "$root\mock\stderr"
        Write-Host "`nsender log:"
        Write-Host $log
    }
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item Env:\VIGIL_IT_DD_KEY -ErrorAction SilentlyContinue
    # Let a sender started by the last tick finish before cleaning up.
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
