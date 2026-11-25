# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Lead 2, PowerShell engine: two jobs due in the same tick, a (first) and b
# (second). b's launch is made to throw: the temporary name of its launch
# record (locks\b.<run id>.launch.tmp.<pid>) is taken by a directory, for
# every run id the supervisor could give it in the next minutes. That stands
# for anything that makes a launch throw after an earlier one succeeded (a
# disk filling at the flush, a process that cannot be started).
# What happens to a, already started, on the following ticks?
# -Control: the same without the obstruction.
# Throwaway root under $env:TEMP\vv. Ends only processes whose command line
# names that root.
param([string]$Shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", [switch]$Control,
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..\..\..\..')).Path)
$base = Join-Path $env:TEMP 'vv'
[void](New-Item -ItemType Directory -Force -Path $base)
$r = Join-Path $base ("r-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $r)
Copy-Item -Recurse (Join-Path $Repo 'app'), (Join-Path $Repo 'vendor') $r
[void](& $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r init empty --instance t --backend file 2>&1)
[void](New-Item -ItemType Directory -Force -Path "$r\scripts", "$r\state\locks")
[IO.File]::WriteAllText("$r\scripts\a.ps1", "Start-Sleep -Seconds 240`n")
[IO.File]::WriteAllText("$r\scripts\b.ps1", "exit 0`n")
$cfg = [IO.File]::ReadAllText("$r\config\vigil.config") -replace '(?m)^tick\s*=.*$', 'tick = 5s'
$cfg += "`n[job.a]`nfile = scripts/a.ps1`nrun_every = 1m`n`n[job.b]`nfile = scripts/b.ps1`nrun_every = 1m`n"
[IO.File]::WriteAllText("$r\config\vigil.config", $cfg)
"shell: $Shell ($(& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')); control: $([bool]$Control)"
"precheck: $((& $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r precheck 2>&1 | Select-Object -Last 1))"

$p = Start-Process -FilePath $Shell -PassThru -WindowStyle Hidden -RedirectStandardOutput "$r\sup.out" -RedirectStandardError "$r\sup.err" `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$r\app\vigil.ps1`"", '-Root', "`"$r`"", 'supervise')
"supervisor started, pid $($p.Id)"
if (-not $Control) {
    $now = [DateTime]::UtcNow
    $n = 0
    for ($s = 0; $s -lt 200; $s++) {
        $ts = $now.AddSeconds($s).ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
        foreach ($seq in 1..12) { [void](New-Item -ItemType Directory -Force -Path "$r\state\locks\b.$ts-$($p.Id)-$seq.launch.tmp.$($p.Id)"); $n++ }
    }
    "obstruction: $n directories at the temporary names of b's launch records"
}
# To the next whole minute, when both jobs' first slot falls, then six ticks more.
# A job is new at the supervisor's first tick and first runs at the slot after
# it (7.6): leave the first tick 25 s before that minute.
$wait = 60 - [DateTime]::UtcNow.Second
if ($wait -lt 25) { $wait += 60 }
$wait += 32
"waiting $wait s (the next whole minute, then about six 5 s ticks)"
Start-Sleep -Seconds $wait

"`n# The supervisor's log"
Get-ChildItem "$r\logs\supervisor\2*.log" | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } |
    Where-Object { $_ -match 'job a|job b|tick failed' } | ForEach-Object { ($_ -replace [regex]::Escape($r), '<root>') } |
    ForEach-Object { if ($_.Length -gt 230) { $_.Substring(0, 230) + '...' } else { $_ } }
"`n# Workers of job a alive now (command lines naming this root)"
$mine = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($r) })
$wa = @($mine | Where-Object { $_.CommandLine -match ' worker a --run-id (\S+)' })
$wa | ForEach-Object { "pid $($_.ProcessId): worker a --run-id $(([regex]::Match($_.CommandLine, '--run-id (\S+)')).Groups[1].Value)" }
"workers of a alive: $($wa.Count)"
"tokens held for a: $(@(Get-ChildItem "$r\state\locks\a.*.token" -ErrorAction SilentlyContinue).Count)"
if (Test-Path "$r\state\jobs\a.state") { "state file of a: run_id = $(([IO.File]::ReadAllLines("$r\state\jobs\a.state") | Where-Object { $_ -match '^run_id' }) -replace '^run_id\s*=\s*', '')" }
else { 'state file of a: none' }

# Ours only: the supervisor we started, and every process whose command line names this root.
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
foreach ($m in $mine) { if ($m.ProcessId -ne $PID) { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue } }
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $r -ErrorAction SilentlyContinue
