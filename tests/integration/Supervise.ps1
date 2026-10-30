#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: the supervisor (SPECIFICATION.md 4.1, 7, 8, 11.3) on
    Windows.
.DESCRIPTION
    Runs a real supervisor with a one-second tick against real jobs, then
    checks what it did: runs started, the concurrency limit held, overlaps
    skipped, a crashed run and an abandoned launch recorded, and a second
    supervisor refused. The twin of supervise.sh.

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

function Get-SupervisorEvents {
    return (Get-ChildItem -LiteralPath (Join-Path $root 'spool\incoming') -Filter '*-supervisor.events' |
        ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
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
$sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
Start-Sleep -Seconds 25
Test-Equal 'a second supervisor is refused' '1' "$(Invoke-Once)"
Stop-Process -Id $sup.Id -Force
$sup.WaitForExit()

# From here on nothing new may start: hourly slots are never due before the
# 2-second cursors. Let the last workers finish; one more tick reconciles them.
$cfg = Join-Path $root 'config\vigil.config'
[System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace 'run_every = 2s', 'run_every = 1h'))
Start-Sleep -Seconds 7
[void](Invoke-Once)

Test-Equal 'concurrency limit never broken' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'overlap'))"
Test-Equal 'fast ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'status')
Test-Equal 'slow ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\slow.state') 'status')
$runs = @(Get-ChildItem -LiteralPath (Join-Path $root 'spool\incoming') -Filter '*-fast-*.events').Count
Test-Equal 'fast ran more than once' 'True' "$($runs -ge 2)"
$ev = Get-SupervisorEvents
Test-Equal 'slow overlaps were skipped' 'True' "$($ev -cmatch '(?m)^\d+ slow\.skipped 1 count')"
Test-Equal 'heartbeat posted' 'True' "$($ev -cmatch '(?m)^\d+ vigil\.supervisor\.up 1 gauge host=')"
Test-Equal 'disabled job never ran' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'state\jobs\off.state'))"
Test-Equal 'disabled job listed' 'True' "$((Get-Section 'DISABLED') -match '  off')"
Test-Equal 'no locks left' '0' "$(@(Get-ChildItem -LiteralPath $locks -File).Count)"
Test-Equal 'cursors kept' 'fast.cursor slow.cursor' ((Get-ChildItem -LiteralPath (Join-Path $root 'state\schedule') | Sort-Object Name | ForEach-Object Name) -join ' ')

# A run whose worker vanished without an outcome is recorded as crashed.
$boot = Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'boot_id'
$rid = '20260101T000000Z-1-1'
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\fast.state'),
    "[state]`nschema_version = 1`njob = fast`nrun_id = $rid`nstatus = running`nboot_id = $boot`nstarted_epoch = 1`n")
[System.IO.File]::WriteAllText((Join-Path $locks "fast.$rid.token"), '')
[void](Invoke-Once)
Test-Equal 'vanished worker recorded as crashed' 'crashed' (Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'status')
Test-Equal 'crash posted' 'True' "$((Get-SupervisorEvents) -cmatch '(?m)^\d+ fast\.crashes 1 count')"
Test-Equal 'stale token removed' '0' "$(@(Get-ChildItem -LiteralPath $locks -File).Count)"
Test-Equal 'crash listed' 'True' "$((Get-Section 'CRASHED') -match '  fast')"

# A launch never claimed within the grace is abandoned; the job did not run.
$rid = '20260101T000000Z-1-2'
[System.IO.File]::WriteAllText((Join-Path $locks "slow.$rid.launch"),
    "[launch]`njob           = slow`nrun_id        = $rid`nboot_id       = $boot`nlaunch_epoch  = 1`n")
[void](Invoke-Once)
Test-Equal 'old unclaimed launch abandoned' 'False' "$(Test-Path -LiteralPath (Join-Path $locks "slow.$rid.launch"))"
Test-Equal 'abandonment posted' 'True' "$((Get-SupervisorEvents) -cmatch '(?m)^\d+ slow\.abandoned_launches 1 count')"

# A young launch is held: nothing else starts for the job.
$rid = '20260101T000000Z-1-3'
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
[System.IO.File]::WriteAllText((Join-Path $locks "slow.$rid.launch"),
    "[launch]`njob           = slow`nrun_id        = $rid`nboot_id       = $boot`nlaunch_epoch  = $now`n")
[void](Invoke-Once)
Test-Equal 'young launch kept' "slow.$rid.launch" ((Get-ChildItem -LiteralPath $locks -Filter 'slow.*' | ForEach-Object Name) -join ' ')
Test-Equal 'job with a young launch is running' 'True' "$((Get-Section 'RUNNING') -match '  slow')"

if ($script:fail -gt 0) {
    Write-Host "`nsupervisor log:"
    Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 40 }
}
# Workers started by the last ticks may still be finishing.
Start-Sleep -Seconds 6
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
