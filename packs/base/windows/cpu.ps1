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
        used_pct  percent of CPU time in use, across all cores

    Example output:
      metric used_pct 37

    Reading the results (starting points: tune them to the machine):
      Healthy  below 70: normal work, and short spikes to 100 are fine.
      Watch    70 to 90 for 15 minutes or more: little room left for a peak.
      Act      above 90 for 5 minutes or more: find what is using the CPU.

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

Add-Type -Namespace VigilPack -Name Cpu -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
'@

# Totals across all cores since boot; kernel time includes idle time.
function Read-Times {
    $idle = 0L; $kernel = 0L; $user = 0L
    if (-not [VigilPack.Cpu]::GetSystemTimes([ref]$idle, [ref]$kernel, [ref]$user)) { throw 'GetSystemTimes failed' }
    return @($idle, ($kernel + $user))
}

$first = Read-Times
Start-Sleep -Seconds 1
$second = Read-Times
$total = $second[1] - $first[1]
$busy = $total - ($second[0] - $first[0])
$percent = if ($total -gt 0) { [int][Math]::Round(100 * $busy / $total) } else { 0 }

Write-Output "metric used_pct $percent"
