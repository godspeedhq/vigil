#Requires -Version 5.1

<#
.SYNOPSIS
    nodes.ps1 - each Jenkins node: online or not, why and since when, its executors, and what Jenkins' own monitors say of it
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    The built-in node and every agent (/computer/api/json). Jenkins shows its
    node monitors (disk, memory, swap, response time, clock) to administrators
    only: a read-only user gets the rest, and monitors_readable 0. A node a
    monitor took offline (free disk below its threshold, 1 GB by default)
    says so in its reason, which any user sees.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                    1 when Jenkins answers, else 0
      nodes                 the nodes
      monitors_readable     1 when Jenkins shows this user its node
                            monitors (an administrator), else 0
      online                1 when a node is online, else 0, tagged
                            node=<its name> and, when offline, reason=<why>
      temporarily_offline   1 when someone took it offline, tagged
                            node=<its name>
      offline_seconds       how long it has been offline, when Jenkins knows
      executors             its executors
      busy                  of those, running a build now
      idle                  of those, idle
      stuck                 of those, running a build Jenkins thinks stuck
      disk_free_bytes       free space where it keeps its workspace
      disk_threshold_bytes  the free space below which Jenkins takes it
                            offline
      tmp_free_bytes        free space in its temporary folder
      memory_free_bytes     free physical memory
      memory_total_bytes    physical memory
      swap_free_bytes       free swap
      response_ms           how long it takes to answer Jenkins, on average
      clock_diff_ms         its clock against the controller's
      nodes_not_shown       past the first 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  online 1 for every node you expect; disk_free_bytes far above
               disk_threshold_bytes; clock_diff_ms within a second; stuck 0.
      Watch    disk_free_bytes under twice disk_threshold_bytes: Jenkins will
               take the node offline; response_ms in the seconds; a node
               temporarily_offline for days: someone forgot it.
      Act      online 0 where temporarily_offline is 0 (its reason says why:
               the agent stopped, its disk filled); stuck above 0; clock_diff_ms
               in the minutes.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Jenkins up or down; 1 if a setting is wrong, the login is refused, or the address is not Jenkins
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inv = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$url = if ($env:JENKINS_URL) { $env:JENKINS_URL.TrimEnd('/') } else { 'http://127.0.0.1:8080' }
# The login, as a header made here: never on a command line.
$headers = @{}
if ($env:JENKINS_USER) {
    $pair = [Text.Encoding]::UTF8.GetBytes("$($env:JENKINS_USER):$($env:JENKINS_API_TOKEN)")
    $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String($pair)
}
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Get-Json <path>: the page as objects; 'down' when Jenkins does not answer
# (a reading), 'forbidden' when this user may not read it; exits 1 when it
# answers wrong, saying why.
function Get-Json([string]$path) {
    try { $r = Invoke-WebRequest -Uri ($url + $path) -Headers $headers -UseBasicParsing -TimeoutSec 60 }
    catch {
        $resp = $_.Exception.Response
        if (-not $resp) { return 'down' }
        $code = [int]$resp.StatusCode
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('nodes: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("nodes: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("nodes: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("nodes: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
    return $j
}
# A tag's value: no spaces, quotes or control characters, never empty.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A job's full name, from its URL.
function Full-Name([string]$u) {
    $n = $u -replace '^.*?/job/', '' -replace '/job/', '/' -replace '/$', ''
    if (-not $n) { return 'none' }
    return $n
}
function Num([double]$v, [string]$f = '0') { return $v.ToString($f, $inv) }

$c = Read-Page '/computer/api/json?tree=computer[displayName,offline,temporarilyOffline,offlineCauseReason,offlineCause[timestamp],numExecutors,executors[idle,likelyStuck],oneOffExecutors[likelyStuck],monitorData[*]]'
Write-Output 'metric up 1'
$nodes = @($c.computer)
Write-Output "metric nodes $($nodes.Count)"
$readable = @($nodes | Where-Object { $_.monitorData -and @($_.monitorData.PSObject.Properties).Count -gt 0 }).Count -gt 0
Write-Output "metric monitors_readable $(if ($readable) { 1 } else { 0 })"
foreach ($n in ($nodes | Select-Object -First 100)) {
    $t = "node=$(Safe $n.displayName)"
    $why = if ($n.offline -and $n.offlineCauseReason) { " reason=$(Safe $n.offlineCauseReason)" } else { '' }
    Write-Output "metric online $(if ($n.offline) { 0 } else { 1 }) $t$why"
    Write-Output "metric temporarily_offline $(if ($n.temporarilyOffline) { 1 } else { 0 }) $t"
    if ($n.offline -and $n.offlineCause -and $n.offlineCause.timestamp) { Write-Output "metric offline_seconds $(Num ([Math]::Floor([Math]::Max(0, ($nowMs - [double]$n.offlineCause.timestamp) / 1000)))) $t" }
    Write-Output "metric executors $([int]$n.numExecutors) $t"
    Write-Output "metric busy $(@($n.executors | Where-Object { $_ -and $_.idle -eq $false }).Count) $t"
    Write-Output "metric idle $(@($n.executors | Where-Object { $_ -and $_.idle -eq $true }).Count) $t"
    Write-Output "metric stuck $(@(@($n.executors) + @($n.oneOffExecutors) | Where-Object { $_ -and $_.likelyStuck -eq $true }).Count) $t"
    $m = $n.monitorData
    if ($m) {
        $d = $m.'hudson.node_monitors.DiskSpaceMonitor'
        if ($d -and $d.PSObject.Properties['size']) { Write-Output "metric disk_free_bytes $(Num $d.size) $t"; Write-Output "metric disk_threshold_bytes $(Num $d.threshold) $t" }
        $tm = $m.'hudson.node_monitors.TemporarySpaceMonitor'
        if ($tm -and $tm.PSObject.Properties['size']) { Write-Output "metric tmp_free_bytes $(Num $tm.size) $t" }
        $s = $m.'hudson.node_monitors.SwapSpaceMonitor'
        if ($s -and $s.PSObject.Properties['availablePhysicalMemory']) {
            Write-Output "metric memory_free_bytes $(Num $s.availablePhysicalMemory) $t"
            Write-Output "metric memory_total_bytes $(Num $s.totalPhysicalMemory) $t"
            Write-Output "metric swap_free_bytes $(Num $s.availableSwapSpace) $t"
        }
        $r = $m.'hudson.node_monitors.ResponseTimeMonitor'
        if ($r -and $r.PSObject.Properties['average']) { Write-Output "metric response_ms $(Num $r.average) $t" }
        $k = $m.'hudson.node_monitors.ClockMonitor'
        if ($k -and $k.PSObject.Properties['diff']) { Write-Output "metric clock_diff_ms $(Num $k.diff) $t" }
    }
}
Write-Output "metric nodes_not_shown $([Math]::Max(0, $nodes.Count - 100))"
exit 0
