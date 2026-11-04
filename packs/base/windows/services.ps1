#Requires -Version 5.1

<#
.SYNOPSIS
    services.ps1 - failed services on Windows
.DESCRIPTION
    Reports how many services set to start automatically are stopped after
    an error. A service stopped on purpose exits with code 0 and is not
    counted. From the service manager (Get-Service, and sc.exe for a stopped
    service's exit code), not WMI, which refuses a standard user whose Vigil
    was started over SSH.

    Metrics:
        failed  number of failed services

    Example output:
      metric failed 0

    Reading the results (starting points: tune them to the machine):
      Healthy  0, or steady at the usual number for this machine: a few services
               stop themselves with an error and do no harm.
      Act      higher than usual. To see which, run Get-Service, look for
               StartType Automatic and Status Stopped, and run sc.exe query
               on each: a WIN32_EXIT_CODE that is not 0 counts.

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

# Automatic includes delayed starts, as WMI's StartMode Auto did. The
# service manager refuses a standard user under a network logon (Vigil
# started over SSH), and no other source has the services' state: say so.
try { $all = @(Get-Service -ErrorAction Stop) }
catch {
    [Console]::Error.WriteLine('services: the service manager refuses this account here (a network logon, such as an SSH session, as a standard user): run Vigil as a service (--system), or from a desktop logon')
    exit 1
}
$stopped = @($all | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Stopped' })
$failed = 0
foreach ($service in $stopped) {
    # sc.exe's labels are the same in every language of Windows.
    $out = & sc.exe query $service.ServiceName 2>&1
    $line = @($out | Where-Object { "$_" -match '^\s*WIN32_EXIT_CODE\s*:\s*(\d+)' })[0]
    if ($line -and "$line" -match ':\s*(\d+)' -and [int]$Matches[1] -ne 0) { $failed++ }
}

Write-Output "metric failed $failed"
