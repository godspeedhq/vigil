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

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'app\lib\Config.ps1')
. (Join-Path $root 'app\lib\Validate.ps1')
. (Join-Path $root 'app\lib\Effective.ps1')
. (Join-Path $root 'app\lib\Command.ps1')
. (Join-Path $root 'app\lib\Schedule.ps1')

$pass = 0
$fail = 0

Write-Host "PowerShell $($PSVersionTable.PSVersion)"

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

        # Compare without trailing newlines, as the bash runner's $(...) does.
        if ($actual.TrimEnd("`n") -ceq $expected.TrimEnd("`n")) {
            $pass++
            Write-Host "  PASS  $suite/$name"
        }
        else {
            $fail++
            Write-Host "  FAIL  $suite/$name"
            $exp = $expected.TrimEnd("`n").Split("`n")
            $act = $actual.TrimEnd("`n").Split("`n")
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
    }
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
Remove-Item -Recurse -Force -LiteralPath $tmp

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
