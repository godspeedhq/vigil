#Requires -Version 5.1

<#
.SYNOPSIS
    host.ps1 - what this machine is, and how long it has been up, on Windows
.DESCRIPTION
    Reports the time since boot, the number of processes and of logical
    cores, and one info metric whose tags say what the machine runs, from
    the kernel and the registry, not WMI, which refuses a standard user
    whose Vigil was started over SSH. Tag values cannot hold spaces: a space
    becomes _.

    Metrics:
        uptime_seconds  seconds since the machine started
        process_count   processes running now
        cores           logical cores (hardware threads)
        info            always 1 (tags: os_name, os_version, kernel,
                        cpu_model). os_version is the release (23H2, or
                        1607 on Server 2016), kernel the build
                        (10.0.22631.6199)

    Example output:
      metric uptime_seconds 1052642
      metric process_count 312
      metric cores 8
      metric info 1 os_name=Windows_11_Pro os_version=23H2 kernel=10.0.22631.6199 cpu_model=Intel(R)_Core(TM)_i7-6700HQ_CPU_@_2.60GHz

    Reading the results (starting points: tune them to the machine):
      uptime_seconds  going back to near 0 is a restart: expected after
                      updates, worth a look otherwise.
      process_count   steady for the machine; climbing without end usually
                      means processes are started and never end.
      info            a changed kernel shows an update took.

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

# GetTickCount64, built in memory with Reflection.Emit rather than Add-Type,
# which would start the C# compiler on every run. Environment.TickCount
# wraps after 24.9 days.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'VigilPackHost'), 'Run')
$type = $asm.DefineDynamicModule('VigilPackHost').DefineType('VigilPackHost', 'Public, Class, Abstract, Sealed')
$call = $type.DefinePInvokeMethod('GetTickCount64', 'kernel32.dll', 'Public, Static, PinvokeImpl', 'Standard',
    [uint64], [type[]]@(), 'Winapi', 'Unicode')
$call.SetImplementationFlags('PreserveSig')
$kernel32 = $type.CreateType()

# A tag value: spaces become _, and an empty one is "unknown".
function ConvertTo-Tag([string]$Value) {
    $v = ($Value -replace '[\x00-\x20"'']+', '_').Trim('_')
    if ($v) { $v } else { 'unknown' }
}

$version = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$name = [string]$version.ProductName
$build = [int]$version.CurrentBuild
# Windows 11 still calls itself Windows 10 here: its builds start at 22000.
if ($build -ge 22000 -and $version.InstallationType -eq 'Client') { $name = $name -replace '^Windows 10', 'Windows 11' }
# DisplayVersion (23H2) since 20H2; ReleaseId (1607, 1809) before it.
$release = if ($version.DisplayVersion) { $version.DisplayVersion } elseif ($version.ReleaseId) { $version.ReleaseId } else { '' }
$kernel = "$($version.CurrentMajorVersionNumber).$($version.CurrentMinorVersionNumber).$build.$($version.UBR)"
$model = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString

Write-Output "metric uptime_seconds $([long]($kernel32::GetTickCount64() / 1000))"
Write-Output "metric process_count $([System.Diagnostics.Process]::GetProcesses().Count)"
Write-Output "metric cores $([Environment]::ProcessorCount)"
Write-Output "metric info 1 os_name=$(ConvertTo-Tag $name) os_version=$(ConvertTo-Tag $release) kernel=$(ConvertTo-Tag $kernel) cpu_model=$(ConvertTo-Tag $model)"
