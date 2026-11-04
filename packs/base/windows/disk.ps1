#Requires -Version 5.1

<#
.SYNOPSIS
    disk.ps1 - drive use on Windows
.DESCRIPTION
    Reports each local fixed drive, one set of metrics per drive letter.
    Network, optical and removable drives are left out. From .NET's drive
    information, not WMI, which refuses a standard user whose Vigil was
    started over SSH.

    Metrics:
        used_pct     percent of the drive in use (tag: mount)
        used_bytes   space in use, in bytes (tag: mount)
        total_bytes  size of the drive, in bytes (tag: mount)

    Example output:
      metric used_pct 71 mount=C:
      metric used_bytes 305175781376 mount=C:
      metric total_bytes 429496729600 mount=C:

    Reading the results (starting points: tune them to the machine):
      Healthy  below 80.
      Watch    80 to 90, or used_bytes growing fast: work out when it fills up.
      Act      above 90: free some space. At 100, writes fail, and databases
               and logs usually go with them.

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

foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
    # A drive with no file system is not ready, and has no size.
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady -or -not $drive.TotalSize) { continue }

    $total = [long]$drive.TotalSize
    # TotalFreeSpace, not AvailableFreeSpace: what is used, whatever this
    # account's quota.
    $used = $total - [long]$drive.TotalFreeSpace
    $percent = [int][Math]::Floor(100 * $used / $total)
    # C:\ as C:, the drive letter alone.
    $mount = $drive.Name.TrimEnd('\')

    Write-Output "metric used_pct $percent mount=$mount"
    Write-Output "metric used_bytes $used mount=$mount"
    Write-Output "metric total_bytes $total mount=$mount"
}
