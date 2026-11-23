#Requires -Version 5.1

<#
.SYNOPSIS
    queue.ps1 - what is waiting in Jenkins' build queue, the oldest first, and why
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Each item of the queue (/queue/api/json): how long it has waited, and why,
    as Jenkins says it ("Waiting for next available executor on linux",
    "Build #12 is already in progress"). Past the oldest 100, the rest
    counted.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                1 when Jenkins answers, else 0
      queue_length      items waiting
      oldest_seconds    how long the oldest has waited
      stuck             items waiting far longer than they should
      waiting_seconds   how long one item has waited, tagged job=<the job's
                        full name>, state=<stuck, blocked, buildable or
                        waiting> and why=<Jenkins' reason>
      items_not_shown   past the oldest 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  queue_length near 0 most of the time; oldest_seconds in
               seconds.
      Watch    oldest_seconds in minutes with state=buildable: builds wait for
               an executor (jenkins_status executors_busy_pct at 100); add
               agents or executors.
      Act      stuck above 0: a build that will not start (its label matches
               no node online, every such node is offline); why says which.

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('queue: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("queue: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("queue: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("queue: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$q = Read-Page '/queue/api/json?tree=items[inQueueSince,why,blocked,buildable,stuck,task[name,url]]'
Write-Output 'metric up 1'
$items = @($q.items | ForEach-Object { $_ | Add-Member -NotePropertyName age -NotePropertyValue ([Math]::Max(0, ($nowMs - [double]$_.inQueueSince) / 1000)) -PassThru } | Sort-Object age -Descending)
Write-Output "metric queue_length $($items.Count)"
Write-Output "metric oldest_seconds $(if ($items.Count) { Num ([Math]::Floor($items[0].age)) } else { 0 })"
Write-Output "metric stuck $(@($items | Where-Object { $_.stuck }).Count)"
foreach ($i in ($items | Select-Object -First 100)) {
    $state = if ($i.stuck) { 'stuck' } elseif ($i.blocked) { 'blocked' } elseif ($i.buildable) { 'buildable' } else { 'waiting' }
    $why = if ($i.why) { $i.why } else { 'none' }
    Write-Output "metric waiting_seconds $(Num ([Math]::Floor($i.age))) job=$(Safe (Full-Name $i.task.url)) state=$state why=$(Safe $why)"
}
Write-Output "metric items_not_shown $([Math]::Max(0, $items.Count - 100))"
exit 0
