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
    Integration test: the installer (SPECIFICATION.md 18.7) on Windows.
.DESCRIPTION
    From release archives built by tools/release/package.sh (through Git
    Bash): a tampered archive changes nothing; a fresh install unpacks, adds
    app\bin (the vigil command) to the PATH and writes a configuration that
    passes pre-flight, and vigil runs where the execution policy refuses
    scripts; an upgrade replaces app\ and vendor\, never touches config\ or
    scripts\, and moves an earlier version's PATH entry (app\) to app\bin;
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
# A release key for this run: the archives are signed with it, and the
# installer is given its public half with -Key.
$kw = $work.Replace('\', '/')
foreach ($line in @("genrsa -out '$kw/release.key' 2048", "genrsa -out '$kw/other.key' 2048",
        "rsa -in '$kw/release.key' -pubout -out '$kw/release.pem'", "rsa -in '$kw/other.key' -pubout -out '$kw/other.pem'")) {
    & $bash -c "openssl $line" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "openssl $line failed"; exit 1 }
}
$env:VIGIL_SIGN_KEY = "$kw/release.key"
$pem = Join-Path $work 'release.pem'
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

# --- the signature, with -Key ---------------------------------------------------

# SHA256SUMS changed to match a changed archive: only the signature catches it.
$forged = Join-Path $work 'forged'
[void](New-Item -ItemType Directory -Force -Path $forged)
Copy-Item -LiteralPath (Join-Path $bad 'vigil-0.0.1-it.zip'), (Join-Path $work 'r0.0.1-it\SHA256SUMS.sig') -Destination $forged
[System.IO.File]::WriteAllText((Join-Path $forged 'SHA256SUMS'), "$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $forged 'vigil-0.0.1-it.zip')).Hash.ToLowerInvariant())  vigil-0.0.1-it.zip`n")
Test-Equal 'key: a forged SHA256SUMS is refused' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $badRoot, '-Archive', (Join-Path $forged 'vigil-0.0.1-it.zip'), '-Key', $pem, '-NoService'))"
Test-Equal 'key: saying why' 'True' "$($script:lastOut -match 'is not signed by the release key')"
$nosig = Join-Path $work 'nosig'
[void](New-Item -ItemType Directory -Force -Path $nosig)
Copy-Item -LiteralPath $a1, (Join-Path $work 'r0.0.1-it\SHA256SUMS') -Destination $nosig
Test-Equal 'key: without SHA256SUMS.sig, refused' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $badRoot, '-Archive', (Join-Path $nosig 'vigil-0.0.1-it.zip'), '-Key', $pem, '-NoService'))"
Test-Equal 'key: saying why' 'True' "$($script:lastOut -match 'no SHA256SUMS\.sig beside')"
Test-Equal 'key: signed by another key, refused' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $badRoot, '-Archive', $a1, '-Key', (Join-Path $work 'other.pem'), '-NoService'))"
Test-Equal 'key: a key that is not there, refused' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $badRoot, '-Archive', $a1, '-Key', (Join-Path $work 'no.pem'), '-NoService'))"
Test-Equal 'key: saying why' 'True' "$($script:lastOut -match 'no release key at')"
Test-Equal 'key: nothing is installed by any of them' 'False' "$(Test-Path -LiteralPath (Join-Path $badRoot 'app'))"

# --- user mode: fresh install, upgrade, uninstall ----------------------------------

$root = Join-Path $work 'root'
$rc = Invoke-Script $installer @('-User', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it', '-Backend', 'file', '-NoService')
Test-Equal 'install succeeds' '0' "$rc"
if ($rc -ne 0) { Write-Host $script:lastOut }
Test-Equal 'a fresh install without -Key checks no signature' 'False' "$($script:lastOut -match 'verified SHA256SUMS')"
Test-Equal 'the version is recorded' '0.0.1-it' (Get-Version $root)
Test-Equal 'app\bin is on the user PATH' 'True' (Test-OnPath (Join-Path $root 'app\bin') 'User')
Test-Equal 'app is not' 'False' (Test-OnPath (Join-Path $root 'app') 'User')
Test-Equal 'init wrote the configuration' 'True' "$([System.IO.File]::ReadAllText((Join-Path $root 'config\vigil.config')) -match '(?m)^instance = it$')"
$out = & cmd.exe /d /c "`"$(Join-Path $root 'app\bin\vigil.cmd')`" precheck" 2>&1
Test-Equal 'the installed configuration passes pre-flight, through vigil.cmd' '0' "$LASTEXITCODE"

# Where the execution policy refuses scripts, the default on Windows 10 and
# 11, PowerShell finds vigil.cmd, which runs vigil.ps1 all the same.
$out = & $shell -NoProfile -ExecutionPolicy Restricted -Command "`$env:Path = '$(Join-Path $root 'app\bin');' + `$env:Path; vigil version" 2>&1
Test-Equal 'vigil runs from PowerShell where scripts are refused' 'Vigil 0.0.1-it' "$(@($out)[0])"

# An earlier version put app\ on the PATH: a reinstall moves it to app\bin.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', $userPath.Replace((Join-Path $root 'app\bin'), (Join-Path $root 'app')), 'User')

$cfgPath = Join-Path $root 'config\vigil.config'
[System.IO.File]::AppendAllText($cfgPath, "# my change`n")
[System.IO.File]::WriteAllText((Join-Path $root 'scripts\mine.ps1'), 'Write-Output mine')
$cfg = [System.IO.File]::ReadAllText($cfgPath)
# The installed key is the real release key, which did not sign these.
Test-Equal 'upgrade: checked against the installed key' '1' "$(Invoke-Script $installer @('-User', '-Prefix', $root, '-Archive', $a2, '-NoService'))"
# In two parts: PowerShell wraps an error at the console's width.
Test-Equal 'upgrade: saying why' 'True' ([string]($script:lastOut -match 'is not signed by the release key' -and $script:lastOut -match 'release-key\.pem'))
Test-Equal 'upgrade: and refused' '0.0.1-it' (Get-Version $root)
$rc = Invoke-Script $installer @('-User', '-Prefix', $root, '-Archive', $a2, '-Key', $pem, '-NoService')
Test-Equal 'upgrade succeeds' '0' "$rc"
if ($rc -ne 0) { Write-Host $script:lastOut }
Test-Equal 'upgrade: the signature was checked' 'True' ([string]($script:lastOut -match '(?m)^verified SHA256SUMS [(]signed by '))
Test-Equal 'says it upgraded' 'True' "$($script:lastOut -match '(?m)^upgraded ')"
Test-Equal 'app is the new version' '0.0.2-it' (Get-Version $root)
Test-Equal 'the old PATH entry (app) is gone' 'False' (Test-OnPath (Join-Path $root 'app') 'User')
Test-Equal 'for app\bin' 'True' (Test-OnPath (Join-Path $root 'app\bin') 'User')
Test-Equal 'the configuration is untouched' 'True' "$($cfg -ceq [System.IO.File]::ReadAllText($cfgPath))"
Test-Equal 'scripts are untouched' 'True' "$(Test-Path -LiteralPath (Join-Path $root 'scripts\mine.ps1'))"
Test-Equal 'no app.old is left' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'app.old'))"

Test-Equal 'uninstall succeeds' '0' "$(Invoke-Script (Join-Path $root 'app\vigil.ps1') @('uninstall', '--yes'))"
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'the root is gone' 'False' "$(Test-Path -LiteralPath $root)"
Test-Equal 'the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app\bin') 'User')

# --- as the documented one-liner runs it: a fresh install with -Key ------------------
#
# irm ... | iex, or & ([scriptblock]::Create((irm ...))) with flags (18.7):
# the installer's text runs in the caller's own session, with no script
# file behind it. It must verify the signature on a fresh install too, and
# return to its caller rather than exit.
$root = Join-Path $work 'keyed'
$block = "& ([scriptblock]::Create([System.IO.File]::ReadAllText('$installer'))) -User -Prefix '$root' -Archive '$a1' -Key '$pem' -Instance it -Backend file -NoService; 'the caller carries on'"
$out = '' | & $shell -NoProfile -ExecutionPolicy Bypass -Command $block 2>&1
$script:lastOut = ($out | ForEach-Object { "$_" }) -join "`n"
Test-Equal 'one-liner: a fresh install with -Key succeeds' '0.0.1-it' (Get-Version $root)
Test-Equal 'one-liner: the signature was checked' 'True' ([string]($script:lastOut -match '(?m)^verified SHA256SUMS [(]signed by '))
Test-Equal 'one-liner: it returns to its caller, never exits' 'True' ([string]($script:lastOut -match '(?m)^the caller carries on$'))
if (-not (Get-Version $root)) { Write-Host $script:lastOut }
Test-Equal 'one-liner: uninstall succeeds' '0' "$(Invoke-Script (Join-Path $root 'app\vigil.ps1') @('uninstall', '--yes'))"
for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
Test-Equal 'one-liner: the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app\bin') 'User')

# --- system mode, with the service -------------------------------------------------

$admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'SKIP system mode: needs an elevated prompt' }
else {
    $root = Join-Path $work 'sysroot'
    $rc = Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it-sys')
    Test-Equal 'system: install succeeds' '0' "$rc"
    if ($rc -ne 0) { Write-Host $script:lastOut }
    Test-Equal 'system: app\bin is on the machine PATH' 'True' (Test-OnPath (Join-Path $root 'app\bin') 'Machine')
    $vigil = Join-Path $root 'app\vigil.ps1'
    [void](Invoke-Script $vigil @('status'))
    Test-Equal 'system: the service is active' 'True' "$($script:lastOut -match '^service: active')"
    Test-Equal 'system: upgrade succeeds' '0' "$(Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a2, '-Key', $pem))"
    [void](Invoke-Script $vigil @('status'))
    Test-Equal 'system: the service is active after the upgrade' 'True' "$($script:lastOut -match '^service: active')"
    Test-Equal 'system: app is the new version' '0.0.2-it' (Get-Version $root)
    Test-Equal 'system: uninstall succeeds' '0' "$(Invoke-Script $vigil @('uninstall', '--yes'))"
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'system: the root is gone' 'False' "$(Test-Path -LiteralPath $root)"
    Test-Equal 'system: the service is gone' 'False' "$([bool](Get-Service -Name Vigil -ErrorAction SilentlyContinue))"
    Test-Equal 'system: the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app\bin') 'Machine')

    # Without a service, the root is locked all the same (backlog 41).
    $root = Join-Path $work 'sysroot-noservice'
    $rc = Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it-ns', '-NoService')
    Test-Equal 'system, no service: install succeeds' '0' "$rc"
    if ($rc -ne 0) { Write-Host $script:lastOut }
    $acl = Get-Acl -LiteralPath $root
    $who = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) -join ' '
    Test-Equal 'system, no service: the root is SYSTEM and Administrators only' 'True|S-1-5-18 S-1-5-32-544' "$($acl.AreAccessRulesProtected)|$who"
    [void](Invoke-Script (Join-Path $root 'app\vigil.ps1') @('uninstall', '--yes'))
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
    Test-Equal 'system, no service: the PATH entry is gone' 'False' (Test-OnPath (Join-Path $root 'app\bin') 'Machine')

    # A root made before Vigil by someone else (backlog 54): C:\ProgramData
    # lets any user create a folder. One owned by an untrusted account (here
    # the Users group, as a standard user would be), locked to it, is refused,
    # and nothing is put in it.
    $root = Join-Path $work 'sysroot-planted'
    [void](New-Item -ItemType Directory -Path $root)
    [void](& icacls.exe $root /inheritance:r /grant:r '*S-1-5-32-545:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' 2>&1)
    [void](& icacls.exe $root /setowner '*S-1-5-32-545' 2>&1)
    Test-Equal 'planted root: owned by Users for the test' 'S-1-5-32-545' (Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rc = Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it-planted', '-NoService')
    Test-Equal 'planted root: refused' '1' "$rc"
    # An error is wrapped at the console's width, even mid-word, and
    # PowerShell 7 colours it and starts each wrapped line with "|": matched
    # with the colours, the bars, every space and line break taken out.
    $flat = $script:lastOut -replace "$([char]27)\[[0-9;]*m", '' -replace '[\s|]', ''
    $said = $flat -match 'isownedby[^,]+,notbySYSTEMoranadministrator:whoeverownsitcanchangewhatVigilrunsasSYSTEM'
    Test-Equal 'planted root: says who owns it' 'True' "$said"
    if (-not $said) { Write-Host $script:lastOut }
    Test-Equal 'planted root: nothing installed' 'False' "$(Test-Path -LiteralPath (Join-Path $root 'app'))"
    [void](& icacls.exe $root /setowner '*S-1-5-32-544' 2>&1)

    # Owned by Administrators but locked with a write entry for others: the
    # ACL is replaced, keeping only read-only entries.
    [void](& icacls.exe $root /grant:r '*S-1-5-32-545:(RX)' 2>&1)
    [void](& icacls.exe $root /grant '*S-1-5-11:(OI)(CI)(M)' 2>&1)
    $rc = Invoke-Script $installer @('-System', '-Prefix', $root, '-Archive', $a1, '-Instance', 'it-planted', '-NoService')
    Test-Equal 'locked root: install succeeds' '0' "$rc"
    if ($rc -ne 0) { Write-Host $script:lastOut }
    $rules = @((Get-Acl -LiteralPath $root).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" } | Sort-Object) -join ' '
    Test-Equal 'locked root: only SYSTEM and Administrators may write' 'S-1-5-18=FullControl S-1-5-32-544=FullControl S-1-5-32-545=ReadAndExecute, Synchronize' $rules
    [void](Invoke-Script (Join-Path $root 'app\vigil.ps1') @('uninstall', '--yes'))
    for ($i = 0; $i -lt 20 -and (Test-Path -LiteralPath $root); $i++) { Start-Sleep -Milliseconds 500 }
}

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
