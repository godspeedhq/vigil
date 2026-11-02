# memory.ps1 - memory in use.
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$total = [long]$os.TotalVisibleMemorySize * 1024
$used = $total - [long]$os.FreePhysicalMemory * 1024
Write-Output "metric used_pct $([int][Math]::Floor(100 * $used / $total))"
Write-Output "metric used_bytes $used"
Write-Output "metric total_bytes $total"
