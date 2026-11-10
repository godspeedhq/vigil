#Requires -Version 5.1
#
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
    Runs packs' Windows scripts through Vigil: the twin of check-pack.sh --run.
.DESCRIPTION
    .\tools\Check-Pack.ps1 [<pack> ...]      every pack when none is named

    For each pack with a windows\ folder: in a throwaway Vigil, vigil pack
    enable turns it on (which validates its jobs as Vigil sees them), each job
    with a .ps1 runs, and every metric it prints must be a number and listed
    in pack.config. A job whose secret a throwaway Vigil does not have is
    skipped, and says which. The rest of a pack's checks are check-pack.sh's,
    which runs in Git Bash too.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$shell = (Get-Process -Id $PID).Path
$script:failed = 0
$names = @($args)
if ($names.Count -eq 0) {
    $names = @(Get-ChildItem -LiteralPath (Join-Path $repo 'packs') -Directory | ForEach-Object { $_.Name })
}

function Write-Fail {
    param([string]$Pack, [string]$Why)
    $script:failed++
    Write-Host "  FAIL  ${Pack}: $Why"
}

# The jobs of pack.config $Path, in order, each with its metrics.
function Read-PackJobs {
    param([string]$Path)
    $jobs = [ordered]@{}
    $job = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[job\.([^\]]+)\]\s*$') { $job = $Matches[1]; $jobs[$job] = @() }
        elseif ($line -match '^\s*\[') { $job = $null }
        elseif ($job -and $line -match '^\s*metrics\s*=\s*(.*)$') {
            $jobs[$job] = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    return $jobs
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
foreach ($name in $names) {
    $src = Join-Path $repo "packs\$name"
    $before = $script:failed
    if (-not (Test-Path -LiteralPath "$src\pack.config")) { Write-Fail $name "no packs\$name\pack.config"; continue }
    if (-not (Test-Path -LiteralPath "$src\windows")) { Write-Host "  skip  ${name}: no Windows scripts"; continue }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil pack.$PID"
    $root = "$work\root"
    [void](New-Item -ItemType Directory -Force -Path "$root\packs\$name")
    try {
        Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
        Copy-Item -LiteralPath "$src\pack.config" -Destination "$root\packs\$name"
        Get-ChildItem -LiteralPath "$src\windows" -File | Copy-Item -Destination "$root\packs\$name"
        $vigil = Join-Path $root 'app\vigil.ps1'
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root init empty --instance check --backend file 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Fail $name "a throwaway Vigil would not start: $out"; continue }
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root pack enable $name 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Fail $name "vigil pack enable $name refused it: $out"; continue }
        $jobs = Read-PackJobs "$src\pack.config"
        foreach ($j in $jobs.Keys) {
            if (-not (Test-Path -LiteralPath "$root\packs\$name\$j.ps1")) { continue }
            $out = (@(& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root run "${name}_$j" 2>&1) | ForEach-Object { "$_" }) -join ' '
            $rc = $LASTEXITCODE
            # A secret is the operator's to give: this throwaway Vigil has none.
            if ($rc -ne 0 -and $out -match '\(secret (secret:[A-Za-z0-9_]+) unavailable') {
                Write-Host "  skip  ${name}_${j}: needs $($Matches[1]), which a throwaway Vigil does not have"
                continue
            }
            $lines = @()
            $logs = "$root\logs\jobs\${name}_$j"
            if (Test-Path -LiteralPath $logs) {
                $lines = @(Get-ChildItem -LiteralPath $logs -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) })
            }
            if ($rc -ne 0) {
                $err = (@($lines | Where-Object { $_ -match ' err ' } | Select-Object -Last 2 | ForEach-Object { $_ -replace '^\S+ \S+ err ', '' }) -join ' ')
                Write-Fail $name "${name}_$j exited $rc here: $err $out"
                continue
            }
            $m = 0
            foreach ($l in $lines) {
                if ($l -notmatch ' out metric (\S+) ?(\S*)') { continue }
                $m++
                $metric = $Matches[1]; $value = $Matches[2]
                if ($jobs[$j] -notcontains $metric) { Write-Fail $name "${name}_$j printed metric $metric, which pack.config does not list" }
                if ($value -notmatch '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$') { Write-Fail $name "${name}_$j printed $metric as '$value', not a number" }
            }
            if ($m -eq 0) { Write-Fail $name "${name}_$j ran but printed no metric" }
            else { Write-Host "  ran   ${name}_${j}: $m metric line(s)" }
        }
    }
    finally {
        Start-Sleep -Seconds 1
        Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
    }
    if ($script:failed -eq $before) { Write-Host "  ok    $name" }
}

if ($script:failed -gt 0) {
    Write-Host "$($script:failed) to fix: CONTRIBUTING.md says what each rule is for"
    exit 1
}
Write-Host "$($names.Count) pack(s) pass"
exit 0
