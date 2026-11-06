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
    Integration test: vigil config (SPECIFICATION.md 16.6) on Windows, with
    scripted editors. The twin of config-edit.sh.
.DESCRIPTION
    A copy is saved only when valid, keeping the file's ACL; anything refused
    leaves the configuration exactly as it was, and no working folder is
    left behind.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-ce.$PID"
$shell = (Get-Process -Id $PID).Path
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

# vigil config, with stdin redirected as in CI: it never asks.
function Invoke-Config {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $o = '' | & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root config @Arguments 2>&1
    $script:lines = @($o | ForEach-Object { "$_" })
    return "$LASTEXITCODE"
}

# Whether the last output has a line containing $Text.
function Test-Has { param([string]$Text) return "$(@($script:lines | Where-Object { $_.Contains($Text) }).Count -gt 0)" }
function Get-Sum { return (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash }
function Get-Leftovers { return "$(@(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Force -Filter '.vigil-config.*').Count)" }
function Get-Count { param([string]$Path, [string]$Text) return "$(@(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_.Contains($Text) }).Count)" }

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$root = Join-Path $work 'root'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'config'), (Join-Path $root 'scripts'))
$work = (Resolve-Path -LiteralPath $work).ProviderPath
$root = Join-Path $work 'root'
$cfg = Join-Path $root 'config\vigil.config'
Set-Content -LiteralPath (Join-Path $root 'scripts\ok.ps1') -Value 'Write-Output "metric ok 1"'
Set-Content -LiteralPath $cfg -Value @"
[vigil]
instance = ce

[runner.ps]
command = $shell

[runners]
.ps1 = ps

[job.first]
file      = scripts\ok.ps1
run_every = 1h
"@

# The editors, run by cmd with the copy's path last.
$e = Join-Path $work 'editors'
[void](New-Item -ItemType Directory -Path $e)
Set-Content -LiteralPath "$e\none.cmd" -Value '@exit /b 0'
Set-Content -LiteralPath "$e\fails.cmd" -Value '@exit /b 3'
Set-Content -LiteralPath "$e\add.cmd" -Value '@(echo.& echo [job.second]& echo file      = scripts\ok.ps1& echo run_every = 30m)>> %1'
Set-Content -LiteralPath "$e\error.cmd" -Value '@(echo.& echo this line is not a key)>> %1'
Set-Content -LiteralPath "$e\invalid.cmd" -Value '@(echo.& echo [job.third]& echo file      = scripts\ok.ps1& echo run_every = often)>> %1'
# Someone else saves the configuration while this edit is open.
Set-Content -LiteralPath "$e\race.cmd" -Value "@(echo.& echo # changed by someone else)>> `"$cfg`"`r`n@(echo.& echo # mine)>> %1"
# An editor with an argument before the file.
Set-Content -LiteralPath "$e\args.cmd" -Value "@if not `"%1`"==`"--wait`" exit /b 9`r`n@(echo.& echo # with an argument)>> %2"
Remove-Item Env:\VISUAL, Env:\EDITOR -ErrorAction SilentlyContinue
# Who may do what: the owner and each allow or deny rule, as a set. Saving
# from an elevated prompt may turn inherited rules into explicit ones too
# (ReplaceFile does), which grants nothing new.
function Get-Access {
    $a = Get-Acl -LiteralPath $cfg
    $rules = @($a.Access | ForEach-Object { "$($_.IdentityReference) $($_.AccessControlType) $($_.FileSystemRights)" } | Sort-Object -Unique)
    return "$($a.Owner); $($rules -join '; ')"
}
$acl = Get-Access

# --- nothing to save ---------------------------------------------------------

$before = Get-Sum
$env:EDITOR = "$e\none.cmd"
Test-Equal 'unchanged: exit 0' '0' (Invoke-Config)
Test-Equal 'unchanged: says so' 'True' (Test-Has 'no changes')
Test-Equal 'unchanged: the file is as it was' $before (Get-Sum)
Test-Equal 'unchanged: no working folder left' '0' (Get-Leftovers)

$env:EDITOR = "$e\fails.cmd"
Test-Equal 'a failing editor: exit 1' '1' (Invoke-Config)
Test-Equal 'a failing editor: says so' 'True' (Test-Has 'exited with 3; nothing was changed')
Test-Equal 'a failing editor: the file is as it was' $before (Get-Sum)

# --- refused -------------------------------------------------------------------

$env:EDITOR = "$e\error.cmd"
Test-Equal 'an ERROR: exit 1' '1' (Invoke-Config)
Test-Equal 'an ERROR: not saved' 'True' (Test-Has 'has problems and was not saved')
Test-Equal 'an ERROR: the report names the line' 'True' (Test-Has 'line 14:')
Test-Equal 'an ERROR: not at a console, it does not ask' 'False' (Test-Has 'Edit again')
Test-Equal 'an ERROR: the file is as it was' $before (Get-Sum)
Test-Equal 'an ERROR: no working folder left' '0' (Get-Leftovers)

$env:EDITOR = "$e\invalid.cmd"
Test-Equal 'an INVALID job: exit 1' '1' (Invoke-Config)
Test-Equal 'an INVALID job: the report names the job' 'True' (Test-Has 'INVALID  job.third')
Test-Equal 'an INVALID job: the file is as it was' $before (Get-Sum)

$env:EDITOR = "$e\race.cmd"
Test-Equal 'changed during the edit: exit 1' '1' (Invoke-Config)
Test-Equal 'changed during the edit: says so' 'True' (Test-Has 'changed while it was being edited')
Test-Equal 'changed during the edit: the other change stays' '1' (Get-Count $cfg 'changed by someone else')
Test-Equal 'changed during the edit: this edit is not in it' '0' (Get-Count $cfg '# mine')
Test-Equal 'changed during the edit: this edit is kept beside it' '1' (Get-Count "$cfg.edited" '# mine')
Remove-Item -LiteralPath "$cfg.edited" -ErrorAction SilentlyContinue

# --- saved ---------------------------------------------------------------------

$env:EDITOR = "$e\add.cmd"
Test-Equal 'a valid change: exit 0' '0' (Invoke-Config)
Test-Equal 'a valid change: says it is saved' 'True' (Test-Has "saved $cfg")
Test-Equal 'a valid change: it is in the file' '1' (Get-Count $cfg '[job.second]')
Test-Equal 'a valid change: the same access' $acl (Get-Access)
Test-Equal 'a valid change: no working folder left' '0' (Get-Leftovers)
& $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root supervise --once *> $null
Test-Equal 'the supervisor runs the saved configuration' 'True' "$((Get-Count (Join-Path $root 'logs\supervisor\jobs.log') 'second') -ne '0')"
# Its runs are short: let them end before the root goes.
Start-Sleep -Seconds 8

$before = Get-Sum
$env:VISUAL = "$e\none.cmd"
$env:EDITOR = "$e\fails.cmd"
Test-Equal 'VISUAL comes before EDITOR' '0' (Invoke-Config)
Test-Equal 'VISUAL comes before EDITOR: nothing changed' $before (Get-Sum)
Remove-Item Env:\VISUAL

$env:EDITOR = "`"$e\args.cmd`" --wait"
Test-Equal 'an editor with arguments: exit 0' '0' (Invoke-Config)
Test-Equal 'an editor with arguments: saved' '1' (Get-Count $cfg '# with an argument')

# --- what it refuses -----------------------------------------------------------

Set-ItemProperty -LiteralPath $cfg -Name IsReadOnly -Value $true
$before = Get-Sum
$env:EDITOR = "$e\add.cmd"
Test-Equal 'a file it cannot write: exit 1' '1' (Invoke-Config)
Test-Equal 'a file it cannot write: says to use an elevated prompt' 'True' (Test-Has 'an elevated prompt')
Test-Equal 'a file it cannot write: the file is as it was' $before (Get-Sum)
Set-ItemProperty -LiteralPath $cfg -Name IsReadOnly -Value $false

Set-Content -LiteralPath $cfg -Value "[vigil]`nconfig_source = $work\fleet"
$before = Get-Sum
Test-Equal 'a pointer file: exit 1' '1' (Invoke-Config)
Test-Equal 'a pointer file: names the source' 'True' (Test-Has "comes from $work\fleet")
Test-Equal 'a pointer file: the file is as it was' $before (Get-Sum)

Remove-Item -LiteralPath $cfg
Test-Equal 'no configuration: exit 1' '1' (Invoke-Config)
Test-Equal 'no configuration: points at vigil init' 'True' (Test-Has 'vigil init writes one')

Test-Equal 'an argument is a usage error' '64' (Invoke-Config @('extra'))

Remove-Item Env:\EDITOR -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
