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
    Integration test: the crash points of SPECIFICATION.md 22.4.1 drive the
    launch and fan-out tests of 22.4 (20 to 23, 25 to 29), the worker's own
    crash points (7, 16), and a held queue_one run launched as the
    supervisor crashes (8, 9), on Windows.
.DESCRIPTION
    The twin of crash.sh. Two invariants:
      launch:  exactly one run per launch, or none, never two;
      fan-out: every event reaches every one of its targets at least once,
               and no partial file is ever sent.

    CRASH_RACE_ROUNDS (default 10) sets how many times test 23 races a claim
    against an abandonment; CRASH_LOOP_ROUNDS (default 6) the rounds of the
    randomised loop (29).

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-crash.$PID"
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
    try { foreach ($l in [System.IO.File]::ReadAllLines($Path)) { if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] } } } catch { }
    return ''
}

# A tick, waiting for that process alone (a detached worker inherits no pipe
# of ours, but capturing output would wait for it anyway), with the
# environment given. Returns its exit code.
function Invoke-Once {
    param([hashtable]$Env = @{})
    foreach ($k in $Env.Keys) { Set-Item "Env:\$k" $Env[$k] }
    try {
        $p = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'supervise', '--once')
        $p.WaitForExit()
        return $p.ExitCode
    }
    finally { foreach ($k in $Env.Keys) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } }
}
function Get-Locks { param([string]$Job) @(Get-ChildItem -LiteralPath "$root\state\locks" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith("$Job.") } | ForEach-Object Name) -join ' ' }
function Get-LockRid { param([string]$Job) $l = (Get-Locks $Job).Split(' ')[0]; if (-not $l) { return '' }; return ($l.Substring($Job.Length + 1) -replace '\.(launch|token)$', '') }
function Get-Marks { $f = "$root\marks"; if (Test-Path -LiteralPath $f) { @([System.IO.File]::ReadAllLines($f) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() } }
function Get-MarkCount { param([string]$Rid) @(Get-Marks | Where-Object { $_ -ceq $Rid }).Count }
function Get-Overlap { $f = "$root\overlap"; if (Test-Path -LiteralPath $f) { [System.IO.File]::ReadAllText($f).Trim() } else { '' } }
# A sender may be writing a file backend's file while it is read: wait for
# it (up to 5 s) rather than take a busy file for a missing event.
function Read-Backend {
    param([string]$Path)
    for ($i = 0; ; $i++) {
        try { return [System.IO.File]::ReadAllText($Path) }
        catch [System.IO.IOException] { if ($i -ge 50) { throw }; Start-Sleep -Milliseconds 100 }
    }
}
function Test-InBoth { param([string]$Name) foreach ($b in 'a', 'b') { $f = "$root\metrics\$b.prom"; if (-not (Test-Path -LiteralPath $f) -or -not ((Read-Backend $f) -cmatch "(?m)^$Name")) { return $false } }; return $true }
function Wait-Ticking { param([int]$Times, [scriptblock]$Until) for ($i = 0; $i -lt $Times -and -not (& $Until); $i++) { [void](Invoke-Once); Start-Sleep -Seconds 1 } }
function Set-LaunchOld {
    param([string]$Job, [string]$Rid)
    $f = "$root\state\locks\$Job.$Rid.launch"
    if (Test-Path -LiteralPath $f) { [System.IO.File]::WriteAllText($f, ([System.IO.File]::ReadAllText($f) -replace '(?m)^launch_epoch .*$', 'launch_epoch  = 1')) }
}
function Set-Config {
    param([string]$Every)
    [System.IO.File]::WriteAllText("$root\config\vigil.config", @"
[vigil]
instance = crash

[scheduler]
tick = 1s

[backend.a]
type = file
path = metrics\a.prom

[backend.b]
type = file
path = metrics\b.prom

[job.mark]
file      = scripts\mark.cmd
env       = IT_ROOT=$root
run_every = $Every
"@)
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path "$root\config", "$root\scripts", "$root\state\locks", "$root\spool\incoming")
# The job records its run id, and an overlap if two runs ever meet.
Set-Content -LiteralPath "$root\scripts\mark.cmd" -Value @(
    '@echo off',
    'mkdir "%IT_ROOT%\inflight" 2>nul || echo overlap>>"%IT_ROOT%\overlap"',
    'echo %VIGIL_RUN_ID%>>"%IT_ROOT%\marks"',
    'ping -n 2 127.0.0.1 >nul',
    'rmdir "%IT_ROOT%\inflight" 2>nul',
    'echo metric ran 1')

# --- Launch window (22.4, 20 to 22) -------------------------------------------------

# A launch crash point fires at the first launch of a tick, and a tick
# launches its due jobs before the sender (8, 4.5). So each test first lets
# the job's runs end, then makes it due: its launch is then the tick's first.
function Invoke-Settle { Set-Config '3650d'; Wait-Ticking 40 { -not (Get-Locks 'mark') }; Set-Config '1s' }
function Invoke-FaultTick {
    param([hashtable]$Env)
    $script:code = 0
    for ($i = 0; $i -lt 10; $i++) {
        $script:code = Invoke-Once $Env
        if (Get-Locks 'mark') { break }
        Start-Sleep -Seconds 1
    }
    $script:rid = Get-LockRid 'mark'
}

Set-Config '1s'
Wait-Ticking 30 { Test-Path -LiteralPath "$root\state\jobs\mark.state" }

# 20. launch.after_record: the record is written, the worker never started.
Invoke-Settle
Invoke-FaultTick @{ VIGIL_FAULT = 'launch.after_record' }
Set-Config '3650d'
Test-Equal '20: the supervisor crashed after the record' '99' "$code"
Test-Equal '20: the launch record is there' 'True' ([string]([bool]$rid -and (Test-Path -LiteralPath "$root\state\locks\mark.$rid.launch")))
Start-Sleep -Seconds 3
Test-Equal '20: the job did not run' '0' "$(Get-MarkCount $rid)"
[void](Invoke-Once)
Test-Equal '20: a young launch is held, nothing else started' "mark.$rid.launch" (Get-Locks 'mark')
Set-LaunchOld 'mark' $rid
[void](Invoke-Once)
Test-Equal '20: past its grace, abandoned' '' (Get-Locks 'mark')
Test-Equal '20: and never run' '0' "$(Get-MarkCount $rid)"

# 21. launch.after_spawn: the worker started, then the supervisor crashed.
# One crash only, and the run found by its mark, not its lock: a fast worker
# can be done before a lock is looked for.
Invoke-Settle
$before = @(Get-Marks)
$code = Invoke-Once @{ VIGIL_FAULT = 'launch.after_spawn' }
Set-Config '3650d'
Test-Equal '21: the supervisor crashed after the spawn' '99' "$code"
$rid = ''
for ($i = 0; $i -lt 60 -and -not $rid; $i++) {
    Start-Sleep -Milliseconds 500
    $rid = @(Get-Marks | Where-Object { $before -cnotcontains $_ })[0]
}
Test-Equal '21: the worker claimed and ran the job' '1' "$(Get-MarkCount $rid)"
Wait-Ticking 30 { -not (Get-Locks 'mark') }
Test-Equal '21: run once, never beside itself' '1|' "$(Get-MarkCount $rid)|$(Get-Overlap)"
Test-Equal '21: and recorded' 'succeeded' (Get-StateValue "$root\state\jobs\mark.state" 'status')
if ((Get-MarkCount $rid) -ne 1) {
    # What became of the worker the crashed supervisor started.
    Write-Host "`n21: run $rid, exit code $code; marks: $((Get-Marks) -join ' ')"
    Write-Host "locks now: $(Get-Locks 'mark')"
    $sl = (Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    ($sl -split "`n" | Where-Object { $_.Contains($rid) }) | ForEach-Object { Write-Host "  supervisor: $($_.Trim())" }
    Get-ChildItem -LiteralPath "$root\logs\jobs\mark" -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } |
        Where-Object { $_.Contains($rid) } | ForEach-Object { Write-Host "  job log: $_" }
    Write-Host "  mark.state: $((Get-Content -LiteralPath "$root\state\jobs\mark.state" -ErrorAction SilentlyContinue) -join ' | ')"
}
$boot = Get-StateValue "$root\state\jobs\mark.state" 'boot_id'

# 22. worker.before_claim held past the grace: a process carries the run id,
# so the supervisor keeps holding and starts nothing (11.3); the late worker
# then claims and runs the job, once.
Invoke-Settle
Invoke-FaultTick @{ VIGIL_FAULT = 'worker.before_claim'; VIGIL_FAULT_SLEEP = '10' }
Set-Config '3650d'
Test-Equal '22: launched, its worker waiting' "mark.$rid.launch" (Get-Locks 'mark')
Set-LaunchOld 'mark' $rid
[void](Invoke-Once)
Test-Equal '22: past its grace, still held: nothing else started' "mark.$rid.launch" (Get-Locks 'mark')
for ($i = 0; $i -lt 80 -and (Get-MarkCount $rid) -eq 0; $i++) { Start-Sleep -Milliseconds 500 }
Wait-Ticking 30 { -not (Get-Locks 'mark') }
Test-Equal '22: the late worker ran the job, once' '1|' "$(Get-MarkCount $rid)|$(Get-Overlap)"
Test-Equal '22: no token left behind' '' (Get-Locks 'mark')

# --- 23. Claim against abandonment ---------------------------------------------------

# A worker starts on an old launch record while a tick abandons it: exactly
# one side wins, every time.
$rounds = if ($env:CRASH_RACE_ROUNDS -cmatch '^[0-9]+$') { [int]$env:CRASH_RACE_ROUNDS } else { 10 }
$both = 0; $neither = 0
for ($r = 1; $r -le $rounds; $r++) {
    $rid = "20260101T000000Z-23-$r"
    [System.IO.File]::WriteAllText("$root\state\locks\mark.$rid.launch", "[launch]`njob           = mark`nrun_id        = $rid`nboot_id       = $boot`nlaunch_epoch  = 1`n")
    $w = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$vigil`"", '-Root', "`"$root`"", 'worker', 'mark', '--run-id', $rid)
    [void](Invoke-Once)
    $w.WaitForExit()
    $ran = (Get-MarkCount $rid) -gt 0
    $log = (Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
    $abandoned = $log.Contains("launch $rid abandoned")
    if ($ran -and $abandoned) { $both++ }
    if (-not $ran -and -not $abandoned) { $neither++ }
    Wait-Ticking 15 { -not (Get-Locks 'mark') }
}
Test-Equal "23: $rounds races, never both" '0' "$both"
Test-Equal '23: and never neither' '0' "$neither"
Test-Equal '23: no run ever met another' '' (Get-Overlap)

# --- Fan-out (22.4, 25 and 26) -----------------------------------------------------

# One event, named $Name, put in the spool as a job's would be.
function Add-Event {
    param([string]$Name)
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $f = "$root\spool\incoming\$now-it-$Name.events"
    [System.IO.File]::WriteAllText("$f.tmp", "$now $Name 1 gauge host=it`n")
    [System.IO.File]::Move("$f.tmp", $f)
}
function Get-SenderLog { (Get-ChildItem -LiteralPath "$root\logs\jobs\vigil_sender" -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join '' }
# The sender's run ids that started.
function Get-SenderRuns { @([regex]::Matches((Get-SenderLog), '(?m)^\S+ (\S+) run start') | ForEach-Object { $_.Groups[1].Value }) }

# 25. A sender crashed at each point; a later one finishes the fan-out.
$n = 0
foreach ($point in 'fanout.after_claim', 'fanout.after_targets', 'fanout.after_place:1', 'fanout.after_place:2', 'fanout.before_retire', 'sender.after_send') {
    $n++
    $name = "crash_$n"
    # No sender running: one would take the event before the crashing one.
    for ($i = 0; $i -lt 120 -and (Get-Locks 'vigil_sender'); $i++) { Start-Sleep -Milliseconds 500 }
    Add-Event $name
    $before = Get-SenderRuns
    [void](Invoke-Once @{ VIGIL_FAULT = $point })
    $new = ''
    for ($i = 0; $i -lt 60 -and -not $new; $i++) {
        Start-Sleep -Milliseconds 500
        $new = @(Get-SenderRuns | Where-Object { $before -cnotcontains $_ })[0]
    }
    Start-Sleep -Seconds 4
    $ended = (Get-SenderLog).Contains(" $new run end ")
    Test-Equal "25: ${point}: the sender crashed there" 'started|no end' "$(if ($new) { 'started' })|$(if ($ended) { 'ended' } else { 'no end' })"
    Wait-Ticking 30 { Test-InBoth $name }
    Test-Equal "25: ${point}: every target has the event" 'True' "$(Test-InBoth $name)"
}
Wait-Ticking 15 { -not (Get-ChildItem -LiteralPath "$root\spool\fanout" -File -ErrorAction SilentlyContinue) }
Test-Equal '25: nothing left in the fan-out' '' ((@(Get-ChildItem -LiteralPath "$root\spool\fanout" -File -ErrorAction SilentlyContinue | ForEach-Object Name)) -join ' ')

# 26. A copy left half-written (a temporary file) is never sent.
[void](New-Item -ItemType Directory -Force -Path "$root\spool\backends\a")
$partial = "$root\spool\backends\a\.1-it-partial.events.tmp.123"
[System.IO.File]::WriteAllText($partial, "$([DateTimeOffset]::Now.ToUnixTimeSeconds()) partial_copy 1 gauge host=it`n")
Add-Event 'after_partial'
Wait-Ticking 15 { Test-InBoth 'after_partial' }
Test-Equal '26: a temporary file is never sent' 'False' "$((Read-Backend "$root\metrics\a.prom") -cmatch '(?m)^partial_copy')"
Remove-Item -LiteralPath $partial -ErrorAction SilentlyContinue

# 27. A backend removed between a crash and the resume: its copy is dropped
# and counted, and the other backend still gets the event.
function Test-DroppedB { (Read-Backend "$root\metrics\a.prom") -cmatch '(?m)^vigil_spool_dropped_total\{backend="b".*reason="backend_removed"' }
function Test-InA { param([string]$Name) (Test-Path -LiteralPath "$root\metrics\a.prom") -and ((Read-Backend "$root\metrics\a.prom") -cmatch "(?m)^$Name") }
function Test-Targets { [bool](Get-ChildItem -LiteralPath "$root\spool\fanout" -Filter '*.targets' -ErrorAction SilentlyContinue) }
Set-Config '3650d'
for ($i = 0; $i -lt 60 -and (Get-Locks 'vigil_sender'); $i++) { Start-Sleep -Milliseconds 500 }
Add-Event 'removed_b'
[void](Invoke-Once @{ VIGIL_FAULT = 'fanout.after_targets' })
# It crashes at the first file it claims, which may be an older one of
# Vigil's own: any fan-out with its targets fixed will do.
for ($i = 0; $i -lt 40 -and -not (Test-Targets); $i++) { Start-Sleep -Milliseconds 500 }
Start-Sleep -Seconds 1
Test-Equal '27: the sender crashed with the targets fixed' 'True' "$(Test-Targets)"
$cfgPath = "$root\config\vigil.config"
[System.IO.File]::WriteAllText($cfgPath, ([System.IO.File]::ReadAllText($cfgPath) -replace '(?ms)^\[backend\.b\]\r?\ntype = file\r?\npath = metrics\\b\.prom\r?\n', ''))
Wait-Ticking 30 { (Test-InA 'removed_b') -and (Test-DroppedB) }
Test-Equal '27: the backend left has the event' 'True' "$(Test-InA 'removed_b')"
Test-Equal "27: the removed one's copy dropped, counted as backend_removed" 'True' "$(Test-DroppedB)"
# Once the senders have finished: the next may be mid-way through Vigil's own
# newer events, which are not this test's.
for ($i = 0; $i -lt 60 -and (Get-Locks 'vigil_sender'); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal '27: nothing left in the fan-out' '' ((@(Get-ChildItem -LiteralPath "$root\spool\fanout" -File -ErrorAction SilentlyContinue | ForEach-Object Name)) -join ' ')
# b back. A sender started without it delivers by the configuration it was
# launched with (4.3), even events that arrive while it starts: let it end.
Set-Config '3650d'
for ($i = 0; $i -lt 60 -and (Get-Locks 'vigil_sender'); $i++) { Start-Sleep -Milliseconds 500 }

# 28. A copy that fails, as on a full disk: a file where b's queue directory
# should be. The fan-out is not retired, a gets the event meanwhile, and b
# gets it once its copy can be made.
function Test-InB { param([string]$Name) (Test-Path -LiteralPath "$root\metrics\b.prom") -and ((Read-Backend "$root\metrics\b.prom") -cmatch "(?m)^$Name") }
function Test-Fanout { param([string]$Pattern) [bool](@(Get-ChildItem -LiteralPath "$root\spool\fanout" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -cmatch $Pattern })) }
$bq = "$root\spool\backends\b"
Wait-Ticking 30 { -not (Get-ChildItem -LiteralPath $bq -ErrorAction SilentlyContinue) }
Remove-Item -LiteralPath $bq -Recurse -Force -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText($bq, '')
Add-Event 'full_disk'
Wait-Ticking 30 { Test-InA 'full_disk' }
[void](Invoke-Once)
Test-Equal '28: the backend whose copy worked gets the event' 'True' "$(Test-InA 'full_disk')"
Test-Equal '28: the fan-out is not retired' 'True' "$(Test-Fanout 'full_disk\.events$')"
Test-Equal '28: the failed copy is not marked done' 'False' "$(Test-Fanout 'full_disk\.events\.b\.done$')"
Remove-Item -LiteralPath $bq -Force
Wait-Ticking 30 { Test-InB 'full_disk' }
Test-Equal '28: once the copy can be made, b gets the event' 'True' "$(Test-InB 'full_disk')"
Wait-Ticking 15 { -not (Test-Fanout 'full_disk') }
Test-Equal '28: and the fan-out is retired' 'False' "$(Test-Fanout 'full_disk')"

# --- 29. A randomised crash loop ------------------------------------------------------

$points = @('launch.after_record', 'launch.after_spawn', 'fanout.after_claim', 'fanout.after_targets', 'fanout.after_place:1',
    'fanout.after_place:2', 'fanout.before_retire', 'sender.after_send', 'state.after_temp')
$loop = if ($env:CRASH_LOOP_ROUNDS -cmatch '^[0-9]+$') { [int]$env:CRASH_LOOP_ROUNDS } else { 6 }
$lost = 0
Set-Config '1s'
for ($r = 1; $r -le $loop; $r++) {
    $point = $points[(Get-Random -Maximum $points.Count)]
    Add-Event "loop_$r"
    [void](Invoke-Once @{ VIGIL_FAULT = $point })
    Start-Sleep -Seconds 3
    # Abandon any launch the crash left, as the grace would: the job's, or
    # the sender's when the job was still running and the sender's launch
    # was the tick's first.
    foreach ($f in @(Get-ChildItem -LiteralPath "$root\state\locks" -Filter '*.launch' -File -ErrorAction SilentlyContinue)) {
        [System.IO.File]::WriteAllText($f.FullName, ([System.IO.File]::ReadAllText($f.FullName) -replace '(?m)^launch_epoch .*$', 'launch_epoch  = 1'))
    }
    Wait-Ticking 30 { Test-InBoth "loop_$r" }
    if (-not (Test-InBoth "loop_$r")) { $lost++; Write-Host "        lost after $point" }
}
Set-Config '3650d'
Wait-Ticking 30 { -not (Get-Locks 'mark') }
Test-Equal "29: $loop random crashes, every event delivered" '0' "$lost"
Test-Equal '29: no launch ever ran twice' '' ((@(Get-Marks | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object Name)) -join ' ')
Test-Equal '29: no run ever met another' '' (Get-Overlap)

# --- A queued run (9): a crash after its launch never runs it twice ------------------
#
# q holds one run while another is active (queue_one). When the active run
# ends, a tick launches the held one, and crashes right after (backlog 58).
# The held run must be gone from state\pending by then, or the next
# supervisor runs it again. q runs for 8 seconds: a tick here can take a few.
Set-Content -LiteralPath "$root\scripts\q.cmd" -Value @(
    '@echo off',
    'echo %VIGIL_RUN_ID%>>"%IT_ROOT%\qmarks"',
    'ping -n 9 127.0.0.1 >nul')
function Set-ConfigQ {
    param([string]$Every)
    Set-Config '3650d'
    [System.IO.File]::AppendAllText("$root\config\vigil.config", @"

[job.q]
file      = scripts\q.cmd
env       = IT_ROOT=$root
overlap   = queue_one
run_every = $Every
"@)
}
function Test-QQueued { $f = "$root\state\pending"; (Test-Path -LiteralPath $f) -and ([System.IO.File]::ReadAllText($f) -cmatch '(?m)^queued=(.* )?q( |\r?$)') }
Set-ConfigQ '2s'
Wait-Ticking 15 { [bool](Get-Locks 'q') }
# Its next slot comes due while the first run is active: held.
Start-Sleep -Seconds 2
Wait-Ticking 5 { Test-QQueued }
Test-Equal 'queued: a run is held while one is active' 'True' "$(Test-QQueued)"
# Nothing else comes due: only the held run is left to start.
Set-ConfigQ '3650d'
for ($i = 0; $i -lt 30 -and (Get-Locks 'q'); $i++) { Start-Sleep -Seconds 1 }
$code = Invoke-Once @{ VIGIL_FAULT = 'launch.after_spawn' }
Test-Equal 'queued: the supervisor crashed after launching it' '99' "$code"
Test-Equal 'queued: and it is no longer held' 'False' "$(Test-QQueued)"
# Tick until the held run has ended, then a few more.
Wait-Ticking 30 { -not (Get-Locks 'q') }
for ($i = 0; $i -lt 6; $i++) { [void](Invoke-Once); Start-Sleep -Seconds 1 }
Wait-Ticking 30 { -not (Get-Locks 'q') }
Test-Equal 'queued: two runs, never three' '2' "$(@([System.IO.File]::ReadAllLines("$root\qmarks") | Where-Object { $_.Trim() }).Count)"

# --- The worker's crash points (7, 16, 23) ------------------------------------------
#
# Each case crashes the worker of one run of w at a point, then ticks once:
# the run must be concluded as what it was, run once or not at all, and
# leave no token. w runs for 8 s, so a sender started by the same tick is
# done before w's events are written, and the supervisor finds them where
# the worker left them.
Set-Content -LiteralPath "$root\scripts\w.cmd" -Value @(
    '@echo off',
    'echo %VIGIL_RUN_ID%>>"%IT_ROOT%\wmarks"',
    'ping -n 9 127.0.0.1 >nul')
function Set-ConfigW {
    param([string]$Every)
    Set-Config '3650d'
    [System.IO.File]::AppendAllText("$root\config\vigil.config", @"

[job.w]
file      = scripts\w.cmd
env       = IT_ROOT=$root
run_every = $Every
"@)
}
function Get-WRan { param([string]$Rid) $f = "$root\wmarks"; if (Test-Path -LiteralPath $f) { @([System.IO.File]::ReadAllLines($f) | Where-Object { $_.Trim() -ceq $Rid }).Count } else { 0 } }
function Get-WState { param([string]$Key) Get-StateValue "$root\state\jobs\w.state" $Key }
# One run of w with VIGIL_FAULT=$Point; once no process carries its run id,
# one tick.
function Invoke-WCrash {
    param([string]$Point)
    Set-ConfigW '3650d'
    Wait-Ticking 30 { -not (Get-Locks 'w') }
    Set-ConfigW '1s'
    $script:wrid = ''
    for ($i = 0; $i -lt 10 -and -not $script:wrid; $i++) {
        [void](Invoke-Once @{ VIGIL_FAULT = $Point })
        $script:wrid = Get-LockRid 'w'
        if (-not $script:wrid) { Start-Sleep -Seconds 1 }
    }
    Set-ConfigW '3650d'
    $r = $script:wrid
    for ($i = 0; $i -lt 60 -and @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($r) }).Count; $i++) { Start-Sleep -Milliseconds 500 }
    [void](Invoke-Once)
}

# 23. worker.after_claim: the token taken, the job never started.
Invoke-WCrash 'worker.after_claim'
Test-Equal 'worker.after_claim: never ran' '0' "$(Get-WRan $wrid)"
Test-Equal 'worker.after_claim: concluded crashed' "crashed $wrid" "$(Get-WState 'status') $(Get-WState 'run_id')"
Test-Equal 'worker.after_claim: no token left' '' (Get-Locks 'w')

# 7. state.after_temp:1: the first state write interrupted, its temporary
# file left behind, before the job starts.
Invoke-WCrash 'state.after_temp:1'
Test-Equal '7: state.after_temp:1: never ran' '0' "$(Get-WRan $wrid)"
Test-Equal '7: state.after_temp:1: concluded crashed' "crashed $wrid" "$(Get-WState 'status') $(Get-WState 'run_id')"
Test-Equal '7: state.after_temp:1: the temporary file is left, never read' 'True' "$([bool](Get-ChildItem -LiteralPath "$root\state\jobs" -Filter 'w.state.tmp.*' -File -ErrorAction SilentlyContinue))"
Test-Equal '7: state.after_temp:1: no token left' '' (Get-Locks 'w')

# 7 and 16. state.after_temp:3: the final state write interrupted, after
# the run's events: reconciled from them.
Invoke-WCrash 'state.after_temp:3'
Test-Equal '7: state.after_temp:3: ran once' '1' "$(Get-WRan $wrid)"
Test-Equal '7: state.after_temp:3: reconciled from its spool file' "succeeded|reconciled from the spool file|$wrid" "$(Get-WState 'status')|$(Get-WState 'reason')|$(Get-WState 'run_id')"
Test-Equal '7: state.after_temp:3: no token left' '' (Get-Locks 'w')

# 16. worker.after_spool: the events written, the final state never.
Invoke-WCrash 'worker.after_spool'
Test-Equal '16: worker.after_spool: ran once' '1' "$(Get-WRan $wrid)"
Test-Equal '16: worker.after_spool: reconciled from its spool file' "succeeded|reconciled from the spool file|$wrid" "$(Get-WState 'status')|$(Get-WState 'reason')|$(Get-WState 'run_id')"
Test-Equal '16: worker.after_spool: no token left' '' (Get-Locks 'w')

# worker.after_state: the final state written, the token never released.
Invoke-WCrash 'worker.after_state'
Test-Equal 'worker.after_state: ran once' '1' "$(Get-WRan $wrid)"
Test-Equal 'worker.after_state: its own outcome kept' "succeeded||$wrid" "$(Get-WState 'status')|$(Get-WState 'reason')|$(Get-WState 'run_id')"
$slog = (Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'worker.after_state: not taken for a crash' 'False' "$($slog.Contains("run $wrid crashed"))"
Test-Equal 'worker.after_state: no token left' '' (Get-Locks 'w')
Test-Equal "the worker's crash points: no run ever ran twice" '' ((@([System.IO.File]::ReadAllLines("$root\wmarks") | Where-Object { $_.Trim() } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object Name)) -join ' ')

# The supervisor says when crash points are on (22.4.1).
$log = (Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'the supervisor warns while VIGIL_FAULT is set' 'True' "$($log.Contains('VIGIL_FAULT is set'))"

if ($script:fail -gt 0) {
    Write-Host "`nsupervisor log, last 30 lines:"
    ($log -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 30) | ForEach-Object { Write-Host "  $_" }
}
# Let any worker still running end before cleaning up.
for ($i = 0; $i -lt 30 -and (Get-ChildItem -LiteralPath "$root\state\locks" -File -ErrorAction SilentlyContinue); $i++) { [void](Invoke-Once); Start-Sleep -Seconds 1 }
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
