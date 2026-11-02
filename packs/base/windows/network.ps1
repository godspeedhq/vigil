#Requires -Version 5.1

<#
.SYNOPSIS
    network.ps1 - network traffic on Windows
.DESCRIPTION
    Reports the bytes each network interface has moved since it started.
    These are running totals: graph them as a rate.

    Metrics:
        rx_bytes  bytes received (tag: iface)
        tx_bytes  bytes sent (tag: iface)

    Example output:
      metric rx_bytes 1415005394 iface=Ethernet
      metric tx_bytes 283001078 iface=Ethernet

    Reading the results (starting points: tune them to the machine):
      These are running totals, so there is no good or bad value: graph the rate
      of change, and compare it with the speed of the link and your usual level.
      Healthy  steady, and well below the speed of the link.
      Watch    above 70 percent of the speed of the link for 15 minutes or more.
      Act      close to the speed of the link, or no traffic at all on an
               interface that should be busy. Totals restart after a reboot.

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

# The raw class holds the running totals. Despite their names, these counters
# are totals here: only the formatted class turns them into a rate.
foreach ($interface in Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface) {
    # A metric tag cannot hold a space, and interface names often do.
    $name = $interface.Name -replace '[^A-Za-z0-9_.-]', '_'

    Write-Output "metric rx_bytes $([long]$interface.BytesReceivedPersec) iface=$name"
    Write-Output "metric tx_bytes $([long]$interface.BytesSentPersec) iface=$name"
}
