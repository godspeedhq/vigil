#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    Integration test: the supervisor answers for every run, and says so
    truly (backlog 66), on Windows.
.DESCRIPTION
    The twin of run-accounting.sh.
      1. A local job file that is missing: FILE MISSING, file_missing, no
         run; back, the job runs and file_missing goes to 0 (16.3).
      2. A job removed from the configuration mid-run is still stopped at
         its max_runtime and its outcome recorded (11.3); running goes to 0.
      3. A crashed run is counted in runs, as well as crashes (14.2).
      4. A job held for vigil resolve after its run ended is not shown as
         running, nor counted as a worker (13.2).
      5. Retention deletes the output a crashed run left once it is as old
         as the job's log, never a running run's (13.1).

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-acct.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Get-StateValue {
    param([string]$Job, [string]$Key)
    $path = Join-Path $root "state\jobs\$Job.state"
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

# One supervisor tick, then wait (up to 60s) for the sender it may start.
# Started apart, and waited for alone: the job a tick starts inherits the
# output handles of a call with redirection, which would then wait for the
# job to end too.
function Invoke-Tick {
    $p = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise', '--once')
    $p.WaitForExit()
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -Filter 'vigil_sender.*' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
}

# Ticks until $Test is true, at most $Max times, a second apart.
function Invoke-TickUntil {
    param([int]$Max, [scriptblock]$Test)
    for ($i = 0; $i -lt $Max -and -not (& $Test); $i++) { Invoke-Tick; Start-Sleep -Seconds 1 }
}

# The value of a series in the file backend's file.
function Get-Prom {
    param([string]$Name)
    $f = Join-Path $root 'metrics\vigil.prom'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l.StartsWith("$Name{") -or $l.StartsWith("$Name ")) { return $l.Substring($l.LastIndexOf(' ') + 1) }
    }
    return ''
}

# The lines of a section of jobs.log, without their indent.
function Get-Section {
    param([string]$Name)
    $f = Join-Path $root 'logs\supervisor\jobs.log'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $in = $false; $out = @()
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        if ($l -ceq $Name) { $in = $true; continue }
        if ($in -and -not $l) { break }
        if ($in) { $out += $l.Trim() }
    }
    return , $out
}

# The configuration: the backend, then the job sections given.
function Set-Config {
    param([string]$Jobs)
    Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = acct

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom
$Jobs
"@
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
Set-Content -LiteralPath (Join-Path $root 'scripts\slow.cmd') -Value @('@echo off', 'ping -n 61 127.0.0.1 >nul')
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'echo metric ran 1')

try {
    Write-Host '1. a missing local file'
    Set-Config @"

[job.gone]
file      = scripts\gone.cmd
run_every = 1s
"@
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'FILE MISSING in jobs.log' 'gone' ((Get-Section 'FILE MISSING') -join ',')
    Test-Equal 'file_missing is 1' '1' (Get-Prom 'gone_file_missing')
    Test-Equal 'and it never ran' 'False' ([string](Test-Path -LiteralPath (Join-Path $root 'state\jobs\gone.state')))
    Set-Content -LiteralPath (Join-Path $root 'scripts\gone.cmd') -Value @('@echo off', 'echo metric ran 1')
    Invoke-TickUntil 15 { (Get-StateValue 'gone' 'status') -ceq 'succeeded' }
    Test-Equal 'back, it runs' 'succeeded' (Get-StateValue 'gone' 'status')
    Invoke-TickUntil 5 { (Get-Prom 'gone_file_missing') -ceq '0' }
    Test-Equal 'and file_missing goes to 0' '0' (Get-Prom 'gone_file_missing')

    Write-Host '2. a job removed mid-run'
    Set-Config @"

[job.slow]
file        = scripts\slow.cmd
run_every   = 1s
max_runtime = 30s
"@
    Invoke-TickUntil 20 { (Get-StateValue 'slow' 'status') -ceq 'running' }
    Test-Equal 'slow is running' 'running' (Get-StateValue 'slow' 'status')
    Invoke-Tick
    $r = Get-Prom 'slow_running'
    Test-Equal 'its running gauge is up' 'True' ([string]($r -and $r -cne '0'))
    Set-Config ''
    Invoke-Tick
    Test-Equal 'jobs.log still shows its run' 'True' ([string]([bool](@(Get-Section 'RUNNING') | Where-Object { $_ -clike 'slow: *(no longer in the configuration, or invalid in it)' })))
    Invoke-TickUntil 30 { (Get-StateValue 'slow' 'status') -ceq 'timed_out' }
    Test-Equal 'still stopped at its max_runtime' 'timed_out' (Get-StateValue 'slow' 'status')
    $logs = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Test-Equal 'and the supervisor said so' 'True' ([string]($logs -cmatch 'job slow: run \S+ passed max_runtime'))
    Invoke-TickUntil 5 { (Get-Prom 'slow_running') -ceq '0' }
    Test-Equal 'running goes to 0' '0' (Get-Prom 'slow_running')
    Test-Equal 'no locks left' '' ((Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'slow.*' | ForEach-Object { $_.Name }) -join ',')

    Write-Host '3. a crashed run is a run'
    # The job is one process, PING.EXE run directly: Stop-Process ends it
    # whole. taskkill /T, which ends a tree, is refused under some logons
    # (SSH), as WMI is.
    Set-Config @"

[job.crashy]
file      = C:\Windows\System32\PING.EXE
arg       = -n
arg       = 61
arg       = 127.0.0.1
run_every = 1s
"@
    Invoke-TickUntil 20 { (Get-StateValue 'crashy' 'status') -ceq 'running' }
    Set-Config @"

[job.crashy]
file      = C:\Windows\System32\PING.EXE
arg       = -n
arg       = 61
arg       = 127.0.0.1
run_every = 3650d
"@
    $rid = Get-StateValue 'crashy' 'run_id'
    # Its worker and its job, both: nothing is left to record the run.
    foreach ($p in (Get-StateValue 'crashy' 'worker_pid'), (Get-StateValue 'crashy' 'job_pid')) {
        if ($p) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
    }
    Invoke-TickUntil 30 { (Get-StateValue 'crashy' 'status') -ceq 'crashed' }
    Test-Equal 'crashy recorded as crashed' 'crashed' (Get-StateValue 'crashy' 'status')
    Invoke-TickUntil 5 { (Get-Prom 'crashy_crashes_total') -ceq '1' }
    Test-Equal 'counted in crashes' '1' (Get-Prom 'crashy_crashes_total')
    Test-Equal 'and in runs' '1' (Get-Prom 'crashy_runs_total')

    Write-Host '4. a job held after its run ended'
    Set-Config @"

[job.held]
file         = scripts\quick.cmd
run_every    = 3650d
on_uncertain = manual
"@
    & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root run held *> $null
    $hrid = Get-StateValue 'held' 'run_id'
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'state\recovery'))
    [System.IO.File]::WriteAllText((Join-Path $root 'state\recovery\held.recovery'), "[recovery]`njob          = held`nrun_id       = $hrid`nconclusion   = uncertain`nreason       = a test`nfirst_seen   = 1`nlast_checked = 1`npolicy       = manual`nresolved_by  = `nresolved_at  = `n")
    Invoke-Tick
    Test-Equal 'held is under UNCERTAIN' 'True' ([string]([bool](@(Get-Section 'UNCERTAIN') | Where-Object { $_ -clike "held: run $hrid *held until vigil resolve*" })))
    Test-Equal 'not under RUNNING' '' ((@(Get-Section 'RUNNING') | Where-Object { $_ -clike 'held:*' }) -join ',')
    Test-Equal 'and not counted as a worker' '0' (Get-Prom 'vigil_supervisor_workers')

    Write-Host "5. retention of a crashed run's output"
    $dir = Join-Path $root 'logs\jobs\crashy'
    [void](New-Item -ItemType Directory -Force -Path $dir)
    foreach ($f in '20200101T000000Z-1-1.out', '20200101T000000Z-1-1.err.raw', '20200101T000000Z-1-2.out') { [System.IO.File]::WriteAllText((Join-Path $dir $f), '') }
    # A run still going holds its token open, as its worker would.
    $tok = Join-Path $root 'state\locks\crashy.20200101T000000Z-1-2.token'
    $held = [System.IO.File]::Open($tok, 'OpenOrCreate', 'ReadWrite', 'None')
    Invoke-Tick
    $held.Dispose()
    $left = @(Get-ChildItem -LiteralPath $dir | ForEach-Object { $_.Name })
    Test-Equal "a crashed run's old output is deleted" '' (($left | Where-Object { $_ -clike '20200101T000000Z-1-1.*' }) -join ',')
    Test-Equal "a run's that still holds its token is kept" '20200101T000000Z-1-2.out' (($left | Where-Object { $_ -clike '20200101T000000Z-1-2.*' }) -join ',')
    Test-Equal "this run's output, too young, is kept" 'True' ([string]([bool]($left | Where-Object { $_ -clike "$rid.*" })))

    if ($script:fail -gt 0) {
        Write-Host "`njobs.log:"
        Get-Content -LiteralPath (Join-Path $root 'logs\supervisor\jobs.log') -ErrorAction SilentlyContinue
        Write-Host "`nsupervisor log:"
        Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 30 }
    }
}
finally {
    # Nothing of this test may outlive it: a job still running is ended,
    # and only by the name it runs as, never a process that took its id since.
    foreach ($j in @(@('slow', 'cmd'), @('crashy', 'PING'))) {
        $p = Get-StateValue $j[0] 'job_pid'
        if (-not $p -or (Get-StateValue $j[0] 'status') -cne 'running') { continue }
        $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -ceq $j[1]) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
