#Requires -Version 5.1

<#
.SYNOPSIS
    memory.ps1 - memory use on Windows
.DESCRIPTION
    Reports physical memory in use, from the kernel (GlobalMemoryStatusEx),
    not WMI, which refuses a standard user whose Vigil was started over SSH.

    Metrics:
        used_pct     percent of memory in use
        used_bytes   memory in use, in bytes
        total_bytes  installed memory, in bytes

    Example output:
      metric used_pct 62
      metric used_bytes 10637131776
      metric total_bytes 17179869184

    Reading the results (starting points: tune them to the machine):
      Healthy  below 80: room for peaks.
      Watch    80 to 90, or used_bytes climbing steadily, which can mean a leak.
      Act      above 90 for 5 minutes or more: the machine may start to swap,
               or the system may stop processes to free memory.

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

Add-Type -Namespace VigilPack -Name Memory -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct Status {
    public uint Length; public uint Load;
    public ulong TotalPhys; public ulong AvailPhys;
    public ulong TotalPageFile; public ulong AvailPageFile;
    public ulong TotalVirtual; public ulong AvailVirtual; public ulong AvailExtendedVirtual;
}
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GlobalMemoryStatusEx(ref Status status);
'@

$status = New-Object VigilPack.Memory+Status
$status.Length = [System.Runtime.InteropServices.Marshal]::SizeOf($status)
if (-not [VigilPack.Memory]::GlobalMemoryStatusEx([ref]$status)) { throw 'GlobalMemoryStatusEx failed' }

# Available memory is what can be had without swapping: the rest is in use.
$total = [long]$status.TotalPhys
$used = $total - [long]$status.AvailPhys
$percent = [int][Math]::Floor(100 * $used / $total)

Write-Output "metric used_pct $percent"
Write-Output "metric used_bytes $used"
Write-Output "metric total_bytes $total"
