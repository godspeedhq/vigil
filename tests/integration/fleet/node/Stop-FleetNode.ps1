# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Stop-FleetNode.ps1
# Stops the fleet test's bare-metal Vigil supervisor on this machine: only a
# PowerShell process whose command line names C:\Users\vigil-test\vigil-fleet-node
# and "supervise". Over SSH it cannot be stopped (Access denied), so run this
# in PowerShell as Administrator. Its workers finish on their own. Its log
# goes beside it: Stop-FleetNode.log.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'Stop-FleetNode.log') -Force | Out-Null
try {
    $root = 'C:\Users\vigil-test\vigil-fleet-node'
    $procs = @(Get-CimInstance Win32_Process | Where-Object {
            ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'pwsh.exe') -and $_.CommandLine -and
            $_.CommandLine.Contains($root) -and $_.CommandLine -match '\ssupervise(\s|$)' })
    if (-not $procs) { 'no fleet supervisor running' }
    foreach ($p in $procs) {
        "stopping $($p.ProcessId): $($p.CommandLine)"
        Stop-Process -Id $p.ProcessId -Force
    }
    Start-Sleep -Seconds 3
    $left = @($procs | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
    if ($left) { "FAILED: still running: $(($left | ForEach-Object ProcessId) -join ', ')" } else { "stopped $($procs.Count)" }
} catch {
    "FAILED: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
