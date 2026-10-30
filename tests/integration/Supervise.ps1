#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: the supervisor and the sender (SPECIFICATION.md 4.1,
    4.5, 7, 8, 11.3) on Windows.
.DESCRIPTION
    Runs a real supervisor with a one-second tick against real jobs, then
    checks what it did through the file backend's Prometheus file: runs
    started, the concurrency limit held, overlaps skipped, a crashed run and
    an abandoned launch recorded, events for a backend type not implemented
    yet counted as dropped, and a second supervisor refused. The twin of
    supervise.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-sup.$PID"
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

function Invoke-Once {
    & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root supervise --once *> $null
    return $LASTEXITCODE
}

# One supervisor tick, then wait (up to 60s) for the sender it may have
# started, so the Prometheus file is current.
function Invoke-Tick {
    [void](Invoke-Once)
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -Filter 'vigil_sender.*' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
}

# The value of a series (a name; the first series of that name) in the file.
function Get-Prom {
    param([string]$Name)
    $f = Join-Path $root 'metrics\vigil.prom'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l.StartsWith("$Name{") -or $l.StartsWith("$Name ")) { return $l.Substring($l.LastIndexOf(' ') + 1) }
    }
    return ''
}

function Get-Section {
    param([string]$Name)
    $text = [System.IO.File]::ReadAllText((Join-Path $root 'logs\supervisor\jobs.log'))
    $m = [regex]::Match($text, "(?ms)^$Name\r?\n(.*?)(\r?\n\r?\n|\z)")
    return $m.Groups[1].Value
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
$locks = Join-Path $root 'state\locks'

# Both jobs take the same in-flight marker: if they ever overlap, the
# concurrency limit of 1 was broken. ping -n <n+1> waits about n seconds.
Set-Content -LiteralPath (Join-Path $root 'scripts\work.cmd') -Value @(
    '@echo off',
    'mkdir "%IT_ROOT%\inflight" 2>nul || echo overlap>>"%IT_ROOT%\overlap"',
    'ping -n %1 127.0.0.1 >nul',
    'rmdir "%IT_ROOT%\inflight" 2>nul',
    'echo metric slept %1')

Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance       = sup
max_concurrent = 1

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

# Not implemented yet: its events are counted as dropped.
[backend.datadog]
api_key = env:DATADOG_API_KEY

[job.fast]
file      = scripts\work.cmd
arg       = 1
env       = IT_ROOT=$root
run_every = 2s

[job.slow]
file      = scripts\work.cmd
arg       = 4
env       = IT_ROOT=$root
run_every = 2s

[job.off]
file      = scripts\work.cmd
run_every = 2s
enabled   = false
"@

# Run a real supervisor for a while, then stop it.
$supOut = Join-Path $root 'supervise.out'
$supErr = Join-Path $root 'supervise.err'
$sup = Start-Process -FilePath $shell -PassThru -NoNewWindow -RedirectStandardOutput $supOut -RedirectStandardError $supErr -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
Start-Sleep -Seconds 25
# A loaded machine gives fast fewer chances: wait up to 40s more for a second run.
for ($i = 0; $i -lt 40 -and [int]('0' + (Get-Prom 'fast_runs_total')) -lt 2; $i++) { Start-Sleep -Seconds 1 }
Test-Equal 'supervisor still running' 'False' "$($sup.HasExited)"
if ($sup.HasExited) {
    Write-Host "  supervisor exited with $($sup.ExitCode); its output:"
    Get-Content -LiteralPath $supOut, $supErr -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
}
Test-Equal 'a second supervisor is refused' '1' "$(Invoke-Once)"
if (-not $sup.HasExited) { Stop-Process -Id $sup.Id -Force }
$sup.WaitForExit()

# From here on nothing new may start: hourly slots are never due before the
# 2-second cursors. Let the last workers finish; one more tick reconciles them.
$cfg = Join-Path $root 'config\vigil.config'
[System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace 'run_every = 2s', 'run_every = 1h'))
Start-Sleep -Seconds 7
Invoke-Tick
Invoke-Tick

Test-Equal 'concurrency limit never broken' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'overlap'))"
Test-Equal 'fast ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'status')
Test-Equal 'slow ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\slow.state') 'status')
Test-Equal 'sender ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\vigil_sender.state') 'status')
$runs = Get-Prom 'fast_runs_total'
Test-Equal 'fast ran more than once' 'True' "$([int]('0' + $runs) -ge 2)"
Test-Equal 'fast succeeded counted' $runs (Get-Prom 'fast_succeeded_total')
Test-Equal 'job metric delivered' '1' (Get-Prom 'fast_slept')
Test-Equal 'slow overlaps were skipped' 'True' "$((Get-Prom 'slow_skipped_total') -ne '')"
Test-Equal 'heartbeat delivered' '1' (Get-Prom 'vigil_supervisor_up')
$promText = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
Test-Equal 'unimplemented backend counted as dropped' 'True' "$($promText -cmatch '(?m)^vigil_spool_dropped_total\{backend="datadog".*reason="not_implemented"')"
Test-Equal 'disabled job never ran' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'state\jobs\off.state'))"
Test-Equal 'disabled job listed' 'True' "$((Get-Section 'DISABLED') -match '  off')"
Test-Equal 'no locks left' '0' "$(@(Get-ChildItem -LiteralPath $locks -File).Count)"
Test-Equal 'cursors kept' 'fast.cursor slow.cursor' ((Get-ChildItem -LiteralPath (Join-Path $root 'state\schedule') | Sort-Object Name | ForEach-Object Name) -join ' ')
Test-Equal 'file backend queue drained' '0' "$(@(Get-ChildItem -LiteralPath (Join-Path $root 'spool\backends\file') -File -ErrorAction SilentlyContinue).Count)"
Test-Equal 'no fan-out left over' '0' "$(@(Get-ChildItem -LiteralPath (Join-Path $root 'spool\fanout') -File -ErrorAction SilentlyContinue).Count)"

# A run whose worker vanished without an outcome is recorded as crashed.
$boot = Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'boot_id'
$rid = '20260101T000000Z-1-1'
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\fast.state'),
    "[state]`nschema_version = 1`njob = fast`nrun_id = $rid`nstatus = running`nboot_id = $boot`nstarted_epoch = 1`n")
[System.IO.File]::WriteAllText((Join-Path $locks "fast.$rid.token"), '')
Invoke-Tick
Invoke-Tick
Test-Equal 'vanished worker recorded as crashed' 'crashed' (Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'status')
Test-Equal 'crash delivered' '1' (Get-Prom 'fast_crashes_total')
Test-Equal 'stale token removed' '0' "$(@(Get-ChildItem -LiteralPath $locks -File).Count)"

# A launch never claimed within the grace is abandoned; the job did not run.
$rid = '20260101T000000Z-1-2'
[System.IO.File]::WriteAllText((Join-Path $locks "slow.$rid.launch"),
    "[launch]`njob           = slow`nrun_id        = $rid`nboot_id       = $boot`nlaunch_epoch  = 1`n")
Invoke-Tick
Invoke-Tick
Test-Equal 'old unclaimed launch abandoned' 'False' "$(Test-Path -LiteralPath (Join-Path $locks "slow.$rid.launch"))"
Test-Equal 'abandonment delivered' '1' (Get-Prom 'slow_abandoned_launches_total')

# A young launch is held: nothing else starts for the job.
$rid = '20260101T000000Z-1-3'
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
[System.IO.File]::WriteAllText((Join-Path $locks "slow.$rid.launch"),
    "[launch]`njob           = slow`nrun_id        = $rid`nboot_id       = $boot`nlaunch_epoch  = $now`n")
[void](Invoke-Once)
Test-Equal 'young launch kept' "slow.$rid.launch" ((Get-ChildItem -LiteralPath $locks -Filter 'slow.*' | ForEach-Object Name) -join ' ')
Test-Equal 'job with a young launch is running' 'True' "$((Get-Section 'RUNNING') -match '  slow')"

# A failing tick is survived, but must never happen here.
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'no tick failed' '' (([regex]::Matches($supLog, '(?m)^.* ERROR supervisor tick failed.*$') | Select-Object -First 1).Value)

if ($script:fail -gt 0) {
    Write-Host "`nsupervisor log:"
    Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 40 }
    Write-Host "`nsupervisor stderr:"
    Get-Content -LiteralPath $supErr -ErrorAction SilentlyContinue | Select-Object -First 30 | ForEach-Object { Write-Host "    $_" }
    Write-Host "`nsender log:"
    Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\vigil_sender') -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 20 }
}
# Workers started by the last ticks may still be finishing.
Start-Sleep -Seconds 6
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
