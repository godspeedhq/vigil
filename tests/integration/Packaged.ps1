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
    Integration test: a packaged program (SPECIFICATION.md 18.6) on Windows.
    The twin of packaged.sh.
.DESCRIPTION
    The program is laid out as a package lays it out, read-only, with
    app\PACKAGED naming its root elsewhere: Vigil finds that root, vigil init
    puts the package's packs in it, self update and uninstall leave the
    program to its package manager, and nothing is ever written into the
    program.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-pk.$PID"
$shell = (Get-Process -Id $PID).Path
$env:VIGIL_NO_UPDATE_CHECK = '1'
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else {
        $script:fail++
        Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]"
        foreach ($l in $script:lines) { Write-Host "        $l" }
    }
}

# A vigil, with stdin redirected as in CI: it never asks. Returns the exit code.
function Invoke-Vigil {
    param([string]$Program, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $o = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File $Program @Arguments 2>&1
    $script:lines = @($o | ForEach-Object { "$_" })
    return "$LASTEXITCODE"
}

function Test-Has { param([string]$Text) return "$(@($script:lines | Where-Object { $_.Contains($Text) }).Count -gt 0)" }
function Test-File { param([string]$Path) return "$([System.IO.File]::Exists($Path))" }

# Every file of the program with its hash: what must never change.
function Get-Program {
    $p = @(Get-ChildItem -LiteralPath $prog -Recurse -File -Force | Sort-Object FullName |
        ForEach-Object { "$($_.FullName.Substring($prog.Length)) $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
    return $p -join "`n"
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
[void](New-Item -ItemType Directory -Force -Path $work)
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$prog = Join-Path $work 'prog'
$data = Join-Path $work 'data'
$pv = Join-Path $prog 'app\vigil.ps1'

# The program as a package installs it: app and packs side by side.
[void](New-Item -ItemType Directory -Force -Path $prog)
Copy-Item -LiteralPath (Join-Path $repo 'app') -Destination (Join-Path $prog 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $repo 'packs') -Destination (Join-Path $prog 'packs') -Recurse
[System.IO.File]::WriteAllText((Join-Path $prog 'app\VERSION'), "9.9.9`n")
[System.IO.File]::WriteAllText((Join-Path $prog 'app\PACKAGED'), "manager = testpkg`r`nupgrade = choco upgrade vigil`r`nroot    = $data`r`n")
Get-ChildItem -LiteralPath $prog -Recurse -File | ForEach-Object { $_.IsReadOnly = $true }
$before = Get-Program

# --- the root ------------------------------------------------------------------

[void](Invoke-Vigil $pv @('about'))
Test-Equal 'the root is the one PACKAGED names' 'True' (Test-Has "Installed   $data")
Test-Equal 'about names the program and its package manager' 'True' (Test-Has "Program     $prog, by testpkg")

$other = Join-Path $work 'other'
[void](New-Item -ItemType Directory -Force -Path $other)
$env:VIGIL_ROOT = $other
[void](Invoke-Vigil $pv @('about'))
Test-Equal 'VIGIL_ROOT comes before PACKAGED' 'True' (Test-Has "Installed   $other")
[void](Invoke-Vigil $pv @('-Root', $prog, 'about'))
Test-Equal '-Root comes before VIGIL_ROOT' 'True' (Test-Has "Installed   $prog")
Remove-Item Env:\VIGIL_ROOT

# --- vigil init ------------------------------------------------------------------

$cfg = Join-Path $data 'config\vigil.config'
Test-Equal 'init: exit 0' '0' (Invoke-Vigil $pv @('init', '--instance', 'pk', '--backend', 'file'))
Test-Equal 'init: writes the configuration in the root' 'True' (Test-File $cfg)
Test-Equal 'init: puts the packs in the root' 'True' (Test-File (Join-Path $data 'packs\base\pack.config'))
Test-Equal "init: only this platform's scripts, flat" 'True' "$((Test-File (Join-Path $data 'packs\base\cpu.ps1')) -ceq 'True' -and -not (Test-Path -LiteralPath (Join-Path $data 'packs\base\cpu.sh')) -and -not (Test-Path -LiteralPath (Join-Path $data 'packs\base\windows')))"
Test-Equal 'init: turns the base pack on' '1' "$(@(Get-Content -LiteralPath $cfg | Where-Object { $_.StartsWith('# pack base:') }).Count)"

Test-Equal 'a pack job runs from the root' '0' (Invoke-Vigil $pv @('run', 'base_cpu'))
Test-Equal 'its log is in the root' 'True' "$(Test-Path -LiteralPath (Join-Path $data 'logs\jobs\base_cpu'))"

# A pack already in the root stays as it is.
$pc = Join-Path $data 'packs\base\pack.config'
(Get-Item -LiteralPath $pc).IsReadOnly = $false
Add-Content -LiteralPath $pc -Value '# changed here'
Move-Item -LiteralPath $cfg -Destination (Join-Path $work 'kept.config')
Test-Equal 'init again: exit 0' '0' (Invoke-Vigil $pv @('init', '--instance', 'pk', '--backend', 'file'))
Test-Equal 'init again: a pack already there is kept' '1' "$(@(Get-Content -LiteralPath $pc | Where-Object { $_ -ceq '# changed here' }).Count)"

# --- what is left to the package manager ------------------------------------------

Test-Equal 'self update: exit 1' '1' (Invoke-Vigil $pv @('self', 'update'))
Test-Equal 'self update: names the package manager and its command' 'True' (Test-Has 'Vigil was installed by testpkg: update it with choco upgrade vigil')

# Even when the configuration names a version, which otherwise has its own refusal.
$text = [System.IO.File]::ReadAllText($cfg) -replace '(?m)^instance = pk\r?$', "instance = pk`r`nversion = 9.9.8"
[System.IO.File]::WriteAllText($cfg, $text)
Test-Equal 'the configuration names a version' '1' "$(@(Get-Content -LiteralPath $cfg | Where-Object { $_ -ceq 'version = 9.9.8' }).Count)"
[void](Invoke-Vigil $pv @('self', 'update'))
Test-Equal 'self update with a version configured: still the package manager' 'True' (Test-Has 'installed by testpkg')

Test-Equal 'uninstall: exit 1' '1' (Invoke-Vigil $pv @('uninstall', '--yes'))
Test-Equal 'uninstall: says to use the package manager' 'True' (Test-Has 'installed by testpkg: remove it with that')
Test-Equal 'uninstall: the root is kept' 'True' (Test-File $cfg)

# --- the program itself ----------------------------------------------------------

$script:lines = @()
Test-Equal 'nothing was written into the program' $before (Get-Program)

# A program that is not packaged keeps the root above app\, and init copies no
# packs: the install script does that.
$plain = Join-Path $work 'plain'
[void](New-Item -ItemType Directory -Force -Path $plain)
[void](Invoke-Vigil (Join-Path $repo 'app\vigil.ps1') @('-Root', $plain, 'init', '--instance', 'plain', '--backend', 'file'))
Test-Equal 'not packaged: init copies no packs' 'False' "$(Test-Path -LiteralPath (Join-Path $plain 'packs'))"

Get-ChildItem -LiteralPath $work -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
