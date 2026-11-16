#Requires -Version 5.1

<#
.SYNOPSIS
    cpu.ps1 - CPU use on Windows
.DESCRIPTION
    Reads the system's idle, kernel and user time twice, one second apart,
    and reports the share of that second the CPU spent working. From the
    kernel (GetSystemTimes), not WMI: WMI refuses a standard user whose
    Vigil was started over SSH, and the kernel's answer has no names to
    differ between languages of Windows.

    Metrics:
        used_pct    percent of CPU time in use, across all cores
        user_pct    of which running programs
        system_pct  of which the kernel (and its interrupts)
        iowait_pct and steal_pct are not reported: Windows does not count
        them

    Example output:
      metric used_pct 37
      metric user_pct 26
      metric system_pct 11

    Reading the results (starting points: tune them to the machine):
      Healthy  below 70: normal work, and short spikes to 100 are fine.
      Watch    70 to 90 for 15 minutes or more: little room left for a peak.
      Act      above 90 for 5 minutes or more: find what is using the CPU
               (system.processes).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, 1 if the data cannot be read
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

# GetSystemTimes, built in memory with Reflection.Emit rather than Add-Type,
# which would start the C# compiler on every run. Each one-element array
# holds one of its three FILETIME results.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'VigilPackCpu'), 'Run')
$type = $asm.DefineDynamicModule('VigilPackCpu').DefineType('VigilPackCpu', 'Public, Class, Abstract, Sealed')
$call = $type.DefinePInvokeMethod('GetSystemTimes', 'kernel32.dll', 'Public, Static, PinvokeImpl', 'Standard',
    [bool], [type[]]@([long[]], [long[]], [long[]]), 'Winapi', 'Unicode')
$call.SetImplementationFlags('PreserveSig')
$kernel32 = $type.CreateType()

# Totals across all cores since boot; kernel time includes idle time.
function Read-Times {
    $idle = New-Object long[] 1; $kernel = New-Object long[] 1; $user = New-Object long[] 1
    if (-not $kernel32::GetSystemTimes($idle, $kernel, $user)) { throw 'GetSystemTimes failed' }
    return @($idle[0], $kernel[0], $user[0])
}

$first = Read-Times
Start-Sleep -Seconds 1
$second = Read-Times
$idle = $second[0] - $first[0]
$kernel = $second[1] - $first[1] - $idle
$user = $second[2] - $first[2]
$total = $idle + $kernel + $user
function Get-Percent([long]$Part) { if ($total -gt 0) { [int][Math]::Round(100 * $Part / $total) } else { 0 } }

Write-Output "metric used_pct $(Get-Percent ($kernel + $user))"
Write-Output "metric user_pct $(Get-Percent $user)"
Write-Output "metric system_pct $(Get-Percent $kernel)"
