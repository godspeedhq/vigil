# cpu.ps1 - CPU use, from the performance counters.
$c = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
Write-Output "metric used_pct $([int]$c.PercentProcessorTime)"
