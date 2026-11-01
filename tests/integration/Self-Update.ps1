#Requires -Version 5.1

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
    & $bash (ConvertTo-BashPath "$repo\tools\release\package.sh") $Version (ConvertTo-BashPath $d) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
    [System.IO.File]::WriteAllText("$www\releases\tag\v$Version", '')
    Set-Latest $Version
}
function Set-Latest {
    param([string]$Version)
    [System.IO.File]::WriteAllText("$work\mock\redirects", "/releases/latest /releases/tag/v$Version`n")
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

    # A version on request, older included.
    [void](Invoke-Vigil self update --version 0.0.1-it)
    Test-Equal '--version goes back' '0.0.1-it' (Get-Version)
    $r = Invoke-Vigil self update --version 9.9.9
    Test-Equal 'no such release: fails' '1' ([string]$r.Code)
    Test-Equal 'no such release: says so' 'True' ([string]$r.Text.Contains('cannot download'))
    Test-Equal 'no such release: nothing changed' '0.0.1-it' (Get-Version)

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
    [System.IO.File]::WriteAllText("$www\releases\tag\v0.0.3-it", '')
    Set-Latest '0.0.3-it'
    $r = Invoke-Vigil self update
    Test-Equal 'a release that does not run fails' '1' ([string]$r.Code)
    Test-Equal 'saying why' 'True' ([string]$r.Text.Contains('went back to the version that was installed'))
    Test-Equal 'the old version is back' '0.0.1-it' (Get-Version)
    Test-Equal 'and works' 'Vigil 0.0.1-it' (Invoke-Vigil version).Text
    Test-Equal 'no app.old is left' 'False' ([string](Test-Path -LiteralPath "$root\app.old"))

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

    # Hot reload: a supervisor that is running, whoever started it.
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    for ($i = 0; $i -lt 150 -and (Invoke-Vigil version --supervisor).Text -cne '0.0.1-it'; $i++) { Start-Sleep -Milliseconds 200 }
    Test-Equal 'reload: the supervisor is running' '0.0.1-it' (Invoke-Vigil version --supervisor).Text
    $r = Invoke-Vigil self update --version 0.0.2-it
    Test-Equal 'reload: updated' '0' ([string]$r.Code)
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
    }
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
