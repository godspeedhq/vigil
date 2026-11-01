#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil job command line - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Builds the program, argument vector and working directory for a job from
    its effective settings (SPECIFICATION.md 6.4), for a given platform and
    install root. Pure: nothing is started and the filesystem is not read.
    Must produce exactly the same result as command.sh -
    tests/conformance/command holds the shared cases.

    Returns { Error; Message; Program; Args; Cwd; Line }. Line is the
    Arguments string for ProcessStartInfo (windows only), encoded for the
    Microsoft C runtime's command-line parser. Jobs are started through
    ProcessStartInfo, never "& $cmd @args": Windows PowerShell 5.1 drops
    empty arguments and does not escape embedded quotes.

    Requires Config.ps1 and Effective.ps1.
#>

# Characters cmd.exe interprets in a batch file's command line, even inside
# quotes for % and !. An argument containing one is rejected, never escaped:
# escaping for cmd.exe is not reliable (the "BatBadBut" class of flaw).
$Script:VigilBatchUnsafe = '["%!&|<>^]'

function Resolve-VigilPath {
    param([string]$Path, [string]$Platform, [string]$Root)
    if ($Platform -ceq 'windows') {
        $p = $Path.Replace('/', '\')
        if ($p -cmatch '^[A-Za-z]:\\' -or $p.StartsWith('\')) { return $p }
        if ($p -ceq '.') { return $Root }
        return "$Root\$p"
    }
    if ($Path.StartsWith('/')) { return $Path }
    if ($Path -ceq '.') { return $Root }
    return "$Root/$Path"
}

# Encodes one argument for the Microsoft C runtime parser. Backslashes are
# literal except before a quote, where each must be doubled and the quote
# escaped; the closing quote doubles any trailing backslashes.
function ConvertTo-VigilQuotedArg {
    param([string]$Arg, [bool]$Always)
    if (-not $Always -and $Arg.Length -gt 0 -and $Arg -cnotmatch '[ \t"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq [char]'\') { $bs++ }
        elseif ($c -eq [char]'"') {
            [void]$sb.Append('\', 2 * $bs + 1).Append('"')
            $bs = 0
        }
        else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs) }
            [void]$sb.Append($c)
            $bs = 0
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', 2 * $bs) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-VigilJobCommand {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Root,
        # The cached copy of a script from a source (16.5), when the caller has it.
        [string]$Cached
    )

    $result = [pscustomobject]@{
        Error = ''; Message = ''; Program = ''
        Args = New-Object 'System.Collections.Generic.List[string]'
        Cwd = ''; Line = ''
    }

    $runner = ''
    $file = ''
    $jobArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in (Get-VigilEffectiveJob -Index $Index -Id $Id)) {
        switch -CaseSensitive ($row.Key) {
            'file' { $file = $row.Value }
            'runner' { $runner = $row.Value }
            'arg' { $jobArgs.Add($row.Value) }
            'working_dir' { $result.Cwd = Resolve-VigilPath $row.Value $Platform $Root }
        }
    }
    $file = Resolve-VigilPath $file $Platform $Root
    if ($Cached) { $file = $Cached }

    if ($runner.Length -gt 0) {
        $command = (Get-VigilIndexValue -Index $Index -Section "runner.$runner" -Key 'command').Value
        # A command with a directory part is a path; a bare name is found on
        # PATH when the job starts.
        $hasDir = if ($Platform -ceq 'windows') { $command -cmatch '[\\/]' } else { $command.Contains('/') }
        if ($hasDir) { $command = Resolve-VigilPath $command $Platform $Root }
        $result.Program = $command
        $substituted = $false
        foreach ($v in (Get-VigilIndexValues -Index $Index -Section "runner.$runner" -Key 'arg')) {
            if ($v.Contains('{file}')) {
                $v = $v.Replace('{file}', $file)
                $substituted = $true
            }
            $result.Args.Add($v)
        }
        if (-not $substituted) { $result.Args.Add($file) }
    }
    else {
        $result.Program = $file
    }
    foreach ($v in $jobArgs) { $result.Args.Add($v) }

    if ($Platform -cne 'windows') { return $result }

    $lower = $result.Program.ToLowerInvariant()
    $batch = $lower.EndsWith('.bat') -or $lower.EndsWith('.cmd')
    # cmd.exe parses the batch file's own path too.
    if ($batch -and $result.Program -cmatch $Script:VigilBatchUnsafe) {
        $result.Error = 'E_BATCH_PATH'
        $result.Message = "a batch file's path contains a character cmd.exe interprets (`" % ! & | < > ^): $($result.Program)"
        return $result
    }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($v in $result.Args) {
        if ($batch -and $v -cmatch $Script:VigilBatchUnsafe) {
            $result.Error = 'E_BATCH_ARG'
            $result.Message = "an argument to a batch file contains a character cmd.exe interprets (`" % ! & | < > ^): $v"
            return $result
        }
        $parts.Add((ConvertTo-VigilQuotedArg -Arg $v -Always (-not $batch)))
    }
    $result.Line = $parts -join ' '
    return $result
}

# Formats the command of every job that is not INVALID, one row per line:
#   <job> TAB program TAB <path>
#   <job> TAB arg TAB <value>             one per argument
#   <job> TAB cwd TAB <path>
#   <job> TAB cmdline TAB <string>        windows only
#   INVALID TAB <job> TAB <code>          when the command cannot be built
# A rejected configuration prints nothing.
function Format-VigilCommandDump {
    param(
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)]$Records,
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if ($Parsed.Errors.Count -gt 0) { return '' }
    $invalid = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($r in $Records) {
        if ($r.Kind -ceq 'ERROR') { return '' }
        if ($r.Kind -ceq 'INVALID') { [void]$invalid.Add($r.Job) }
    }

    $index = New-VigilConfigIndex -Parsed $Parsed
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $Parsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        $id = $sec.Name.Substring(4)
        if ($invalid.Contains($id)) { continue }
        $c = Get-VigilJobCommand -Index $index -Id $id -Platform $Platform -Root $Root
        if ($c.Error.Length -gt 0) {
            [void]$sb.Append("INVALID`t$id`t$($c.Error)`n")
            continue
        }
        [void]$sb.Append("$id`tprogram`t$($c.Program)`n")
        foreach ($a in $c.Args) { [void]$sb.Append("$id`targ`t$a`n") }
        [void]$sb.Append("$id`tcwd`t$($c.Cwd)`n")
        if ($Platform -ceq 'windows') { [void]$sb.Append("$id`tcmdline`t$($c.Line)`n") }
    }
    return $sb.ToString()
}
