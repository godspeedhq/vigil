#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# The Scoop manifest (backlog 30, step 2), for real: installed from a file
# of its own, started with vigil service install --user, updated, removed.
# On a Windows machine that runs no Vigil of its own (the CI runner), with
# Scoop installed if it is not:
#   Scoop.ps1 -Old <manifest> -New <manifest> -OldVersion <v> -NewVersion <v>
# where each manifest is tap-bucket.sh's bucket\vigil.json for one version,
# pointing at archives this machine can download.

param([string]$Old, [string]$New, [string]$OldVersion, [string]$NewVersion)
$ErrorActionPreference = 'Continue'
$env:VIGIL_NO_UPDATE_CHECK = '1'
$Script:Pass = 0
$Script:Fail = 0
$Script:Out = ''

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $Script:Pass++; Write-Host "  PASS  $Name" }
    else {
        $Script:Fail++
        Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]"
        if ($Script:Out) { $Script:Out.Split("`n") | ForEach-Object { Write-Host "        $_" } }
    }
}
function Test-Has { param([string]$Text) return [string]$Script:Out.Contains($Text) }
# Runs a command, its output (every stream) into $Script:Out, its exit code back.
function Invoke-Out {
    param([scriptblock]$Command)
    $global:LASTEXITCODE = 0
    $Script:Out = (& $Command *>&1 | Out-String).Trim()
    return [string]$global:LASTEXITCODE
}
function Get-SupVersion {
    $f = Join-Path $root 'state\supervisor.version'
    if (Test-Path -LiteralPath $f) { return ([System.IO.File]::ReadAllText($f)).Trim() }
    return ''
}
function Wait-For {
    param([int]$Seconds, [scriptblock]$Until)
    for ($i = 0; $i -lt $Seconds * 2 -and -not (& $Until); $i++) { Start-Sleep -Milliseconds 500 }
}
function Show-Diagnosis {
    Write-Host '        --- vigil status'
    (vigil status *>&1 | Out-String).Split("`n") | ForEach-Object { Write-Host "        $_" }
    Write-Host '        --- the supervisor log'
    Get-ChildItem -LiteralPath (Join-Path $root 'logs\supervisor') -Filter '2*.log' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 20 } | ForEach-Object { Write-Host "        $_" }
}

# --- Scoop ----------------------------------------------------------------------------

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    $get = Join-Path ([System.IO.Path]::GetTempPath()) 'get-scoop.ps1'
    Invoke-RestMethod -Uri 'https://get.scoop.sh' -OutFile $get
    & $get -RunAsAdmin *> $null
}
$scoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$root = Join-Path $scoopDir 'persist\vigil'
Write-Host "vigil manifest $OldVersion then $NewVersion, Scoop in $scoopDir, PowerShell $($PSVersionTable.PSVersion)"

# Installed from a manifest file, which Scoop reads again to update: the
# new version's manifest replaces it there.
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-scoop-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$manifest = Join-Path $work 'vigil.json'
Copy-Item -LiteralPath $Old -Destination $manifest

# --- install ----------------------------------------------------------------------

$c = Invoke-Out { scoop install $manifest }
if (-not (Get-Command vigil -ErrorAction SilentlyContinue)) { Write-Host "        scoop install: $($Script:Out)" }
Test-Equal 'install: says what to do next' 'True' (Test-Has 'vigil service install --user')
$cmd = Get-Command vigil -ErrorAction SilentlyContinue
Test-Equal 'the command is on PATH, as a Scoop shim' 'True' ([string]($cmd -and $cmd.Source.StartsWith((Join-Path $scoopDir 'shims'), [System.StringComparison]::OrdinalIgnoreCase)))
Test-Equal 'it runs the version installed' "Vigil $OldVersion" ((vigil version | Out-String).Trim())
$c = Invoke-Out { vigil about }
Test-Equal 'about: the root is the persist folder' 'True' (Test-Has "Installed   $root")
Test-Equal 'about: the program and its package manager' 'True' (Test-Has 'by Scoop')
Test-Equal 'a starting configuration was written' 'True' ([string](Test-Path -LiteralPath (Join-Path $root 'config\vigil.config')))
Test-Equal 'the base pack is in the root' 'True' ([string](Test-Path -LiteralPath (Join-Path $root 'packs\base\cpu.ps1')))
$c = Invoke-Out { vigil run base_cpu }
Test-Equal 'a job runs' '0' $c
$c = Invoke-Out { vigil self update }
Test-Equal 'self update: refused' '1' $c
Test-Equal 'self update: says scoop update vigil' 'True' (Test-Has 'scoop update vigil')

# --- the service: Scoop runs none, so vigil service install --user does ----------------

$c = Invoke-Out { vigil service install --user }
Test-Equal 'service install --user: succeeds' '0' $c
Wait-For 30 { (Get-SupVersion) -ceq $OldVersion }
Test-Equal 'the supervisor runs' $OldVersion (Get-SupVersion)
$run = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Vigil -ErrorAction SilentlyContinue).Vigil
Test-Equal 'the Run entry names current, not this version''s folder' 'True' ([string]$run.Contains('\apps\vigil\current\app\'))
if ($Script:Fail) { Write-Host "        Run entry: $run"; Show-Diagnosis }

# --- update -----------------------------------------------------------------------------

Add-Content -LiteralPath (Join-Path $root 'config\vigil.config') -Value '# a job of our own: kept'
Copy-Item -LiteralPath $New -Destination $manifest -Force
$c = Invoke-Out { scoop update vigil }
if ((vigil version | Out-String).Trim() -cne "Vigil $NewVersion") { Write-Host "        scoop update: $($Script:Out)" }
Test-Equal 'update: the new version' "Vigil $NewVersion" ((vigil version | Out-String).Trim())
Test-Equal 'update: the configuration is kept' 'True' ([string]([System.IO.File]::ReadAllText((Join-Path $root 'config\vigil.config')).Contains('a job of our own')))
Wait-For 60 { (Get-SupVersion) -ceq $NewVersion }
Test-Equal 'update: the supervisor runs the new version' $NewVersion (Get-SupVersion)
if ($Script:Fail) { Show-Diagnosis }

# --- remove -------------------------------------------------------------------------------

$c = Invoke-Out { scoop uninstall vigil }
Test-Equal 'uninstall: the command is gone' 'False' ([string][bool](Get-Command vigil -ErrorAction SilentlyContinue))
Test-Equal 'uninstall: the Run entry is gone' '' ([string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Vigil -ErrorAction SilentlyContinue).Vigil)
$left = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('supervise') -and $_.CommandLine.Contains($root) })
Test-Equal 'uninstall: the supervisor is stopped' '0' ([string]$left.Count)
Test-Equal 'uninstall: the root is kept' 'True' ([string](Test-Path -LiteralPath (Join-Path $root 'config\vigil.config')))
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "$($Script:Pass) passed, $($Script:Fail) failed"
if ($Script:Fail) { exit 1 }
exit 0
