#Requires -Version 5.1

<#
.SYNOPSIS
    Runs the shared conformance suite against the PowerShell implementation.
.DESCRIPTION
    The bash twin is run-conformance.sh; both read the same cases and must
    pass the same expectations.

      tests/conformance/parser/<case>.config      input
      tests/conformance/parser/<case>.expected    Format-VigilConfigDump output
      tests/conformance/validate/<case>.config    input
      tests/conformance/validate/<case>.expected  Format-VigilValidationDump output
      tests/conformance/effective/<case>.config     input
      tests/conformance/effective/<case>.expected   validation dump, then
                                                    Format-VigilEffectiveDump
      tests/conformance/command/<case>.config       input; a name ending -windows
                                                    uses platform windows and root
                                                    C:\Program Files\Vigil, others
                                                    posix and /opt/vigil
      tests/conformance/command/<case>.expected     validation dump, then
                                                    Format-VigilCommandDump
      tests/conformance/schedule/<case>.config      input
      tests/conformance/schedule/<case>.table       decisions table, inputs and
                                                    expected decisions per row;
                                                    compared with comments and
                                                    blank lines dropped and
                                                    columns single-spaced
      tests/mocks/<path>.config                     the example configurations
      tests/conformance/mocks/<path>.expected       validation dump, then
                                                    Format-VigilEffectiveDump
      tests/conformance/recovery/<case>.table       rows of evidence and expected
                                                    Get-VigilRecoveryConclusion
      tests/conformance/outcome/<case>.table        rows of exit_codes, exit code
                                                    and expected Get-VigilOutcome
      tests/conformance/metrics/<case>.stdout       a run's stdout; -nagios in the
                                                    name parses perfdata, a
                                                    trailing -cap<n> sets the cap
      tests/conformance/metrics/<case>.expected     Format-VigilMetricsDump output
      tests/conformance/events/<case>.config        a configuration, with the run
                                                    in <case>.run and its output
                                                    in <case>.stdout
      tests/conformance/events/<case>.expected      Get-VigilRunEvents output
      tests/conformance/report/<suite>-<case>.expected
                                                    Format-VigilPrecheckReportDump
                                                    of each validate and effective case

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'app\lib\windows\Config.ps1')
. (Join-Path $root 'app\lib\windows\Validate.ps1')
. (Join-Path $root 'app\lib\windows\Effective.ps1')
. (Join-Path $root 'app\lib\windows\Command.ps1')
. (Join-Path $root 'app\lib\windows\Schedule.ps1')
. (Join-Path $root 'app\lib\windows\Outcome.ps1')
. (Join-Path $root 'app\lib\windows\Metrics.ps1')
. (Join-Path $root 'app\lib\windows\Events.ps1')
. (Join-Path $root 'app\lib\windows\Recovery.ps1')
. (Join-Path $root 'app\lib\windows\Prom.ps1')
. (Join-Path $root 'app\lib\windows\Secrets.ps1')
. (Join-Path $root 'app\lib\windows\Worker.ps1')
. (Join-Path $root 'app\lib\windows\Precheck.ps1')

$pass = 0
$fail = 0

Write-Host "PowerShell $($PSVersionTable.PSVersion)"

# Counts and reports one case, comparing without trailing newlines as the
# bash runner's $(...) does.
function Compare-Case {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Actual.TrimEnd("`n") -ceq $Expected.TrimEnd("`n")) {
        $Script:pass++
        Write-Host "  PASS  $Name"
        return
    }
    $Script:fail++
    Write-Host "  FAIL  $Name"
    $exp = $Expected.TrimEnd("`n").Split("`n")
    $act = $Actual.TrimEnd("`n").Split("`n")
    $max = [Math]::Max($exp.Length, $act.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $e = if ($i -lt $exp.Length) { $exp[$i] } else { '<none>' }
        $a = if ($i -lt $act.Length) { $act[$i] } else { '<none>' }
        if ($e -cne $a) {
            Write-Host "        line $($i + 1): expected [$($e -replace "`t", '\t')]"
            Write-Host "                 actual   [$($a -replace "`t", '\t')]"
        }
    }
}

foreach ($suite in @('parser', 'validate', 'effective', 'command', 'schedule')) {
    $cases = Get-ChildItem -LiteralPath (Join-Path $here "conformance\$suite") -Filter '*.config' |
        Sort-Object Name

    foreach ($case in $cases) {
        $name         = [System.IO.Path]::GetFileNameWithoutExtension($case.Name)
        $expectedPath = [System.IO.Path]::ChangeExtension($case.FullName, '.expected')

        $parsed = ConvertFrom-VigilConfig -Path $case.FullName
        if ($suite -eq 'parser') {
            $actual = Format-VigilConfigDump -Parsed $parsed
        }
        else {
            $records = Test-VigilConfig -Parsed $parsed
            $actual = Format-VigilValidationDump -Parsed $parsed -Records $records
            if ($suite -eq 'effective') {
                $actual += Format-VigilEffectiveDump -Parsed $parsed -Records $records
            }
            elseif ($suite -eq 'command') {
                if ($name.EndsWith('-windows')) { $platform = 'windows'; $installRoot = 'C:\Program Files\Vigil' }
                else { $platform = 'posix'; $installRoot = '/opt/vigil' }
                $actual += Format-VigilCommandDump -Parsed $parsed -Records $records -Platform $platform -Root $installRoot
            }
            elseif ($suite -eq 'schedule') {
                $expectedPath = [System.IO.Path]::ChangeExtension($case.FullName, '.table')
                $actual += Format-VigilScheduleTableDump -Parsed $parsed -Path $expectedPath
            }
        }
        if ($suite -eq 'schedule') {
            $rows = foreach ($line in [System.IO.File]::ReadAllLines($expectedPath)) {
                $c = Split-VigilScheduleRow $line
                if ($null -ne $c) { $c -join ' ' }
            }
            $expected = ($rows -join "`n") + "`n"
        }
        else {
            $expected = [System.IO.File]::ReadAllText($expectedPath)
        }

        Compare-Case "$suite/$name" $expected $actual
    }
}

# The report vigil precheck prints, for every validate and effective case:
# tests/conformance/report/<suite>-<case>.expected holds
# Format-VigilPrecheckReportDump.
foreach ($suite in @('validate', 'effective')) {
    foreach ($case in (Get-ChildItem -LiteralPath (Join-Path $here "conformance\$suite") -Filter '*.config' | Sort-Object Name)) {
        $name = "$suite-$([System.IO.Path]::GetFileNameWithoutExtension($case.Name))"
        $parsed = ConvertFrom-VigilConfig -Path $case.FullName
        $records = Test-VigilConfig -Parsed $parsed
        $actual = Format-VigilPrecheckReportDump -Parsed $parsed -Records $records
        Compare-Case "report/$name" ([System.IO.File]::ReadAllText((Join-Path $here "conformance\report\$name.expected"))) $actual
    }
}

# The example configurations in tests/mocks, every tier: each must give the
# validation and effective dumps recorded in tests/conformance/mocks.
$mockRoot = Join-Path $here 'mocks'
$mocks = Get-ChildItem -LiteralPath $mockRoot -Filter '*.config' -Recurse |
    ForEach-Object { $_.FullName.Substring($mockRoot.Length + 1).Replace('\', '/') } |
    Sort-Object
foreach ($rel in $mocks) {
    $name = $rel.Substring(0, $rel.Length - '.config'.Length)
    $parsed = ConvertFrom-VigilConfig -Path (Join-Path $mockRoot $rel)
    $records = Test-VigilConfig -Parsed $parsed
    $actual = (Format-VigilValidationDump -Parsed $parsed -Records $records) +
        (Format-VigilEffectiveDump -Parsed $parsed -Records $records)
    $expected = [System.IO.File]::ReadAllText((Join-Path $here "conformance\mocks\$name.expected"))
    Compare-Case "mocks/$name" $expected $actual
}

# Exit code classification: each table row is "<exit_codes> <code>
# <outcome>", and the case passes when every row gives its outcome.
foreach ($table in (Get-ChildItem -LiteralPath (Join-Path $here 'conformance\outcome') -Filter '*.table' | Sort-Object Name)) {
    $exp = New-Object System.Text.StringBuilder
    $act = New-Object System.Text.StringBuilder
    foreach ($line in [System.IO.File]::ReadAllLines($table.FullName)) {
        $c = @($line.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries))
        if ($c.Count -eq 0 -or $c[0].StartsWith('#')) { continue }
        [void]$exp.Append("$($c[0]) $($c[1]) $($c[2])`n")
        [void]$act.Append("$($c[0]) $($c[1]) $(Get-VigilOutcome -ExitCodes $c[0] -Code $c[1])`n")
    }
    Compare-Case "outcome/$($table.BaseName)" $exp.ToString() $act.ToString()
}

# Recovery conclusions: each table row is the evidence and the expected
# conclusion; the case passes when every row gives its conclusion.
foreach ($table in (Get-ChildItem -LiteralPath (Join-Path $here 'conformance\recovery') -Filter '*.table' | Sort-Object Name)) {
    $exp = New-Object System.Text.StringBuilder
    $act = New-Object System.Text.StringBuilder
    foreach ($line in [System.IO.File]::ReadAllLines($table.FullName)) {
        $c = @($line.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries))
        if ($c.Count -eq 0 -or $c[0].StartsWith('#')) { continue }
        [void]$exp.Append(($c[0..6] -join ' ') + "`n")
        $got = Get-VigilRecoveryConclusion -Launch $c[0] -Token $c[1] -Process $c[2] -Boot $c[3] -State $c[4] -Spool $c[5]
        [void]$act.Append(($c[0..5] -join ' ') + " $got`n")
    }
    Compare-Case "recovery/$($table.BaseName)" $exp.ToString() $act.ToString()
}

# Job output: <case>.stdout parsed with mode nagios when the name contains
# -nagios, and with the cap given by a trailing -cap<n>, else the default.
foreach ($out in (Get-ChildItem -LiteralPath (Join-Path $here 'conformance\metrics') -Filter '*.stdout' | Sort-Object Name)) {
    $name = $out.BaseName
    $mode = if ($name.Contains('-nagios')) { 'nagios' } else { 'standard' }
    $cap = $Script:VigilMetricLinesMax
    if ($name -cmatch '-cap([0-9]+)$') { $cap = [int]$Matches[1] }
    $actual = Format-VigilMetricsDump (ConvertFrom-VigilJobOutput -Mode $mode -Cap $cap -Path $out.FullName)
    $expected = [System.IO.File]::ReadAllText([System.IO.Path]::ChangeExtension($out.FullName, '.expected'))
    Compare-Case "metrics/$name" $expected $actual
}

# Run events: <case>.config, the run in <case>.run ("<key> <value>" lines:
# job, epoch, mode, outcome, exit_code, duration, host, os) and its output
# in <case>.stdout.
foreach ($case in (Get-ChildItem -LiteralPath (Join-Path $here 'conformance\events') -Filter '*.config' | Sort-Object Name)) {
    $run = @{}
    foreach ($line in [System.IO.File]::ReadAllLines([System.IO.Path]::ChangeExtension($case.FullName, '.run'))) {
        $kv = $line.Split([char[]]@(' ', "`t"), 2, [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($kv.Count -eq 2) { $run[$kv[0]] = $kv[1].Trim() }
    }
    $parsed = ConvertFrom-VigilConfig -Path $case.FullName
    $output = ConvertFrom-VigilJobOutput -Mode $run.mode -Cap $Script:VigilMetricLinesMax -Path ([System.IO.Path]::ChangeExtension($case.FullName, '.stdout'))
    $events = Get-VigilRunEvents -Parsed $parsed -Id $run.job -Epoch $run.epoch -Outcome $run.outcome -ExitCode $run.exit_code `
        -Duration $run.duration -HostName $run.host -Os $run.os -Output $output
    $actual = ($events | ForEach-Object { "$_`n" }) -join ''
    Compare-Case "events/$($case.BaseName)" ([System.IO.File]::ReadAllText([System.IO.Path]::ChangeExtension($case.FullName, '.expected'))) $actual
}

# File backend: <case>.prom (the file before, may be empty) merged with
# <case>.events must give <case>.expected.
foreach ($old in (Get-ChildItem -LiteralPath (Join-Path $here 'conformance\prom') -Filter '*.prom' | Sort-Object Name)) {
    $actual = Merge-VigilProm -Old $old.FullName -Events @([System.IO.Path]::ChangeExtension($old.FullName, '.events'))
    Compare-Case "prom/$($old.BaseName)" ([System.IO.File]::ReadAllText([System.IO.Path]::ChangeExtension($old.FullName, '.expected'))) $actual
}

# File-level cases need inputs that cannot be committed as fixtures: a
# missing file, and files at and over the 1 MiB limit (all "a", no newline,
# so a file at the limit is read and reports one E_NO_EQUALS).
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-conformance.$PID"
[void](New-Item -ItemType Directory -Force -Path $tmp)
$atLimit = [System.Text.Encoding]::ASCII.GetBytes('a' * $Script:VigilConfigMaxBytes)
[System.IO.File]::WriteAllBytes((Join-Path $tmp 'at-limit.config'), $atLimit)
[System.IO.File]::WriteAllBytes((Join-Path $tmp 'over-limit.config'), $atLimit + [byte]97)
$checks = @(
    @('missing', "ERROR`t0`tE_FILE_NOT_FOUND"),
    @('at-limit', "ERROR`t1`tE_NO_EQUALS"),
    @('over-limit', "ERROR`t0`tE_FILE_TOO_LARGE")
)
foreach ($check in $checks) {
    $actual = (Format-VigilConfigDump -Parsed (ConvertFrom-VigilConfig -Path (Join-Path $tmp "$($check[0]).config"))).TrimEnd("`n")
    if ($actual -ceq $check[1]) {
        $pass++
        Write-Host "  PASS  file/$($check[0])"
    }
    else {
        $fail++
        Write-Host "  FAIL  file/$($check[0]): expected [$($check[1])] actual [$actual]"
    }
}
# A run printing more metric lines than the default cap: the excess is
# dropped and counted.
$flood = Join-Path $tmp 'flood.stdout'
[System.IO.File]::WriteAllText($flood, ("metric m 1`n" * ($Script:VigilMetricLinesMax + 5)))
$summary = (Format-VigilMetricsDump (ConvertFrom-VigilJobOutput -Mode 'standard' -Cap $Script:VigilMetricLinesMax -Path $flood)).TrimEnd("`n").Split("`n")[-1]
Compare-Case 'file/metric-flood' "SUMMARY metric_lines=$($Script:VigilMetricLinesMax) invalid_lines=0 dropped_lines=5" $summary
Remove-Item -Recurse -Force -LiteralPath $tmp

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
