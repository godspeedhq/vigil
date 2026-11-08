# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    What a Windows version brings that Vigil depends on (backlog 26, step 1).
.DESCRIPTION
    Prints one Markdown table row per item, for
    tests/integration/backends/reports/windows-compatibility.md. Changes
    nothing, needs no administrator, and runs on Windows PowerShell 2.0 and
    later, so that it can report a machine too old for Vigil:

        powershell -NoProfile -ExecutionPolicy Bypass -File Probe.ps1
#>

$ErrorActionPreference = 'Continue'
function Row { param([string]$Item, [string]$Value) Write-Output "| $Item | $Value |" }
function Has { param([string]$Name) if (Get-Command $Name -ErrorAction SilentlyContinue) { 'yes' } else { 'no' } }

$nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
Write-Output '| Item | Value |'
Write-Output '| --- | --- |'
Row 'Windows' "$($nt.ProductName), $($nt.InstallationType)"
# Windows 11 still calls itself Windows 10 in ProductName: the build tells.
$release = if ($nt.DisplayVersion) { $nt.DisplayVersion } elseif ($nt.ReleaseId) { $nt.ReleaseId } else { $nt.CurrentVersion }
Row 'Build' "$($nt.CurrentBuild).$($nt.UBR) ($release)"
Row 'Windows PowerShell' "$($PSVersionTable.PSVersion)"
Row 'PowerShell 7 (pwsh)' $(if (Get-Command pwsh -ErrorAction SilentlyContinue) { "$((Get-Command pwsh).Version)" } else { 'no' })

# .NET Framework 4.x: the Release value names the version.
$rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
$net = 'none'
if ($rel) {
    $net = 'below 4.5'
    foreach ($p in @(@(533320, '4.8.1'), @(528040, '4.8'), @(461808, '4.7.2'), @(461308, '4.7.1'), @(460798, '4.7'), @(394802, '4.6.2'), @(394254, '4.6.1'), @(393295, '4.6'), @(379893, '4.5.2'), @(378675, '4.5.1'), @(378389, '4.5'))) {
        if ($rel -ge $p[0]) { $net = $p[1]; break }
    }
    $net = "$net (release $rel)"
}
Row '.NET Framework' $net

# TLS: what this process offers by default, and what the registry says.
Row 'TLS protocols offered by default' "$([Net.ServicePointManager]::SecurityProtocol)"
Row 'TLS 1.2 known to .NET' $(if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls12') { 'yes' } else { 'no' })
foreach ($k in @(@('64-bit', 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'), @('32-bit', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319'))) {
    $v = (Get-ItemProperty $k[1] -ErrorAction SilentlyContinue).SchUseStrongCrypto
    Row "SchUseStrongCrypto, $($k[0]) .NET" $(if ($null -eq $v) { 'not set' } else { "$v" })
}
# A real HTTPS request, as Vigil makes them: TLS 1.2 added, the certificate
# checked by Windows.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $r = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 20 -Uri 'https://github.com/godspeedhq/vigil'
    Row 'HTTPS to github.com, TLS 1.2 on' "yes ($([int]$r.StatusCode))"
}
catch { Row 'HTTPS to github.com, TLS 1.2 on' "no: $($_.Exception.Message)" }

Row 'OpenSSH client (ssh)' (Has ssh)
Row 'curl.exe' (Has curl.exe)
Row 'tar.exe' (Has tar.exe)
Row 'git' (Has git)
try { [void](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop); Row 'WMI (CIM) from this session' 'yes' }
catch { Row 'WMI (CIM) from this session' "no: $($_.Exception.Message)" }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Row 'This session elevated' $(if ($admin) { 'yes' } else { 'no' })
Row 'Execution policy' "$(Get-ExecutionPolicy)"
