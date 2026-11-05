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
    Integration test: [vigil] version (SPECIFICATION.md 18.11) on Windows.
.DESCRIPTION
    A real supervisor follows the version its configuration names, up and
    down, through the vigil_update worker, against mock-files.py as the
    release server with releases built by tools/release/package.sh: an
    update, a downgrade, a release that is not there yet, one that does not
    run, one that would go back past a data format change, and a version
    from a fetched configuration. vigil self update refuses while it is set.
    The twin of version-config.sh.

    Needs Python, and bash for package.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil version.$PID"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

# Runs vigil in the install; @{ Code; Text }.
function Invoke-Vigil {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

function Get-Version { $f = Join-Path $root 'app\VERSION'; if (Test-Path -LiteralPath $f) { ([System.IO.File]::ReadAllText($f)).Trim() } }
function Get-SupLog {
    $t = ''
    foreach ($f in Get-ChildItem -LiteralPath "$root\logs\supervisor" -Filter '2*.log' -ErrorAction SilentlyContinue) { $t += [System.IO.File]::ReadAllText($f.FullName) }
    return $t
}
function Get-Update {
    param([string]$Key)
    try {
        foreach ($l in [System.IO.File]::ReadAllLines("$root\state\update.state")) {
            if ($l -cmatch "^$Key *= ?(.*)$") { return $Matches[1] }
        }
    }
    catch { }
    return ''
}
function Get-Runs {
    param([string]$Job)
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath "$root\logs\jobs\$Job" -Filter '*.log' -ErrorAction SilentlyContinue) {
        $n += @([System.IO.File]::ReadAllLines($f.FullName) | Where-Object { $_.Contains(' run start') }).Count
    }
    return $n
}
# Waits up to $Seconds for $Test to return $true.
function Wait-Until {
    param([int]$Seconds, [scriptblock]$Test)
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        if (& $Test) { return }
        Start-Sleep -Milliseconds 500
    }
}
# Sets [vigil] version in configuration file $Path, or removes it for '-'.
function Set-ConfigVersion {
    param([string]$Path, [string]$Version)
    $out = New-Object System.Text.StringBuilder
    $sec = ''
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch '^\[(.+)\]') { $sec = $Matches[1] }
        elseif ($sec -ceq 'vigil' -and $l -cmatch '^version *=') { continue }
        [void]$out.Append("$l`n")
        if ($l -ceq '[vigil]' -and $Version -cne '-') { [void]$out.Append("version = $Version`n") }
    }
    [System.IO.File]::WriteAllText($Path, $out.ToString())
}
function Show-Run {
    Write-Host "        app\VERSION $(Get-Version); update.state:"
    try { [System.IO.File]::ReadAllLines("$root\state\update.state") | ForEach-Object { Write-Host "          $_" } } catch { }
    (Get-SupLog).Split("`n") | Select-Object -Last 15 | ForEach-Object { Write-Host "        sup: $_" }
    foreach ($f in Get-ChildItem -LiteralPath "$root\logs\jobs\vigil_update" -Filter '*.log' -ErrorAction SilentlyContinue) {
        [System.IO.File]::ReadAllLines($f.FullName) | Select-Object -Last 15 | ForEach-Object { Write-Host "        update: $_" }
    }
}

function ConvertTo-BashPath { param([string]$Path) return $Path.Replace('\', '/') }
function Invoke-Openssl {
    param([string]$Line)
    & $bash -c "openssl $Line" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl $Line failed" }
}
function Write-Sums {
    param([string]$Dir, [string[]]$Files)
    $t = ''
    foreach ($f in $Files) { $t += "$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Dir $f)).Hash.ToLowerInvariant())  $f`n" }
    [System.IO.File]::WriteAllText((Join-Path $Dir 'SHA256SUMS'), $t)
}
# Publishes release $Version on the mock, built from this repository.
function Publish-Release {
    param([string]$Version)
    $d = Join-Path $www "releases\download\v$Version"
    [void](New-Item -ItemType Directory -Force -Path $d, "$www\releases\tag")
    & $bash -c "VIGIL_SIGN_KEY='$(ConvertTo-BashPath "$work\release.key")' bash '$(ConvertTo-BashPath "$repo\tools\release\package.sh")' '$Version' '$(ConvertTo-BashPath $d)'" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
    [System.IO.File]::WriteAllText("$www\releases\tag\v$Version", '')
}
# Publishes release $To, made from release $From by $Change, run in its app\.
function Publish-Variant {
    param([string]$From, [string]$To, [scriptblock]$Change)
    $b = Join-Path $work "variant-$To"
    Expand-Archive -LiteralPath "$www\releases\download\v$From\vigil-$From.zip" -DestinationPath $b
    Rename-Item -LiteralPath "$b\vigil-$From" -NewName "vigil-$To"
    [System.IO.File]::WriteAllText("$b\vigil-$To\app\VERSION", "$To`n")
    & $Change "$b\vigil-$To\app"
    $d = Join-Path $www "releases\download\v$To"
    [void](New-Item -ItemType Directory -Force -Path $d)
    Compress-Archive -Path "$b\vigil-$To" -DestinationPath "$d\vigil-$To.zip"
    Copy-Item "$repo\install.ps1" $d
    Write-Sums $d @("vigil-$To.zip", 'install.ps1')
    $bd = ConvertTo-BashPath $d
    Invoke-Openssl "dgst -sha256 -sign '$kw/release.key' -out '$bd/SHA256SUMS.sig' '$bd/SHA256SUMS'"
    [System.IO.File]::WriteAllText("$www\releases\tag\v$To", '')
}
function Set-Latest { param([string]$Version) [System.IO.File]::WriteAllText("$work\mock\redirects", "/releases/latest /releases/tag/v$Version`n") }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$python = $null
foreach ($p in @('python3', 'python', 'py')) {
    if (Get-Command $p -CommandType Application -ErrorAction SilentlyContinue) {
        & $p -c 'import http.server' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $python = (Get-Command $p -CommandType Application | Select-Object -First 1).Source; break }
    }
}
if (-not $python) { Write-Host 'needs Python'; exit 1 }
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $bash) { Write-Host 'needs Git Bash, for package.sh'; exit 1 }
[void](New-Item -ItemType Directory -Force -Path (Join-Path $work 'mock\www'))
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$www = Join-Path $work 'mock\www'
$root = Join-Path $work 'root'
$cfg = Join-Path $root 'config\vigil.config'
$mock = $null
$sup = $null
$savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')

try {
    $kw = ConvertTo-BashPath $work
    Invoke-Openssl "genrsa -out '$kw/release.key' 2048"
    Invoke-Openssl "rsa -in '$kw/release.key' -pubout -out '$kw/release.pem'"
    $env:VIGIL_TEST_RELEASE_KEY = "$work\release.pem"
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$work\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$work\mock\stderr"
    $portFile = Join-Path $work 'mock\port'
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $port = if (Test-Path -LiteralPath $portFile) { [System.IO.File]::ReadAllText($portFile).Trim() } else { '' }
    if (-not $port) { Get-Content -LiteralPath "$work\mock\stderr"; throw 'the mock did not start' }
    $env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$port"

    Publish-Release '0.1.0-it'
    Publish-Release '0.2.0-it'
    Set-Latest '0.2.0-it'

    # Installed, with a supervisor and a job that runs throughout.
    # No starting configuration: the base pack's jobs would only make the
    # renames of app\ wait for more processes.
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$www\releases\download\v0.1.0-it\install.ps1" -User -Version '0.1.0-it' -Prefix $root -NoInit -NoService 2>&1
    $rc = $LASTEXITCODE
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Test-Equal 'installed' '0' ([string]$rc)
    if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" }; throw 'install failed' }
    [void](New-Item -ItemType Directory -Force -Path "$root\config", "$root\scripts")
    Set-Content -LiteralPath "$root\scripts\beat.cmd" -Value @('@echo off', 'echo metric beats 1')
    [System.IO.File]::WriteAllText($cfg, "[vigil]`ninstance = vc`n`n[scheduler]`ntick = 1s`n`n[backend.file]`npath = metrics\vigil.prom`n`n[job.beat]`nfile      = scripts\beat.cmd`nrun_every = 2s`n")
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList $argv
    Wait-Until 60 { (Get-Runs 'beat') -ge 1 }
    Test-Equal 'without version, nothing moves' '0.1.0-it' (Get-Version)
    Test-Equal 'without version, self update is not refused' '0' ([string](Invoke-Vigil self update --check).Code)

    # An update.
    Set-ConfigVersion $cfg '0.2.0-it'
    Wait-Until 120 { (Get-Version) -ceq '0.2.0-it' }
    Test-Equal 'it updates to the version named' '0.2.0-it' (Get-Version)
    Wait-Until 60 { (Get-Update 'version') -ceq '0.2.0-it' -and (Get-Update 'result') -ceq 'succeeded' }
    Test-Equal 'and records it' 'succeeded' (Get-Update 'result')
    Test-Equal 'as the same supervisor process' 'False' ([string]$sup.HasExited)
    Test-Equal 'which runs the new version' '0.2.0-it' (Invoke-Vigil version --supervisor).Text
    Wait-Until 30 { (Get-SupLog).Contains('Vigil is now 0.2.0-it') }
    Test-Equal 'the supervisor log says so' 'True' ([string](Get-SupLog).Contains('Vigil is now 0.2.0-it, as the configuration asks'))
    Test-Equal 'and said what it was doing' 'True' ([string](Get-SupLog).Contains('updating Vigil 0.1.0-it to 0.2.0-it, as the configuration asks'))
    Test-Equal 'the configuration was not written to' 'True' ([string]([System.IO.File]::ReadAllText($cfg) -cmatch '(?m)^version = 0\.2\.0-it$'))
    if ((Get-Version) -cne '0.2.0-it') { Show-Run }
    $before = Get-Runs 'beat'
    Wait-Until 30 { (Get-Runs 'beat') -ge $before + 2 }
    Test-Equal 'jobs carry on' 'True' ([string]((Get-Runs 'beat') -ge $before + 2))
    $r = Invoke-Vigil self update
    Test-Equal 'self update is refused while version is set' '1' ([string]$r.Code)
    Test-Equal 'saying where to go' 'True' ([string]$r.Text.Contains('the version is set in the configuration (version = 0.2.0-it): change it there to update'))
    Test-Equal 'with --version too' '1' ([string](Invoke-Vigil self update --version 0.1.0-it).Code)
    Test-Equal '--check still works' '0' ([string](Invoke-Vigil self update --check).Code)
    $saved = $env:VIGIL_TEST_RELEASE_URL
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL
    $r = Invoke-Vigil precheck
    $env:VIGIL_TEST_RELEASE_URL = $saved
    Test-Equal 'precheck notes the version' 'True' ([string]$r.Text.Contains('note  version 0.2.0-it: this is 0.2.0-it'))
    Test-Equal 'and that this account can update' 'True' ([string]$r.Text.Contains('note  this account can update Vigil'))

    # A downgrade.
    Set-ConfigVersion $cfg '0.1.0-it'
    Wait-Until 120 { (Get-Version) -ceq '0.1.0-it' }
    Test-Equal 'it goes back to an older version named' '0.1.0-it' (Get-Version)
    Wait-Until 60 { (Get-Update 'version') -ceq '0.1.0-it' -and (Get-Update 'result') -ceq 'succeeded' }
    Test-Equal 'and records it' 'succeeded' (Get-Update 'result')

    # A release that is not there yet: logged, kept, tried again.
    Set-ConfigVersion $cfg '0.5.0-it'
    Wait-Until 90 { (Get-Update 'version') -ceq '0.5.0-it' -and (Get-Update 'result') -ceq 'unavailable' }
    Test-Equal 'a release not there: recorded as unavailable' 'unavailable' (Get-Update 'result')
    Test-Equal 'nothing changed' '0.1.0-it' (Get-Version)
    Wait-Until 30 { (Get-SupLog).Contains('Vigil 0.5.0-it, which the configuration asks for, could not be downloaded') }
    Test-Equal 'logged as a warning' 'True' ([string]((Get-SupLog) -cmatch 'WARN supervisor Vigil 0\.5\.0-it, which the configuration asks for, could not be downloaded: .*; staying on 0\.1\.0-it, trying again in 5 minutes'))
    $r = Invoke-Vigil status
    Test-Equal 'status shows it' 'True' ([string]$r.Text.Contains('the configuration asks for 0.5.0-it; this is 0.1.0-it'))
    Test-Equal 'and why' 'True' ([string]$r.Text.Contains('could not be downloaded:'))
    Publish-Release '0.5.0-it'
    # Five minutes, made short: the record is aged instead.
    $us = "$root\state\update.state"
    [System.IO.File]::WriteAllText($us, ([System.IO.File]::ReadAllText($us) -replace '(?m)^epoch .*$', 'epoch   = 1'))
    Wait-Until 120 { (Get-Version) -ceq '0.5.0-it' }
    Test-Equal 'once it is there, the retry takes it' '0.5.0-it' (Get-Version)
    if ((Get-Version) -cne '0.5.0-it') { Show-Run }

    # A release that does not run: rolled back, not tried again.
    Publish-Variant '0.5.0-it' '0.9.0-it' { param($App) [System.IO.File]::WriteAllText("$App\vigil.ps1", "exit 1`n") }
    Set-ConfigVersion $cfg '0.9.0-it'
    Wait-Until 120 { (Get-Update 'version') -ceq '0.9.0-it' -and (Get-Update 'result') -ceq 'failed' }
    Test-Equal 'a release that does not run: recorded as failed' 'failed' (Get-Update 'result')
    Test-Equal 'the working version stays' '0.5.0-it' (Get-Version)
    Test-Equal 'and runs' 'Vigil 0.5.0-it' (Invoke-Vigil version).Text
    Test-Equal 'the reason is the installer''s' 'True' ([string](Get-Update 'reason').Contains('went back to the version that was installed'))
    Wait-Until 30 { (Get-SupLog).Contains('Vigil 0.9.0-it, which the configuration asks for, could not be installed') }
    Test-Equal 'logged as an error' 'True' ([string]((Get-SupLog) -cmatch 'ERROR supervisor Vigil 0\.9\.0-it, which the configuration asks for, could not be installed: .*; staying on 0\.5\.0-it until the configuration names another version'))
    $at = Get-Update 'epoch'
    Start-Sleep -Seconds 8
    Test-Equal 'not tried again' $at (Get-Update 'epoch')
    Test-Equal 'started once' '1' ([string]([regex]::Matches((Get-SupLog), 'to 0\.9\.0-it, as the configuration asks')).Count)
    Test-Equal 'status shows it' 'True' ([string](Invoke-Vigil status).Text.Contains('not tried again until the version changes'))

    # Back past a data format change: refused.
    Publish-Variant '0.5.0-it' '0.6.0-it' {
        param($App)
        [void](New-Item -ItemType Directory -Force -Path "$App\migrations")
        [System.IO.File]::WriteAllText("$App\migrations\2.ps1", "exit 0`n")
        [System.IO.File]::WriteAllText("$App\migrations\2.sh", "exit 0`n")
    }
    Set-ConfigVersion $cfg '0.6.0-it'
    Wait-Until 120 { (Get-Version) -ceq '0.6.0-it' }
    Test-Equal 'a release with a new data format' '0.6.0-it' (Get-Version)
    Wait-Until 30 { (Test-Path -LiteralPath "$root\state\format") -and ([System.IO.File]::ReadAllText("$root\state\format").Trim() -ceq '2') }
    Test-Equal 'migrates the data' '2' $(try { [System.IO.File]::ReadAllText("$root\state\format").Trim() } catch { '' })
    Set-ConfigVersion $cfg '0.5.0-it'
    # The installer waits for a reload that never comes, then puts 0.6.0 back.
    Wait-Until 480 { (Get-Update 'version') -ceq '0.5.0-it' -and (Get-Update 'result') -ceq 'failed' }
    Test-Equal 'going back past it fails' 'failed' (Get-Update 'result')
    Test-Equal 'and changes nothing' '0.6.0-it' (Get-Version)
    Test-Equal 'the supervisor says why' 'True' ([string](Get-SupLog).Contains('staying on Vigil 0.6.0-it, not reloading to 0.5.0-it'))
    Test-Equal 'the supervisor is still running' 'False' ([string]$sup.HasExited)
    if ((Get-Version) -cne '0.6.0-it') { Show-Run }

    # The version from a fetched configuration.
    Publish-Variant '0.6.0-it' '0.7.0-it' { param($App) }
    $fleet = Join-Path $work 'fleet'
    [void](New-Item -ItemType Directory -Force -Path "$fleet\hosts")
    Set-ConfigVersion $cfg '0.7.0-it'
    Copy-Item -LiteralPath $cfg -Destination "$fleet\hosts\vc.config"
    [System.IO.File]::WriteAllText($cfg, "[vigil]`nconfig_source = fleet`nconfig_file   = hosts/vc.config`n`n[source.fleet]`ntype        = local`npath        = $fleet`ncheck_every = 1s`n")
    Wait-Until 120 { (Get-Version) -ceq '0.7.0-it' }
    Test-Equal 'a fetched configuration moves it' '0.7.0-it' (Get-Version)
    if ((Get-Version) -cne '0.7.0-it') { Show-Run }
    Test-Equal 'self update is refused by the fetched version' 'True' ([string](Invoke-Vigil self update).Text.Contains('version = 0.7.0-it'))
    # Latest first, so that once the line is gone self update finds nothing to do.
    Set-Latest '0.7.0-it'
    Set-ConfigVersion "$fleet\hosts\vc.config" '-'
    Wait-Until 60 { -not (Invoke-Vigil self update).Text.Contains('set in the configuration') }
    $r = Invoke-Vigil self update
    Test-Equal 'removing the line gives self update back' '0' ([string]$r.Code)
    Test-Equal 'nothing moved meanwhile' '0.7.0-it' (Get-Version)

    Test-Equal 'no run crashed' 'False' ([string](Get-SupLog).Contains('crashed'))
    Test-Equal 'the supervisor ran throughout' 'False' ([string]$sup.HasExited)
    if ($script:fail -gt 0) { Show-Run }
}
finally {
    foreach ($p in @($sup, $mock)) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } } }
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\VIGIL_TEST_RELEASE_KEY -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
