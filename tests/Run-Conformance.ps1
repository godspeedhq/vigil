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

    Exit code: 0 all passed, 1 any failed.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'app\lib\Config.ps1')
. (Join-Path $root 'app\lib\Validate.ps1')
. (Join-Path $root 'app\lib\Effective.ps1')
. (Join-Path $root 'app\lib\Command.ps1')

$pass = 0
$fail = 0

Write-Host "PowerShell $($PSVersionTable.PSVersion)"

foreach ($suite in @('parser', 'validate', 'effective', 'command')) {
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
        }
        $expected = [System.IO.File]::ReadAllText($expectedPath)

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

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
