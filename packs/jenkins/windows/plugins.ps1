#Requires -Version 5.1

<#
.SYNOPSIS
    plugins.ps1 - Jenkins' plugins: how many, those with an update, those not active
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    The plugin manager (/pluginManager/api/json). It needs more than a
    read-only user: Overall/SystemRead (Jenkins started with
    -Djenkins.security.SystemReadPermission=true) or Overall/Administer.
    Without it, this job says readable 0, and nothing else: no failure.

    Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
    in JENKINS_API_TOKEN (a secret), with Invoke-WebRequest; the token goes in a header made
    here, never on a command line. Over https, the
    certificate must be one Windows trusts (JENKINS_CACERT is not read here).

    Metrics:
      up              1 when Jenkins answers, else 0
      readable        1 when this user may read the plugins, else 0
      plugins         plugins installed
      updates         of those, with a newer version to install
      inactive        of those, not active (failed to load, or a dependency
                      missing)
      disabled        of those, disabled
      update          always 1, for one plugin with an update, tagged
                      plugin=<its name> and version=<the version installed>
      inactive_plugin always 1, for one plugin not active, tagged the same
      updates_not_shown  past the first 100, how many were left out

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the controller):
      Healthy  inactive 0; updates few, and applied on a schedule.
      Watch    updates climbing: plugins left behind (and their security
               fixes); readable 0: give the user Overall/SystemRead to see
               them.
      Act      inactive above 0: a plugin failed to load, and what depends
               on it does not work (the reason is in Jenkins' log).

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
        if ($code -eq 401) { Write-Output 'metric up 0'; [Console]::Error.WriteLine('plugins: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong'); exit 1 }
        if ($code -eq 403) { return 'forbidden' }
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("plugins: $url$path answered HTTP $code"); exit 1
    }
    if (-not $r.Headers['X-Jenkins']) {
        Write-Output 'metric up 0'; [Console]::Error.WriteLine("plugins: $url answers, but not as Jenkins (no X-Jenkins header)"); exit 1
    }
    $script:jenkinsVersion = [string]$r.Headers['X-Jenkins']
    return ($r.Content | ConvertFrom-Json)
}
# The page this job reads, and up.
function Read-Page([string]$path) {
    $j = Get-Json $path
    if ($j -is [string] -and $j -eq 'down') { Write-Output 'metric up 0'; exit 0 }
    if ($j -is [string] -and $j -eq 'forbidden') { Write-Output 'metric up 0'; [Console]::Error.WriteLine("plugins: this user may not read ${path}: give it Overall/Read, Job/Read and Agent/Read"); exit 1 }
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

$p = Get-Json '/pluginManager/api/json?depth=1&tree=plugins[shortName,version,active,enabled,hasUpdate]'
if ($p -is [string] -and $p -eq 'down') { Write-Output 'metric up 0'; exit 0 }
if ($p -is [string] -and $p -eq 'forbidden') { Write-Output 'metric up 1'; Write-Output 'metric readable 0'; exit 0 }
Write-Output 'metric up 1'
Write-Output 'metric readable 1'
$all = @($p.plugins)
$upd = @($all | Where-Object { $_.hasUpdate })
$ina = @($all | Where-Object { -not $_.active })
Write-Output "metric plugins $($all.Count)"
Write-Output "metric updates $($upd.Count)"
Write-Output "metric inactive $($ina.Count)"
Write-Output "metric disabled $(@($all | Where-Object { -not $_.enabled }).Count)"
foreach ($x in ($upd | Select-Object -First 100)) { Write-Output "metric update 1 plugin=$(Safe $x.shortName) version=$(Safe $x.version)" }
foreach ($x in ($ina | Select-Object -First 100)) { Write-Output "metric inactive_plugin 1 plugin=$(Safe $x.shortName) version=$(Safe $x.version)" }
Write-Output "metric updates_not_shown $([Math]::Max(0, $upd.Count - 100))"
exit 0
