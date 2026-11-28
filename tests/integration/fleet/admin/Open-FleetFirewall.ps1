# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Open-FleetFirewall.ps1 [-Remove] - on the machine running the fleet test's
# backend (Windows), in PowerShell as Administrator: lets the fleet's
# machines reach it, on the private network only and only from the
# subnets given (default the test machines', 192.168.4.0/24 and
# 192.168.5.0/24): TCP 8443 (Gitea), 4318 (OTLP) and 3000 (Grafana).
# -Remove deletes exactly these rules. Its log goes beside it.
param([switch]$Remove, [string[]]$From = @('192.168.4.0/24', '192.168.5.0/24'))
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot "Open-FleetFirewall-$env:COMPUTERNAME.log") -Force | Out-Null
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Not elevated: right-click PowerShell, Run as administrator, then run this again.' }
    $rules = @{ 'Vigil fleet test: Gitea' = 8443; 'Vigil fleet test: OTLP' = 4318; 'Vigil fleet test: Grafana' = 3000 }
    foreach ($name in $rules.Keys) {
        Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        if ($Remove) { "Removed: $name"; continue }
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rules[$name] `
            -RemoteAddress $From -Profile Private | Out-Null
        "Allowed: $name, TCP $($rules[$name]), from $($From -join ', '), private networks"
    }
    $net = Get-NetConnectionProfile | Select-Object -First 1
    "This machine's network: $($net.Name), $($net.NetworkCategory)$(if ($net.NetworkCategory -ne 'Private') { ' - the rules apply to Private networks only: make this one Private (Settings, Network)' })"
} catch {
    "FAILED: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
