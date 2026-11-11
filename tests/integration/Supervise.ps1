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
    Integration test: the supervisor and the sender (SPECIFICATION.md 4.1,
    4.5, 7, 8, 11.3) on Windows.
.DESCRIPTION
    Runs a real supervisor with a one-second tick against real jobs, then
    checks what it did through the file backend's Prometheus file: runs
    started, jobs running together with no ceiling, overlaps skipped, a
    crashed run and an abandoned launch recorded, events for a backend type
    not implemented yet counted as dropped, and a second supervisor refused.
    The twin of supervise.sh.

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

# Both jobs take the same in-flight marker. Nothing caps how many run at
# once (8), and both start on the same slots, so slow (3s) and fast (2s)
# are in flight together whatever it takes each to start.
# ping -n <n+1> waits about n seconds.
Set-Content -LiteralPath (Join-Path $root 'scripts\work.cmd') -Value @(
    '@echo off',
    'mkdir "%IT_ROOT%\inflight" 2>nul || echo overlap>>"%IT_ROOT%\overlap"',
    'ping -n %1 127.0.0.1 >nul',
    'rmdir "%IT_ROOT%\inflight" 2>nul',
    'echo metric slept %1')

Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = sup

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

# Not implemented yet: its events are counted as dropped.
[backend.newrelic]
api_key = env:NEW_RELIC_KEY

[job.fast]
file      = scripts\work.cmd
arg       = 3
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

# From here on nothing new may start: 3650-day slots (the next one in
# 2029) are never due before the 2-second cursors. An hour would be crossed
# by a run at hh:59. Let the last workers finish; one more tick reconciles them.
$cfg = Join-Path $root 'config\vigil.config'
# A run still waiting for a slot is kept across a restart (8), and would start.
Remove-Item -LiteralPath (Join-Path $root 'state\pending') -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace 'run_every = 2s', 'run_every = 3650d'))
Start-Sleep -Seconds 7
Invoke-Tick
Invoke-Tick
# Stop-Process can land between a launch record and its worker's claim. No
# worker ever holds that record, and Vigil abandons it once it is older than
# the 30-second grace (11.3). The test ages it rather than waiting, and the
# tick below must then abandon it.
$orphans = @(Get-ChildItem -LiteralPath $locks -Filter '*.launch' -File -ErrorAction SilentlyContinue)
if ($orphans.Count -gt 0) {
    Write-Host "  note  the stop left an unclaimed launch: $(($orphans | ForEach-Object Name) -join ' '); aged past the grace"
    foreach ($o in $orphans) {
        [System.IO.File]::WriteAllText($o.FullName, ([System.IO.File]::ReadAllText($o.FullName) -replace '(?m)^(launch_epoch *= *)\d+', '${1}1'))
    }
    Invoke-Tick
}

Test-Equal 'jobs run together: no ceiling' 'True' "$(Test-Path -LiteralPath (Join-Path $root 'overlap'))"
Test-Equal 'fast ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\fast.state') 'status')
Test-Equal 'slow ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\slow.state') 'status')
Test-Equal 'sender ran and succeeded' 'succeeded' (Get-StateValue (Join-Path $root 'state\jobs\vigil_sender.state') 'status')
$runs = Get-Prom 'fast_runs_total'
Test-Equal 'fast ran more than once' 'True' "$([int]('0' + $runs) -ge 2)"
Test-Equal 'fast succeeded counted' $runs (Get-Prom 'fast_succeeded_total')
Test-Equal 'job metric delivered' '3' (Get-Prom 'fast_slept')
Test-Equal 'slow overlaps were skipped' 'True' "$((Get-Prom 'slow_skipped_total') -ne '')"
Test-Equal 'heartbeat delivered' '1' (Get-Prom 'vigil_supervisor_up')
$promText = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
Test-Equal 'unimplemented backend counted as dropped' 'True' "$($promText -cmatch '(?m)^vigil_spool_dropped_total\{backend="newrelic".*reason="not_implemented"')"
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

# A run whose worker went before its final state, while the sender was
# copying its events: they are in fanout, and still prove it finished.
$rid = '20260101T000000Z-1-4'
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\fast.state'),
    "[state]`nschema_version = 1`njob = fast`nrun_id = $rid`nstatus = running`nboot_id = $boot`nstarted_epoch = 1`n")
[System.IO.File]::WriteAllText((Join-Path $locks "fast.$rid.token"), '')
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'spool\fanout'))
# A blank line and one with no name in it are passed over, not a failed tick.
[System.IO.File]::WriteAllText((Join-Path $root "spool\fanout\1-fast-$rid.events"), "`n1`n1 fast.succeeded 1 count host=it`n")
Invoke-Tick
$st = Join-Path $root 'state\jobs\fast.state'
Test-Equal 'run reconciled from its events in the fan-out' 'succeeded|reconciled from the spool file' "$(Get-StateValue $st 'status')|$(Get-StateValue $st 'reason')"

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

# vigil status from an account that cannot read the install (backlog 40).
function Invoke-Vigil {
    $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @args 2>&1 | ForEach-Object { [string]$_ })
    return @{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$r = Invoke-Vigil status
Test-Equal 'status shows jobs.log' '0|True' "$($r.Code)|$($r.Text -cmatch '(?m)^Vigil .* at ')"
$sup = Join-Path $root 'logs\supervisor'
[void](& icacls.exe $sup /deny "${me}:(OI)(CI)(R)" 2>&1)
try {
    $r = Invoke-Vigil status
    Test-Equal 'status with logs it cannot read: refused' '1' ([string]$r.Code)
    Test-Equal 'saying why, not that there is no jobs.log yet' "vigil: cannot read $sup from this account: run vigil status from an elevated prompt for a system install" $r.Text.Split("`n")[-1]
    Test-Equal 'and no PowerShell error' 'False' ([string]($r.Text -match 'Test-Path|no jobs.log yet'))
}
finally { [void](& icacls.exe $sup /remove:d $me 2>&1) }
$cfgDir = Join-Path $root 'config'
[void](& icacls.exe $cfgDir /deny "${me}:(OI)(CI)(R)" 2>&1)
try {
    $r = Invoke-Vigil precheck
    Test-Equal 'a configuration it cannot read: E_FILE_UNREADABLE' 'True' ([string]($r.Text -cmatch 'config file not readable'))
    Test-Equal 'not a PowerShell error' 'False' ([string]($r.Text -match 'Test-Path'))
    $r = Invoke-Vigil status
    Test-Equal 'status still shows jobs.log, quietly' '0|True|False' "$($r.Code)|$($r.Text -cmatch '(?m)^Vigil .* at ')|$($r.Text -match 'Test-Path')"
}
finally { [void](& icacls.exe $cfgDir /remove:d $me 2>&1) }

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
# Orphaned (11.3, §22 item 14): kill a run's worker while its job keeps
# running. The job holds the run, so no second run starts beside it, and
# jobs.log says ORPHANED; once the job ends, the run is concluded.
$mainRoot = $root
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-orphan.$PID"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
# One tick, waiting for that process alone: "& ... *> $null" would also wait
# for the long job, which ends up holding the output pipe.
function Invoke-OnceAlone {
    $p = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise', '--once')
    $p.WaitForExit()
}
Set-Content -LiteralPath (Join-Path $root 'scripts\long.cmd') -Value @('@echo off', 'ping -n 31 127.0.0.1 >nul', 'echo metric done 1')
Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = orphan

[job.long]
file      = scripts\long.cmd
run_every = 1s
"@
$st = Join-Path $root 'state\jobs\long.state'
# The first tick may only schedule the job: tick until its run has started.
for ($i = 0; $i -lt 30 -and -not (Get-StateValue $st 'job_pid'); $i++) { Invoke-OnceAlone; Start-Sleep -Seconds 1 }
$rid = Get-StateValue $st 'run_id'
$wpid = Get-StateValue $st 'worker_pid'
$jpid = Get-StateValue $st 'job_pid'
Test-Equal 'orphan: the run started' 'True' ([string]([bool]$wpid -and [bool]$jpid))
Stop-Process -Id ([int]$wpid) -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20 -and (Get-Process -Id ([int]$wpid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
Invoke-OnceAlone
Invoke-OnceAlone
$jobsLog = [System.IO.File]::ReadAllText((Join-Path $root 'logs\supervisor\jobs.log'))
Test-Equal 'orphan: its job still runs' 'True' ([string][bool](Get-Process -Id ([int]$jpid) -ErrorAction SilentlyContinue))
Test-Equal 'orphan: no second run is started' '' ((@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'long.*.launch' | ForEach-Object Name)) -join ' ')
Test-Equal 'orphan: still the same run' $rid (Get-StateValue $st 'run_id')
Test-Equal 'orphan: jobs.log says ORPHANED' 'True' ([string]($jobsLog -cmatch "(?m)^ORPHANED\r?\n  long: run $rid, its worker \(pid $wpid\) is gone"))
for ($i = 0; $i -lt 90 -and (Get-Process -Id ([int]$jpid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Invoke-OnceAlone
# Read from the supervisor's log: that tick may already have started the next
# run, whose worker rewrites the state file.
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'orphan: once the job ends, the run is concluded' 'True' ([string]$supLog.Contains("job long: run $rid crashed"))
Test-Equal 'orphan: and its token is gone' '' ((@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter "long.$rid.*" | ForEach-Object Name)) -join ' ')
# Let the next run end before cleaning up.
for ($i = 0; $i -lt 40 -and (Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'long.*' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

# Damaged numbers (11.3, backlog 44): a launch record whose epoch is not a
# number, a state file whose numbers are not, and an empty state file, next
# to a healthy job. Each is read as damage, never cast: the tick carries on,
# the healthy job runs, the launch is abandoned, and both state files are
# quarantined and reported as state_corrupt.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-damaged.$PID"
foreach ($d in 'config', 'scripts', 'state\locks', 'state\jobs') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'echo metric done 1')
$cfg = "[vigil]`ninstance = damaged`n`n[backend.file]`npath = metrics\vigil.prom`n`n"
foreach ($j in 'ok', 'launch', 'nums', 'empty') { $cfg += "[job.$j]`nfile      = scripts\quick.cmd`nrun_every = 1s`n`n" }
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $cfg)
[System.IO.File]::WriteAllText((Join-Path $root 'state\locks\launch.20260101T000000Z-1-1.launch'), "[launch]`njob           = launch`nrun_id        = 20260101T000000Z-1-1`nlaunch_epoch  = 17x`n")
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\nums.state'), "[state]`nschema_version = 1`nstatus = running`nrun_id = 20260101T000000Z-1-2`nstarted_epoch = abc`ndeadline_epoch = 1`njob_pid = 08`nworker_pid = 99999999999`n")
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\empty.state'), '')
# The first tick only schedules a new job (7.6): tick until ok has run.
$okState = Join-Path $root 'state\jobs\ok.state'
for ($i = 0; $i -lt 30 -and (Get-StateValue $okState 'status') -cne 'succeeded'; $i++) { Invoke-Tick; Start-Sleep -Seconds 1 }
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'damaged: no tick failed' 'False' ([string]$supLog.Contains('tick failed'))
Test-Equal 'damaged: the healthy job ran' 'succeeded' (Get-StateValue $okState 'status')
Test-Equal 'damaged: the launch with a bad epoch was abandoned' '' ((@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'launch.20260101T000000Z-1-1.*' | ForEach-Object Name)) -join ' ')
$quarantine = Join-Path $root 'state\quarantine'
Test-Equal 'damaged: bad numbers quarantined' 'True' ([string][bool](Get-ChildItem -LiteralPath $quarantine -Filter 'nums.*' -ErrorAction SilentlyContinue))
Test-Equal 'damaged: an empty state file quarantined' 'True' ([string][bool](Get-ChildItem -LiteralPath $quarantine -Filter 'empty.*' -ErrorAction SilentlyContinue))
Invoke-Tick
Test-Equal 'damaged: state_corrupt reported for bad numbers' '1' (Get-Prom 'nums_state_corrupt_total')
Test-Equal 'damaged: state_corrupt reported for an empty file' '1' (Get-Prom 'empty_state_corrupt_total')
Test-Equal 'damaged: the abandoned launch reported' '1' (Get-Prom 'launch_abandoned_launches_total')
if ($script:fail -gt 0) { Write-Host $supLog.Substring([Math]::Max(0, $supLog.Length - 2000)) }
for ($i = 0; $i -lt 40 -and (Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Exclude '*.abandoned' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
$root = $mainRoot

# Workers started by the last ticks may still be finishing.
Start-Sleep -Seconds 6
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
