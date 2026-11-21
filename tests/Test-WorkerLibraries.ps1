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
    Checks that a Windows worker, and each vigil command, loads every library
    it can use (backlogs 52 and 65).
.DESCRIPTION
    A worker loads only the libraries app\vigil.ps1 lists for its kind of
    run ($workerLibs): a job, or one of Vigil's own workers. A command loads
    only those it lists for that command ($commandLibs). A function or script
    variable from a library it did not load would fail only when that path
    runs, maybe rarely. So this reads the code, not a run: from each kind's
    entry functions, and each command's branch of vigil.ps1's switch (with
    the code before it that every command runs), it follows every command any
    function calls and every $Script: variable it reads, through all
    branches, and fails on any defined in a library the list leaves out. A
    command missing from $commandLibs fails too: it would load them all.

    -Show prints each kind's and each command's closure, to write the lists
    from.

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

# The calls and $Script: reads in $Ast, as seeds for Get-Needed.
function Get-Calls($Ast) {
    $s = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName(); if ($n) { [void]$s.Add("f:$n") }
    }
    foreach ($v in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($v.VariablePath.UserPath -match '^script:(.+)$') { [void]$s.Add("v:$($Matches[1])") }
    }
    return @($s)
}
# The libraries reached from $Seeds (f:<function> and v:<variable>), not
# following the functions in $Stop.
function Get-Needed([string[]]$Seeds, [string[]]$Stop) {
    $libs = New-Object 'System.Collections.Generic.HashSet[string]'
    $seen = @{}; $queue = New-Object System.Collections.Queue
    foreach ($e in $Seeds) { $queue.Enqueue($e) }
    while ($queue.Count) {
        $n = $queue.Dequeue()
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = 1
        $name = $n.Substring(2)
        if ($n.StartsWith('v:')) { if ($varLib.ContainsKey($name)) { [void]$libs.Add($varLib[$name]) }; continue }
        if ($Stop -contains $name -or -not $funcLib.ContainsKey($name)) { continue }
        if ($funcLib[$name]) { [void]$libs.Add($funcLib[$name]) }
        foreach ($x in $uses[$name]) { $queue.Enqueue($x) }
    }
    return @($libs | Sort-Object)
}

$entry = @('f:Get-VigilWorkerContext', 'f:Invoke-VigilWorker')
$needed = @{ '*' = Get-Needed $entry @($own.Values) }
foreach ($k in $own.Keys) { $needed[$k] = Get-Needed ($entry + "f:$($own[$k])") @($own.Values | Where-Object { $_ -cne $own[$k] }) }

# Commands: vigil.ps1's own functions are followed too (in no library), and
# each command's branch of its switch, with what every command runs between
# loading the libraries and the switch.
$main = Get-Ast (Join-Path $repo 'app\vigil.ps1')
foreach ($fn in $main.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcLib[$fn.Name] = ''
    $uses[$fn.Name] = Get-Calls $fn.Body
}
$top = @($main.EndBlock.Statements)
$load = [array]::IndexOf($top, @($top | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and "$($_.Condition)" -ceq '$libs' })[0])
$switch = @($top | Where-Object { $_ -is [System.Management.Automation.Language.SwitchStatementAst] -and "$($_.Condition)" -ceq '$Command' })[0]
if ($load -lt 0 -or -not $switch) { Write-Host '  FAIL  app\vigil.ps1: no library loop, or no switch on $Command'; exit 1 }
$common = @()
for ($i = $load + 1; $i -lt [array]::IndexOf($top, $switch); $i++) { $common += Get-Calls $top[$i] }
$commands = @{}
foreach ($clause in $switch.Clauses) {
    # A clause is one command, or several in a script block ($_ -ceq 'start' -or ...).
    $names = @($clause.Item1.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    $libsFor = Get-Needed ($common + (Get-Calls $clause.Item2)) @()
    foreach ($c in $names) { if ($c -cne 'worker') { $commands[$c] = $libsFor } }
}

if ($Show) {
    foreach ($k in $needed.Keys | Sort-Object) { "{0,-14} {1}" -f $k, ($needed[$k] -join ', ') }
    foreach ($k in $commands.Keys | Sort-Object) { "{0,-14} {1}" -f $k, ($commands[$k] -join ', ') }
    exit 0
}

# The lists vigil.ps1 loads, read from its source: literal hashtables.
function Test-Lists([string]$Name, $Needed, [switch]$Every) {
    $assign = $main.Find({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($a.Left)" -ceq $Name }.GetNewClosure(), $true)
    if (-not $assign) { $script:fail++; Write-Host "  FAIL  app\vigil.ps1 has no $Name"; return }
    $lists = $assign.Right.Expression.SafeGetValue()
    foreach ($k in $Needed.Keys | Sort-Object) {
        if ($Every -and -not $lists.ContainsKey($k)) { $script:fail++; Write-Host "  FAIL  ${k}: not in $Name, so it loads every library"; continue }
        $have = @($lists[$k])
        $missing = @($Needed[$k] | Where-Object { $have -notcontains $_ })
        if ($missing.Count -eq 0) { $script:pass++; Write-Host "  PASS  $k loads every library it can use" }
        else { $script:fail++; Write-Host "  FAIL  ${k}: missing $($missing -join ', ')" }
        foreach ($l in $have) {
            if (-not (Test-Path -LiteralPath (Join-Path $libDir "$l.ps1"))) { $script:fail++; Write-Host "  FAIL  ${k}: no library $l" }
        }
    }
}
Test-Lists '$workerLibs' $needed
Test-Lists '$commandLibs' $commands -Every
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
