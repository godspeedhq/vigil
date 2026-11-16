#Requires -Version 5.1

<#
.SYNOPSIS
    network.ps1 - network traffic on Windows
.DESCRIPTION
    Reports what each network interface has moved since it started.
    These are running totals: graph them as a rate. Loopback and tunnel
    interfaces, and interfaces that have moved nothing, are left out. From
    .NET's network information, not WMI, which refuses a standard user
    whose Vigil was started over SSH; an interface is named as Windows
    shows it (Ethernet, Wi-Fi).

    Metrics:
        rx_bytes    bytes received (tag: iface)
        tx_bytes    bytes sent (tag: iface)
        rx_packets  packets received (tag: iface)
        tx_packets  packets sent (tag: iface)
        rx_errors   received packets with errors (tag: iface)
        tx_errors   packets that failed to send (tag: iface)
        rx_drops    received packets discarded (tag: iface)
        tx_drops    packets discarded before sending (tag: iface)

    Example output:
      metric rx_bytes 1415005394 iface=Ethernet
      metric tx_bytes 283001078 iface=Ethernet
      metric rx_packets 1872264 iface=Ethernet
      metric tx_packets 940124 iface=Ethernet
      metric rx_errors 0 iface=Ethernet
      metric tx_errors 0 iface=Ethernet
      metric rx_drops 12 iface=Ethernet
      metric tx_drops 0 iface=Ethernet

    Reading the results (starting points: tune them to the machine):
      These are running totals, so there is no good or bad value: graph the rate
      of change, and compare it with the speed of the link and your usual level.
      Healthy  steady, and well below the speed of the link; errors at 0.
      Watch    above 70 percent of the link speed for 15 minutes or more, or
               errors or drops rising.
      Act      close to the link speed, no traffic where there should be some,
               or errors rising steadily: a cable, a port or a driver. Totals
               restart after a reboot.

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

$skip = @([System.Net.NetworkInformation.NetworkInterfaceType]::Loopback, [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel)
foreach ($interface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($skip -contains $interface.NetworkInterfaceType) { continue }
    # IPv4 and IPv6 together, since the interface came up.
    $stats = $interface.GetIPStatistics()
    # An interface that has moved nothing (a VPN that is off) is left out.
    if ([long]$stats.BytesReceived + [long]$stats.BytesSent -eq 0) { continue }
    # A metric tag cannot hold a space, and interface names often do.
    $name = $interface.Name -replace '[^A-Za-z0-9_.-]', '_'

    Write-Output "metric rx_bytes $([long]$stats.BytesReceived) iface=$name"
    Write-Output "metric tx_bytes $([long]$stats.BytesSent) iface=$name"
    Write-Output "metric rx_packets $([long]$stats.UnicastPacketsReceived + [long]$stats.NonUnicastPacketsReceived) iface=$name"
    Write-Output "metric tx_packets $([long]$stats.UnicastPacketsSent + [long]$stats.NonUnicastPacketsSent) iface=$name"
    Write-Output "metric rx_errors $([long]$stats.IncomingPacketsWithErrors) iface=$name"
    Write-Output "metric tx_errors $([long]$stats.OutgoingPacketsWithErrors) iface=$name"
    Write-Output "metric rx_drops $([long]$stats.IncomingPacketsDiscarded) iface=$name"
    Write-Output "metric tx_drops $([long]$stats.OutgoingPacketsDiscarded) iface=$name"
}
