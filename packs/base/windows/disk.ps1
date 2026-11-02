# disk.ps1 - each local drive's use.
foreach ($d in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3') {
    if (-not $d.Size) { continue }
    $total = [long]$d.Size
    $used = $total - [long]$d.FreeSpace
    Write-Output "metric used_pct $([int][Math]::Floor(100 * $used / $total)) mount=$($d.DeviceID)"
    Write-Output "metric used_bytes $used mount=$($d.DeviceID)"
    Write-Output "metric total_bytes $total mount=$($d.DeviceID)"
}
