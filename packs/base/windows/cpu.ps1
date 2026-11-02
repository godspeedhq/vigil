#Requires -Version 5.1

<#
.SYNOPSIS
    cpu.ps1 - CPU use on Windows
.DESCRIPTION
    Reads the total processor time from the Windows performance counters.
    CIM is used because the counters it reports have the same names in
    every language of Windows.

    Metrics:
        used_pct  percent of CPU time in use, across all cores

    Example output:
      metric used_pct 37

    Reading the results (starting points: tune them to the machine):
      Healthy  below 70: normal work, and short spikes to 100 are fine.
      Watch    70 to 90 for 15 minutes or more: little room left for a peak.
      Act      above 90 for 5 minutes or more: find what is using the CPU.

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

# _Total is the sum across all cores.
$processor = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"

Write-Output "metric used_pct $([int]$processor.PercentProcessorTime)"
