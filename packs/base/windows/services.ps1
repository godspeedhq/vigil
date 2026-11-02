# services.ps1 - services set to start on their own that stopped with an error.
$failed = @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode='Auto' AND State='Stopped'" |
        Where-Object { $_.ExitCode -ne 0 }).Count
Write-Output "metric failed $failed"
