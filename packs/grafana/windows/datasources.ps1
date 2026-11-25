#Requires -Version 5.1

<#
.SYNOPSIS
    datasources.ps1 - does every Grafana data source answer, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Lists Grafana's data sources and asks Grafana to check each one, as the Test
    button on its settings page does: Grafana makes one small query to it and
    says whether it answered. A data source that does not answer is a dashboard
    that shows nothing and an alert rule that cannot fire. It needs a token: a
    Viewer's is enough, and can change nothing. It only reads: every request is
    a GET, and it changes nothing.

    Reads GRAFANA_URL (default http://localhost:3000): /api/datasources and, for
    each of the first 20 by name, /api/datasources/uid/<uid>/health, with
    GRAFANA_TOKEN (or GRAFANA_USER and GRAFANA_PASSWORD).
    What the scripts share is in _grafana.ps1, beside this one.

    Metrics:
      up                     1 when Grafana answered, else 0
      login_ok               1 when the token (or the user) may list the data
                             sources; 0 when there is none, or it is refused
                             (and nothing more is read)
      datasource_ok          1 when the data source answered Grafana's check,
                             else 0; tagged name=<its name> and type=<its kind>
      datasources            data sources configured
      datasources_failing    of those checked, the ones that did not answer
      datasources_not_shown  data sources past the first 20, not checked

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  login_ok 1; datasources_failing 0.
      Watch    datasources_not_shown above 0: only the first 20 by name are
               checked.
      Act      datasources_failing above 0: datasource_ok 0 names it. Its
               dashboards are empty and the alert rules that read it error (the
               alerting job) until it answers again; login_ok 0: the token is
               missing, expired or revoked, and this job sees nothing.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, when Grafana does not answer (up 0), and
      when there is no login or it is refused (login_ok 0); 1 when it answers
      wrong
#>

$Job = 'datasources'
. (Join-Path $PSScriptRoot '_grafana.ps1')

# The data sources, and what each answers when asked for its health: only
# with a login (GRAFANA_TOKEN, or GRAFANA_USER and GRAFANA_PASSWORD).
if (-not $script:Auth) {
    Write-Output 'metric login_ok 0'
    [Console]::Error.WriteLine("${Job}: no login: this job needs a Viewer's token (secret = GRAFANA_TOKEN=secret:GRAFANA_TOKEN; packs/grafana/README.md)")
    exit 0
}
$r = Get-Answer '/api/datasources'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1'; Write-Output 'metric login_ok 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'forbidden' { Write-Output 'metric up 1'; Write-Output 'metric login_ok 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
# Kept in a variable first: Windows PowerShell 5.1 hands a JSON array back
# as one object, and @() makes it the list.
$parsed = $r.Body | ConvertFrom-Json
$list = @($parsed | ForEach-Object { $_ } | Sort-Object -Property name -CaseSensitive)
$shown = 0; $failing = 0
foreach ($d in $list) {
    if ($shown -ge 20) { break }
    $shown++
    $h = Get-Answer ('/api/datasources/uid/' + [Uri]::EscapeDataString([string]$d.uid) + '/health')
    $ok = 0
    if ($h.State -eq 'ok') { try { if (($h.Body | ConvertFrom-Json).status -ceq 'OK') { $ok = 1 } } catch { } }
    if (-not $ok) { $failing++ }
    Write-Output "metric datasource_ok $ok name=$(Safe $d.name) type=$(Safe $d.type)"
}
Write-Output "metric datasources $($list.Count)"
Write-Output "metric datasources_failing $failing"
Write-Output "metric datasources_not_shown $($list.Count - $shown)"
exit 0
