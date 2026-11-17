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
    Integration test: "vigil run <job>" end to end on Windows
    (SPECIFICATION.md 4.3).
.DESCRIPTION
    Builds a throwaway install root, runs real jobs through the real
    command, and checks the exit code, state file, spool events, job log and
    lock files of each run. The twin of run-job.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-it.$PID"
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
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return $null
}

function Invoke-Vigil {
    param([string[]]$Arguments)
    # Expected messages on stderr must not stop the test (CI runs with Stop).
    $ErrorActionPreference = 'Continue'
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
$scripts = Join-Path $root 'scripts'
Set-Content -LiteralPath (Join-Path $scripts 'ok.ps1') -Value @(
    'Write-Output "starting"', 'Write-Output "metric rows 5 table=orders"', 'Write-Output "metric bad"',
    '[Console]::Error.WriteLine("to stderr")', 'exit 0')
# A lot of output, an empty line in the middle, and a metric only at the end.
Set-Content -LiteralPath (Join-Path $scripts 'noisy.ps1') -Value @(
    '1..30000 | ForEach-Object { "line $_" }', "''", 'Write-Output "metric last 1"', '[Console]::Error.WriteLine("err one")')
Set-Content -LiteralPath (Join-Path $scripts 'check_disk.ps1') -Value @(
    'Write-Output "DISK WARNING - C: 85% | C:=11700MB;15600;17550;0;19500"', 'exit 1')
Set-Content -LiteralPath (Join-Path $scripts 'fail.ps1') -Value @('Write-Output "metric partial 1"', 'exit 2')
Set-Content -LiteralPath (Join-Path $scripts 'env.ps1') -Value @(
    'Write-Output "metric greeting_len $($env:GREETING.Length)"',
    'Write-Output "metric run_id_set $(if ($env:VIGIL_RUN_ID) { 1 } else { 0 })"',
    'Write-Output "metric args $($args.Count)"')

Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @"
[vigil]
instance = it

[tags]
env = test

[runner.ps]
command = $shell
arg     = -NoProfile
arg     = -ExecutionPolicy
arg     = Bypass
arg     = -File

[runners]
.ps1 = ps

[job.ok]
file      = scripts\ok.ps1
run_every = 5m

[job.noisy]
file      = scripts\noisy.ps1
run_every = 5m

[job.disk]
metric_name = os.disk
file        = scripts\check_disk.ps1
run_every   = 5m
exit_codes  = nagios

[job.fail]
file      = scripts\fail.ps1
run_every = 5m

[job.env]
file        = scripts\env.ps1
arg         = one
arg         = two words
env         = GREETING=hello
require_env = PATH
run_every   = 5m

[job.needs_env]
file        = scripts\env.ps1
require_env = VIGIL_IT_SURELY_UNSET
run_every   = 5m

[job.missing]
file      = scripts\missing.ps1
run_every = 5m
"@

function Test-Run {
    param([string]$Job, [int]$Code, [string]$Status, [string]$Reason)
    $r = Invoke-Vigil @('run', $Job)
    Test-Equal "$Job exit code" "$Code" "$($r.Code)"
    $st = Join-Path $root "state\jobs\$Job.state"
    Test-Equal "$Job status" $Status (Get-StateValue $st 'status')
    Test-Equal "$Job reason" $Reason (Get-StateValue $st 'reason')
    $left = @(Get-ChildItem -LiteralPath (Join-Path $root 'state\locks') -File | Where-Object { $_.Name.StartsWith("$Job.") })
    Test-Equal "$Job no locks left" '0' "$($left.Count)"
    Test-Equal "$Job summary line" "${Job}: $Status" ([regex]::Match($r.Output, "^${Job}: [a-z_]+", 'Multiline').Value)
}

# The events of a job's latest run, without epoch and host.
function Get-Events {
    param([string]$Job)
    $f = Get-ChildItem -LiteralPath (Join-Path $root 'spool\incoming') -Filter "*-$Job-*.events" | Sort-Object Name | Select-Object -Last 1
    $lines = foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
        ($l -replace '^[0-9]+ ', '' -replace ' host=[^ ]*', '' -replace ' os=[^ ]*', '')
    }
    return ($lines -join "`n")
}

Test-Run 'ok' 0 'succeeded' ''
Test-Equal 'ok events' ("ok.duration_seconds 0 gauge instance=it job=ok env=test`n" +
    "ok.runs 1 count instance=it job=ok env=test`n" +
    "ok.succeeded 1 count instance=it job=ok env=test`n" +
    "ok.rows 5 gauge instance=it job=ok env=test table=orders`n" +
    "ok.invalid_metric_lines 1 count instance=it job=ok env=test") ((Get-Events 'ok') -replace 'duration_seconds [0-9]+', 'duration_seconds 0')
$st = Join-Path $root 'state\jobs\ok.state'
Test-Equal 'ok state summary' '1 1 0' "$(Get-StateValue $st 'metric_lines') $(Get-StateValue $st 'invalid_lines') $(Get-StateValue $st 'dropped_lines')"
$log = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\ok') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'ok log has stdout' '1' "$(([regex]::Matches($log, ' out metric rows 5 table=orders\r?$', 'Multiline')).Count)"
Test-Equal 'ok log has stderr' '1' "$(([regex]::Matches($log, ' err to stderr\r?$', 'Multiline')).Count)"
Test-Equal 'ok log has end' '1' "$(([regex]::Matches($log, ' run end succeeded in ')).Count)"

# Output is copied to files as it comes, not held in memory, and the job log
# is written from them exactly as before.
Test-Run 'noisy' 0 'succeeded' ''
$log = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\noisy') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
Test-Equal 'noisy log has every line' '30000' "$(([regex]::Matches($log, ' out line [0-9]+\r?$', 'Multiline')).Count)"
Test-Equal 'noisy log keeps the empty line' '1' "$(([regex]::Matches($log, ' out \r?$', 'Multiline')).Count)"
Test-Equal 'noisy log has stderr' '1' "$(([regex]::Matches($log, ' err err one\r?$', 'Multiline')).Count)"
Test-Equal 'noisy metric after all that output' 'True' "$((Get-Events 'noisy') -match '(?m)^noisy\.last 1 gauge')"
Test-Equal 'noisy leaves no output files' '0' "$(@(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\noisy') -File | Where-Object { $_.Extension -cne '.log' }).Count)"

Test-Run 'disk' 1 'warning' 'exit code 1'
Test-Equal 'disk perf event' 'os.disk.perf 12268339200 gauge instance=it job=disk env=test label=C:' (((Get-Events 'disk') -split "`n") | Where-Object { $_.StartsWith('os.disk.perf ') })

Test-Run 'fail' 2 'failed' 'exit code 2'
Test-Equal 'fail failures event' 'fail.failures 1 count instance=it job=fail env=test exit_code=2' (((Get-Events 'fail') -split "`n") | Where-Object { $_ -match 'failures' })

Test-Run 'env' 0 'succeeded' ''
Test-Equal 'env passes env, run id and arguments' "env.greeting_len 5`nenv.run_id_set 1`nenv.args 2" `
    ((((Get-Events 'env') -split "`n") | Where-Object { $_ -match 'greeting_len|run_id_set|\.args ' } | ForEach-Object { $_ -replace ' gauge.*', '' }) -join "`n")

Test-Run 'needs_env' 2 'failed' 'missing environment variable VIGIL_IT_SURELY_UNSET'
Test-Run 'missing' 2 'failed' "file not found: $root\scripts\missing.ps1"
Test-Equal 'missing failures event has no exit code' 'missing.failures 1 count instance=it job=missing env=test' (((Get-Events 'missing') -split "`n") | Where-Object { $_ -match 'failures' })

# A run of a job that is in progress is refused.
$fake = Join-Path $root 'state\locks\ok.20260101T000000Z-1.token'
[System.IO.File]::WriteAllText($fake, '')
Test-Equal 'run refused while a token exists' '4' "$((Invoke-Vigil @('run', 'ok')).Code)"
[System.IO.File]::Delete($fake)

# A worker whose launch record is gone does not run the job.
Test-Equal 'abandoned launch is not run' '4' "$((Invoke-Vigil @('worker', 'ok', '--run-id', '20260101T000000Z-2')).Code)"
Test-Equal 'unknown job is not run' '4' "$((Invoke-Vigil @('run', 'nosuchjob')).Code)"

# A launch carrying the run resolved by the supervisor ([run], 4.3): the
# same state and events as above, and the configuration is not read again,
# so an edit saved after the launch does not change the run.
foreach ($lib in 'Config', 'Validate', 'Effective', 'Command', 'Worker') { . (Join-Path $repo "app\lib\windows\$lib.ps1") }
$configFile = Join-Path $root 'config\vigil.config'
function New-RunLaunch {
    param([string]$Job, [string]$Rid)
    $p = ConvertFrom-VigilConfig -Path $configFile
    $run = Format-VigilRunSection -Parsed $p -Index (New-VigilConfigIndex -Parsed $p) -Job $Job -Root $root -Script '' `
        -Logs (Join-Path $root 'logs') -Spool (Join-Path $root 'spool')
    [System.IO.File]::WriteAllText((Join-Path $root "state\locks\$Job.$Rid.launch"),
        "[launch]`njob           = $Job`nrun_id        = $Rid`nboot_id       = b`nlaunch_epoch  = 1`n$run")
    return $run
}
$before = @{}
foreach ($job in 'env', 'disk') { $before[$job] = (Get-Events $job) -replace 'duration_seconds [0-9]+', 'duration_seconds 0' }
$saved = [System.IO.File]::ReadAllText($configFile)
$n = 0
foreach ($job in 'env', 'disk') {
    $n++
    $rid = "20260101T000000Z-3$n"
    Test-Equal "$job launch has [run]" 'True' ([string]((New-RunLaunch $job $rid) -cmatch '(?m)^\[run\]$'))
    # Saved after the launch: the run keeps what it was launched with.
    [System.IO.File]::WriteAllText($configFile, $saved.Replace('GREETING=hello', 'GREETING=hi').Replace('os.disk', 'os.other').Replace('env = test', 'env = edited'))
    $code = (Invoke-Vigil @('worker', $job, '--run-id', $rid)).Code
    [System.IO.File]::WriteAllText($configFile, $saved)
    Test-Equal "$job from [run]: exit code" $(if ($job -ceq 'disk') { '1' } else { '0' }) "$code"
    Test-Equal "$job from [run]: the same events" $before[$job] ((Get-Events $job) -replace 'duration_seconds [0-9]+', 'duration_seconds 0')
    Test-Equal "$job from [run]: instance" 'it' (Get-StateValue (Join-Path $root "state\jobs\$job.state") 'instance')
}
# Vigil's own workers and a job with a secret read the configuration.
Add-Content -LiteralPath $configFile -Value "`n[job.secretive]`nfile      = scripts\env.ps1`nsecret    = GREETING=env:PATH`nrun_every = 5m"
$p = ConvertFrom-VigilConfig -Path $configFile
$ix = New-VigilConfigIndex -Parsed $p
Test-Equal 'no [run] for a job with a secret' '' (Format-VigilRunSection -Parsed $p -Index $ix -Job 'secretive' -Root $root -Script '' -Logs 'l' -Spool 's')
Test-Equal 'no [run] for the sender' '' (Format-VigilRunSection -Parsed $p -Index $ix -Job 'vigil_sender' -Root $root -Script '' -Logs 'l' -Spool 's')

Remove-Item -Recurse -Force -LiteralPath $root
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
