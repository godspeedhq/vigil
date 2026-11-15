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
    Checks that a Windows worker loads every library its kind of run can
    use (backlog 52).
.DESCRIPTION
    A worker loads only the libraries app\vigil.ps1 lists for its kind of
    run ($workerLibs): a job, or one of Vigil's own workers. A function or
    script variable from a library it did not load would fail only when that
    path runs, maybe rarely. So this reads the code, not a run: from each
    kind's entry functions it follows every command any function calls and
    every $Script: variable it reads, through all branches, and fails on any
    defined in a library the list leaves out.

    -Show prints each kind's closure, to write the lists from.

    Exit code: 0 all passed, 1 any failed.
#>

param([switch]$Show)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$libDir = Join-Path $repo 'app\lib\windows'
$script:pass = 0
$script:fail = 0

function Get-Ast([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "${Path}: $($errors[0].Message)" }
    return $ast
}

# Where each function and script variable is defined, and what each
# function uses.
$funcLib = @{}; $varLib = @{}; $uses = @{}
foreach ($f in Get-ChildItem -LiteralPath $libDir -Filter *.ps1) {
    $ast = Get-Ast $f.FullName
    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $funcLib[$fn.Name] = $f.BaseName
        $u = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($c in $fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName(); if ($n) { [void]$u.Add("f:$n") }
        }
        foreach ($v in $fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if ($v.VariablePath.UserPath -match '^script:(.+)$') { [void]$u.Add("v:$($Matches[1])") }
        }
        $uses[$fn.Name] = $u
    }
    # Script variables assigned at the top of a library, outside any function.
    foreach ($a in $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] }) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.Left.VariablePath.UserPath -match '^script:(.+)$') {
            $varLib[$Matches[1]] = $f.BaseName
        }
    }
}

# The libraries each kind needs: what its entry functions reach. A job's run
# stops at the functions only Vigil's own workers call.
$own = @{ vigil_sender = 'Invoke-VigilSend'; vigil_fetch = 'Invoke-VigilFetch'; vigil_logs = 'Invoke-VigilLogs'; vigil_update = 'Invoke-VigilUpdate' }
function Get-Needed([string[]]$Entry, [string[]]$Stop) {
    $libs = New-Object 'System.Collections.Generic.HashSet[string]'
    $seen = @{}; $queue = New-Object System.Collections.Queue
    foreach ($e in $Entry) { $queue.Enqueue("f:$e") }
    while ($queue.Count) {
        $n = $queue.Dequeue()
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = 1
        $name = $n.Substring(2)
        if ($n.StartsWith('v:')) { if ($varLib.ContainsKey($name)) { [void]$libs.Add($varLib[$name]) }; continue }
        if ($Stop -contains $name -or -not $funcLib.ContainsKey($name)) { continue }
        [void]$libs.Add($funcLib[$name])
        foreach ($x in $uses[$name]) { $queue.Enqueue($x) }
    }
    return @($libs | Sort-Object)
}

$entry = @('Get-VigilWorkerContext', 'Invoke-VigilWorker')
$needed = @{ '*' = Get-Needed $entry @($own.Values) }
foreach ($k in $own.Keys) { $needed[$k] = Get-Needed ($entry + $own[$k]) @($own.Values | Where-Object { $_ -cne $own[$k] }) }

if ($Show) {
    foreach ($k in $needed.Keys | Sort-Object) { "{0,-13} {1}" -f $k, ($needed[$k] -join ', ') }
    exit 0
}

# The lists vigil.ps1 loads, read from its source: a literal hashtable.
$main = Get-Ast (Join-Path $repo 'app\vigil.ps1')
$assign = $main.Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($a.Left)" -ceq '$workerLibs' }, $true)
if (-not $assign) { Write-Host '  FAIL  app\vigil.ps1 has no $workerLibs'; exit 1 }
$lists = $assign.Right.Expression.SafeGetValue()

foreach ($k in $needed.Keys | Sort-Object) {
    $have = @($lists[$k])
    $missing = @($needed[$k] | Where-Object { $have -notcontains $_ })
    if ($missing.Count -eq 0) { $script:pass++; Write-Host "  PASS  $k loads every library it can use" }
    else { $script:fail++; Write-Host "  FAIL  ${k}: missing $($missing -join ', ')" }
    foreach ($l in $have) {
        if (-not (Test-Path -LiteralPath (Join-Path $libDir "$l.ps1"))) { $script:fail++; Write-Host "  FAIL  ${k}: no library $l" }
    }
}
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
