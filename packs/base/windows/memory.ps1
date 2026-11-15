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

# GlobalMemoryStatusEx, built in memory with Reflection.Emit rather than
# Add-Type, which would start the C# compiler on every run. Its
# MEMORYSTATUSEX is 64 bytes: dwLength (set to 64), dwMemoryLoad, then
# ullTotalPhys at 8 and ullAvailPhys at 16.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'VigilPackMemory'), 'Run')
$type = $asm.DefineDynamicModule('VigilPackMemory').DefineType('VigilPackMemory', 'Public, Class, Abstract, Sealed')
$call = $type.DefinePInvokeMethod('GlobalMemoryStatusEx', 'kernel32.dll', 'Public, Static, PinvokeImpl', 'Standard',
    [bool], [type[]]@(, [byte[]]), 'Winapi', 'Unicode')
$call.SetImplementationFlags('PreserveSig')
$kernel32 = $type.CreateType()

$status = New-Object byte[] 64
[BitConverter]::GetBytes([uint32]64).CopyTo($status, 0)
if (-not $kernel32::GlobalMemoryStatusEx($status)) { throw 'GlobalMemoryStatusEx failed' }

# Available memory is what can be had without swapping: the rest is in use.
$total = [long][BitConverter]::ToUInt64($status, 8)
$used = $total - [long][BitConverter]::ToUInt64($status, 16)
$percent = [int][Math]::Floor(100 * $used / $total)

Write-Output "metric used_pct $percent"
Write-Output "metric used_bytes $used"
Write-Output "metric total_bytes $total"
