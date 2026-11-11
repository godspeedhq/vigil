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
    Integration test: what this account cannot read is never taken for
    missing (backlog 45).
.DESCRIPTION
    Denies this account read on folders of an install, the way a system
    install's are closed to an ordinary account, then checks that each
    command says it cannot read them, names the folder and fails, rather than
    calling it absent: vigil config, pack enable and list, init, secret list
    and delete, precheck, self update --check, and a release_path that cannot
    be read. A deny entry holds for administrators too. The twin of
    unreadable.sh.

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-unread.$PID"
$root = Join-Path $work 'root'
$shell = (Get-Process -Id $PID).Path
$me = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

# vigil, with stdin redirected as in CI: it never asks. Sets $script:code and
# returns the output, one string.
function Invoke-Vigil {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $o = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @Arguments 2>&1
    $script:code = "$LASTEXITCODE"
    return (@($o | ForEach-Object { "$_" }) -join "`n").Trim()
}

# A deny entry for Everyone (S-1-1-0), which holds for this account too, and
# is removed whole afterwards. Not one for this account: icacls would also
# take the rights out of the account's own allow entry, for good.
function Close-Folder { param([string]$Path) [void](& icacls.exe $Path /deny '*S-1-1-0:(OI)(CI)(RD,RA,REA)' 2>&1) }
function Open-Folder { param([string]$Path) [void](& icacls.exe $Path /remove:d '*S-1-1-0' 2>&1) }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$env:VIGIL_NO_UPDATE_CHECK = '1'
# A copy of the program with a VERSION, as a release has, so self update gets
# as far as reading its source.
foreach ($d in 'config', 'scripts') { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app') -Destination (Join-Path $root 'app')
Copy-Item -Recurse -LiteralPath (Join-Path $repo 'packs') -Destination (Join-Path $root 'packs')
[System.IO.File]::WriteAllText((Join-Path $root 'app\VERSION'), "0.0.1-it`n")
Set-Content -LiteralPath (Join-Path $root 'scripts\x.cmd') -Value @('@echo off', 'echo metric done 1')
$cfg = Join-Path $root 'config\vigil.config'
[System.IO.File]::WriteAllText($cfg, "[vigil]`ninstance = unread`n`n[job.x]`nfile      = scripts\x.cmd`nrun_every = 1m`nsecret    = X=secret:FOO`n")
$ErrorActionPreference = 'Continue'
[void]('v' | & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root secret set FOO --stdin 2>&1)
Test-Equal 'set up: the secret is stored' 'True' ([string][System.IO.File]::Exists((Join-Path $root 'config\secrets\FOO')))

$configDir = Join-Path $root 'config'
$how = 'from this account: run this from an elevated prompt for a system install'
$secretHow = 'from this account: secrets are set and read as the account Vigil runs as'
try {
    # Every command below runs with config\ closed to this account.
    Close-Folder $configDir
    $out = Invoke-Vigil @('config')
    Test-Equal 'config: refused' '1' $script:code
    Test-Equal 'config: says it cannot read the folder' "vigil: cannot read $configDir $how" $out
    $out = Invoke-Vigil @('pack', 'enable', 'base')
    Test-Equal 'pack enable: refused' '1' $script:code
    Test-Equal 'pack enable: says it cannot read the folder' "vigil: cannot read $configDir $how" $out
    $out = Invoke-Vigil @('pack', 'list')
    Test-Equal 'pack list: refused, not every job off' '1' $script:code
    Test-Equal 'pack list: says it cannot read the folder' "vigil: cannot read $configDir $how" $out
    $out = Invoke-Vigil @('init')
    Test-Equal 'init: refused' '1' $script:code
    Test-Equal 'init: says it cannot read the folder' "vigil: cannot read $configDir $how" (@($out.Split("`n"))[-1])
    $out = Invoke-Vigil @('self', 'update', '--check')
    Test-Equal 'self update --check: refused, not GitHub' '1' $script:code
    Test-Equal 'self update --check: says the source cannot be read' "vigil: cannot read $configDir from this account, which says where releases come from: run this from an elevated prompt for a system install" $out
    $out = Invoke-Vigil @('precheck')
    Test-Equal 'precheck: refused' '1' $script:code
    Test-Equal 'precheck: the configuration cannot be read' 'True' ([string]$out.Contains("config file not readable: $cfg"))
}
finally { Open-Folder $configDir }
Test-Equal 'init: nothing left behind' '' ((@(Get-ChildItem -LiteralPath $configDir -Force | Where-Object { $_.Name.Contains('.tmp.') } | ForEach-Object Name)) -join ' ')
Test-Equal 'and the configuration is untouched' 'True' ([string]([System.IO.File]::ReadAllText($cfg).Contains('secret    = X=secret:FOO')))

# Only the secret store, then only the scripts, closed. The store has an ACL
# of its own, not config\'s, and Windows lets an account through a folder it
# may not list to one it may read: closing config\ does not close it.
$secrets = Join-Path $configDir 'secrets'
try {
    Close-Folder $secrets
    $out = Invoke-Vigil @('secret', 'list')
    Test-Equal 'secret list: refused, not empty' '1' $script:code
    Test-Equal 'secret list: says it cannot read the folder' "vigil: cannot read $secrets $secretHow" $out
    $out = Invoke-Vigil @('secret', 'delete', 'FOO')
    Test-Equal 'secret delete: refused, not "no secret"' '1' $script:code
    Test-Equal 'secret delete: says it cannot read the folder' "vigil: cannot read $secrets $secretHow" $out
    $out = Invoke-Vigil @('precheck')
    Test-Equal 'precheck: a secret it cannot read is not "not found"' 'True' ([string]$out.Contains("secret:FOO unavailable: cannot read $secrets $secretHow"))
}
finally { Open-Folder $secrets }
Test-Equal 'secret delete: the secret is still there' 'True' ([string][System.IO.File]::Exists((Join-Path $secrets 'FOO')))
$scripts = Join-Path $root 'scripts'
try {
    Close-Folder $scripts
    $out = Invoke-Vigil @('precheck')
    Test-Equal 'precheck: a script it cannot read is not "file not found"' 'True' ([string]$out.Contains("job.x: cannot read $scripts from this account"))
}
finally { Open-Folder $scripts }

# A release_path this account cannot read names the folder and the account,
# for a version asked for as for the latest.
$releases = Join-Path $work 'releases'
[void](New-Item -ItemType Directory -Force -Path $releases)
[System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg).Replace("instance = unread`n", "instance = unread`nrelease_path = $releases`n")))
try {
    Close-Folder $releases
    $out = Invoke-Vigil @('self', 'update', '--version', '0.0.2-it')
    Test-Equal 'release_path: a version that cannot be read is refused' '1' $script:code
    Test-Equal 'release_path: names the folder and the account' "vigil: cannot read Vigil 0.0.2-it from $releases (as $me): is it there, and readable by this account?" $out
    $out = Invoke-Vigil @('self', 'update', '--check')
    Test-Equal 'release_path: the latest names them too' "vigil: cannot read the latest release from $releases (as $me): is it there, and readable by this account?" $out
}
finally { Open-Folder $releases }

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
