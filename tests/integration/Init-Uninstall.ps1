#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: vigil init (SPECIFICATION.md 19) and vigil uninstall
    (18.8) on Windows.
.DESCRIPTION
    init writes a configuration that passes pre-flight and whose sample job
    runs, and never overwrites one. uninstall ends only the workers proven
    to be the root's - an unrelated process stays - and removes the root, or
    all but config and scripts. The twin of init-uninstall.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil init.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function New-Root {
    param([string]$Root)
    [void](New-Item -ItemType Directory -Force -Path $Root)
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app') -Destination $Root
}

# Runs vigil with stdin redirected, as deployment tooling would.
function Invoke-Vigil {
    param([string]$Root, [string[]]$Arguments)
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'app\vigil.ps1') -Root $Root @Arguments 2>&1
    $script:lastOut = ($out | ForEach-Object { "$_" }) -join "`n"
    return $LASTEXITCODE
}

function Get-StateValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

function Test-Alive { param([string]$Id) return "$([bool](Get-Process -Id ([int]$Id) -ErrorAction SilentlyContinue))" }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"

# --- init -----------------------------------------------------------------

$r = Join-Path $work 'init'
New-Root $r
$cfg = Join-Path $r 'config\vigil.config'
Test-Equal 'init succeeds' '0' "$(Invoke-Vigil $r @('init', '--instance', 'it-host', '--backend', 'file,datadog'))"
Test-Equal 'init writes the configuration' 'True' "$(Test-Path -LiteralPath $cfg)"
Test-Equal 'init writes the sample script' 'True' "$(Test-Path -LiteralPath (Join-Path $r 'scripts\disk.ps1'))"
Test-Equal 'init names the variables to set' '1' "$(@($script:lastOut -split "`n" | Where-Object { $_ -ceq '  DATADOG_API_KEY' }).Count)"
Test-Equal 'every credential is a reference' '0' "$(@([System.IO.File]::ReadAllLines($cfg) | Where-Object { $_ -match '^api_key' -and $_ -notmatch '= *(env|secret|store):' }).Count)"
$env:DATADOG_API_KEY = 'x'
Test-Equal 'the configuration passes pre-flight' '0' "$(Invoke-Vigil $r @('precheck'))"
Remove-Item Env:\DATADOG_API_KEY
Test-Equal 'the sample job succeeds' '0' "$(Invoke-Vigil $r @('run', 'disk'))"
$before = [System.IO.File]::ReadAllText($cfg)
Test-Equal 'init again is refused' '1' "$(Invoke-Vigil $r @('init'))"
Test-Equal 'and leaves the configuration alone' 'True' "$($before -ceq [System.IO.File]::ReadAllText($cfg))"

$r = Join-Path $work 'init2'
New-Root $r
$cfg = Join-Path $r 'config\vigil.config'
Test-Equal 'an unknown backend is refused' '1' "$(Invoke-Vigil $r @('init', '--backend', 'splunk'))"
Test-Equal 'a bad instance name is refused' '1' "$(Invoke-Vigil $r @('init', '--instance', 'a b'))"
Test-Equal 'and nothing is written' 'False' "$(Test-Path -LiteralPath $cfg)"
Test-Equal 'init --no-sample succeeds' '0' "$(Invoke-Vigil $r @('init', '--no-sample'))"
Test-Equal 'with no job' '0' "$(@([System.IO.File]::ReadAllLines($cfg) | Where-Object { $_ -match '^\[job\.' }).Count)"
Test-Equal 'defaults to the file backend' '1' "$(@([System.IO.File]::ReadAllLines($cfg) | Where-Object { $_ -ceq '[backend.file]' }).Count)"

# --- uninstall ----------------------------------------------------------------

# A root whose job holds on, started by a real supervisor that is then
# stopped, as a service stop would: the worker and its job carry on.
$r = Join-Path $work 'un'
New-Root $r
[void](New-Item -ItemType Directory -Force -Path (Join-Path $r 'config'), (Join-Path $r 'scripts'))
[System.IO.File]::WriteAllText((Join-Path $r 'scripts\hold.cmd'), "@echo off`r`nping -n 300 127.0.0.1 > nul`r`n")
[System.IO.File]::WriteAllText((Join-Path $r 'config\vigil.config'), "[vigil]`ninstance = un`n`n[scheduler]`ntick = 1s`n`n[job.hold]`nfile      = scripts\hold.cmd`nrun_every = 2s`n")
$sup = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $r 'app\vigil.ps1')`"", '-Root', "`"$r`"", 'supervise') -WindowStyle Hidden -PassThru
$st = Join-Path $r 'state\jobs\hold.state'
for ($i = 0; $i -lt 120 -and -not (Get-StateValue $st 'job_pid'); $i++) { Start-Sleep -Milliseconds 500 }
# Test cleanup of the test's own supervisor; its workers carry on.
Stop-Process -Id $sup.Id -Force
$wpid = Get-StateValue $st 'worker_pid'
$jpid = Get-StateValue $st 'job_pid'
Test-Equal 'the job is running' 'True' (Test-Alive $jpid)
# An unrelated process naming the root: never Vigil's to end.
$decoy = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', "ping -n 300 127.0.0.1 > nul & rem `"$r`"") -WindowStyle Hidden -PassThru

Test-Equal 'uninstall without --yes off a console is refused' '1' "$(Invoke-Vigil $r @('uninstall'))"
Test-Equal 'and removes nothing' 'True' "$(Test-Path -LiteralPath (Join-Path $r 'app'))"

Test-Equal 'uninstall --yes succeeds' '0' "$(Invoke-Vigil $r @('uninstall', '--yes'))"
Test-Equal 'it listed the processes it would end' 'True' "$($script:lastOut -match "running Vigil processes:.*\b$jpid\b")"
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $r); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'the root is gone' 'False' "$(Test-Path -LiteralPath $r)"
for ($i = 0; $i -lt 20 -and (Test-Alive $jpid) -eq 'True'; $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'the job was ended' 'False' (Test-Alive $jpid)
Test-Equal 'the worker was ended' 'False' (Test-Alive $wpid)
Test-Equal 'the unrelated process was not' 'True' (Test-Alive $decoy.Id)
& taskkill.exe /T /F /PID $decoy.Id 2>&1 | Out-Null

$r = Join-Path $work 'keep'
New-Root $r
[void](New-Item -ItemType Directory -Force -Path (Join-Path $r 'scripts'), (Join-Path $r 'state\jobs'), (Join-Path $r 'logs'))
[System.IO.File]::WriteAllText((Join-Path $r 'scripts\a.ps1'), 'x')
[void](Invoke-Vigil $r @('init', '--no-sample'))
Test-Equal 'uninstall --keep-config succeeds' '0' "$(Invoke-Vigil $r @('uninstall', '--yes', '--keep-config'))"
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath (Join-Path $r 'app')); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'keeps config and scripts' 'config scripts' ((@(Get-ChildItem -LiteralPath $r -Force | ForEach-Object { $_.Name } | Sort-Object)) -join ' ')
Test-Equal 'keeps the configuration itself' 'True' "$(Test-Path -LiteralPath (Join-Path $r 'config\vigil.config'))"

$nr = Join-Path $work 'notroot'
[void](New-Item -ItemType Directory -Force -Path $nr)
$out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'app\vigil.ps1') -Root $nr uninstall --yes 2>&1
Test-Equal 'a folder without app\vigil.ps1 is refused' '1' "$LASTEXITCODE"
Test-Equal 'and left alone' 'True' "$(Test-Path -LiteralPath $nr)"

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
