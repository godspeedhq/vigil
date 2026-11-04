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
    Integration test: the data format and its migrations (SPECIFICATION.md
    18.7) on Windows.
.DESCRIPTION
    Runs a copy of app\ with migrations of its own, so nothing here depends
    on a real format change. The twin of format.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil format.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

function Get-Stored {
    $f = Join-Path $root 'state\format'
    if ([System.IO.File]::Exists($f)) { return [System.IO.File]::ReadAllText($f).Trim() }
    return ''
}
function Set-Stored { param([string]$Text) [System.IO.File]::WriteAllText((Join-Path $root 'state\format'), "$Text`n") }
function Set-Version { param([string]$Text) [System.IO.File]::WriteAllText((Join-Path $root 'app\VERSION'), "$Text`n") }
function Get-Ack { [System.IO.File]::ReadAllText((Join-Path $root 'state\supervisor.version')).Trim() }
function Add-Good {
    param([int]$N)
    $body = 'param($State, $Spool, $Logs)' + "`n" + "Add-Content -LiteralPath (Join-Path `$State 'trace') -Value `"$N `$State `$Spool `$Logs`"`n"
    [System.IO.File]::WriteAllText((Join-Path $root "app\migrations\$N.ps1"), $body)
}
function Add-Bad { param([int]$N) [System.IO.File]::WriteAllText((Join-Path $root "app\migrations\$N.ps1"), "exit 3`n") }
function Get-Trace {
    $f = Join-Path $root 'state\trace'
    if (-not [System.IO.File]::Exists($f)) { return @() }
    return @([System.IO.File]::ReadAllLines($f) | Where-Object { $_ })
}
function Get-SupervisorLog {
    $t = ''
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '2*.log') {
        try {
            $s = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            $r = New-Object System.IO.StreamReader($s)
            $t += $r.ReadToEnd()
            $r.Dispose()
        }
        catch { }
    }
    return $t
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$root = Join-Path $work 'root'
[void](New-Item -ItemType Directory -Force -Path $root)
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = Join-Path $work 'root'
$sup = $null

try {
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Set-Version '1.0.0'
    [void](Invoke-Vigil init --instance format --backend file --no-pack)
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'app\migrations'))
    $cfg = Join-Path $root 'config\vigil.config'
    [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^tick *= *.*$', 'tick = 1s'))

    Write-Host 'A fresh install'
    Test-Equal 'starts' '0' ([string](Invoke-Vigil supervise --once).Code)
    Test-Equal 'is format 1' '1' (Get-Stored)

    Write-Host 'An install from before formats'
    Remove-Item -LiteralPath (Join-Path $root 'state\format')
    Test-Equal 'precheck reads it as format 1' 'True' ([string]((Invoke-Vigil precheck).Text -cmatch '(?m)data format: 1\s*$'))
    [void](Invoke-Vigil supervise --once)
    Test-Equal 'is stamped format 1' '1' (Get-Stored)

    Write-Host 'Migrations'
    Add-Good 2
    Add-Good 3
    Test-Equal 'precheck says what will move' 'True' ([string]((Invoke-Vigil precheck).Text.Contains('data format: 1, moves to 3')))
    Test-Equal 'run' '0' ([string](Invoke-Vigil supervise --once).Code)
    Test-Equal 'reach the highest' '3' (Get-Stored)
    $dirs = "$root\state $root\spool $root\logs"
    Test-Equal 'in order, given the directories' "2 $dirs|3 $dirs" ((Get-Trace) -join '|')
    [void](Invoke-Vigil supervise --once)
    Test-Equal 'run once only' '2' ([string](Get-Trace).Count)

    Write-Host 'A migration that fails'
    Add-Good 4
    Add-Bad 5
    Add-Good 6
    Remove-Item -LiteralPath (Join-Path $root 'state\trace')
    $r = Invoke-Vigil supervise --once
    Test-Equal 'stops the start' '1' ([string]$r.Code)
    Test-Equal 'says which' 'True' ([string]$r.Text.Contains('migration 5 failed'))
    Test-Equal 'keeps the step before it' '4' (Get-Stored)
    Add-Good 5
    [void](Invoke-Vigil supervise --once)
    Test-Equal 'is retried, not repeated' '4|5|6' ((@(Get-Trace) | ForEach-Object { $_.Split(' ')[0] }) -join '|')
    Test-Equal 'and finishes' '6' (Get-Stored)
    Add-Good 8
    $r = Invoke-Vigil supervise --once
    Test-Equal 'a gap stops the start' 'True' ([string]$r.Text.Contains('migration 7 is missing'))
    Test-Equal 'and moves nothing' '6' (Get-Stored)
    Remove-Item -LiteralPath (Join-Path $root 'app\migrations\8.ps1')

    Write-Host 'Data of a newer format'
    Set-Stored '7'
    $r = Invoke-Vigil supervise --once
    Test-Equal 'is refused' '1' ([string]$r.Code)
    Test-Equal 'says so' 'True' ([string]$r.Text.Contains('format 7, newer than the format 6'))
    Test-Equal 'is not touched' '7' (Get-Stored)
    Test-Equal 'precheck fails' '1' ([string](Invoke-Vigil precheck).Code)
    Set-Stored 'six'
    Test-Equal 'an unreadable number is refused' '1' ([string](Invoke-Vigil supervise --once).Code)
    Set-Stored '6'

    Write-Host 'A hot reload'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList $argv `
        -RedirectStandardOutput "$work\supervise.out" -RedirectStandardError "$work\supervise.err"
    for ($i = 0; $i -lt 120 -and -not (Get-SupervisorLog).Contains("supervisor started, pid $($sup.Id)"); $i++) { Start-Sleep -Milliseconds 500 }
    # Backlog 19: once, on PowerShell 7, this supervisor had exited before
    # the checks below. Whether it started at all, and what it said.
    Test-Equal 'the supervisor starts' 'True' ([string](Get-SupervisorLog).Contains("supervisor started, pid $($sup.Id)"))
    Remove-Item -LiteralPath (Join-Path $root 'state\trace')
    Add-Bad 7
    Set-Version '2.0.0'
    for ($i = 0; $i -lt 120 -and -not (Get-SupervisorLog).Contains('staying on Vigil 1.0.0'); $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'a failed migration keeps the supervisor' 'False' ([string]$sup.HasExited)
    Test-Equal 'on the same version' '1.0.0' (Get-Ack)
    Test-Equal 'and the data where it was' '6' (Get-Stored)
    Test-Equal 'and says why, once' '1' ([string]([regex]::Matches((Get-SupervisorLog), 'staying on Vigil 1\.0\.0')).Count)
    Set-Version '1.0.0'
    Start-Sleep -Seconds 5
    Add-Good 7
    Set-Version '2.0.0'
    for ($i = 0; $i -lt 120 -and (Get-Ack) -cne '2.0.0'; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'the retried update reloads' '2.0.0' (Get-Ack)
    Test-Equal 'the same process' 'False' ([string]$sup.HasExited)
    Test-Equal 'the data moved' '7' (Get-Stored)
    Test-Equal 'by that one step' '7' ((@(Get-Trace) | ForEach-Object { $_.Split(' ')[0] }) -join ' ')
    if ($script:fail -gt 0) {
        Write-Host "        supervisor $($sup.Id) exited: $($sup.HasExited)"
        (Get-SupervisorLog).Split("`n") | Select-Object -Last 25 | ForEach-Object { Write-Host "        log: $_" }
        foreach ($f in 'supervise.out', 'supervise.err') {
            Get-Content -LiteralPath "$work\$f" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "        ${f}: $_" }
        }
    }
}
finally {
    if ($sup -and -not $sup.HasExited) { try { Stop-Process -Id $sup.Id -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
