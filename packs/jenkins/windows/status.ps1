#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a Jenkins controller: up, its version, executors busy, the queue, nodes offline, and whether it is shutting down
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads Jenkins' REST API (/api/json, /computer/api/json, /queue/api/json)
    at JENKINS_URL, as JENKINS_USER with the API token in JENKINS_API_TOKEN (a
    secret), with Invoke-WebRequest. A read-only user is enough: Overall/Read,
    Job/Read and Agent/Read. The token goes in a header made here, never on
    a command line. Over https, the certificate must be one Windows
    trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                       1 when Jenkins answers, else 0
      version                  always 1, tagged version=<Jenkins' version>
      quieting_down            1 when it is preparing to shut down: no new
                               build starts
      executors_total          executors on every node online
      executors_busy           of those, running a build now
      executors_busy_pct       executors_busy, as a percentage of the total
      queue_length             items waiting in the build queue
      queue_buildable          of those, ready and waiting for an executor
      queue_blocked            of those, blocked (by another build, or a
                               resource)
      queue_stuck              of those, waiting far longer than they should
      nodes                    nodes: the built-in node and every agent
      nodes_offline            of those, offline
      nodes_temporarily_offline  of those, taken offline by someone

    Example output:
      metric up 1
      metric version 1 version=2.580.2
      metric quieting_down 0
      metric executors_total 2
      metric executors_busy 1
      metric executors_busy_pct 50
      metric nodes 3
      metric nodes_offline 2
      metric nodes_temporarily_offline 1
      metric queue_length 1
      metric queue_buildable 1
      metric queue_blocked 0
      metric queue_stuck 1

    Reading the results (starting points: tune them to the controller):
      Healthy  up 1; quieting_down 0; executors_busy_pct below 80 most of the
               time; queue_stuck 0; nodes_offline only those taken offline
               on purpose.
      Watch    executors_busy_pct at 100 for long stretches, with
               queue_buildable above 0: builds wait for executors; add
               agents. nodes_temporarily_offline you did not expect.
      Act      up 0; quieting_down 1 when no restart is planned: nothing new
               builds; queue_stuck above 0: builds that will not start (a
               label no node has, or every node for it offline);
               nodes_offline rising.

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('status: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("status: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("status: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("status: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$j = Read-Page '/api/json?tree=quietingDown'
Write-Output 'metric up 1'
$v = if ($script:jenkinsVersion -match '^([0-9][0-9.]*)') { $Matches[1] } else { 'unknown' }
Write-Output "metric version 1 version=$v"
Write-Output "metric quieting_down $(if ($j.quietingDown) { 1 } else { 0 })"
$c = Get-Json '/computer/api/json?tree=busyExecutors,totalExecutors,computer[offline,temporarilyOffline]'
if ($c -is [string]) { [Console]::Error.WriteLine('status: /computer could not be read'); exit 1 }
Write-Output "metric executors_total $($c.totalExecutors)"
Write-Output "metric executors_busy $($c.busyExecutors)"
if ($c.totalExecutors -gt 0) { Write-Output "metric executors_busy_pct $(Num (100 * $c.busyExecutors / $c.totalExecutors) '0.##')" }
$nodes = @($c.computer)
Write-Output "metric nodes $($nodes.Count)"
Write-Output "metric nodes_offline $(@($nodes | Where-Object { $_.offline }).Count)"
Write-Output "metric nodes_temporarily_offline $(@($nodes | Where-Object { $_.temporarilyOffline }).Count)"
$q = Get-Json '/queue/api/json?tree=items[blocked,buildable,stuck]'
if ($q -is [string]) { [Console]::Error.WriteLine('status: /queue could not be read'); exit 1 }
$items = @($q.items)
Write-Output "metric queue_length $($items.Count)"
Write-Output "metric queue_buildable $(@($items | Where-Object { $_.buildable }).Count)"
Write-Output "metric queue_blocked $(@($items | Where-Object { $_.blocked }).Count)"
Write-Output "metric queue_stuck $(@($items | Where-Object { $_.stuck }).Count)"
exit 0
