#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: uncertain runs (SPECIFICATION.md 11.4, 11.5; fault
    injection 22.4 cases 10, 11, 12, 18, 19) on Windows.
.DESCRIPTION
    Each of three jobs gets a run that is alive (a process holds its run
    token) and past its deadline, but whose recorded job process is an
    unrelated one: ownership cannot be proven, so nothing may be killed.
    The jobs differ only in on_uncertain:
      w  wait     held while uncertain; released when the evidence clears
      r  replace  scheduling goes on, posting possible_duplicates
      m  manual   still held after the evidence clears, until vigil resolve
    Every tick is a fresh supervisor process, so holds must survive
    restarts. The twin of uncertain.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-unc.$PID"
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
    & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root supervise --once *>> (Join-Path $root 'once.out')
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

function Get-Section {
    param([string]$Name)
    $text = [System.IO.File]::ReadAllText((Join-Path $root 'logs\supervisor\jobs.log'))
    return [regex]::Match($text, "(?ms)^$Name\r?\n(.*?)(\r?\n\r?\n|\z)").Groups[1].Value
}

function Get-SupervisorLog {
    return (Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '*-*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$locks = Join-Path $root 'state\locks'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'), (Join-Path $root 'state\jobs'), $locks)
Set-Content -LiteralPath (Join-Path $root 'scripts\quick.cmd') -Value @('@echo off', 'ping -n 2 127.0.0.1 >nul')
Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

[job.w]
file         = scripts\quick.cmd
run_every    = 2s
on_uncertain = wait

[job.r]
file         = scripts\quick.cmd
run_every    = 2s
on_uncertain = replace

[job.m]
file         = scripts\quick.cmd
run_every    = 2s
on_uncertain = manual
"@

. (Join-Path $repo 'app\lib\windows\Worker.ps1')
$boot = Get-VigilBootId

# An unrelated process: the recorded "job process" of every fake run. It
# must never be killed.
$unrelated = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '300', '127.0.0.1' -PassThru -WindowStyle Hidden
$now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
$holders = @{}
foreach ($j in @('w', 'r', 'm')) {
    $rid = "20260101T000000Z-9-$j"
    $token = Join-Path $locks "$j.$rid.token"
    [System.IO.File]::WriteAllText($token, '')
    # A stand-in worker: holds the run token exclusively, so the run is alive.
    $holders[$j] = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command',
        "`$f = [System.IO.File]::Open('$token', 'Open', 'Read', 'None'); Start-Sleep -Seconds 300")
    [System.IO.File]::WriteAllText((Join-Path $root "state\jobs\$j.state"),
        "[state]`nschema_version = 1`njob = $j`nrun_id = $rid`nstatus = running`nboot_id = $boot`nstarted_epoch = $now`n" +
        "deadline_epoch = 1`njob_pid = $($unrelated.Id)`njob_name = cmd.exe`n")
}
Start-Sleep -Seconds 3

Invoke-Tick
Start-Sleep -Seconds 3
Invoke-Tick

foreach ($j in @('w', 'r', 'm')) {
    Test-Equal "${j}: recovery record written" 'uncertain' (Get-StateValue (Join-Path $root "state\recovery\$j.recovery") 'conclusion')
    Test-Equal "${j}: listed as uncertain" 'True' "$((Get-Section 'UNCERTAIN') -match "  ${j}: past max_runtime, but its job process cannot be proven")"
}
Test-Equal 'w: policy recorded' 'wait' (Get-StateValue (Join-Path $root 'state\recovery\w.recovery') 'policy')
Test-Equal 'unrelated process never killed' 'False' "$($unrelated.HasExited)"
Test-Equal 'w: held, no new run' '0' "$(@(Get-ChildItem -LiteralPath $locks -Filter 'w.*' | Where-Object { $_.Name -notlike '*-9-w*' }).Count)"
Test-Equal 'm: held, no new run' '0' "$(@(Get-ChildItem -LiteralPath $locks -Filter 'm.*' | Where-Object { $_.Name -notlike '*-9-m*' }).Count)"
Test-Equal 'r: replaced, a new run started' 'True' "$((Get-SupervisorLog) -match 'job r: run .* started beside an uncertain run')"
Invoke-Tick
Test-Equal 'uncertain gauge delivered' '1' (Get-Prom 'w_uncertain')
Test-Equal 'possible duplicates counted' 'True' "$((Get-Prom 'r_possible_duplicates_total') -ne '')"
& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root resolve nosuch *> $null
Test-Equal 'resolve refuses a job that is not held' '1' "$LASTEXITCODE"

# The evidence clears: the stand-in workers exit, releasing their tokens.
Stop-Process -Id $holders['w'].Id, $holders['m'].Id -Force
Start-Sleep -Seconds 1
Invoke-Tick
# Released at once, w may already have run again: its conclusion is in the log.
Test-Equal 'w: concluded crashed' 'True' "$((Get-SupervisorLog) -match 'job w: run 20260101T000000Z-9-w crashed')"
Test-Equal 'w: released, record gone' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'state\recovery\w.recovery'))"
Test-Equal 'm: concluded crashed' 'crashed' (Get-StateValue (Join-Path $root 'state\jobs\m.state') 'status')
Test-Equal 'm: still held after the evidence cleared' 'crashed' (Get-StateValue (Join-Path $root 'state\recovery\m.recovery') 'conclusion')
Test-Equal 'm: listed as held until resolved' 'True' "$((Get-Section 'UNCERTAIN') -match '  m: run .* crashed; held until vigil resolve')"
Invoke-Tick
Test-Equal 'm: held across another restart' 'True' "$(Test-Path -LiteralPath (Join-Path $root 'state\recovery\m.recovery'))"

& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root resolve m *> $null
Test-Equal 'resolve succeeds for a held job' '0' "$LASTEXITCODE"
Invoke-Tick
Test-Equal 'm: released after resolve' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'state\recovery\m.recovery'))"
Test-Equal 'release logged with who resolved it' 'True' "$((Get-SupervisorLog) -match 'job m: hold on run 20260101T000000Z-9-m released, resolved by')"
Test-Equal 'unrelated process still never killed' 'False' "$($unrelated.HasExited)"
Test-Equal 'no tick failed' 'False' "$((Get-SupervisorLog) -match 'tick failed')"

if ($script:fail -gt 0) {
    Write-Host "`nsupervisor log:"
    Write-Host (((Get-SupervisorLog).Split("`n") | Select-Object -Last 40) -join "`n")
}
foreach ($p in @($unrelated) + @($holders.Values)) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
Start-Sleep -Seconds 4
Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
