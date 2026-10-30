#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: max_runtime (SPECIFICATION.md 10.3, 11.5, 11.6) on
    Windows.
.DESCRIPTION
    A real supervisor stops an overrunning job once its process is proven to
    be the run's, ending its process tree. The run is recorded as timed_out,
    counted as a timeout, and nothing of it lives on. The twin of
    max-runtime.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-mrt.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Get-StateValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

function Invoke-Tick {
    & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root supervise --once *> $null
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -Filter 'vigil_sender.*' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
}

function Get-Prom {
    param([string]$Name)
    $f = Join-Path $root 'metrics\vigil.prom'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l.StartsWith("$Name{") -or $l.StartsWith("$Name ")) { return $l.Substring($l.LastIndexOf(' ') + 1) }
    }
    return ''
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))

# The job would finish after about 30 seconds and leave a marker; it may not.
Set-Content -LiteralPath (Join-Path $root 'scripts\long.cmd') -Value @(
    '@echo off',
    'ping -n 31 127.0.0.1 >nul',
    'echo done>"%IT_ROOT%\long.finished"')

Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = mrt

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

[job.long]
file        = scripts\long.cmd
env         = IT_ROOT=$root
run_every   = 2s
max_runtime = 3s
"@

$sup = Start-Process -FilePath $shell -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root 'supervise.out') `
    -RedirectStandardError (Join-Path $root 'supervise.err') -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
Start-Sleep -Seconds 20
if (-not $sup.HasExited) { Stop-Process -Id $sup.Id -Force }
$sup.WaitForExit()

# No new runs from here on; let everything settle.
$cfg = Join-Path $root 'config\vigil.config'
[System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace 'run_every   = 2s', 'run_every   = 1h'))
Start-Sleep -Seconds 5
Invoke-Tick
Invoke-Tick

$st = Join-Path $root 'state\jobs\long.state'
Test-Equal 'long recorded as timed_out' 'timed_out' (Get-StateValue $st 'status')
Test-Equal 'long reason' 'stopped after max_runtime 3s' (Get-StateValue $st 'reason')
Test-Equal 'deadline recorded' 'True' "$((Get-StateValue $st 'deadline_epoch') -ne '')"
Test-Equal 'job name is the real process' 'cmd.exe' (Get-StateValue $st 'job_name')
Test-Equal 'timeouts counted' 'True' "$((Get-Prom 'long_timeouts_total') -ne '')"
Test-Equal 'timeouts are not failures' '' (Get-Prom 'long_failures_total')
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'tree ended and logged' 'True' "$($supLog -match 'job long: run .* passed max_runtime; ending its process tree')"
Test-Equal 'no tick failed' 'False' "$($supLog -match 'tick failed')"
Test-Equal 'no locks or markers left' '0' "$(@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -File).Count)"

# The job's process tree is gone: nothing lives on to finish its wait.
Start-Sleep -Seconds 30
Test-Equal "long's process did not survive" 'False' "$(Test-Path -LiteralPath (Join-Path $root 'long.finished'))"

if ($script:fail -gt 0) {
    Write-Host "`nsupervisor log:"
    Write-Host ($supLog.Split("`n") | Select-Object -Last 30 | Out-String)
}
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
