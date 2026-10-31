#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: the installer (SPECIFICATION.md 18.7) on Windows.
.DESCRIPTION
    From release archives built by tools/release/package.sh (through Git
    Bash): a tampered archive changes nothing; a fresh install unpacks, adds
    app\ to the PATH and writes a configuration that passes pre-flight; an
    upgrade replaces app\ and vendor\ and never touches config\ or scripts\;
    uninstall removes it all, PATH entry included. From an elevated prompt
    (as on CI runners) the system-mode install registers and starts the
    service too. The twin of install.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil inst.$PID"
$installer = Join-Path $repo 'install.ps1'
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Script {
    param([string]$Path, [string[]]$Arguments)
    $out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    $script:lastOut = ($out | ForEach-Object { "$_" }) -join "`n"
    return $LASTEXITCODE
}

function Get-Version { param([string]$Root) $f = Join-Path $Root 'app\VERSION'; if (Test-Path -LiteralPath $f) { ([System.IO.File]::ReadAllText($f)).Trim() } }
function Test-OnPath { param([string]$Dir, [string]$Scope) return "$([bool](@("$([Environment]::GetEnvironmentVariable('Path', $Scope))".Split(';') | Where-Object { $_ -ieq $Dir }).Count))" }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path $work)
$bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
foreach ($v in @('0.0.1-it', '0.0.2-it')) {
    & $bash (Join-Path $repo 'tools/release/package.sh') $v (Join-Path $work "r$v") > $null 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host 'packaging failed'; exit 1 }
}
$a1 = Join-Path $work 'r0.0.1-it\vigil-0.0.1-it.zip'
$a2 = Join-Path $work 'r0.0.2-it\vigil-0.0.2-it.zip'

# --- a tampered archive -------------------------------------------------------

$bad = Join-Path $work 'bad'
[void](New-Item -ItemType Directory -Force -Path $bad)
Copy-Item -LiteralPath $a1 -Destination $bad
[System.IO.File]::AppendAllText((Join-Path $bad 'vigil-0.0.1-it.zip'), 'x')
Copy-Item -LiteralPath (Join-Path $work 'r0.0.1-it\SHA256SUMS') -Destination $bad
$badRoot = Join-Path $work 'badroot'
Test-Equal 'a tampered archive is refused' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $badRoot, '-Archive', (Join-Path $bad 'vigil-0.0.1-it.zip'), '-NoService'))"
Test-Equal 'saying why' 'True' "$($script:lastOut -match 'SHA-256 mismatch')"
Test-Equal 'and nothing is installed' 'False' "$(Test-Path -LiteralPath (Join-Path $badRoot 'app'))"

# --- user mode: fresh install, upgrade, uninstall ----------------------------------

$root = Join-Path $work 'root'
$rc = Invoke-Script $installer @('-User', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it', '-Backend', 'file', '-NoService')
Test-Equal 'install succeeds' '0' "$rc"
if ($rc -ne 0) { Write-Host $script:lastOut }
Test-Equal 'the version is recorded' '0.0.1-it' (Get-Version $root)
Test-Equal 'app is on the user PATH' 'True' (Test-OnPath (Join-Path $root 'app') 'User')
Test-Equal 'init wrote the configuration' 'True' "$([System.IO.File]::ReadAllText((Join-Path $root 'config\vigil.config')) -match '(?m)^instance = it$')"
$out = & cmd.exe /d /c "`"$(Join-Path $root 'app\vigil.cmd')`" precheck" 2>&1
Test-Equal 'the installed configuration passes pre-flight, through vigil.cmd' '0' "$LASTEXITCODE"

$cfgPath = Join-Path $root 'config\vigil.config'
[System.IO.File]::AppendAllText($cfgPath, "# my change`n")
[System.IO.File]::WriteAllText((Join-Path $root 'scripts\mine.ps1'), 'Write-Output mine')
$cfg = [System.IO.File]::ReadAllText($cfgPath)
Test-Equal 'upgrade succeeds' '0' "$(Invoke-Script $installer @('-User', '-Prefix', $root, '-Archive', $a2, '-NoService'))"
Test-Equal 'says it upgraded' 'True' "$($script:lastOut -match '(?m)^upgraded ')"
Test-Equal 'app is the new version' '0.0.2-it' (Get-Version $root)
Test-Equal 'the configuration is untouched' 'True' "$($cfg -ceq [System.IO.File]::ReadAllText($cfgPath))"
Test-Equal 'scripts are untouched' 'True' "$(Test-Path -LiteralPath (Join-Path $root 'scripts\mine.ps1'))"
Test-Equal 'no app.old is left' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'app.old'))"

Test-Equal 'uninstall succeeds' '0' "$(Invoke-Script (Join-Path $root 'app\vigil.ps1') @('uninstall', '--yes'))"
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'the root is gone' 'False' "$(Test-Path -LiteralPath $root)"
Test-Equal 'the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app') 'User')

# --- system mode, with the service -------------------------------------------------

$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'SKIP system mode: needs an elevated prompt' }
else {
    $root = Join-Path $work 'sysroot'
    $rc = Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it-sys')
    Test-Equal 'system: install succeeds' '0' "$rc"
    if ($rc -ne 0) { Write-Host $script:lastOut }
    Test-Equal 'system: app is on the machine PATH' 'True' (Test-OnPath (Join-Path $root 'app') 'Machine')
    $vigil = Join-Path $root 'app\vigil.ps1'
    [void](Invoke-Script $vigil @('status'))
    Test-Equal 'system: the service is active' 'True' "$($script:lastOut -match '^service: active')"
    Test-Equal 'system: upgrade succeeds' '0' "$(Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a2))"
    [void](Invoke-Script $vigil @('status'))
    Test-Equal 'system: the service is active after the upgrade' 'True' "$($script:lastOut -match '^service: active')"
    Test-Equal 'system: app is the new version' '0.0.2-it' (Get-Version $root)
    Test-Equal 'system: uninstall succeeds' '0' "$(Invoke-Script $vigil @('uninstall', '--yes'))"
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'system: the root is gone' 'False' "$(Test-Path -LiteralPath $root)"
    Test-Equal 'system: the service is gone' 'False' "$([bool](Get-Service -Name Vigil -ErrorAction SilentlyContinue))"
    Test-Equal 'system: the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app') 'Machine')
}

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
