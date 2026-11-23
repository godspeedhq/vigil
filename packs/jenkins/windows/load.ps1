#Requires -Version 5.1

<#
.SYNOPSIS
    load.ps1 - Jenkins' own load averages: its queue and executors, over ten seconds, a minute and an hour
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Jenkins' load statistics (/overallLoad/api/json): what it has averaged
    itself, every ten seconds, minute and hour. Smoother than one reading:
    a queue that averaged 5 over the hour is a queue that never empties.
    Each is reported once Jenkins has averaged it (a minute or an hour after
    it started).

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                    1 when Jenkins answers, else 0
      queue_length          items in the queue that can run, on average,
                            tagged window=<10s, 1m or 1h>
      queue_length_total    every item in the queue, on average, tagged the
                            same
      executors_busy        executors busy, on average, tagged the same
      executors_idle        executors idle, on average, tagged the same
      executors_available   executors that could take a build, on average
      executors_online      executors on nodes online, on average
      executors_connecting  executors on nodes still connecting, on average
      executors_defined     executors defined, online or not, on average
      executors_total       executors in all, on average

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  queue_length window=1h below 1; executors_busy window=1h
               well below executors_online.
      Watch    queue_length window=1h above 1: the queue rarely empties;
               executors_busy close to executors_online for the hour.
      Act      executors_connecting window=1h above 0 for long: agents that
               cannot connect; executors_online falling against
               executors_defined: nodes dropping.

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('load: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("load: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("load: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("load: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$l = Read-Page '/overallLoad/api/json?tree=queueLength[sec10[latest],min[latest],hour[latest]],totalQueueLength[sec10[latest],min[latest],hour[latest]],busyExecutors[sec10[latest],min[latest],hour[latest]],idleExecutors[sec10[latest],min[latest],hour[latest]],availableExecutors[sec10[latest],min[latest],hour[latest]],onlineExecutors[sec10[latest],min[latest],hour[latest]],connectingExecutors[sec10[latest],min[latest],hour[latest]],definedExecutors[sec10[latest],min[latest],hour[latest]],totalExecutors[sec10[latest],min[latest],hour[latest]]'
Write-Output 'metric up 1'
foreach ($pair in @(@('queueLength', 'queue_length'), @('totalQueueLength', 'queue_length_total'), @('busyExecutors', 'executors_busy'), @('idleExecutors', 'executors_idle'), @('availableExecutors', 'executors_available'), @('onlineExecutors', 'executors_online'), @('connectingExecutors', 'executors_connecting'), @('definedExecutors', 'executors_defined'), @('totalExecutors', 'executors_total'))) {
    $s = $l.($pair[0])
    if (-not $s) { continue }
    foreach ($w in @(@('sec10', '10s'), @('min', '1m'), @('hour', '1h'))) {
        $x = $s.($w[0])
        if ($x -and $null -ne $x.latest) { Write-Output "metric $($pair[1]) $(Num $x.latest '0.##') window=$($w[1])" }
    }
}
exit 0
