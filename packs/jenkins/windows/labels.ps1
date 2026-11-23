#Requires -Version 5.1

<#
.SYNOPSIS
    labels.ps1 - each Jenkins label: its executors busy and idle, its nodes offline, the jobs tied to it
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Every label of every node (/computer/api/json, each node's labels): how
    much capacity it has and how much is in use. A job tied to a label runs
    only there: a label at 100% busy holds its jobs in the queue, whatever the
    rest of Jenkins has free.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                1 when Jenkins answers, else 0
      labels            the labels
      executors_total   executors with a label, on its nodes online, tagged
                        label=<its name>
      executors_busy    of those, running a build now
      executors_idle    of those, idle
      busy_pct          executors_busy, as a percentage of executors_total
      nodes             nodes with the label
      nodes_offline     of those, offline
      tied_jobs         jobs tied to the label
      labels_not_shown  past the first 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  busy_pct below 80 most of the time; nodes_offline 0.
      Watch    busy_pct at 100 for long stretches: the jobs tied to it wait
               (jenkins_queue says which).
      Act      executors_total 0 where tied_jobs is above 0: every node with
               the label is offline, and its jobs will not run.

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('labels: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("labels: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("labels: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("labels: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$c = Read-Page '/computer/api/json?tree=computer[offline,assignedLabels[name,busyExecutors,idleExecutors,totalExecutors,nodes[nodeName],tiedJobs[name]]]'
Write-Output 'metric up 1'
$labels = [ordered]@{}
foreach ($n in @($c.computer)) {
    foreach ($l in @($n.assignedLabels)) {
        if (-not $l) { continue }
        if (-not $labels.Contains($l.name)) { $labels[$l.name] = @{ L = $l; Offline = 0 } }
        if ($n.offline) { $labels[$l.name].Offline++ }
    }
}
$names = @($labels.Keys | Sort-Object)
Write-Output "metric labels $($names.Count)"
foreach ($k in ($names | Select-Object -First 100)) {
    $l = $labels[$k].L; $t = "label=$(Safe $k)"
    Write-Output "metric executors_total $([int]$l.totalExecutors) $t"
    Write-Output "metric executors_busy $([int]$l.busyExecutors) $t"
    Write-Output "metric executors_idle $([int]$l.idleExecutors) $t"
    if ([int]$l.totalExecutors -gt 0) { Write-Output "metric busy_pct $(Num (100 * $l.busyExecutors / $l.totalExecutors) '0.##') $t" }
    Write-Output "metric nodes $(@($l.nodes).Count) $t"
    Write-Output "metric nodes_offline $($labels[$k].Offline) $t"
    Write-Output "metric tied_jobs $(@($l.tiedJobs | Where-Object { $_ }).Count) $t"
}
Write-Output "metric labels_not_shown $([Math]::Max(0, $names.Count - 100))"
exit 0
