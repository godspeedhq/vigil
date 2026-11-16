#Requires -Version 5.1

<#
.SYNOPSIS
    diskio.ps1 - disk reads and writes on Windows
.DESCRIPTION
    Reports what each physical disk has read and written since it started,
    from the disk driver's own counters (IOCTL_DISK_PERFORMANCE), which a
    standard user may read, where WMI refuses one whose Vigil was started
    over SSH. These are running totals: graph them as a rate.

    Metrics:
        read_bytes   bytes read (tag: disk)
        write_bytes  bytes written (tag: disk)
        reads        reads completed (tag: disk)
        writes       writes completed (tag: disk)
        busy_ms is not reported: the driver counts idle time only since
        the disk arrived, so busy time cannot be told apart for one added
        later

    Example output:
      metric read_bytes 1368534375936 disk=PhysicalDrive0
      metric write_bytes 417119243264 disk=PhysicalDrive0
      metric reads 73993279 disk=PhysicalDrive0
      metric writes 14359573 disk=PhysicalDrive0

    Reading the results (starting points: tune them to the machine):
      These are running totals, so there is no good or bad value: graph the
      rate of change against your usual level. A rate far above it, for
      long, is worth finding the reason for (system.processes). Totals
      restart after a reboot; reads and writes also restart after 4294967295.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, 1 if no disk can be read
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

# CreateFileW, DeviceIoControl and CloseHandle, built in memory with
# Reflection.Emit rather than Add-Type, which would start the C# compiler
# on every run.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'VigilPackDiskIo'), 'Run')
$type = $asm.DefineDynamicModule('VigilPackDiskIo').DefineType('VigilPackDiskIo', 'Public, Class, Abstract, Sealed')
foreach ($m in @(
        @('CreateFileW', [IntPtr], @([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr])),
        @('DeviceIoControl', [bool], @([IntPtr], [uint32], [IntPtr], [uint32], [byte[]], [uint32], [uint32[]], [IntPtr])),
        @('CloseHandle', [bool], @(, [IntPtr])))) {
    $call = $type.DefinePInvokeMethod($m[0], 'kernel32.dll', 'Public, Static, PinvokeImpl', 'Standard',
        $m[1], [type[]]$m[2], 'Winapi', 'Unicode')
    $call.SetImplementationFlags('PreserveSig')
}
$kernel32 = $type.CreateType()

$IOCTL_DISK_PERFORMANCE = 0x70020
$OPEN_EXISTING = 3
$SHARE_READ_WRITE = 3
$invalid = [IntPtr](-1)

$found = 0
# Disks are numbered from 0, with gaps where one was removed.
for ($n = 0; $n -lt 32; $n++) {
    # Access 0: to ask the driver, not to read the disk.
    $handle = $kernel32::CreateFileW("\\.\PhysicalDrive$n",0, $SHARE_READ_WRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
    if ($handle -eq $invalid) { continue }
    # DISK_PERFORMANCE: BytesRead at 0, BytesWritten at 8, ReadCount at 40
    # and WriteCount at 44, in 88 bytes.
    $perf = New-Object byte[] 88
    $returned = New-Object uint32[] 1
    try { $ok = $kernel32::DeviceIoControl($handle, $IOCTL_DISK_PERFORMANCE, [IntPtr]::Zero, 0, $perf, 88, $returned, [IntPtr]::Zero) }
    finally { [void]$kernel32::CloseHandle($handle) }
    if (-not $ok) { continue }
    $found++
    $disk = "PhysicalDrive$n"
    Write-Output "metric read_bytes $([BitConverter]::ToInt64($perf, 0)) disk=$disk"
    Write-Output "metric write_bytes $([BitConverter]::ToInt64($perf, 8)) disk=$disk"
    Write-Output "metric reads $([BitConverter]::ToUInt32($perf, 40)) disk=$disk"
    Write-Output "metric writes $([BitConverter]::ToUInt32($perf, 44)) disk=$disk"
}
if ($found -eq 0) {
    [Console]::Error.WriteLine('diskio: no disk answered: none could be opened, or its driver keeps no counters')
    exit 1
}
