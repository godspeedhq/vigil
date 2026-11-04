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
    run-update.ps1 - a real update on a real machine (SPECIFICATION.md
    18.7), on Windows. The twin of run-update.sh.
.DESCRIPTION
        .\scripts\run-update.ps1 [-From 0.2.0]

    A published release, installed by its own installer from GitHub,
    updates itself to the latest release from GitHub, with no test
    overrides. The supervisor must carry on as the same process, with its
    jobs, state and metrics intact. Nothing is mocked and nothing is built.

    The install root is a throwaway folder, so a Vigil already installed on
    this machine is not touched; the user PATH is put back afterwards. No
    Docker, no backend. Its evidence is kept like the other runs'.

    Exit code: 0 all passed, 1 any failed.
#>

param([string]$From = '0.2.0')

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$shell = (Get-Process -Id $PID).Path
. (Join-Path $here 'evidence.ps1')

$From = $From.TrimStart('v')
$github = 'https://github.com/godspeedhq/vigil'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil update.$PID"
[void](New-Item -ItemType Directory -Force -Path $work)
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = Join-Path $work 'root'
$script:pass = 0
$script:fail = 0
$sup = $null
$long = $null
$savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

function Get-Runs {
    param([string]$Job)
    $d = Join-Path $root "logs\jobs\$Job"
    if (-not (Test-Path -LiteralPath $d)) { return 0 }
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $d -Filter '*.log') {
        $n += @([System.IO.File]::ReadAllLines($f.FullName) | Where-Object { $_.Contains(' run start') }).Count
    }
    return $n
}

function Get-Version { ([System.IO.File]::ReadAllText((Join-Path $root 'app\VERSION'))).Trim() }

# What Vigil printed, shown and kept as <name>.out.
function Show-Out {
    param([string]$Name, $Result)
    [System.IO.File]::WriteAllText((Join-Path $work "$Name.out"), $Result.Text)
    $Result.Text.Split("`n") | ForEach-Object { Write-Host $_ }
    Write-Host ''
}

try {
    Start-Evidence "update-from-$From" $bk '' "$($MyInvocation.MyCommand.Path) -From $From"
    # The real release server, and the real release key: no test overrides.
    foreach ($v in 'VIGIL_TEST_RELEASE_URL', 'VIGIL_TEST_RELEASE_KEY', 'VIGIL_FAULT') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'

    # Where GitHub's latest release redirects is the version to expect.
    $req = [System.Net.WebRequest]::Create("$github/releases/latest")
    $req.AllowAutoRedirect = $false
    $resp = $req.GetResponse()
    $latest = ($resp.Headers['Location'] -split '/v')[-1]
    $resp.Close()
    Write-Host "updating from $From; the latest release is $latest`n"
    if (-not $latest -or $latest -ceq $From) { throw "nothing to update to: the latest release is [$latest]" }

    # The old release, through its own installer, as its users ran it.
    Invoke-WebRequest -UseBasicParsing -Uri "$github/releases/download/v$From/install.ps1" -OutFile "$work\install.ps1"
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$work\install.ps1" -User -Version $From -Prefix $root -Instance update -Backend file -NoService 2>&1
    $rc = $LASTEXITCODE
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    [System.IO.File]::WriteAllText("$work\install.out", (@($out | ForEach-Object { "$_" }) -join "`n"))
    Test-Equal "Vigil $From installs from GitHub" '0' ([string]$rc)
    if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" }; throw 'install failed' }
    Test-Equal "and is $From" $From (Get-Version)
    # From 0.2.1 on, a release carries the release key, and its self update
    # refuses what the key did not sign. It says nothing when the signature
    # is good, so the run checks the same signature with the same key itself.
    $oldKey = $null
    if (Test-Path -LiteralPath "$root\app\release-key.pem") {
        $oldKey = "$work\old-key.pem"
        Copy-Item -LiteralPath "$root\app\release-key.pem" -Destination $oldKey
        Write-Host "Vigil $From has the release key: its update must be signed by it"
    }
    else { Write-Host "Vigil $From has no release key: its update checks the SHA-256 only (signed releases began with 0.2.1)" }

    # Jobs that outlive the update: one always due, one running across it.
    Set-Content -LiteralPath "$root\scripts\beat.cmd" -Value @('@echo off', 'echo metric beats 1')
    Set-Content -LiteralPath "$root\scripts\long.cmd" -Value @('@echo off', 'ping -n 21 127.0.0.1 > nul', 'echo metric long 1')
    $cfg = Join-Path $root 'config\vigil.config'
    $text = ([System.IO.File]::ReadAllText($cfg)) -replace '(?m)^tick *= *.*$', 'tick = 1s'
    if ($text -cnotmatch '(?m)^tick') { $text += "`n[scheduler]`ntick = 1s`n" }
    $text += "`n[job.beat]`nfile      = scripts\beat.cmd`nrun_every = 2s`n`n[job.long]`nfile      = scripts\long.cmd`nrun_every = 3650d`n"
    [System.IO.File]::WriteAllText($cfg, $text)
    $sum = (Get-FileHash -LiteralPath $cfg).Hash

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"")
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList ($argv + 'supervise')
    for ($i = 0; $i -lt 180 -and (Get-Runs 'beat') -lt 2; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal "jobs run on $From" 'True' ([string]((Get-Runs 'beat') -ge 2))
    Test-Equal "the supervisor is $From" $From (Invoke-Vigil version --supervisor).Text
    $long = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList ($argv + @('run', 'long'))
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$root\state\jobs\long.state"); $i++) { Start-Sleep -Milliseconds 200 }
    $before = Get-Runs 'beat'

    Write-Host "`n> vigil self update --check"
    Show-Out 'check' (Invoke-Vigil self update --check)
    Write-Host '> vigil self update'
    $r = Invoke-Vigil self update
    Show-Out 'update' $r
    Test-Equal 'it updates itself from GitHub' '0' ([string]$r.Code)
    Test-Equal "to $latest" $latest (Get-Version)
    for ($i = 0; $i -lt 120 -and (Invoke-Vigil version --supervisor).Text -cne $latest; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal "the supervisor came up as $latest" $latest (Invoke-Vigil version --supervisor).Text
    Test-Equal 'the same process' 'False' ([string]$sup.HasExited)
    Test-Equal 'the configuration is untouched' $sum (Get-FileHash -LiteralPath $cfg).Hash
    if ($oldKey) {
        # Git for Windows' openssl: Windows has none of its own.
        $openssl = Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'
        foreach ($f in 'SHA256SUMS', 'SHA256SUMS.sig') { Invoke-WebRequest -UseBasicParsing -Uri "$github/releases/download/v$latest/$f" -OutFile "$work\$f" }
        & $openssl dgst -sha256 -verify $oldKey -signature "$work\SHA256SUMS.sig" "$work\SHA256SUMS" 2>&1 | Out-Null
        Test-Equal "$latest is signed by the key $From has" '0' ([string]$LASTEXITCODE)
    }
    Test-Equal "$latest has the release key" 'True' ([string](Test-Path -LiteralPath "$root\app\release-key.pem"))

    # Everything picks up where it left off.
    [void]$long.WaitForExit(120000)
    $t = ''
    foreach ($f in Get-ChildItem -LiteralPath "$root\logs\jobs\long" -Filter '*.log') { $t += [System.IO.File]::ReadAllText($f.FullName) }
    Test-Equal 'the job running across it finished' '1' ([string]([regex]::Matches($t, 'run end succeeded')).Count)
    Test-Equal 'and ran once' '1' ([string](Get-Runs 'long'))
    for ($i = 0; $i -lt 180 -and (Get-Runs 'beat') -le $before + 2; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'scheduled jobs carry on' 'True' ([string]((Get-Runs 'beat') -gt $before + 2))
    $sv = ''
    foreach ($f in Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log') { $sv += [System.IO.File]::ReadAllText($f.FullName) }
    Test-Equal 'no run crashed' 'False' ([string]$sv.Contains('crashed'))
    Test-Equal 'metrics still flow' 'True' ([string]([System.IO.File]::ReadAllText("$root\metrics\vigil.prom") -cmatch '(?m)^beat_beats'))
    Test-Equal 'nothing quarantined' 'False' ([string](Test-Path -LiteralPath "$root\state\quarantine"))

    # Now on the latest, there is nothing to update to.
    Write-Host '> vigil self update'
    $r = Invoke-Vigil self update
    Show-Out 'again' $r
    Test-Equal 'a second update finds nothing newer' '0' ([string]$r.Code)
    Test-Equal "and leaves $latest in place" $latest (Get-Version)
    if ($script:fail -gt 0) { Write-Host ($sv.Split("`n") | Select-Object -Last 30) }
}
catch { $script:fail++; Write-Host "  FAIL  $_" }
finally {
    # The supervisor and run this script started, and nothing else.
    foreach ($p in @($sup, $long)) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } } }
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Start-Sleep -Seconds 2
    Write-Host "$($script:pass) passed, $($script:fail) failed"
    Save-Evidence $work $root @()
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
exit 0
