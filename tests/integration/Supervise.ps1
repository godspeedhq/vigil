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
    not implemented yet counted as dropped, a second supervisor refused, and
    the faults of 22.4 tests 1, 2, 13, 17 and 24 (a corrupt or missing state
    file, a reboot, a launch from the previous boot), and a queue_one run
    held across a restart.
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
[System.IO.File]::WriteAllText((Join-Path $root "spool\fanout\1-fast-$rid.events"), "`n1`n1 fast.duration_seconds 0 gauge host=it`n1 fast.runs 1 count host=it`n1 fast.succeeded 1 count host=it`n")
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
# vigil status --watch (backlog 57), given 5 seconds from its first frame:
# how it ended, 'running' when it was still going and was stopped (it is
# this test's own process), else its exit code; and what it printed.
# PowerShell alone can take seconds to start on a busy machine, so the
# 5 seconds start at the first frame, or it ends, within a minute.
function Read-Shared {
    param([string]$Path)
    try {
        $s = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object System.IO.StreamReader($s)).ReadToEnd() } finally { $s.Dispose() }
    }
    catch { '' }
}
function Invoke-Watch {
    $out = "$root.watch"
    $p = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError "$out.err" -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'status', '--watch')
    [void]$p.Handle
    for ($i = 0; $i -lt 120 -and -not $p.HasExited -and -not ((Read-Shared $out) -cmatch '(?m)^every 2 s'); $i++) { Start-Sleep -Milliseconds 500 }
    $how = if ($p.WaitForExit(5000)) { [string]$p.ExitCode } else { $p.Kill(); [void]$p.WaitForExit(5000); 'running' }
    $text = [System.IO.File]::ReadAllText($out) + [System.IO.File]::ReadAllText("$out.err")
    Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
    return @{ How = $how; Text = $text }
}
$w = Invoke-Watch
Test-Equal 'status --watch keeps going' 'running' $w.How
$frames = ([regex]::Matches($w.Text, '(?m)^every 2 s, Ctrl\+C to stop: ')).Count
Test-Equal 'a frame every 2 seconds' 'True' ([string]($frames -ge 2))
Test-Equal 'each with jobs.log' ([string]$frames) ([string]([regex]::Matches($w.Text, '(?m)^Vigil .* at ')).Count)
$r = Invoke-Vigil status --watch now
Test-Equal 'status --watch with more: usage' '64' ([string]$r.Code)
$sup = Join-Path $root 'logs\supervisor'
[void](& icacls.exe $sup /deny "${me}:(OI)(CI)(R)" 2>&1)
try {
    $r = Invoke-Vigil status
    Test-Equal 'status with logs it cannot read: refused' '1' ([string]$r.Code)
    Test-Equal 'saying why, not that there is no jobs.log yet' "vigil: cannot read $sup from this account: run vigil status from an elevated prompt for a system install" $r.Text.Split("`n")[-1]
    Test-Equal 'and no PowerShell error' 'False' ([string]($r.Text -match 'Test-Path|no jobs.log yet'))
    $w = Invoke-Watch
    Test-Equal 'status --watch with logs it cannot read: refused, once' '1|1' "$($w.How)|$(([regex]::Matches($w.Text, 'cannot read')).Count)"
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
# The job runs until the test has checked it, not for a time a slow machine
# may outlast before the checks (49): it ends when long.stop appears, or after
# five minutes, so it never outlives a failed run.
$stop = Join-Path $root 'scripts\long.stop'
Set-Content -LiteralPath (Join-Path $root 'scripts\long.cmd') -Value @('@echo off', 'set n=0', ':w', "if exist ""$stop"" goto e", 'set /a n+=1', 'if %n% geq 300 goto e', 'ping -n 2 127.0.0.1 >nul', 'goto w', ':e', 'echo metric done 1')
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

# While that run is alive (22.4, 17, 1 and 2). The job is due every second,
# so a supervisor that lost track of the run would start another.
$locksDir = Join-Path $root 'state\locks'
function Get-Others { (@(Get-ChildItem -LiteralPath $locksDir -Filter 'long.*' | Where-Object { -not $_.Name.StartsWith("long.$rid.") } | ForEach-Object Name)) -join ' ' }
function Test-BothAlive { [string]([bool](Get-Process -Id ([int]$jpid) -ErrorAction SilentlyContinue) -and [bool](Get-Process -Id ([int]$wpid) -ErrorAction SilentlyContinue)) }
# 17. The supervisor never writes a live run's state file.
$sum = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($st))
Invoke-OnceAlone
Invoke-OnceAlone
Test-Equal "17: a live run's state file is never written" $sum ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($st)))
# 1. Its state file corrupted: the run is found by its token and run id.
$good = [System.IO.File]::ReadAllBytes($st)
[System.IO.File]::WriteAllText($st, "not a state file`n")
Invoke-OnceAlone
Invoke-OnceAlone
Test-Equal '1: corrupt state: the job still runs' 'True' (Test-BothAlive)
Test-Equal '1: no run started beside it' '' (Get-Others)
Test-Equal '1: and its state file left as it is' "not a state file`n" ([System.IO.File]::ReadAllText($st))
# 2. Its state file deleted: the same.
[System.IO.File]::Delete($st)
Invoke-OnceAlone
Invoke-OnceAlone
Test-Equal '2: deleted state: the job still runs' 'True' (Test-BothAlive)
Test-Equal '2: no run started beside it' '' (Get-Others)
Test-Equal '2: and nothing writes it' 'False' ([string][System.IO.File]::Exists($st))
[System.IO.File]::WriteAllBytes($st, $good)

Stop-Process -Id ([int]$wpid) -Force -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 20 -and (Get-Process -Id ([int]$wpid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
Invoke-OnceAlone
Invoke-OnceAlone
$jobsLog = [System.IO.File]::ReadAllText((Join-Path $root 'logs\supervisor\jobs.log'))
Test-Equal 'orphan: its job still runs' 'True' ([string][bool](Get-Process -Id ([int]$jpid) -ErrorAction SilentlyContinue))
Test-Equal 'orphan: no second run is started' '' ((@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'long.*.launch' | ForEach-Object Name)) -join ' ')
Test-Equal 'orphan: still the same run' $rid (Get-StateValue $st 'run_id')
Test-Equal 'orphan: jobs.log says ORPHANED' 'True' ([string]($jobsLog -cmatch "(?m)^ORPHANED\r?\n  long: run $rid, its worker \(pid $wpid\) is gone"))
[System.IO.File]::WriteAllText($stop, '')
for ($i = 0; $i -lt 40 -and (Get-Process -Id ([int]$jpid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Invoke-OnceAlone
# Read from the supervisor's log: that tick may already have started the next
# run, whose worker rewrites the state file.
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'orphan: once the job ends, the run is concluded' 'True' ([string]$supLog.Contains("job long: run $rid crashed"))
Test-Equal 'orphan: and its token is gone' '' ((@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter "long.$rid.*" | ForEach-Object Name)) -join ' ')
# Let the next run end before cleaning up.
for ($i = 0; $i -lt 40 -and (Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'long.*' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

# A reboot (22.4, 13 and 24), as a boot id that is not this boot's: every
# run recorded as running then is concluded, and a launch record from then is
# abandoned at once, however young. Neither job is ever due, so no run of
# theirs rewrites what this checks.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-reboot.$PID"
foreach ($d in 'config', 'scripts', 'state\locks', 'state\jobs') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'echo metric done 1')
$cfg = "[vigil]`ninstance = reboot`n`n"
foreach ($j in 'one', 'two', 'three') { $cfg += "[job.$j]`nfile      = scripts\quick.cmd`nrun_every = 3650d`n`n" }
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $cfg)
# The processes of before the reboot: one that has ended.
$gone = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$gone.WaitForExit()
foreach ($j in 'one', 'two') {
    [System.IO.File]::WriteAllText((Join-Path $root "state\jobs\$j.state"),
        "[state]`nschema_version = 1`njob = $j`nrun_id = 20260101T000000Z-1-$j`nstatus = running`nboot_id = before-the-reboot`nstarted_epoch = 1`njob_pid = $($gone.Id)`nworker_pid = $($gone.Id)`n")
    [System.IO.File]::WriteAllText((Join-Path $root "state\locks\$j.20260101T000000Z-1-$j.token"), '')
}
[System.IO.File]::WriteAllText((Join-Path $root 'state\locks\three.20260101T000000Z-1-three.launch'),
    "[launch]`njob           = three`nrun_id        = 20260101T000000Z-1-three`nboot_id       = before-the-reboot`nlaunch_epoch  = $([DateTimeOffset]::Now.ToUnixTimeSeconds())`n")
Invoke-OnceAlone
$rebootLocks = (@(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -File | ForEach-Object Name)) -join ' '
Test-Equal '13: after a reboot, every run recorded as running is concluded' 'crashed crashed' "$(Get-StateValue (Join-Path $root 'state\jobs\one.state') 'status') $(Get-StateValue (Join-Path $root 'state\jobs\two.state') 'status')"
Test-Equal '13: and their tokens are gone' 'False' ([string]($rebootLocks -match '(^| )(one|two)\.'))
Test-Equal '24: a launch from before the reboot is abandoned at once' 'False' ([string]($rebootLocks -match '(^| )three\.'))
$supLog = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal '24: and logged' 'True' ([string]$supLog.Contains('job three: launch 20260101T000000Z-1-three abandoned'))
Test-Equal '24: never run' 'False' ([string][System.IO.File]::Exists((Join-Path $root 'state\jobs\three.state')))
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

# queue_one end to end (9, 8): a slot that comes due while a run is active
# is held, one only, and kept in state\pending across a supervisor restart.
# With no supervisor it never starts; after the restart it starts once the
# active run has ended, never beside it. A run lasts 15 s: a tick here can
# take a few.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-queue.$PID"
foreach ($d in 'config', 'scripts') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Set-Content -LiteralPath (Join-Path $root 'scripts\slow.cmd') -Value @(
    '@echo off',
    'mkdir "%IT_ROOT%\inflight" 2>nul || echo overlap>>"%IT_ROOT%\overlap"',
    'echo %VIGIL_RUN_ID%>>"%IT_ROOT%\runs"',
    'ping -n 16 127.0.0.1 >nul',
    'rmdir "%IT_ROOT%\inflight" 2>nul')
function Set-QueueConfig {
    param([string]$Every)
    [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'),
        "[vigil]`ninstance = queue`n`n[scheduler]`ntick = 1s`n`n[job.slow]`nfile      = scripts\slow.cmd`nenv       = IT_ROOT=$root`noverlap   = queue_one`nrun_every = $Every`n")
}
function Test-Held { $f = Join-Path $root 'state\pending'; (Test-Path -LiteralPath $f) -and ([System.IO.File]::ReadAllText($f) -cmatch '(?m)^queued=(.* )?slow( |\r?$)') }
function Get-Runs { $f = Join-Path $root 'runs'; if (Test-Path -LiteralPath $f) { @([System.IO.File]::ReadAllLines($f) | Where-Object { $_.Trim() }).Count } else { 0 } }
function Test-SlowIdle { -not (Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'slow.*' -ErrorAction SilentlyContinue) }
function Test-Skipped { [bool]((Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' -ErrorAction SilentlyContinue | ForEach-Object { Read-Shared $_.FullName }) -join '' -match 'job slow: slot \S+ skipped: a run is still active') }
Set-QueueConfig '2s'
$qSup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
for ($i = 0; $i -lt 120 -and -not (Test-Held); $i++) { Start-Sleep -Milliseconds 500 }
# A later slot of the active run is skipped, not held too. Then nothing
# more comes due, and the supervisor stops while the run is still active.
for ($i = 0; $i -lt 60 -and -not (Test-Skipped); $i++) { Start-Sleep -Milliseconds 500 }
Set-QueueConfig '3650d'
if (-not $qSup.HasExited) { Stop-Process -Id $qSup.Id -Force }
$qSup.WaitForExit()
# A run is active from its launch; its cmd.exe can take a few seconds more
# to write its line.
for ($i = 0; $i -lt 60 -and (Get-Runs) -lt 1; $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'queue_one: a slot due while a run is active is held' 'True' "$(Test-Held)"
Test-Equal 'queue_one: one run active, one held' '1' "$(Get-Runs)"
for ($i = 0; $i -lt 60 -and -not (Test-SlowIdle); $i++) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 2
Test-Equal 'queue_one: with no supervisor, the held run never starts' '1 True' "$(Get-Runs) $(Test-Held)"
for ($i = 0; $i -lt 30 -and (Get-Runs) -lt 2; $i++) { Invoke-OnceAlone; Start-Sleep -Seconds 1 }
Test-Equal 'queue_one: after a restart, the held run starts' '2' "$(Get-Runs)"
Test-Equal 'queue_one: and is no longer held' 'False' "$(Test-Held)"
for ($i = 0; $i -lt 40 -and -not (Test-SlowIdle); $i++) { Invoke-OnceAlone; Start-Sleep -Seconds 1 }
Invoke-OnceAlone
Test-Equal 'queue_one: one held run only, the others skipped' '2 True' "$(Get-Runs) $(Test-Skipped)"
Test-Equal 'queue_one: no run ever met another' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'overlap'))"
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

# jobs.log (13.2): each section a job can be in, saying what 13.2 says it
# does. busy runs (its PID, how long, how long to max_runtime), quick has
# run (its outcome, when it ended, how long it took), later waits (its next
# time), broken is INVALID (why), and gone is a run whose worker vanished:
# CRASHED in the tick that concludes it.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-status.$PID"
foreach ($d in 'config', 'scripts', 'state\jobs', 'state\locks') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Set-Content -LiteralPath (Join-Path $root 'scripts\busy.cmd') -Value @('@echo off', 'ping -n 31 127.0.0.1 >nul')
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'echo metric done 1')
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), ("[vigil]`ninstance = status`n`n[job.busy]`nfile        = scripts\busy.cmd`nrun_every   = 3650d`nmax_runtime = 10m`n`n" +
        "[job.quick]`nfile      = scripts\quick.cmd`nrun_every = 3650d`n`n[job.later]`nfile      = scripts\quick.cmd`nrun_every = 1h`n`n" +
        "[job.broken]`nfile = scripts\quick.cmd`n`n[job.gone]`nfile      = scripts\quick.cmd`nrun_every = 3650d`n"))
function Get-StatusSection { param([string]$Name) $m = [regex]::Match((Read-Shared (Join-Path $root 'logs\supervisor\jobs.log')), "(?ms)^$Name\r?\n(.*?)(\r?\n\r?\n|\z)"); $m.Groups[1].Value }
function Start-Run {
    param([string]$Job)
    Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'run', $Job)
}
(Start-Run 'quick').WaitForExit()
[void](Start-Run 'busy')
$busyState = Join-Path $root 'state\jobs\busy.state'
for ($i = 0; $i -lt 60 -and -not ((Get-StateValue $busyState 'status') -ceq 'running' -and (Get-StateValue $busyState 'job_pid')); $i++) { Start-Sleep -Milliseconds 500 }
# gone: a run of this boot whose worker and job have both exited, its
# token left behind.
$gone = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$gone.WaitForExit()
$boot = Get-StateValue (Join-Path $root 'state\jobs\quick.state') 'boot_id'
[System.IO.File]::WriteAllText((Join-Path $root 'state\jobs\gone.state'),
    "[state]`nschema_version = 1`njob = gone`nrun_id = 20260101T000000Z-1-gone`nstatus = running`nboot_id = $boot`nstarted_epoch = 1`njob_pid = $($gone.Id)`nworker_pid = $($gone.Id)`n")
[System.IO.File]::WriteAllText((Join-Path $root 'state\locks\gone.20260101T000000Z-1-gone.token'), '')
Invoke-OnceAlone
Test-Equal 'jobs.log: RUNNING gives the PID, how long, and the time to max_runtime' 'True' "$((Get-StatusSection 'RUNNING') -cmatch '(?m)^  busy: pid \d+, running for \d+s, max_runtime in \d+s\r?$')"
Test-Equal 'jobs.log: LAST RUN gives the outcome, when it ended, and how long it took' 'True' "$((Get-StatusSection 'LAST RUN') -cmatch '(?m)^  quick: succeeded at [0-9T:Z-]+, took \d+s\r?$')"
Test-Equal 'jobs.log: WAITING gives the next time' 'True' "$((Get-StatusSection 'WAITING') -cmatch '(?m)^  later: next ')"
Test-Equal 'jobs.log: INVALID gives why' 'True' "$((Get-StatusSection 'INVALID') -cmatch '(?m)^  broken: .*run_every, run_at or cron')"
Test-Equal 'jobs.log: CRASHED names the run that just crashed' 'True' "$((Get-StatusSection 'CRASHED') -cmatch '(?m)^  gone\r?$')"
Invoke-OnceAlone
Test-Equal 'jobs.log: and only in the tick that concluded it' 'False' "$((Get-StatusSection 'CRASHED') -cmatch 'gone')"
Test-Equal 'jobs.log: then its LAST RUN says crashed' 'True' "$((Get-StatusSection 'LAST RUN') -cmatch '(?m)^  gone: crashed')"
if ($script:fail -gt 0) { Write-Host (Read-Shared (Join-Path $root 'logs\supervisor\jobs.log')) }
$busyPid = Get-StateValue $busyState 'job_pid'
if ($busyPid) { Stop-Process -Id ([int]$busyPid) -Force -ErrorAction SilentlyContinue }
for ($i = 0; $i -lt 60 -and (Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter 'busy.*' -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue

# The revision (16.5): the same file gives the same revision on every
# platform. This one, byte for byte, is 746a566b1e8b, computed with Python's
# hashlib from 16.5's definition; supervise.sh expects the same.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-revision.$PID"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'))
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), "[vigil]`ninstance = revision`n`n[backend.file]`npath = metrics/vigil.prom`n")
Invoke-Tick
Invoke-Tick
$revProm = Join-Path $root 'metrics\vigil.prom'
Test-Equal 'revision: the same as on every platform' '746a566b1e8b' ([regex]::Match($(if (Test-Path -LiteralPath $revProm) { Read-Shared $revProm }), '(?m)^vigil_config_info\{.*revision="([0-9a-f]+)"').Groups[1].Value)
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

# A rejected edit (16.3): the last valid configuration stays active, and so
# the runs it launches use it, not the file that was rejected.
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-rejected.$PID"
foreach ($d in 'config', 'scripts') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'echo metric done 1')
$good = "[vigil]`ninstance = rejected`n`n[scheduler]`ntick = 1s`n`n[job.kept]`nfile      = scripts\quick.cmd`nrun_every = 1s`n"
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $good)
$keptState = Join-Path $root 'state\jobs\kept.state'
$rejOut = Join-Path $root 'supervise.out'
$rejErr = Join-Path $root 'supervise.err'
$rejSup = Start-Process -FilePath $shell -PassThru -NoNewWindow -RedirectStandardOutput $rejOut -RedirectStandardError $rejErr -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
for ($i = 0; $i -lt 60 -and (Get-StateValue $keptState 'status') -cne 'succeeded'; $i++) { Start-Sleep -Seconds 1 }
$before = Get-StateValue $keptState 'run_id'
Test-Equal 'rejected edit: the job ran before it' 'True' ([string][bool]$before)
# An unknown section rejects the whole file.
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), "$good`n[weird]`n")
$supDir = Join-Path $root 'logs\supervisor'
$rejLog = ''
for ($i = 0; $i -lt 30 -and -not $rejLog.Contains('configuration rejected'); $i++) {
    Start-Sleep -Seconds 1
    $rejLog = (Get-ChildItem -LiteralPath $supDir -Filter '*-*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
}
Test-Equal 'rejected edit: the supervisor rejects it' 'True' ([string]$rejLog.Contains('configuration rejected'))
$jobsLog = Join-Path $supDir 'jobs.log'
for ($i = 0; $i -lt 10 -and (Read-Shared $jobsLog) -cnotmatch '(?m)^CONFIGURATION REJECTED - the last valid configuration is active\r?$'; $i++) { Start-Sleep -Seconds 1 }
Test-Equal 'rejected edit: jobs.log says so first' 'CONFIGURATION REJECTED - the last valid configuration is active' (((Read-Shared $jobsLog) -split "`r?`n")[2])
# A run launched after the rejection must still run, with the last valid
# configuration.
$rejected = Get-StateValue $keptState 'run_id'
for ($i = 0; $i -lt 60; $i++) {
    $now = Get-StateValue $keptState 'run_id'
    if ($now -cne $rejected -and $now -cne $before -and (Get-StateValue $keptState 'status') -ceq 'succeeded') { break }
    Start-Sleep -Seconds 1
}
Test-Equal 'rejected edit: later runs still run' 'True' ([string]((Get-StateValue $keptState 'run_id') -cne $rejected -and (Get-StateValue $keptState 'status') -ceq 'succeeded'))

# A valid edit activates at once (16.3): a job added is scheduled without a
# restart, and a run in progress across the activation finishes untouched,
# under the configuration it started with.
Set-Content -LiteralPath (Join-Path $root 'scripts\span.cmd') -Value @('@echo off', 'ping -n 9 127.0.0.1 >nul', 'echo metric done 1')
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), "$good`n[job.span]`nfile      = scripts\span.cmd`nrun_every = 1s`n")
$spanState = Join-Path $root 'state\jobs\span.state'
for ($i = 0; $i -lt 120 -and (Get-StateValue $spanState 'status') -cne 'running'; $i++) { Start-Sleep -Milliseconds 500 }
$spanRid = Get-StateValue $spanState 'run_id'
Test-Equal 'live edit: a run in progress' 'running' (Get-StateValue $spanState 'status')
[System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'),
    "$good`n[job.span]`nfile      = scripts\span.cmd`nrun_every = 3650d`n`n[job.added]`nfile      = scripts\quick.cmd`nrun_every = 1s`n")
$addedState = Join-Path $root 'state\jobs\added.state'
for ($i = 0; $i -lt 120 -and (Get-StateValue $addedState 'status') -cne 'succeeded'; $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'live edit: a job added runs, without a restart' 'succeeded False' "$(Get-StateValue $addedState 'status') $($rejSup.HasExited)"
for ($i = 0; $i -lt 60 -and (Get-StateValue $spanState 'status') -ceq 'running'; $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'live edit: the run across the activation finished untouched' "succeeded $spanRid" "$(Get-StateValue $spanState 'status') $(Get-StateValue $spanState 'run_id')"
$liveLog = (Get-ChildItem -LiteralPath $supDir -Filter '*-*.log' -ErrorAction SilentlyContinue | ForEach-Object { Read-Shared $_.FullName }) -join ''
Test-Equal 'live edit: nothing was stopped' 'False' "$($liveLog -match 'ending its process tree|crashed')"
if (-not $rejSup.HasExited) { Stop-Process -Id $rejSup.Id -Force }
$rejSup.WaitForExit()
if ($script:fail -gt 0) {
    $rejLog = (Get-ChildItem -LiteralPath $supDir -Filter '*-*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    Write-Host $rejLog.Substring([Math]::Max(0, $rejLog.Length - 1500))
}
for ($i = 0; $i -lt 40 -and @(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(kept|span|added)\.' }).Count; $i++) { Start-Sleep -Milliseconds 500 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
$root = $mainRoot

# --- What the core verification found (V-02, V-03, V-04, V-07, V-08) -------
# Each in a root of its own, with nothing of the tests above in it.
$mainRoot = $root
$root = "$mainRoot.v"
$vcfg = Join-Path $root 'config\vigil.config'
function New-VRoot {
    param([string]$Tick)
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
    [System.IO.File]::WriteAllText($vcfg, "[vigil]`ninstance = v`n`n[scheduler]`ntick = $Tick`n")
}
function Add-VConfig { param([string]$Text) [System.IO.File]::AppendAllText($vcfg, $Text) }
function Set-VScript { param([string]$Name, [string[]]$Lines) Set-Content -LiteralPath (Join-Path $root "scripts\$Name") -Value (@('@echo off') + $Lines) }
function Get-VCount {
    param([string]$Pattern)
    $d = Join-Path $root 'logs\supervisor'
    if (-not (Test-Path -LiteralPath $d)) { return 0 }
    @(Get-ChildItem -LiteralPath $d -Filter '2*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match $Pattern }).Count
}
function Get-VStatus { param([string]$Job) Get-StateValue (Join-Path $root "state\jobs\$Job.state") 'status' }
function Get-VLocks { param([string]$Filter) @(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -Filter $Filter -ErrorAction SilentlyContinue).Count }
# Ticks, a second apart, until $Until holds; at most $Tries.
function Invoke-TickUntil { param([scriptblock]$Until, [int]$Tries = 40) for ($i = 0; $i -lt $Tries; $i++) { if (& $Until) { return }; [void](Invoke-Once); Start-Sleep -Seconds 1 } }
function Wait-Until { param([scriptblock]$Until, [int]$Tries = 80) for ($i = 0; $i -lt $Tries; $i++) { if (& $Until) { return }; Start-Sleep -Milliseconds 500 } }
function Start-VSupervisor {
    Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise')
}
# Ends the supervisor this test started, and what it started under this root.
function Stop-VRoot {
    param($Supervisor)
    if ($Supervisor) { Stop-Process -Id $Supervisor.Id -Force -ErrorAction SilentlyContinue }
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

Write-Host 'Numbers with a leading zero (V-03)'
New-VRoot '08s'
Set-VScript 'ok.cmd' @('exit /b 0')
Add-VConfig "`n[log]`nmax_file_mb = 08`nretain_days = 08`n`n[spool]`nmax_mb = 08`n`n[job.ok]`nfile = scripts\ok.cmd`nrun_every = 08m`nmax_runtime = 08s`n"
Test-Equal 'a supervisor reads 08 as eight, and runs' '0' ([string](Invoke-Once))
& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root run ok *> $null
Test-Equal 'so does a worker' '0' "$LASTEXITCODE"

Write-Host 'A launch that throws, after another job''s succeeded (V-02)'
New-VRoot '1s'
Set-VScript 'a.cmd' @('ping -n 41 127.0.0.1 >nul')
Set-VScript 'b.cmd' @('exit /b 0')
$vsup = Start-VSupervisor
# The temporary name of every launch record b could get in the next minutes
# is taken by a directory: b's launch throws, a's does not. Before the jobs
# exist, so that their first slot finds it there.
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'state\locks'))
$t0 = [DateTime]::UtcNow
for ($s = 0; $s -lt 70; $s++) {
    $ts = $t0.AddSeconds($s).ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    foreach ($seq in 1..60) { [void][System.IO.Directory]::CreateDirectory((Join-Path $root "state\locks\b.$ts-$($vsup.Id)-$seq.launch.tmp.$($vsup.Id)")) }
}
Add-VConfig "`n[job.a]`nfile = scripts\a.cmd`nrun_every = 2s`n`n[job.b]`nfile = scripts\b.cmd`nrun_every = 2s`n"
Wait-Until { (Get-VCount 'job b: could not be launched') -ge 2 } 120
Test-Equal 'the job whose launch throws is said, each time' 'True' ([string]((Get-VCount 'job b: could not be launched') -ge 2))
Test-Equal 'the job started before it is started once, not again every tick' '1' ([string](Get-VCount 'job a: run .* started'))
Test-Equal 'one worker, one token' '1' ([string](Get-VLocks 'a.*.token'))
Test-Equal 'and the tick did not fail for it' '0' ([string](Get-VCount 'tick failed'))
Stop-VRoot $vsup

Write-Host 'A run held by queue_one, and its job then disabled (V-08)'
New-VRoot '1s'
Set-VScript 'q.cmd' @('ping -n 21 127.0.0.1 >nul')
Add-VConfig "`n[job.q]`nfile = scripts\q.cmd`nrun_every = 2s`noverlap = queue_one`n"
Invoke-TickUntil { (Get-VCount 'job q: run .* started') -ge 1 }
$vpending = Join-Path $root 'state\pending'
Invoke-TickUntil { (Test-Path -LiteralPath $vpending) -and ([System.IO.File]::ReadAllText($vpending) -match '(?m)^queued=\s*q\s*$') }
Test-Equal 'queue_one holds the next run' 'True' ([string]((Test-Path -LiteralPath $vpending) -and ([System.IO.File]::ReadAllText($vpending) -match '(?m)^queued=\s*q\s*$')))
Add-VConfig "enabled = false`n"
[void](Invoke-Once)
Test-Equal 'disabled: the held run is dropped, and it is said' '1' ([string](Get-VCount 'job q: the run held for it is dropped: the job is disabled'))
# The active run ends; nothing must start in its place.
Wait-Until { (Get-VLocks 'q.*.token') -eq 0 } 80
[void](Invoke-Once); Start-Sleep -Seconds 1; [void](Invoke-Once)
Test-Equal 'and it is never started' '1' ([string](Get-VCount 'job q: run .* started'))
Stop-VRoot $null

Write-Host 'Waiting for a first fetch, with a run in progress (V-04)'
New-VRoot '1s'
Set-VScript 'long.cmd' @('ping -n 91 127.0.0.1 >nul')
Add-VConfig "`n[job.long]`nfile = scripts\long.cmd`nrun_every = 2s`nmax_runtime = 3s`n"
Invoke-TickUntil { (Get-VStatus 'long') -ceq 'running' }
# A source that cannot be fetched, and a job that needs it.
Add-VConfig "`n[source.extra]`ntype = local`npath = $root\nowhere`n`n[job.fromsource]`nsource = extra`nfile = check.cmd`nrun_every = 1h`n"
Invoke-TickUntil { (Get-VStatus 'long') -cne 'running' } 30
$vjobs = Join-Path $root 'logs\supervisor\jobs.log'
Test-Equal 'the configuration waits for its first fetch' 'True' ([string]((Test-Path -LiteralPath $vjobs) -and [System.IO.File]::ReadAllText($vjobs).Contains('waiting for the first fetch')))
Test-Equal 'a run in progress is still held to its max_runtime' 'timed_out' (Get-VStatus 'long')
Stop-VRoot $null

Write-Host 'state_dir changed while a run is in progress (V-07)'
New-VRoot '1s'
Set-VScript 'long.cmd' @('ping -n 13 127.0.0.1 >nul')
Add-VConfig "`n[job.long]`nfile = scripts\long.cmd`nrun_every = 2s`n"
$vsup = Start-VSupervisor
Wait-Until { (Get-VLocks 'long.*.token') -ge 1 } 120
Test-Equal 'a run is in progress' '1' ([string](Get-VLocks 'long.*.token'))
[System.IO.File]::WriteAllText($vcfg, ([System.IO.File]::ReadAllText($vcfg) -replace '(?m)^instance = v$', "instance = v`nstate_dir = state2"))
Wait-Until { (Get-VCount 'state_dir is now .* takes effect when Vigil is next started') -ge 1 } 40
Test-Equal 'the supervisor says the change waits for the next start' '1' ([string](Get-VCount 'state_dir is now .* takes effect when Vigil is next started'))
Test-Equal 'it keeps the state directory it started with' 'False' ([string](Test-Path -LiteralPath (Join-Path $root 'state2\locks')))
Test-Equal 'and starts no second run beside the first' '1' ([string](Get-VCount 'job long: run .* started'))
# The first run ends; the next one's worker must find its launch record in
# the supervisor's directory, whatever the file says now.
Wait-Until { (Get-VCount 'job long: run .* started') -ge 2 } 120
Wait-Until { (Get-VLocks 'long.*.token') -ge 1 } 60
Test-Equal 'a run started after the edit claims its launch there' '1 0' "$(Get-VLocks 'long.*.token') $(Get-VLocks 'long.*.launch')"
Stop-VRoot $vsup
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
$root = $mainRoot

# Workers started by the last ticks may still be finishing.
Start-Sleep -Seconds 6
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
