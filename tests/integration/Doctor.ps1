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
    Integration test: what a run costs (cpu_seconds, SPECIFICATION.md 12.2)
    and "vigil doctor" (16.7) on Windows.
.DESCRIPTION
    Builds a throwaway install root, runs a job that does work, and checks
    its state and what doctor reports: its cost, the cores Vigil keeps busy
    (ok, and WARN from a made-up history), the shell start, a state folder
    no one may read, a root with no runs, and the Windows checks. .NET's
    native images are present on CI's runners, so their absence is tested
    with the stand-in of 22.4.6, in doctor (WARN) and in precheck (a note).
    The twin of doctor.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-doctor.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

# Whether the text has a line matching the regular expression.
function Test-Line {
    param([string]$Name, [string]$Text, [string]$Pattern)
    $hit = @($Text -split "`r?`n" | Where-Object { $_ -cmatch $Pattern }).Count -gt 0
    if ($hit) { Test-Equal $Name 'yes' 'yes' } else { Test-Equal $Name "a line matching $Pattern" $Text }
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
    $ErrorActionPreference = 'Continue'
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$scripts = Join-Path $root 'scripts'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), $scripts)
Set-Content -LiteralPath (Join-Path $scripts 'burn.ps1') -Value @(
    '$i = 0; while ($i -lt 300000) { $i++ }', 'Write-Output "metric loops $i"')
Set-Content -LiteralPath (Join-Path $scripts 'idle.ps1') -Value 'exit 0'
Set-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value @'
[vigil]
instance = doctor

[job.burn]
file      = scripts/burn.ps1
run_every = 5m

[job.idle]
file      = scripts/idle.ps1
run_every = 5m
'@
$inv = [System.Globalization.CultureInfo]::InvariantCulture

Write-Host '== no runs yet'
$r = Invoke-Vigil @('doctor')
Test-Equal 'no runs: exit code' '0' "$($r.Code)"
Test-Line 'no runs: said so' $r.Output '^  note  no runs recorded yet$'
Test-Line 'no runs: the shell start' $r.Output '^  ok    (powershell|pwsh)\.exe: [0-9]+\.[0-9]{2} CPU s, [0-9]+\.[0-9]{2} s$'

Write-Host '== cpu_seconds'
[void](Invoke-Vigil @('run', 'burn'))
[void](Invoke-Vigil @('run', 'burn'))
[void](Invoke-Vigil @('run', 'idle'))
$cpu = Get-StateValue (Join-Path $root 'state\jobs\burn.state') 'cpu_seconds'
Test-Equal 'burn: cpu_seconds is a number' 'yes' $(if ($cpu -cmatch '^[0-9]+\.[0-9]{2}$') { 'yes' } else { "$cpu" })
Test-Equal 'burn: cpu_seconds is not zero' 'yes' $(if ([double]::Parse($cpu, $inv) -gt 0) { 'yes' } else { 'no' })
Test-Equal 'idle: cpu_seconds recorded' 'yes' $(if ((Get-StateValue (Join-Path $root 'state\jobs\idle.state') 'cpu_seconds') -cmatch '^[0-9]+\.[0-9]{2}$') { 'yes' } else { 'no' })

Write-Host '== doctor'
$r = Invoke-Vigil @('doctor')
foreach ($l in ($r.Output.TrimEnd() -split "`r?`n")) { Write-Host "    | $l" }
Test-Equal 'doctor: exit code' '0' "$($r.Code)"
Test-Line 'doctor: burn ran twice in the hour' $r.Output "^  burn +2 +$([regex]::Escape($cpu)) s +[0-9]+ s$"
Test-Line 'doctor: idle ran once' $r.Output '^  idle +1 '
Test-Line 'doctor: the cores' $r.Output '^  (ok    |note  )Vigil keeps [0-9]\.[0-9]{2} of a core busy'
Test-Line 'doctor: native images, ok' $r.Output "^  ok    \.NET native images: "
Test-Line 'doctor: Defender, said' $r.Output '^  (ok    |note  )Defender: '
Test-Line 'doctor: logging policies, said' $r.Output '^  (ok    |note  )PowerShell logging polic'

Write-Host '== above half a core'
$jobs = Join-Path $root 'state\jobs'
Set-Content -LiteralPath (Join-Path $jobs 'heavy.state') -Value "[state]`njob = heavy`ncpu_seconds = 40.50`nduration_seconds = 41"
$hl = Join-Path $root 'logs\jobs\heavy'
[void](New-Item -ItemType Directory -Force -Path $hl)
$now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
$lines = @(1..60 | ForEach-Object { "$now r$_ run start" }) + '2020-01-01T00:00:00Z r-old run start'
[System.IO.File]::WriteAllLines((Join-Path $hl 'today.log'), [string[]]$lines)
$r = Invoke-Vigil @('doctor')
Test-Equal 'heavy: exit code' '1' "$($r.Code)"
Test-Line 'heavy: first, 60 runs in the hour' $r.Output '^  heavy +60 +40\.50 s +41 s$'
Test-Line 'heavy: WARN' $r.Output '^  WARN  Vigil keeps 0\.[6-9][0-9] of a core busy, above half of one'
Test-Line 'heavy: the summary' $r.Output '^doctor: 1 warning\(s\)$'
Remove-Item -Force (Join-Path $jobs 'heavy.state'); Remove-Item -Recurse -Force $hl

Write-Host '== without native images (the stand-in, 22.4.6)'
$env:VIGIL_TEST_NGEN_MISSING = '1'
try {
    $r = Invoke-Vigil @('doctor')
    Test-Equal 'ngen: doctor exit code' '1' "$($r.Code)"
    Test-Line 'ngen: doctor WARN, with the command' $r.Output "^  WARN  Windows PowerShell starts without \.NET's native images: .*ngen\.exe executeQueuedItems"
    $r = Invoke-Vigil @('precheck')
    Test-Line 'ngen: precheck note' $r.Output "^  note  Windows PowerShell starts without \.NET's native images"
    Test-Line 'ngen: precheck fails while the stand-in is set' $r.Output '^  FAIL  VIGIL_TEST_NGEN_MISSING is set'
}
finally { Remove-Item Env:VIGIL_TEST_NGEN_MISSING }
$r = Invoke-Vigil @('precheck')
Test-Equal 'ngen: no precheck note with native images' '0' "$(@($r.Output -split "`r?`n" | Where-Object { $_ -cmatch 'native images' }).Count)"

Write-Host '== a state folder no one may read'
[void](& icacls.exe $jobs /deny '*S-1-1-0:(OI)(CI)(RD,RA,REA)' 2>&1)
try { $r = Invoke-Vigil @('doctor') }
finally { [void](& icacls.exe $jobs /remove:d '*S-1-1-0' 2>&1) }
Test-Equal 'unreadable: exit code' '1' "$($r.Code)"
Test-Line 'unreadable: says which' $r.Output "^  WARN  cannot read $([regex]::Escape($jobs)) from this account"
Test-Line 'unreadable: the Windows checks still' $r.Output '^Windows$'

Write-Host '== a configuration no one may read'
$cfg = Join-Path $root 'config\vigil.config'
[void](& icacls.exe $cfg /deny '*S-1-1-0:(R)' 2>&1)
try { $r = Invoke-Vigil @('doctor') }
finally { [void](& icacls.exe $cfg /remove:d '*S-1-1-0' 2>&1) }
Test-Equal 'config unreadable: exit code' '1' "$($r.Code)"
Test-Line 'config unreadable: says which' $r.Output "^  WARN  cannot read $([regex]::Escape($cfg)) from this account"
Test-Line 'config unreadable: the shell start still' $r.Output '^  ok    (powershell|pwsh)\.exe: '
Test-Line 'config unreadable: the Windows checks still' $r.Output '^Windows$'

Remove-Item -Recurse -Force $root
Write-Host ''
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
