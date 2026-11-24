#Requires -Version 5.1

<#
.SYNOPSIS
    sites.ps1 - IIS and its sites, from its counters, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether IIS's web service runs and for how long, and each site's
    connections (now and the most), its requests (by method: GET, POST, HEAD,
    the others), its 404s and locked errors, the bytes it sent and received, its
    anonymous and authenticated users, and its CGI and ISAPI requests running,
    from the Web Service counters. It only reads: it changes nothing.

    The account Vigil runs as needs no administrator: it reads IIS's performance
    counters as a member of Performance Monitor Users (LocalSystem, the Vigil
    service's account, already may). It reads the counter set Web Service, every
    site.
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      up                         1 when IIS's web service (W3SVC) answers with
                                 its counters, else 0
      uptime_seconds             since the web service started
      sites                      sites
      connections                connections now, all sites together
      site_uptime_seconds        since the site started, tagged site=<its name>
                                 (0: stopped)
      site_connections           connections now, tagged site
      site_connections_max       the most at once since it started, tagged site
      site_requests_count        requests (a running total), tagged site
      site_method_count          requests by method (a running total), tagged
                                 site and method=<get, post, head, put, delete,
                                 options or other>
      site_not_found_count       answers 404 (a running total), tagged site
      site_locked_count          requests refused because the file was locked
                                 (423), tagged site
      site_bytes_sent_count      bytes sent (a running total), tagged site
      site_bytes_received_count  bytes received (a running total), tagged site
      site_users                 users now, tagged site and kind=<anonymous or
                                 authenticated>
      site_cgi_running           CGI and ISAPI requests running now, tagged site
      sites_not_shown            sites past the first 100, left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to the server):
      Healthy  up 1; every site_uptime_seconds above 0; site_not_found_count
               rising slowly (graph the _count totals as rates).
      Watch    site_not_found_count rising fast (a broken link, a scan);
               site_connections near what the site should see.
      Act      up 0: IIS does not serve; site_uptime_seconds 0: that site is
               stopped.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, IIS up or down
#>

$Job = 'sites'
. (Join-Path $PSScriptRoot '_iis.ps1')

$ws = Get-Set 'Web Service'
if ($null -eq $ws -or -not $ws.ContainsKey('_Total')) { M 'up' 0; exit 0 }
M 'up' 1
M 'uptime_seconds' $ws['_Total']['service uptime']
$names = Get-Instances $ws
M 'sites' $names.Count
M 'connections' $ws['_Total']['current connections']
foreach ($s in @($names | Select-Object -First 100)) {
    $c = $ws[$s]; $t = "site=$(Safe $s)"
    M 'site_uptime_seconds' $c['service uptime'] $t
    M 'site_connections' $c['current connections'] $t
    M 'site_connections_max' $c['maximum connections'] $t
    M 'site_requests_count' $c['total method requests'] $t
    foreach ($m in 'get', 'post', 'head', 'put', 'delete', 'options') { M 'site_method_count' $c["total $m requests"] "$t method=$m" }
    $other = 0; foreach ($m in 'trace', 'move', 'copy', 'mkcol', 'propfind', 'proppatch', 'search', 'lock', 'unlock') { $other += N $c["total $m requests"] }
    M 'site_method_count' ($other + (N $c['total other request methods'])) "$t method=other"
    M 'site_not_found_count' $c['total not found errors'] $t
    M 'site_locked_count' $c['total locked errors'] $t
    M 'site_bytes_sent_count' $c['total bytes sent'] $t
    M 'site_bytes_received_count' $c['total bytes received'] $t
    M 'site_users' $c['current anonymous users'] "$t kind=anonymous"
    M 'site_users' $c['current nonanonymous users'] "$t kind=authenticated"
    M 'site_cgi_running' ((N $c['current cgi requests']) + (N $c['current isapi extension requests'])) $t
}
M 'sites_not_shown' ([Math]::Max($names.Count - 100, 0))
exit 0
