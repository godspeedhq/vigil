#Requires -Version 5.1

<#
.SYNOPSIS
    builds.ps1 - the builds running now on Jenkins, the longest first, against how long they usually take
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Every build running on an executor (/computer/api/json), pipelines too
    (their flyweight executors): how long it has run, Jenkins' estimate from
    its last builds, and how far past it. Past the longest 100, the rest
    counted.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up                  1 when Jenkins answers, else 0
      running             builds running now
      overdue             of those, running more than twice their estimate
      running_seconds     how long one build has run, tagged job=<the job's
                          full name>, build=<its number> and node=<where it
                          runs>
      estimated_seconds   how long Jenkins expects it to take (from its last
                          successful builds), tagged the same
      estimate_pct        running_seconds, as a percentage of the estimate
      builds_not_shown    past the longest 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  overdue 0; estimate_pct below 150 for every build.
      Watch    estimate_pct above 150: slower than usual (a slow agent, a
               slow dependency, tests that grew).
      Act      overdue above 0, and estimate_pct climbing run after run: a
               build hung (waiting for input, a lock, a network call), holding
               its executor.

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('builds: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("builds: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("builds: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("builds: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$c = Read-Page '/computer/api/json?tree=computer[displayName,executors[currentExecutable[url,number,timestamp,estimatedDuration]],oneOffExecutors[currentExecutable[url,number,timestamp,estimatedDuration]]]'
Write-Output 'metric up 1'
$seen = @{}
$builds = New-Object System.Collections.Generic.List[object]
foreach ($n in @($c.computer)) {
    foreach ($e in (@($n.executors) + @($n.oneOffExecutors))) {
        if (-not $e -or -not $e.currentExecutable -or -not $e.currentExecutable.url) { continue }
        $b = $e.currentExecutable
        if ($seen.ContainsKey($b.url)) { continue }
        $seen[$b.url] = $true
        $builds.Add([pscustomobject]@{
                Job = ((Full-Name $b.url) -replace '/[0-9]+$', ''); Number = $b.number; Node = $n.displayName
                Secs = [Math]::Max(0, ($nowMs - [double]$b.timestamp) / 1000); Est = [double]$b.estimatedDuration / 1000
            })
    }
}
$sorted = @($builds | Sort-Object Secs -Descending)
Write-Output "metric running $($sorted.Count)"
Write-Output "metric overdue $(@($sorted | Where-Object { $_.Est -gt 0 -and $_.Secs -gt 2 * $_.Est }).Count)"
foreach ($b in ($sorted | Select-Object -First 100)) {
    $t = "job=$(Safe $b.Job) build=$($b.Number) node=$(Safe $b.Node)"
    Write-Output "metric running_seconds $(Num ([Math]::Floor($b.Secs))) $t"
    if ($b.Est -gt 0) {
        Write-Output "metric estimated_seconds $(Num ([Math]::Floor($b.Est))) $t"
        Write-Output "metric estimate_pct $(Num (100 * $b.Secs / $b.Est) '0.##') $t"
    }
}
Write-Output "metric builds_not_shown $([Math]::Max(0, $sorted.Count - 100))"
exit 0
