# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Trust-TestCA.ps1 [-Remove] - on a Windows machine of the fleet test, in
# PowerShell as Administrator: adds the fleet test's CA (ca.crt, beside this
# script) to the machine's trusted roots, so Vigil and Git there trust the
# backend's certificate; -Remove takes it out again, by its thumbprint, and
# nothing else. Its log goes beside it: Trust-TestCA-<computer>.log.
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot "Trust-TestCA-$env:COMPUTERNAME.log") -Force | Out-Null
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Not elevated: right-click PowerShell, Run as administrator, then run this again.' }
    $file = Join-Path $PSScriptRoot 'ca.crt'
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $file
    if ($cert.Subject -ne 'CN=Vigil fleet test CA') { throw "ca.crt is not the fleet test CA: $($cert.Subject)" }
    "CA: $($cert.Subject), thumbprint $($cert.Thumbprint), until $($cert.NotAfter)"
    $there = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $cert.Thumbprint
    if ($Remove) {
        if ($there) { $there | Remove-Item; 'Removed from the trusted roots.' } else { 'It was not there: nothing to remove.' }
    } else {
        if ($there) { 'Already trusted.' } else { Import-Certificate -FilePath $file -CertStoreLocation Cert:\LocalMachine\Root | Out-Null; 'Added to the trusted roots.' }
    }
} catch {
    "FAILED: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
