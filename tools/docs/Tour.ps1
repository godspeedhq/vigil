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
    Tour.ps1 - a tour of Vigil on Windows, for the "Logs and output" page.
.DESCRIPTION
    The twin of tour.sh. Installs this checkout in a temporary folder, runs
    the commands people use every day, runs the supervisor for real for a
    minute or two, and prints each command's output and each log file as it
    is. CI runs it on main, and tour-page.sh turns that console output into
    the page, so nothing on the page is typed by hand.

    The temporary folder is shown as C:\ProgramData\Vigil, where a system
    install puts it; nothing else is changed. Lines starting with :: mark
    where each piece begins, for tour-page.sh:

        ::section <title>    ::note <text>    ::cmd <command>    ::file <path>

    Exit code: 0, or 1 if Vigil could not be set up at all.
#>

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-tour.$PID"
[void](New-Item -ItemType Directory -Force -Path "$work\root\packs\base", "$work\root\scripts")
$work = (Get-Item -LiteralPath $work).FullName
$root = "$work\root"
$shown = 'C:\ProgramData\Vigil'
$sup = $null

# The temporary root, as a system install would have it.
function Hide-Root {
    param([string]$Text)
    return $Text.Replace($root, $shown)
}

function Write-Section { param([string]$Text) Write-Output "::section $Text" }
function Write-Note { param([string]$Text) Write-Output "::note $Text" }

# Runs vigil with the given arguments, shown as typed, then its exit code.
function Invoke-Shown {
    Write-Output "::cmd vigil $($args -join ' ')"
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $out) { Hide-Root "$l" }
    Write-Output "(exit code $code)"
}

# Prints a file under the root, or the part of it from the first line
# matching a pattern.
function Show-File {
    param([string]$Path, [string]$From)
    Write-Output "::file $shown\$Path"
    $on = -not $From
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $root $Path))) {
        if (-not $on -and $l -cmatch $From) { $on = $true }
        if ($on) { Hide-Root $l }
    }
}

# Prints the lines of a file under the root that match a pattern.
function Show-Lines {
    param([string]$Path, [string]$Pattern)
    Write-Output "::file $shown\$Path"
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $root $Path))) { if ($l -cmatch $Pattern) { Hide-Root $l } }
}

# Waits up to a number of seconds for text matching a pattern in the files
# a wildcard names.
function Wait-For {
    param([int]$Seconds, [string]$Pattern, [string]$Files)
    for ($i = 0; $i -lt $Seconds; $i++) {
        foreach ($f in @(Get-ChildItem -Path $Files -File -ErrorAction SilentlyContinue)) {
            try { if ([System.IO.File]::ReadAllText($f.FullName) -cmatch $Pattern) { return } } catch { }
        }
        Start-Sleep -Seconds 1
    }
}

# How many times the supervisor has logged a line containing some text.
function Get-Logged {
    param([string]$Text)
    $n = 0
    foreach ($f in @(Get-ChildItem -Path "$root\logs\supervisor\2*.log" -File -ErrorAction SilentlyContinue)) {
        $n += @([System.IO.File]::ReadAllLines($f.FullName) | Where-Object { $_.Contains($Text) }).Count
    }
    return $n
}

# Waits up to 30 seconds for the supervisor to log one more such line.
function Wait-Logged {
    param([string]$Text, [int]$Before)
    for ($i = 0; $i -lt 30 -and (Get-Logged $Text) -le $Before; $i++) { Start-Sleep -Seconds 1 }
}

try {
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Copy-Item -LiteralPath (Join-Path $repo 'packs\base\pack.config') -Destination "$root\packs\base"
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\base\windows') -File | Copy-Item -Destination "$root\packs\base"

    Write-Section 'What is installed'
    Invoke-Shown version
    Invoke-Shown about

    Write-Section 'A first configuration'
    Write-Note 'vigil init writes a commented configuration with the base pack turned on. Away from a console it asks no questions.'
    Invoke-Shown init --instance web-01 --backend file
    if (-not (Test-Path -LiteralPath "$root\config\vigil.config")) { exit 1 }
    Invoke-Shown pack list

    # Two jobs of our own: one that fails, and one that runs too long.
    [System.IO.File]::WriteAllText("$root\scripts\backup_check.ps1", (@(
                '# Fails on purpose: the last backup is too old.'
                'Write-Output "metric age_hours 31"'
                '[Console]::Error.WriteLine("last backup is 31 hours old (limit 24)")'
                'exit 2'
            ) -join "`r`n") + "`r`n")
    [System.IO.File]::WriteAllText("$root\scripts\report.ps1", (@(
                '# Hangs on purpose, to be stopped at max_runtime.'
                'Write-Output "building the report"'
                'Start-Sleep -Seconds 600'
            ) -join "`r`n") + "`r`n")
    [System.IO.File]::AppendAllText("$root\config\vigil.config", (@(
                ''
                '[job.backup_check]'
                'file = scripts\backup_check.ps1'
                'run_every = 1m'
                ''
                '[job.report]'
                'file = scripts\report.ps1'
                'run_every = 1m'
                'max_runtime = 15s'
                'grace = 5s'
            ) -join "`r`n") + "`r`n")
    Write-Section 'Two jobs of our own'
    Write-Note 'One fails on purpose and one hangs on purpose, to show what Vigil does with each.'
    Show-File 'config\vigil.config' '^\[job\.backup_check\]'
    Show-File 'scripts\backup_check.ps1'
    Show-File 'scripts\report.ps1'

    Write-Section 'Checking before running'
    Invoke-Shown precheck
    $good = [System.IO.File]::ReadAllText("$root\config\vigil.config")
    $broken = "`r`n[job.broken]`r`nfile = scripts\missing.ps1`r`nrun_every = soon`r`n"
    [System.IO.File]::AppendAllText("$root\config\vigil.config", $broken)
    Write-Note 'A mistake: a job with a schedule Vigil cannot read. precheck says what is wrong, and where.'
    Invoke-Shown precheck
    [System.IO.File]::WriteAllText("$root\config\vigil.config", $good)

    Write-Section 'Running a job by hand'
    Invoke-Shown run base_cpu
    Invoke-Shown run backup_check
    Invoke-Shown run no_such_job

    Write-Section 'Secrets'
    Write-Note 'The value comes from standard input, or a hidden prompt at a console. It is never shown again.'
    Write-Output "::cmd 's3cret' | vigil secret set DB_PASSWORD --stdin"
    $out = 's3cret' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root secret set DB_PASSWORD --stdin 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $out) { Hide-Root "$l" }
    Write-Output "(exit code $code)"
    Invoke-Shown secret list

    Write-Section 'Turning pack jobs off and on'
    Invoke-Shown pack disable base_disk
    Invoke-Shown pack list
    Invoke-Shown pack enable base_disk

    # --- The supervisor, for real ----------------------------------------------

    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    Write-Section 'The supervisor at work'
    Write-Note 'Here the supervisor runs straight from the command line rather than as a service, for a minute or two. Jobs with run_every = 1m start on the next whole minute.'
    Wait-For 150 'status += timed_out' "$root\state\jobs\report.state"
    Wait-For 30 'run end' "$root\logs\jobs\base_disk\*.log"
    Invoke-Shown status
    Show-File 'logs\supervisor\jobs.log'

    Write-Section 'Mistakes while it runs'
    Write-Note 'A broken job is set aside as INVALID, and every other job keeps running.'
    [System.IO.File]::AppendAllText("$root\config\vigil.config", $broken)
    Wait-For 30 '(?m)^INVALID' "$root\logs\supervisor\jobs.log"
    Show-File 'logs\supervisor\jobs.log'
    $n = Get-Logged 'configuration loaded'
    [System.IO.File]::WriteAllText("$root\config\vigil.config", $good)
    Wait-Logged 'configuration loaded' $n
    Write-Note 'A mistake outside any job, here a misspelt section name, rejects the whole file. The last good configuration stays active, and the supervisor says so in its log and in jobs.log.'
    $n = Get-Logged 'configuration rejected'
    [System.IO.File]::AppendAllText("$root\config\vigil.config", "`r`n[schedular]`r`ntick = 30s`r`n")
    Wait-Logged 'configuration rejected' $n
    Wait-For 30 '(?m)^CONFIGURATION REJECTED' "$root\logs\supervisor\jobs.log"
    Show-File 'logs\supervisor\jobs.log'
    $last = @(Get-ChildItem -Path "$root\logs\supervisor\2*.log" -File | Sort-Object Name)[-1].Name
    Show-Lines "logs\supervisor\$last" 'ERROR'
    Write-Note 'Then the mistake is put right, and the supervisor loads it at its next tick.'
    $n = Get-Logged 'configuration loaded'
    [System.IO.File]::WriteAllText("$root\config\vigil.config", $good)
    Wait-Logged 'configuration loaded' $n

    Write-Section 'The logs'
    # The supervisor this script started, and nothing else.
    $sup.Kill()
    $sup.WaitForExit()
    $sup = $null
    foreach ($f in @(Get-ChildItem -Path "$root\logs\supervisor\2*.log" -File)) { Show-File "logs\supervisor\$($f.Name)" }
    foreach ($j in @('base_cpu', 'base_disk', 'backup_check', 'report')) {
        foreach ($f in @(Get-ChildItem -Path "$root\logs\jobs\$j\*.log" -File -ErrorAction SilentlyContinue)) { Show-File "logs\jobs\$j\$($f.Name)" }
    }

    Write-Section 'State and metrics'
    Write-Note 'Each job has a state file: how its last run ended, and why.'
    Show-File 'state\jobs\report.state'
    Write-Note 'The file backend writes the metrics in the Prometheus text format, for node_exporter or a test. A few of them:'
    Show-Lines 'metrics\vigil.prom' '^(system_cpu|system_memory_used|backup_check|report)'
    Write-Output '::done'
}
finally {
    if ($sup -and -not $sup.HasExited) { $sup.Kill() }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
