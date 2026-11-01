#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: upgrading from the latest published release to this
    build (SPECIFICATION.md 18.7) on Windows.
.DESCRIPTION
    The real installer installs the real release from GitHub, a real
    supervisor runs real jobs on it, and that release's own vigil self
    update moves it to this build, served by mock-files.py. The supervisor
    must carry on as the same process, with its jobs, state and metrics
    intact. The twin of upgrade.sh. The user PATH is put back afterwards.

    Needs Python, and bash for package.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil upgrade.$PID"
$next = '99.0.0-it'
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
[void](New-Item -ItemType Directory -Force -Path "$work\mock\www\releases\tag")
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = Join-Path $work 'root'
$mock = $null
$sup = $null
$long = $null
$savedPath = [Environment]::GetEnvironmentVariable('Path', 'User')

try {
    # The published release, through the real installer.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/godspeedhq/vigil/releases/latest/download/install.ps1' -OutFile "$work\install.ps1"
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File "$work\install.ps1" -User -Prefix $root -Instance upgrade -Backend file -NoService 2>&1
    $rc = $LASTEXITCODE
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Test-Equal 'the published release installs' '0' ([string]$rc)
    if ($rc -ne 0) { $out | ForEach-Object { Write-Host "        $_" }; throw 'install failed' }
    Write-Host "upgrading from $(Get-Version)"

    # Jobs that outlive the update: one always due, one running across it.
    Set-Content -LiteralPath "$root\scripts\beat.cmd" -Value @('@echo off', 'echo metric beats 1')
    Set-Content -LiteralPath "$root\scripts\long.cmd" -Value @('@echo off', 'ping -n 16 127.0.0.1 > nul', 'echo metric long 1')
    $cfg = Join-Path $root 'config\vigil.config'
    $text = ([System.IO.File]::ReadAllText($cfg)) -replace '(?m)^tick *= *.*$', 'tick = 1s'
    if ($text -cnotmatch '(?m)^tick') { $text += "`n[scheduler]`ntick = 1s`n" }
    $text += "`n[job.beat]`nfile      = scripts\beat.cmd`nrun_every = 2s`n`n[job.long]`nfile      = scripts\long.cmd`nrun_every = 3650d`n"
    [System.IO.File]::WriteAllText($cfg, $text)
    $sum = (Get-FileHash -LiteralPath $cfg).Hash

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"")
    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList ($argv + 'supervise')
    for ($i = 0; $i -lt 180 -and (Get-Runs 'beat') -lt 2; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'jobs run on the published release' 'True' ([string]((Get-Runs 'beat') -ge 2))
    $long = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList ($argv + @('run', 'long'))
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath "$root\state\jobs\long.state"); $i++) { Start-Sleep -Milliseconds 200 }
    $before = Get-Runs 'beat'

    # This build, as a release on the mock.
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-files.py`"", "`"$work\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$work\mock\stderr"
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath "$work\mock\port"); $i++) { Start-Sleep -Milliseconds 100 }
    $d = "$work\mock\www\releases\download\v$next"
    [void](New-Item -ItemType Directory -Force -Path $d)
    & $bash ($repo.Replace('\', '/') + '/tools/release/package.sh') $next $d.Replace('\', '/') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'packaging failed' }
    [System.IO.File]::WriteAllText("$work\mock\www\releases\tag\v$next", '')
    [System.IO.File]::WriteAllText("$work\mock\redirects", "/releases/latest /releases/tag/v$next`n")
    $env:VIGIL_TEST_RELEASE_URL = "http://127.0.0.1:$([System.IO.File]::ReadAllText("$work\mock\port").Trim())"

    # The published release updates itself.
    $r = Invoke-Vigil self update
    Test-Equal 'it updates itself' '0' ([string]$r.Code)
    if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    Test-Equal 'to this build' $next (Get-Version)
    for ($i = 0; $i -lt 60 -and (Invoke-Vigil version --supervisor).Text -cne $next; $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'the supervisor came up as this build' $next (Invoke-Vigil version --supervisor).Text
    Test-Equal 'the same process' 'False' ([string]$sup.HasExited)
    Test-Equal 'the configuration is untouched' $sum (Get-FileHash -LiteralPath $cfg).Hash

    # Everything picks up where it left off.
    [void]$long.WaitForExit(90000)
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
    if ($script:fail -gt 0) { Write-Host ($sv.Split("`n") | Select-Object -Last 20) }
}
finally {
    foreach ($p in @($sup, $mock, $long)) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } } }
    [Environment]::SetEnvironmentVariable('Path', $savedPath, 'User')
    Remove-Item Env:\VIGIL_TEST_RELEASE_URL -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
