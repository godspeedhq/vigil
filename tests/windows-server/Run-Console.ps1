# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

#Requires -Version 5.1
<#
.SYNOPSIS
Runs the Vigil suites that SSH cannot: the ones that need Windows' data
protection (DPAPI) or the service manager.

.DESCRIPTION
Over SSH, Windows refuses DPAPI and the service manager to vigil-test, so
Secrets, Precheck and Base-Pack's base_services never really ran. This runs
those three suites from a console or Remote Desktop session, as whoever runs
it.

The suites use their own temporary folders: they do not touch the installed
Vigil service or its configuration. Nothing is installed.

The checkout (vigil-main.zip, next to this script) is unpacked to a temporary
folder and removed afterwards. Each suite's output, and a summary, are saved
to console-results\ next to this script, so Claude can read them.

.EXAMPLE
Signed in at the machine or over Remote Desktop (not over SSH), from
PowerShell in this script's folder:

  powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Console.ps1
#>

$zip = Join-Path $PSScriptRoot 'vigil-main.zip'
$out = Join-Path $PSScriptRoot 'console-results'
if (-not (Test-Path $zip)) { Write-Host "vigil-main.zip not found next to this script" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force $out | Out-Null
$summary = Join-Path $out 'summary.txt'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$session = if ($env:SSH_CONNECTION) { 'SSH (this will fail the same way: use the console or Remote Desktop)' } elseif ($env:SESSIONNAME) { $env:SESSIONNAME } else { 'unknown' }
$head = @(
    "Run-Console $(Get-Date -Format s) on $env:COMPUTERNAME",
    "account: $($id.Name); elevated: $elevated; session: $session",
    "checkout: vigil-main.zip, SHA-256 $((Get-FileHash $zip -Algorithm SHA256).Hash)"
)
Set-Content -LiteralPath $summary -Value $head
$head | ForEach-Object { Write-Host $_ }

$dir = Join-Path $env:TEMP ('vigil-console.' + $PID)
Expand-Archive -LiteralPath $zip -DestinationPath $dir
try {
    foreach ($t in 'Secrets', 'Precheck', 'Base-Pack') {
        Write-Host "running $t ..."
        $f = Join-Path $dir "tests\integration\$t.ps1"
        $log = Join-Path $out "$t.txt"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$f`"" -RedirectStandardOutput $log -RedirectStandardError "$log.err" -NoNewWindow -PassThru -Wait
        $sum = Get-Content $log | Where-Object { $_ -match '^\s*\d+ passed' } | Select-Object -Last 1
        $line = '{0,-10} exit {1}  {2,4} s  {3}' -f $t, $p.ExitCode, [int]$sw.Elapsed.TotalSeconds, $sum
        Add-Content -LiteralPath $summary -Value $line
        Write-Host $line
    }
}
finally {
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}
Write-Host "Saved to $out" -ForegroundColor Green
