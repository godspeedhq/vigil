# network.ps1 - bytes each interface has moved since it started.
foreach ($n in Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface) {
    $name = $n.Name -replace '[^A-Za-z0-9_.-]', '_'
    Write-Output "metric rx_bytes $([long]$n.BytesReceivedPersec) iface=$name"
    Write-Output "metric tx_bytes $([long]$n.BytesSentPersec) iface=$name"
}
