#Requires -Version 5.1

<#
.SYNOPSIS
    services.ps1 - failed services on Windows
.DESCRIPTION
    Reports how many services set to start automatically are stopped after
    an error. A service stopped on purpose exits with code 0 and is not
    counted.

    Metrics:
        failed  number of failed services

    Example output:
      metric failed 0

    Reading the results (starting points: tune them to the machine):
      Healthy  0, or steady at the usual number for this machine: a few services
               stop themselves with an error and do no harm.
      Act      higher than usual. To see which, run Get-CimInstance Win32_Service
               and look for StartMode Auto, State Stopped and ExitCode not 0.

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

$stopped = Get-CimInstance -ClassName Win32_Service -Filter "StartMode='Auto' AND State='Stopped'"
$failed = @($stopped | Where-Object { $_.ExitCode -ne 0 }).Count

Write-Output "metric failed $failed"
