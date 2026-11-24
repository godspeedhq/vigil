# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. See the LICENSE file for the full terms.
#
# Enable-IIS.ps1: turns IIS on, on the Windows Server test box, and sets up the
# sites the iis pack is tested against. Run it once, at the console, from
# PowerShell opened as Administrator:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File \\192.168.4.40\Downloads\vigil-2025\Enable-IIS.ps1
#
# It may be run again: what is already there is kept.
#   -Reset   puts the test sites back as they started (after a test crashed one)
#   -Remove  takes away the test sites, the certificate, vigil-test's access
#            and IIS itself
#
# It writes enable-iis-log.txt beside itself, which vigil-test can read.
#
# What it does:
#   1. Installs IIS with logging, request monitoring, ASP.NET 4.8 and the
#      management tools.
#   2. Puts vigil-test in Performance Monitor Users (IIS's counters) and Event
#      Log Readers (IIS's events), and lets it read IIS's logs. Nothing else:
#      vigil-test stays a plain user.
#   3. Sets up four test sites, each in its own application pool:
#        vigil-ok       http 8081, https 8443  a page, and one that takes 10 s
#        vigil-fail     http 8082              a page that answers 500
#        vigil-stopped  http 8083              its pool stopped: 503
#        vigil-crash    http 8084              a page that crashes its worker;
#                                              3 crashes and IIS stops the pool
#      The https binding has a certificate made here that expires in 10 days,
#      on purpose.
param([switch]$Reset, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript -Path (Join-Path $here 'enable-iis-log.txt') -Force | Out-Null
try {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from PowerShell opened as Administrator.'
    }
    if (-not (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue)) {
        throw 'Install-WindowsFeature is not here: this script is for Windows Server.'
    }
    $user = 'vigil-test'
    $root = 'C:\inetpub\vigil-test'
    $logs = 'C:\inetpub\logs\LogFiles'
    $certName = 'vigil iis test (expires on purpose)'
    $sites = [ordered]@{
        'vigil-ok'      = 8081
        'vigil-fail'    = 8082
        'vigil-stopped' = 8083
        'vigil-crash'   = 8084
    }
    $features = 'Web-Server', 'Web-Default-Doc', 'Web-Static-Content', 'Web-Http-Errors',
                'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Asp-Net45',
                'Web-Mgmt-Console', 'Web-Scripting-Tools'

    if ($Remove) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        if (Get-Module WebAdministration) {
            foreach ($s in $sites.Keys) {
                if (Get-Website | Where-Object { $_.Name -eq $s }) { Remove-Website -Name $s; "removed site $s" }
                if (Test-Path "IIS:\AppPools\$s") { Remove-WebAppPool -Name $s; "removed pool $s" }
            }
            if (Test-Path 'IIS:\SslBindings\0.0.0.0!8443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!8443'; 'removed the 8443 certificate binding' }
        }
        Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $certName } | ForEach-Object { Remove-Item $_.PSPath; "removed certificate $($_.Thumbprint)" }
        if (Test-Path $root) { Remove-Item $root -Recurse -Force; "removed $root" }
        foreach ($g in 'Performance Monitor Users', 'Event Log Readers') {
            try { Remove-LocalGroupMember -Group $g -Member $user; "$user left $g" } catch { "$user was not in $g" }
        }
        if (Test-Path $logs) { icacls $logs /remove:g $user | Out-Null; "$user may no longer read $logs" }
        $r = Uninstall-WindowsFeature -Name $features
        "IIS removed: $($r.Success); restart needed: $($r.RestartNeeded)"
        return
    }

    # 1. IIS: only the features not there yet. A restart Windows wants for
    # something else (an update) does not stop the rest.
    $missing = @(Get-WindowsFeature -Name $features | Where-Object { -not $_.Installed } | ForEach-Object Name)
    if ($Reset -or -not $missing.Count) { 'IIS is installed' }
    else {
        $r = Install-WindowsFeature -Name $missing -IncludeManagementTools
        "IIS installed ($($missing -join ', ')): $($r.Success); restart needed: $($r.RestartNeeded)"
        if ("$($r.RestartNeeded)" -eq 'Yes') { 'Restart the server, then run this script again to finish.'; return }
    }
    Import-Module WebAdministration

    # 2. vigil-test may read the counters, the events and the logs, nothing more
    foreach ($g in 'Performance Monitor Users', 'Event Log Readers') {
        try { Add-LocalGroupMember -Group $g -Member $user; "$user joined $g" } catch { "$user is already in $g" }
    }
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    icacls $logs /grant "${user}:(OI)(CI)RX" | Out-Null
    "$user may read $logs"

    # 3. The test sites
    $pages = @{
        'ok\index.html'     = '<!doctype html><title>vigil ok</title><p>vigil ok</p>'
        'ok\slow.aspx'      = '<%@ Page Language="C#" %><% System.Threading.Thread.Sleep(10000); %>slow on purpose'
        'fail\index.html'   = '<!doctype html><title>vigil fail</title><p>try boom.aspx</p>'
        'fail\boom.aspx'    = '<%@ Page Language="C#" %><% throw new System.Exception("vigil test: a 500 on purpose"); %>'
        'stopped\index.html' = '<!doctype html><title>vigil stopped</title><p>never served: the pool is stopped</p>'
        'crash\index.html'  = '<!doctype html><title>vigil crash</title><p>try crash.aspx</p>'
        'crash\crash.aspx'  = '<%@ Page Language="C#" %><% System.Environment.FailFast("vigil test: the worker crashes on purpose"); %>'
    }
    foreach ($p in $pages.Keys) {
        $f = Join-Path $root $p
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        Set-Content -Path $f -Value $pages[$p] -Encoding UTF8
    }
    foreach ($s in $sites.Keys) {
        if (-not (Test-Path "IIS:\AppPools\$s")) { New-WebAppPool -Name $s | Out-Null; "made pool $s" }
        if (-not (Get-Website | Where-Object { $_.Name -eq $s })) {
            New-Website -Name $s -Port $sites[$s] -PhysicalPath (Join-Path $root ($s -replace '^vigil-', '')) -ApplicationPool $s | Out-Null
            "made site $s on port $($sites[$s])"
        }
    }
    # three crashes in five minutes and IIS stops vigil-crash (rapid-fail protection)
    Set-ItemProperty 'IIS:\AppPools\vigil-crash' -Name failure.rapidFailProtectionMaxCrashes -Value 3
    Set-ItemProperty 'IIS:\AppPools\vigil-stopped' -Name autoStart -Value $false

    # https on vigil-ok, with a certificate that expires in 10 days
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $certName } | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -DnsName 'localhost', 'vigil-iis-test' -CertStoreLocation Cert:\LocalMachine\My `
            -NotAfter (Get-Date).AddDays(10) -FriendlyName $certName
        "made certificate $($cert.Thumbprint), expires $($cert.NotAfter)"
    }
    if (-not (Get-WebBinding -Name 'vigil-ok' -Protocol https -Port 8443)) {
        New-WebBinding -Name 'vigil-ok' -Protocol https -Port 8443 | Out-Null
    }
    if (-not (Test-Path 'IIS:\SslBindings\0.0.0.0!8443')) {
        (Get-WebBinding -Name 'vigil-ok' -Protocol https -Port 8443).AddSslCertificate($cert.Thumbprint, 'My')
        'bound the certificate to 8443'
    }

    # Every site as it starts: all running, vigil-stopped stopped
    foreach ($s in $sites.Keys) {
        $want = if ($s -eq 'vigil-stopped') { 'Stopped' } else { 'Started' }
        $now = (Get-WebAppPoolState -Name $s).Value
        if ($want -eq 'Started' -and $now -ne 'Started') { Start-WebAppPool -Name $s; "started pool $s" }
        if ($want -eq 'Stopped' -and $now -ne 'Stopped') { Stop-WebAppPool -Name $s; "stopped pool $s" }
        if ((Get-WebsiteState -Name $s).Value -ne 'Started') { Start-Website -Name $s }
    }
    if ($Reset) { 'reset: the test sites are as they started' }

    # What there is now
    ''
    'Pools:'
    Get-ChildItem IIS:\AppPools | ForEach-Object { '  {0,-24} {1}' -f $_.Name, $_.State }
    'Sites:'
    Get-Website | ForEach-Object { '  {0,-24} {1,-8} {2}' -f $_.Name, $_.State, (($_.Bindings.Collection | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join ', ') }
    'Answers:'
    foreach ($u in 'http://localhost:8081/', 'http://localhost:8082/boom.aspx', 'http://localhost:8083/') {
        try { $c = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30).StatusCode }
        catch { $c = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $_.Exception.Message } }
        '  {0,-34} {1}' -f $u, $c
    }
    'Counters (as vigil-test will read them):'
    foreach ($c in '\APP_POOL_WAS(*)\Current Application Pool State', '\HTTP Service Request Queues(*)\CurrentQueueSize') {
        try { (Get-Counter -Counter $c -ErrorAction Stop).CounterSamples | ForEach-Object { '  {0} = {1}' -f $_.Path, $_.CookedValue } }
        catch { "  $c : $($_.Exception.Message)" }
    }
    ''
    'Done. vigil-test must log in again (a new SSH session) to pick up its new groups.'
} finally {
    Stop-Transcript | Out-Null
}
