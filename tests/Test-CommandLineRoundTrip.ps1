#Requires -Version 5.1

<#
.SYNOPSIS
    Checks Vigil's Windows command-line encoding against Windows itself.
.DESCRIPTION
    The command conformance cases compare both implementations with expected
    files, which only proves they agree with each other. This test is the
    independent check: for every job in tests/conformance/command/*-windows,
    it parses the generated Arguments string back with CommandLineToArgvW -
    the Windows API with the same rules as the Microsoft C runtime that most
    programs use - and requires exactly the original argument vector.

    Windows only. Uses Add-Type for the API declaration; that is test code
    and is never shipped.

    Exit code: 0 all round-trips exact, 1 any mismatch.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'app\lib\windows\Config.ps1')
. (Join-Path $root 'app\lib\windows\Validate.ps1')
. (Join-Path $root 'app\lib\windows\Effective.ps1')
. (Join-Path $root 'app\lib\windows\Command.ps1')

Add-Type -Namespace VigilTest -Name Native -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
static extern System.IntPtr CommandLineToArgvW(
    [MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
[DllImport("kernel32.dll")]
static extern System.IntPtr LocalFree(System.IntPtr hMem);
public static string[] Split(string commandLine) {
    int n;
    System.IntPtr argv = CommandLineToArgvW(commandLine, out n);
    try {
        string[] result = new string[n];
        for (int i = 0; i < n; i++) {
            result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * System.IntPtr.Size));
        }
        return result;
    }
    finally { LocalFree(argv); }
}
'@

$pass = 0
$fail = 0
$cases = Get-ChildItem -LiteralPath (Join-Path $here 'conformance\command') -Filter '*-windows.config' | Sort-Object Name
foreach ($case in $cases) {
    $parsed = ConvertFrom-VigilConfig -Path $case.FullName
    $index = New-VigilConfigIndex -Parsed $parsed
    foreach ($sec in $parsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        $id = $sec.Name.Substring(4)
        $c = Get-VigilJobCommand -Index $index -Id $id -Platform 'windows' -Root 'C:\Program Files\Vigil'
        if ($c.Error.Length -gt 0) { continue }

        # A placeholder program name: the first token follows different rules
        # and is passed separately (ProcessStartInfo.FileName).
        $argv = [VigilTest.Native]::Split("x $($c.Line)")
        $actual = @($argv | Select-Object -Skip 1)
        $expected = @($c.Args)
        $same = $actual.Count -eq $expected.Count
        for ($i = 0; $same -and $i -lt $expected.Count; $i++) {
            if ($actual[$i] -cne $expected[$i]) { $same = $false }
        }
        if ($same) {
            $pass++
            Write-Host "  PASS  $($case.BaseName)/$id ($($expected.Count) args)"
        }
        else {
            $fail++
            Write-Host "  FAIL  $($case.BaseName)/$id"
            Write-Host "        expected: [$($expected -join '] [')]"
            Write-Host "        actual:   [$($actual -join '] [')]"
        }
    }
}

Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
