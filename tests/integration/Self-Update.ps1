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
    Integration test: vigil self update (SPECIFICATION.md 18.7) on Windows.
.DESCRIPTION
    Runs against mock-files.py as the release server, with releases built by
    tools/release/package.sh. Finding the latest release, updating, leaving
    config\ and scripts\ alone, a running job that finishes across the
    update, refusing whatever does not verify, and going back when a new
    version does not run. The twin of self-update.sh.

    Needs Python, and bash for package.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil update.$PID"
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

# The supervisor's process id, from its lock file, which it keeps open.
function Get-VigilLockPid {
    $fs = New-Object System.IO.FileStream -ArgumentList "$root\state\supervisor.lock", 'Open', 'Read', 'ReadWrite'
    try { $t = (New-Object System.IO.StreamReader -ArgumentList $fs).ReadToEnd() }
    finally { $fs.Dispose() }
    if ($t -cmatch 'pid = ([0-9]+)') { return $Matches[1] }
    return ''
}

function Get-Version { $f = Join-Path $root 'app\VERSION'; if (Test-Path -LiteralPath $f) { ([System.IO.File]::ReadAllText($f)).Trim() } }

# Publishes release $Version on the mock, and makes it the latest.
function Publish-Release {
    param([string]$Version)
    $d = Join-Path $www "releases\download\v$Version"
    [void](New-Item -ItemType Directory -Force -Path $d, "$www\releases\tag")
    & $bash -c "VIGIL_SIGN_KEY='$(ConvertTo-BashPath "$work\release.key")' bash '$(ConvertTo-BashPath "$repo\tools\release\package.sh")' '$Version' '$(ConvertTo-BashPath $d)'" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
    [System.IO.File]::WriteAllText("$www\releases\tag\v$Version", '')
    Set-Latest $Version
}
function Set-Latest {
    param([string]$Version)
    [System.IO.File]::WriteAllText("$work\mock\redirects", "/releases/latest /releases/tag/v$Version`n")
}
# Openssl, through Git Bash.
function Invoke-Openssl {
    param([string]$Line)
    & $bash -c "openssl $Line" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "openssl $Line failed" }
}
function ConvertTo-BashPath {
    param([string]$Path)
    return $Path.Replace('\', '/')
}

function Write-Sums {
    param([string]$Dir, [string[]]$Files)
    $t = ''
    foreach ($f in $Files) { $t += "$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Dir $f)).Hash.ToLowerInvariant())  $f`n" }
    [System.IO.File]::WriteAllText((Join-Path $Dir 'SHA256SUMS'), $t)
}

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
$www = Join-Path $work 'mock\www'
[void](New-Item -ItemType Directory -Force -Path $www)
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$www = Join-Path $work 'mock\www'
$root = Join-Path $work 'root'
$mock = $null

try {
    # A release key for this run, known to Vigil only through the test override.
    $kw = ConvertTo-BashPath $work
    Invoke-Openssl "genrsa -out '$kw/release.key' 2048"
    Invoke-Openssl "genrsa -out '$kw/other.key' 2048"
    Invoke-Openssl "rsa -in '$kw/release.key' -pubout -out '$kw/release.pem'"
    $env:VIGIL_TEST_RELEASE_KEY = "$work\release.pem"
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$work\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$work\mock\stderr"
    $portFile = Join-Path $work 'mock\port'
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $port = if (Test-Path -LiteralPath $portFile) { [System.IO.File]::ReadAllText($portFile).Trim() } else { '' }
    Test-Equal 'mock started' 'True' ([string][bool]$port)
    if (-not $port) { Get-Content -LiteralPath "$work\mock\stderr"; throw 'the mock did not start' }
    $env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$port"

    # A copy from the repository.
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'app\vigil.ps1') version 2>&1
    Test-Equal 'version: a repository copy says so' 'True' ([string]("$out".Contains('from the repository')))
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'app\vigil.ps1') self update 2>&1
    Test-Equal 'a repository copy is not updated' '1' ([string]$LASTEXITCODE)
    Test-Equal 'saying why' 'True' ([string]("$out".Contains('update it with git')))

    # The one-line path: the installer finds the latest release itself.
    Publish-Release '0.0.1-it'
    $d1 = Join-Path $www 'releases\download\v0.0.1-it'
    # No PATH change for the test: -Upgrade is what self update uses, and a
    # fresh install's PATH step has its own test in Install.ps1.
    $savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$d1\install.ps1" -User -Prefix $root -Instance it -Backend file -NoService 2>&1
    $rc = $LASTEXITCODE
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Test-Equal 'install from the latest release' '0' ([string]$rc)
    if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'its version' 'Vigil 0.0.1-it' (Invoke-Vigil version).Text
    Test-Equal 'the packs are in place' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\cpu.ps1"))
    Test-Equal 'with no other platform''s scripts' '0' ([string]@(Get-ChildItem -LiteralPath "$root\packs" -Recurse -Filter '*.sh').Count)
    Test-Equal 'and in no platform folder' 'False' ([string](Test-Path -LiteralPath "$root\packs\base\windows"))
    [System.IO.File]::WriteAllText("$root\packs\base\untouched", "mine`n")
    $about = (Invoke-Vigil about).Text
    Test-Equal 'about: who made it' 'True' ([string]$about.Contains('Created by  Bankole Ogundero and the Vigil contributors'))
    Test-Equal 'about: where it is' 'True' ([string]$about.Contains("Installed   $root"))

    [System.IO.File]::AppendAllText("$root\config\vigil.config", "# my change`n")
    Set-Content -LiteralPath "$root\scripts\mine.cmd" -Value @('@echo off', 'echo mine')
    $cfg = (Get-FileHash -LiteralPath "$root\config\vigil.config").Hash

    # Nothing newer.
    $r = Invoke-Vigil self update
    Test-Equal 'up to date: succeeds' '0' ([string]$r.Code)
    Test-Equal 'up to date: says so' 'True' ([string]$r.Text.Contains('nothing to do'))

    # A newer release.
    Publish-Release '0.0.2-it'
    $r = Invoke-Vigil self update --check
    Test-Equal '--check: succeeds' '0' ([string]$r.Code)
    Test-Equal '--check: names the new version' 'True' ([string]$r.Text.Contains('0.0.2-it is available'))
    Test-Equal '--check: changes nothing' '0.0.1-it' (Get-Version)

    # When /releases/latest fails (GitHub has answered 504 for half an hour
    # while the downloads worked), the API names the latest release; when
    # both fail, nothing is changed. The mock serves the API's answer at
    # /api/releases/latest.
    Remove-Item -LiteralPath "$work\mock\redirects" -Force
    [void](New-Item -ItemType Directory -Force -Path "$www\api\releases")
    [System.IO.File]::WriteAllText("$www\api\releases\latest", "{`"url`":`"x`",`"tag_name`":`"v0.0.2-it`",`"name`":`"0.0.2-it`"}`n")
    $r = Invoke-Vigil self update --check
    Test-Equal 'the page failing: the API names the new version' 'True' ([string]$r.Text.Contains('0.0.2-it is available'))
    $apiRoot = Join-Path $work 'root-api'
    $savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$www\releases\download\v0.0.2-it\install.ps1" -User -Prefix $apiRoot -Instance it -Backend file -NoService 2>&1
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Test-Equal 'the page failing: the installer asks the API' '0.0.2-it' ([string](Get-Content -LiteralPath "$apiRoot\app\VERSION" -ErrorAction SilentlyContinue))
    Remove-Item -LiteralPath $apiRoot, "$www\api" -Recurse -Force -ErrorAction SilentlyContinue
    $r = Invoke-Vigil self update
    Test-Equal 'both failing: refused' '1' ([string]$r.Code)
    Test-Equal 'both failing: saying why' 'True' ([string]$r.Text.Contains('cannot reach GitHub to find the latest release'))
    Test-Equal 'both failing: changes nothing' '0.0.1-it' (Get-Version)
    Set-Latest '0.0.2-it'

    # A job running across the update finishes, under the code it started with.
    Set-Content -LiteralPath "$root\scripts\slow.cmd" -Value @('@echo off', 'ping -n 11 127.0.0.1 > nul', 'echo finished slowly')
    [System.IO.File]::AppendAllText("$root\config\vigil.config", "`n[job.slow]`nfile = scripts\slow.cmd`nrun_every = 3650d`n")
    $slow = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'run', 'slow')
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$root\state\jobs\slow.state"); $i++) { Start-Sleep -Milliseconds 200 }

    $r = Invoke-Vigil self update
    Test-Equal 'update succeeds' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'the new version is installed' '0.0.2-it' (Get-Version)
    [void]$slow.WaitForExit(60000)
    $log = @(Get-ChildItem -LiteralPath "$root\logs\jobs\slow" -Filter '*.log')[0].FullName
    $text = [System.IO.File]::ReadAllText($log)
    Test-Equal 'the running job finished' 'True' ([string]$text.Contains('run end succeeded'))
    Test-Equal 'and ran once' '1' ([string]([regex]::Matches($text, 'run start')).Count)
    Test-Equal 'the configuration is kept' 'True' ([string][System.IO.File]::ReadAllText("$root\config\vigil.config").Contains('# my change'))
    Test-Equal 'scripts are untouched' 'True' ([string](Test-Path -LiteralPath "$root\scripts\mine.cmd"))
    Test-Equal 'no app.old or app.new is left' 'False' ([string]((Test-Path -LiteralPath "$root\app.old") -or (Test-Path -LiteralPath "$root\app.new")))
    Test-Equal 'no service was registered' 'False' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))
    Test-Equal 'precheck refuses the test release server' '1' ([string](Invoke-Vigil precheck).Code)

    # A version on request, older included. A process holds a file in app\
    # throughout, as one starting on a busy host does for a moment: Windows
    # will not rename the folder until it lets go.
    Set-Content -LiteralPath "$work\hold.ps1" -Value @('param($File, $Marker)', '$f = [System.IO.File]::Open($File, ''Open'', ''Read'', ''Read'')', '[System.IO.File]::WriteAllText($Marker, ''held'')', 'Start-Sleep -Seconds 25', '$f.Close()')
    $hold = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$work\hold.ps1`"", "`"$root\app\vigil.ps1`"", "`"$work\held`"")
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$work\held"); $i++) { Start-Sleep -Milliseconds 200 }
    # And a program runs from vendor.old, as a service's NSSM does after an
    # earlier update renamed its vendor\, until the service restarts: it
    # cannot be deleted, so the update moves it aside instead of failing.
    [void](New-Item -ItemType Directory -Force -Path "$root\vendor.old")
    Copy-Item -LiteralPath "$env:SystemRoot\System32\PING.EXE" -Destination "$root\vendor.old\held.exe"
    $running = Start-Process -FilePath "$root\vendor.old\held.exe" -ArgumentList @('-n', '120', '127.0.0.1') -PassThru -WindowStyle Hidden
    $r = Invoke-Vigil self update --version 0.0.1-it
    Test-Equal '--version goes back' '0.0.1-it' (Get-Version)
    Test-Equal 'an update waits for a held folder' 'True' ([string]$r.Text.Contains('waiting for processes reading'))
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'a vendor.old in use is moved aside' 'True' ([string](@(Get-ChildItem -LiteralPath $root -Directory -Filter 'vendor.old.*').Count -eq 1))
    Stop-Process -Id $running.Id -ErrorAction SilentlyContinue
    [void]$running.WaitForExit(10000)
    [void]$hold.WaitForExit(40000)
    $r = Invoke-Vigil self update --version 9.9.9
    Test-Equal 'no such release: fails' '1' ([string]$r.Code)
    Test-Equal 'no such release: says so' 'True' ([string]$r.Text.Contains('cannot download'))
    Test-Equal 'no such release: nothing changed' '0.0.1-it' (Get-Version)

    # A release_url: the releases from a copy of their own (18.7). The copy
    # holds the release files as GitHub's, and names the latest in
    # releases\latest\VERSION. GitHub's stand-in names no latest at all, so
    # whatever is found comes from the copy, and the mock's log shows nothing
    # else was asked.
    $m = Join-Path $www 'mirror'
    [void](New-Item -ItemType Directory -Force -Path "$m\releases\download", "$m\releases\latest")
    Copy-Item -LiteralPath $d1, (Join-Path $www 'releases\download\v0.0.2-it') -Destination "$m\releases\download" -Recurse
    [System.IO.File]::WriteAllText("$m\releases\latest\VERSION", "0.0.2-it`n")
    Remove-Item -LiteralPath "$work\mock\redirects" -Force
    $cfgFile = "$root\config\vigil.config"
    $saved = [System.IO.File]::ReadAllText($cfgFile)
    $mirrorUrl = "$env:VIGIL_TEST_RELEASE_URL/mirror"
    [System.IO.File]::WriteAllText($cfgFile, ($saved -replace '(?m)^\[vigil\]\r?$', "[vigil]`nrelease_url = $mirrorUrl"))
    $requests = "$work\mock\requests.log"
    $fromCopy = { [string]@([System.IO.File]::ReadAllLines($requests) | Where-Object { $_ -match '"path"' -and $_ -notmatch '"path": "/mirror/' }).Count }
    Test-Equal 'release_url: about names it' 'True' ([string](Invoke-Vigil about).Text.Contains("Releases    $mirrorUrl"))
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil self update --check
    Test-Equal 'release_url: --check names the copy''s latest' 'True' ([string]$r.Text.Contains('0.0.2-it is available'))
    $r = Invoke-Vigil self update
    Test-Equal 'release_url: update succeeds' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'release_url: the new version is installed' '0.0.2-it' (Get-Version)
    Test-Equal 'release_url: nothing was asked of GitHub' '0' (& $fromCopy)
    [System.IO.File]::WriteAllText("$m\releases\latest\VERSION", "0.0.1-it`n")
    $r = Invoke-Vigil self update
    Test-Equal 'release_url: an older latest is not taken' '0' ([string]$r.Code)
    Test-Equal 'release_url: saying why' 'True' ([string]$r.Text.Contains('newer than the latest release from'))
    Test-Equal 'release_url: and nothing changed' '0.0.2-it' (Get-Version)
    # SHA256SUMS changed on the copy, to match a changed archive.
    $md1 = "$m\releases\download\v0.0.1-it"
    [System.IO.File]::AppendAllText("$md1\vigil-0.0.1-it.zip", 'x')
    Write-Sums $md1 @('vigil-0.0.1-it.zip', 'install.ps1')
    $r = Invoke-Vigil self update --version 0.0.1-it
    Test-Equal 'release_url: a changed release is refused' '1' ([string]$r.Code)
    Test-Equal 'release_url: saying why' 'True' ([string]$r.Text.Contains('not signed by the Vigil release key'))
    Test-Equal 'release_url: and nothing changed' '0.0.2-it' (Get-Version)
    Remove-Item -LiteralPath "$m\releases\latest\VERSION"
    $r = Invoke-Vigil self update
    Test-Equal 'release_url: unreachable, refused' '1' ([string]$r.Code)
    Test-Equal 'release_url: naming it' 'True' ([string]$r.Text.Contains("cannot reach $mirrorUrl to find the latest release"))
    [System.IO.File]::WriteAllText("$m\releases\latest\VERSION", "0.0.2-it`n")
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil pack update --check
    Test-Equal 'release_url: pack update finds the packs there' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'release_url: pack update asked nothing of GitHub' '0' (& $fromCopy)
    [System.IO.File]::WriteAllText($requests, '')
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = "$work\cache-copy"
    [void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA)
    [void](Invoke-Vigil self refresh-check)
    $cache = "$work\cache-copy\vigil-update-check"
    $env:LOCALAPPDATA = $savedLocal
    $seen = if (Test-Path -LiteralPath $cache) { @([System.IO.File]::ReadAllText($cache).Trim().Split(' '))[1] } else { '' }
    Test-Equal 'release_url: the notice''s check asks the copy' '0.0.2-it' ([string]$seen)
    Test-Equal 'release_url: and nothing of GitHub' '0' (& $fromCopy)
    [System.IO.File]::WriteAllText($cfgFile, $saved)
    Set-Latest '0.0.2-it'
    [void](Invoke-Vigil self update --version 0.0.1-it)
    Test-Equal 'release_url: back as it was' '0.0.1-it' (Get-Version)

    # A release_path: the releases from a folder or a share (18.7). The same
    # layout, copied rather than downloaded: the mock's log shows nothing was
    # asked of it at all.
    $s = Join-Path $work 'share'
    [void](New-Item -ItemType Directory -Force -Path "$s\releases\download", "$s\releases\latest")
    Copy-Item -LiteralPath $d1, (Join-Path $www 'releases\download\v0.0.2-it') -Destination "$s\releases\download" -Recurse
    [System.IO.File]::WriteAllText("$s\releases\latest\VERSION", "0.0.2-it`n")
    Remove-Item -LiteralPath "$work\mock\redirects" -Force
    $withPath = { param($p) [System.IO.File]::WriteAllText($cfgFile, ($saved -replace '(?m)^\[vigil\]\r?$', "[vigil]`n$p")) }
    & $withPath "release_path = $s"
    $asked = { [string]@([System.IO.File]::ReadAllLines($requests) | Where-Object { $_ -match '"path"' }).Count }
    Test-Equal 'release_path: about names it' 'True' ([string](Invoke-Vigil about).Text.Contains("Releases    $s"))
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil self update --check
    Test-Equal 'release_path: --check names the folder''s latest' 'True' ([string]$r.Text.Contains('0.0.2-it is available'))
    $r = Invoke-Vigil self update
    Test-Equal 'release_path: update succeeds' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'release_path: the new version is installed' '0.0.2-it' (Get-Version)
    Test-Equal 'release_path: nothing was downloaded' '0' (& $asked)
    [System.IO.File]::WriteAllText("$s\releases\latest\VERSION", "0.0.1-it`n")
    $r = Invoke-Vigil self update
    Test-Equal 'release_path: an older latest is not taken' '0' ([string]$r.Code)
    Test-Equal 'release_path: saying why' 'True' ([string]$r.Text.Contains("newer than the latest release from $s"))
    Test-Equal 'release_path: and nothing changed' '0.0.2-it' (Get-Version)
    # SHA256SUMS changed on the share, to match a changed archive.
    $sd1 = "$s\releases\download\v0.0.1-it"
    [System.IO.File]::AppendAllText("$sd1\vigil-0.0.1-it.zip", 'x')
    Write-Sums $sd1 @('vigil-0.0.1-it.zip', 'install.ps1')
    $r = Invoke-Vigil self update --version 0.0.1-it
    Test-Equal 'release_path: a changed release is refused' '1' ([string]$r.Code)
    Test-Equal 'release_path: saying why' 'True' ([string]$r.Text.Contains('not signed by the Vigil release key'))
    Test-Equal 'release_path: and nothing changed' '0.0.2-it' (Get-Version)
    Rename-Item -LiteralPath $s -NewName 'share.away'
    $r = Invoke-Vigil self update
    Test-Equal 'release_path: missing, refused' '1' ([string]$r.Code)
    Test-Equal 'release_path: naming it and the account' 'True' ([string]$r.Text.Contains("cannot read the latest release from $s (as $([Environment]::UserDomainName)\$([Environment]::UserName))"))
    Rename-Item -LiteralPath "$work\share.away" -NewName 'share'
    [System.IO.File]::WriteAllText("$s\releases\latest\VERSION", "0.0.2-it`n")
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil pack update --check
    Test-Equal 'release_path: pack update finds the packs there' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    $env:LOCALAPPDATA = "$work\cache-path"
    [void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA)
    [void](Invoke-Vigil self refresh-check)
    $cache = "$work\cache-path\vigil-update-check"
    $env:LOCALAPPDATA = $savedLocal
    $seen = if (Test-Path -LiteralPath $cache) { @([System.IO.File]::ReadAllText($cache).Trim().Split(' '))[1] } else { '' }
    Test-Equal 'release_path: the notice''s check reads the folder' '0.0.2-it' ([string]$seen)
    Test-Equal 'release_path: and nothing was downloaded' '0' (& $asked)
    # The same folder by UNC path, through the drive's administrative share:
    # only where this account may open it (an administrator, as on CI).
    $unc = "\\localhost\$($s.Substring(0, 1))`$$($s.Substring(2))"
    if (Test-Path -LiteralPath "$unc\releases\latest\VERSION") {
        & $withPath "release_path = $unc"
        $r = Invoke-Vigil self update --check
        Test-Equal 'release_path by UNC: --check reads the share' 'True' ([string]$r.Text.Contains('0.0.2-it is installed: nothing to do'))
        Copy-Item -Path "$d1\*" -Destination $sd1 -Force
        $r = Invoke-Vigil self update --version 0.0.1-it
        Test-Equal 'release_path by UNC: an update from the share' '0' ([string]$r.Code)
        if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    }
    else { Write-Host "  SKIP  release_path by UNC: $unc cannot be opened by this account" }
    & $withPath "release_path = $s`nrelease_url = https://artifacts.example.com/vigil"
    $r = Invoke-Vigil self update
    Test-Equal 'release_path and release_url: refused' '1' ([string]$r.Code)
    Test-Equal 'release_path and release_url: saying why' 'True' ([string]$r.Text.Contains("sets both 'release_url' and 'release_path'"))
    & $withPath 'release_path = releases'
    $r = Invoke-Vigil self update
    Test-Equal 'release_path relative: refused' '1' ([string]$r.Code)
    Test-Equal 'release_path relative: saying why' 'True' ([string]$r.Text.Contains("'release_path' must be an absolute path"))
    [System.IO.File]::WriteAllText($cfgFile, $saved)
    Set-Latest '0.0.2-it'
    [void](Invoke-Vigil self update --version 0.0.1-it)
    Test-Equal 'release_path: back as it was' '0.0.1-it' (Get-Version)

    # A release_url that needs a login (18.7): the copy above, now answering
    # 401 to any request without the header. The header's value is in
    # Vigil's secret store.
    [System.IO.File]::WriteAllText("$m\releases\latest\VERSION", "0.0.2-it`n")
    Copy-Item -Path "$d1\*" -Destination $md1 -Force
    [System.IO.File]::WriteAllText("$work\mock\require", "/mirror/ X-Vigil-It: Bearer it-token-1`n")
    Remove-Item -LiteralPath "$work\mock\redirects" -Force -ErrorAction SilentlyContinue
    $setSecret = { param($v) $v | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root secret set RELEASES_AUTH --stdin 2>&1 | Out-Null; return $LASTEXITCODE }
    Test-Equal 'login: the secret is stored' '0' ([string](& $setSecret 'Bearer it-token-1'))
    $login = { param($n, $v)
        $l = "[vigil]`nrelease_url = $mirrorUrl"
        if ($n) { $l += "`nrelease_header_name = $n" }
        if ($v) { $l += "`nrelease_header_value = $v" }
        [System.IO.File]::WriteAllText($cfgFile, ($saved -replace '(?m)^\[vigil\]\r?$', $l))
    }
    & $login '' ''
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: none given, refused' '1' ([string]$r.Code)
    Test-Equal 'login: saying the copy asks for one' 'True' ([string]$r.Text.Contains("$mirrorUrl asks for a login (HTTP 401): set release_header_name and release_header_value"))
    & $login 'X-Vigil-It' 'secret:RELEASES_AUTH'
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: --check names the copy''s latest' 'True' ([string]$r.Text.Contains('0.0.2-it is available'))
    if (-not $r.Text.Contains('0.0.2-it is available')) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'login: the header was sent' 'True' ([string]([System.IO.File]::ReadAllText($requests).Contains('"X-Vigil-It": "Bearer it-token-1"')))
    $r = Invoke-Vigil self update
    Test-Equal 'login: update succeeds' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'login: the new version is installed' '0.0.2-it' (Get-Version)
    Test-Equal 'login: nothing was asked of GitHub' '0' (& $fromCopy)
    Test-Equal 'login: the value is not in the output' 'False' ([string]$r.Text.Contains('it-token-1'))
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil pack update --check
    Test-Equal 'login: pack update finds the packs there' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'login: pack update asked nothing of GitHub' '0' (& $fromCopy)
    $env:LOCALAPPDATA = "$work\cache-login"
    [void](New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA)
    [void](Invoke-Vigil self refresh-check)
    $cache = "$work\cache-login\vigil-update-check"
    $env:LOCALAPPDATA = $savedLocal
    $seen = if (Test-Path -LiteralPath $cache) { @([System.IO.File]::ReadAllText($cache).Trim().Split(' '))[1] } else { '' }
    Test-Equal 'login: the notice''s check uses it' '0.0.2-it' ([string]$seen)
    [void](& $setSecret 'Bearer it-wrong-1')
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: a wrong one, refused' '1' ([string]$r.Code)
    Test-Equal 'login: saying the login was refused' 'True' ([string]$r.Text.Contains("$mirrorUrl refused the login (HTTP 401): check release_header_value"))
    Test-Equal 'login: not saying what was sent' 'False' ([string]$r.Text.Contains('it-wrong-1'))
    [void](& $setSecret 'Bearer it-token-1')
    & $login 'X-Vigil-It' 'env:VIGIL_IT_NOT_SET'
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: a secret not there, refused' '1' ([string]$r.Code)
    Test-Equal 'login: naming it' 'True' ([string]$r.Text.Contains('release_header_value env:VIGIL_IT_NOT_SET unavailable: not set in the environment'))
    # A redirect elsewhere is not followed, so the header goes nowhere else.
    & $login 'X-Vigil-It' 'secret:RELEASES_AUTH'
    [void](New-Item -ItemType Directory -Force -Path "$www\elsewhere")
    [System.IO.File]::WriteAllText("$www\elsewhere\VERSION", "0.0.2-it`n")
    [System.IO.File]::WriteAllText("$work\mock\redirects", "/mirror/releases/latest/VERSION /elsewhere/VERSION`n")
    [System.IO.File]::WriteAllText($requests, '')
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: a redirect, refused' '1' ([string]$r.Code)
    Test-Equal 'login: saying why' 'True' ([string]$r.Text.Contains('redirected the request (HTTP 302): Vigil follows no redirect while release_header_name is set'))
    if (-not $r.Text.Contains('redirected the request')) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'login: the redirect was not followed' 'False' ([string]([System.IO.File]::ReadAllText($requests).Contains('/elsewhere/')))
    Remove-Item -LiteralPath "$work\mock\redirects" -Force
    [System.IO.File]::WriteAllText($cfgFile, ($saved -replace '(?m)^\[vigil\]\r?$', "[vigil]`nrelease_header_name = X-Vigil-It`nrelease_header_value = secret:RELEASES_AUTH"))
    $r = Invoke-Vigil self update --check
    Test-Equal 'login without release_url: refused' '1' ([string]$r.Code)
    Test-Equal 'login without release_url: saying why' 'True' ([string]$r.Text.Contains("sets 'release_header_name' without 'release_url'"))
    & $login 'X-Vigil-It' ''
    $r = Invoke-Vigil self update --check
    Test-Equal 'login: half of it, refused' '1' ([string]$r.Code)
    Test-Equal 'login: half of it, saying why' 'True' ([string]$r.Text.Contains("needs both 'release_header_name' and 'release_header_value'"))
    Remove-Item -LiteralPath "$work\mock\require" -Force
    [System.IO.File]::WriteAllText($cfgFile, $saved)
    Set-Latest '0.0.2-it'
    [void](Invoke-Vigil self update --version 0.0.1-it)
    Test-Equal 'login: back as it was' '0.0.1-it' (Get-Version)

    # What does not verify changes nothing.
    $d = Join-Path $www 'releases\download\v0.0.2-it'
    Copy-Item "$d\install.ps1" "$work\install.good"
    [System.IO.File]::AppendAllText("$d\install.ps1", "`n# tampered`n")
    $r = Invoke-Vigil self update
    Test-Equal 'a tampered installer is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('does not match its SHA256SUMS'))
    Test-Equal 'and nothing changed' '0.0.1-it' (Get-Version)
    Copy-Item "$work\install.good" "$d\install.ps1" -Force

    Copy-Item "$d\vigil-0.0.2-it.zip" "$work\good.zip"
    [System.IO.File]::AppendAllText("$d\vigil-0.0.2-it.zip", 'x')
    $r = Invoke-Vigil self update
    Test-Equal 'a tampered archive is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('SHA-256 mismatch'))
    Test-Equal 'and nothing changed' '0.0.1-it' (Get-Version)
    Copy-Item "$work\good.zip" "$d\vigil-0.0.2-it.zip" -Force

    $bd = ConvertTo-BashPath $d
    Copy-Item "$d\SHA256SUMS.sig" "$work\good.sig"
    Invoke-Openssl "dgst -sha256 -sign '$kw/other.key' -out '$bd/SHA256SUMS.sig' '$bd/SHA256SUMS'"
    $r = Invoke-Vigil self update
    Test-Equal 'a release signed by another key is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('not signed by the Vigil release key'))
    Test-Equal 'and nothing changed' '0.0.1-it' (Get-Version)
    Remove-Item -LiteralPath "$d\SHA256SUMS.sig"
    $r = Invoke-Vigil self update
    Test-Equal 'an unsigned release is refused' '1' ([string]$r.Code)
    Test-Equal 'and nothing changed' '0.0.1-it' (Get-Version)
    Copy-Item "$work\good.sig" "$d\SHA256SUMS.sig"
    $savedKey = $env:VIGIL_TEST_RELEASE_KEY
    $env:VIGIL_TEST_RELEASE_KEY = "$work\no-such-key.pem"
    $r = Invoke-Vigil self update
    Test-Equal 'with no release key, the update is refused' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]($r.Text -match 'release key .* is missing'))
    Test-Equal 'and nothing changed' '0.0.1-it' (Get-Version)
    $env:VIGIL_TEST_RELEASE_KEY = $savedKey

    # A release that does not run: back to the one that does.
    $b = Join-Path $work 'broken'
    Expand-Archive -LiteralPath "$d\vigil-0.0.2-it.zip" -DestinationPath $b
    Rename-Item -LiteralPath "$b\vigil-0.0.2-it" -NewName 'vigil-0.0.3-it'
    [System.IO.File]::WriteAllText("$b\vigil-0.0.3-it\app\VERSION", "0.0.3-it`n")
    [System.IO.File]::WriteAllText("$b\vigil-0.0.3-it\app\vigil.ps1", "exit 1`n")
    $d3 = Join-Path $www 'releases\download\v0.0.3-it'
    [void](New-Item -ItemType Directory -Force -Path $d3)
    Compress-Archive -Path "$b\vigil-0.0.3-it" -DestinationPath "$d3\vigil-0.0.3-it.zip"
    Copy-Item "$repo\install.ps1" $d3
    Write-Sums $d3 @('vigil-0.0.3-it.zip', 'install.ps1')
    $bd3 = ConvertTo-BashPath $d3
    Invoke-Openssl "dgst -sha256 -sign '$kw/release.key' -out '$bd3/SHA256SUMS.sig' '$bd3/SHA256SUMS'"
    [System.IO.File]::WriteAllText("$www\releases\tag\v0.0.3-it", '')
    Set-Latest '0.0.3-it'
    $r = Invoke-Vigil self update
    Test-Equal 'a release that does not run fails' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('went back to the version that was installed'))
    Test-Equal 'the old version is back' '0.0.1-it' (Get-Version)
    Test-Equal 'and works' 'Vigil 0.0.1-it' (Invoke-Vigil version).Text
    Test-Equal 'no app.old is left' 'False' ([string](Test-Path -LiteralPath "$root\app.old"))
    Test-Equal 'the vendor.old moved aside goes once free' '0' ([string]@(Get-ChildItem -LiteralPath $root -Directory -Filter 'vendor.old.*').Count)

    # Runs waiting for a slot survive a restart.
    Set-Content -LiteralPath "$root\scripts\waited.cmd" -Value @('@echo off', 'echo waited')
    [System.IO.File]::AppendAllText("$root\config\vigil.config", "`n[job.waited]`nfile = scripts\waited.cmd`nrun_every = 3650d`n")
    [System.IO.File]::WriteAllText("$root\state\pending", "pending= waited gone`nqueued=`n")
    [void](Invoke-Vigil supervise --once)
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$root\state\jobs\waited.state"); $i++) { Start-Sleep -Milliseconds 200 }
    Test-Equal 'a waiting run is picked up' 'True' ([string](Test-Path -LiteralPath "$root\state\jobs\waited.state"))
    Test-Equal 'and the list is cleared' 'False' ([string](Test-Path -LiteralPath "$root\state\pending"))

    # Update notices.
    Set-Latest '0.0.2-it'
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $work
    $r = Invoke-Vigil version
    Test-Equal 'notice: asks in the background' 'True' ([string]$r.Text.StartsWith('Vigil 0.0.1-it'))
    for ($i = 0; $i -lt 150 -and -not (Test-Path -LiteralPath "$work\vigil-update-check"); $i++) { Start-Sleep -Milliseconds 200 }
    Test-Equal 'notice: names the new version' 'True' ([string](Invoke-Vigil version).Text.Contains('Vigil 0.0.2-it is available'))
    $env:VIGIL_NO_UPDATE_CHECK = '1'
    Test-Equal 'notice: can be turned off' 'False' ([string](Invoke-Vigil version).Text.Contains('is available'))
    Remove-Item Env:\VIGIL_NO_UPDATE_CHECK
    $env:LOCALAPPDATA = $saved

    # Hot reload: a supervisor that is running, whoever started it. An
    # earlier supervisor's version is still on disk: without removing it, the
    # wait below can end before this one has started, and the update land
    # before it reads its version, leaving nothing to reload.
    Remove-Item -LiteralPath "$root\state\supervisor.version" -Force -ErrorAction SilentlyContinue
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    for ($i = 0; $i -lt 150 -and (Invoke-Vigil version --supervisor).Text -cne '0.0.1-it'; $i++) { Start-Sleep -Milliseconds 200 }
    Test-Equal 'reload: the supervisor is running' '0.0.1-it' (Invoke-Vigil version --supervisor).Text
    $r = Invoke-Vigil self update --version 0.0.2-it
    Test-Equal 'reload: updated' '0' ([string]$r.Code)
    Test-Equal 'self update leaves the packs alone' 'True' ([string](Test-Path -LiteralPath "$root\packs\base\untouched"))
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    for ($i = 0; $i -lt 150 -and (Invoke-Vigil version --supervisor).Text -cne '0.0.2-it'; $i++) { Start-Sleep -Milliseconds 200 }
    Test-Equal 'reload: it came up as the new version' '0.0.2-it' (Invoke-Vigil version --supervisor).Text
    Test-Equal 'reload: the same process' 'False' ([string]$sup.HasExited)
    $st = Get-Content -LiteralPath "$root\state\supervisor.lock" -ErrorAction SilentlyContinue
    if (-not $sup.HasExited) { Stop-Process -Id $sup.Id -Force }
    Start-Sleep -Seconds 1

    # A running system service, only on CI: it registers a real service and
    # changes the machine's PATH.
    $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $env:CI -or -not $admin) { Write-Host 'SKIP system mode: only on CI, as administrator' }
    else {
        Set-Latest '0.0.2-it'
        $root = Join-Path $work 'sys'
        $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$d1\install.ps1" -System -Prefix $root -Version '0.0.1-it' -Instance it-sys 2>&1
        $rc = $LASTEXITCODE
        Test-Equal 'system: installed' '0' ([string]$rc)
        if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" } }
        Test-Equal 'system: the service is active' 'True' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))
        for ($i = 0; $i -lt 50 -and (Invoke-Vigil version --supervisor).Text -cne '0.0.1-it'; $i++) { Start-Sleep -Milliseconds 200 }
        $pid1 = (Get-VigilLockPid)
        $r = Invoke-Vigil self update
        Test-Equal 'system: updated' '0' ([string]$r.Code)
        if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
        Test-Equal 'system: the new version' '0.0.2-it' (Get-Version)
        Test-Equal 'system: the service is active after' 'True' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))
        Test-Equal 'system: not restarted: the same process' $pid1 (Get-VigilLockPid)
        Set-Latest '0.0.3-it'
        $r = Invoke-Vigil self update
        Test-Equal 'system: a release that does not run fails' '1' ([string]$r.Code)
        Test-Equal 'system: the old version is back' '0.0.2-it' (Get-Version)
        Test-Equal 'system: and its service is active' 'True' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))
        $r = Invoke-Vigil uninstall --yes
        Test-Equal 'system: uninstall succeeds' '0' ([string]$r.Code)

        # install -UpdateBy: a real ordinary account.
        $it = 'vigil-it'
        $bytes = New-Object byte[] 24
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secret = 'Aa1!' + [Convert]::ToBase64String($bytes)
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME"
        $account = $computer.Create('User', $it)
        $account.SetPassword($secret)
        $account.SetInfo()
        # Outside the runner's profile, which an ordinary account cannot enter.
        $byDir = Join-Path $env:SystemDrive "vigil-it.$PID"
        # Runs vigil as that account, or tries what -Probe lists; @{ Code; Text }.
        function Invoke-AsUser {
            param([string[]]$Argv, [string[]]$Probe)
            $f = "$byDir\user"
            Remove-Item -LiteralPath "$f.out", "$f.code" -ErrorAction SilentlyContinue
            $line = ($Argv | ForEach-Object { "'$_'" }) -join ', '
            $run = if ($Probe) { $Probe } else {
                @("`$a = @($line)",
                    "`$o = & '$shell' -NoProfile -ExecutionPolicy Bypass -File '$root\app\vigil.ps1' -Root '$root' @a 2>&1",
                    "`$c = `$LASTEXITCODE")
            }
            Set-Content -LiteralPath "$f.ps1" -Value (@(
                    "`$env:VIGIL_TEST_RELEASE_URL = '$env:VIGIL_TEST_RELEASE_URL'",
                    "`$env:VIGIL_TEST_RELEASE_KEY = '$env:VIGIL_TEST_RELEASE_KEY'",
                    '$env:VIGIL_NO_UPDATE_CHECK = ''1''') + $run + @(
                    "[System.IO.File]::WriteAllText('$f.out', ((`$o | ForEach-Object { `"`$_`" }) -join `"``n`"))",
                    "[System.IO.File]::WriteAllText('$f.code', `"`$c`")"))
            $p = Start-Process -FilePath $shell -PassThru -Credential $credential -LoadUserProfile -WorkingDirectory $byDir -RedirectStandardError "$f.err" `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$f.ps1`"")
            [void]$p.WaitForExit(240000)
            if (-not (Test-Path -LiteralPath "$f.code")) {
                Write-Host "        the test account's process ended with $($p.ExitCode)"
                Get-Content -LiteralPath "$f.err" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "        $_" }
            }
            $text = if (Test-Path -LiteralPath "$f.out") { [System.IO.File]::ReadAllText("$f.out") } else { '' }
            $code = if (Test-Path -LiteralPath "$f.code") { [System.IO.File]::ReadAllText("$f.code").Trim() } else { 'none' }
            return @{ Code = $code; Text = $text }
        }
        try {
            Set-Latest '0.0.1-it'
            $root = Join-Path $work 'by'
            $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$d1\install.ps1" -System -Prefix $root -Version '0.0.1-it' -Instance it-by -UpdateBy $it 2>&1
            $rc = $LASTEXITCODE
            Test-Equal 'update-by: installed' '0' ([string]$rc)
            if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" } }
            $bad = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$d1\install.ps1" -System -Prefix "$work\no" -Version '0.0.1-it' -UpdateBy 'vigil-nobody' 2>&1
            Test-Equal 'update-by: an unknown account is refused first' 'True' ([string](("$bad".Contains('vigil-nobody')) -and -not (Test-Path -LiteralPath "$work\no")))

            # The test account reads its script here, and writes its results.
            [void](New-Item -ItemType Directory -Force -Path $byDir)
            $acl = Get-Acl -LiteralPath $byDir
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($it, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
            Set-Acl -LiteralPath $byDir -AclObject $acl
            $credential = New-Object System.Management.Automation.PSCredential($it, (ConvertTo-SecureString $secret -AsPlainText -Force))

            # A task's environment comes from the machine, not from the caller.
            [Environment]::SetEnvironmentVariable('VIGIL_TEST_RELEASE_URL', $env:VIGIL_TEST_RELEASE_URL, 'Machine')
            [Environment]::SetEnvironmentVariable('VIGIL_TEST_RELEASE_KEY', $env:VIGIL_TEST_RELEASE_KEY, 'Machine')

            $w = Invoke-AsUser @('version')
            Test-Equal 'update-by: the account can run vigil' 'Vigil 0.0.1-it' $w.Text
            Test-Equal 'update-by: not as an administrator' 'True' ([string]((Invoke-AsUser @('service', 'stop')).Code -cmatch '^[1-9]'))
            Test-Equal 'update-by: the service still runs' 'True' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))

            Set-Latest '0.0.2-it'
            $pid2 = Get-VigilLockPid
            $r = Invoke-AsUser @('self', 'update')
            Test-Equal 'update-by: updated, not as an administrator' '0' $r.Code
            if ($r.Code -ne '0') { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
            Test-Equal 'update-by: it shows the update' 'True' ([string]$r.Text.Contains('upgraded'))
            Test-Equal 'update-by: the release is installed' '0.0.2-it' (Get-Version)
            Test-Equal 'update-by: the service is active' 'True' ([string](Invoke-Vigil status).Text.StartsWith('service: active'))
            Test-Equal 'update-by: not restarted' $pid2 (Get-VigilLockPid)

            $r = Invoke-AsUser @('self', 'update', '--version', '0.0.1-it')
            Test-Equal 'update-by: no version of your own choosing' '1' $r.Code
            Test-Equal 'update-by: the version stays' '0.0.2-it' (Get-Version)

            # Each thing the account might use to change what SYSTEM runs.
            $targets = @("$root\app\vigil.ps1", "$root\app\planted.ps1", "$root\app\migrations\99.ps1", "$root\app\lib\windows\planted.ps1", "$root\update\planted", "$root\update\output", "$root\planted", "$root\scripts\planted", "$root\vendor\planted")
            $probe = @('$o = @()', ('foreach ($p in ''' + ($targets -join ''', ''') + ''') {'),
                '    try { [System.IO.File]::AppendAllText($p, ''x''); $o += "wrote $p" } catch { }',
                '}',
                ('try { [void][System.IO.File]::ReadAllBytes(''' + "$root\config\vigil.config" + '''); $o += ''read config'' } catch { }'),
                '$null = & schtasks.exe /Change /TN ''Vigil Update'' /TR cmd.exe 2>&1',
                'if ($LASTEXITCODE -eq 0) { $o += ''changed the task'' }',
                '$c = 0')
            $r = Invoke-AsUser -Probe $probe
            Test-Equal 'update-by: the probe ran' '0' $r.Code
            Test-Equal 'update-by: nothing SYSTEM runs can be changed, config\ stays closed' '' $r.Text
            $sd = (New-Object -ComObject Schedule.Service)
            $sd.Connect()
            $sddl = $sd.GetFolder('\').GetTask('Vigil Update').GetSecurityDescriptor(4)
            Test-Equal 'update-by: the task may only be read and run' 'True' ([string]($sddl -cmatch '\(A;;(FRFX|0x1200a9);;;S-1-5-21-'))
            $rights = @((Get-Acl -LiteralPath "$root\app").Access | Where-Object { $_.IdentityReference.Value -like "*\$it" } | ForEach-Object { [string]$_.FileSystemRights })
            Test-Equal 'update-by: read access follows the new app\' 'ReadAndExecute, Synchronize' ($rights -join ',')
            $config = @((Get-Acl -LiteralPath "$root\config").Access | Where-Object { $_.IdentityReference.Value -like "*\$it" }).Count
            Test-Equal 'update-by: config\ stays closed' '0' ([string]$config)

            Set-Latest '0.0.3-it'
            $r = Invoke-AsUser @('self', 'update')
            Test-Equal 'update-by: a release that does not run fails' '1' $r.Code
            Test-Equal 'update-by: the old version is back' '0.0.2-it' (Get-Version)
            Set-Latest '0.0.2-it'

            $r = Invoke-Vigil uninstall --yes
            Test-Equal 'update-by: uninstall succeeds' '0' ([string]$r.Code)
            $left = $null
            try { $s2 = New-Object -ComObject Schedule.Service; $s2.Connect(); $left = $s2.GetFolder('\').GetTask('Vigil Update') } catch { }
            Test-Equal 'update-by: uninstall removes the task' 'True' ([string]($null -eq $left))
        }
        finally {
            [Environment]::SetEnvironmentVariable('VIGIL_TEST_RELEASE_URL', [NullString]::Value, 'Machine')
            [Environment]::SetEnvironmentVariable('VIGIL_TEST_RELEASE_KEY', [NullString]::Value, 'Machine')
            $computer.Delete('User', $it)
            Remove-Item -LiteralPath $byDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\VIGIL_TEST_RELEASE_KEY -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
