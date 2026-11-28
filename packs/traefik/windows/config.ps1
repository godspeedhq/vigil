#Requires -Version 5.1

<#
.SYNOPSIS
    config.ps1 - what in Traefik's configuration is broken, and its certificates, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports, from Traefik's read-only API, its version; its routers, services
    and middlewares, for HTTP, TCP and UDP, with those in error and in warning;
    each router in error by name, with the reason (a router in error takes no
    traffic); and its TLS certificates, those Traefik warns about, the soonest
    to expire and those within 30 days. It only reads: every request is a GET,
    and it changes nothing.

    Reads TRAEFIK_URL (default http://localhost:8080): /api/version,
    /api/overview, /api/<http, tcp, udp>/routers?status=disabled and
    /api/certificates (--api=true).
    What the scripts share is in _traefik.ps1, beside this one.

    Metrics:
      up                       1 when its API answered, else 0
      version                  always 1, tagged version=<its version>
      routers                  routers, tagged protocol=<http, tcp or udp>
      routers_errors           of them, in error: they take no traffic
      routers_warnings         in warning
      services                 services, tagged protocol=
      services_errors          of them, in error
      services_warnings        in warning
      middlewares              middlewares, tagged protocol=<http or tcp>
      middlewares_errors       of them, in error
      middlewares_warnings     in warning
      certificates             TLS certificates
      certificates_warnings    of them, those Traefik warns about (expiring
                               soon)
      certificates_errors      of them, in error
      router_error             a router in error: 1, tagged protocol=,
                               router=<its name> and reason=<the start of its
                               error>
      router_errors_not_shown  routers in error past the first 20
      cert_expires_days        days until the soonest certificate expires (below
                               0: expired)
      certs_expiring_30d       certificates that expire within 30 days

    Example output (the rest are in the same form):
      metric up 1
      metric version 1 version=3.8.0
      metric routers 10 protocol=http
      metric routers_errors 2 protocol=http
      metric routers_warnings 0 protocol=http
      metric services 7 protocol=http
      metric services_errors 0 protocol=http
      metric services_warnings 0 protocol=http
      metric middlewares 2 protocol=http
      metric middlewares_errors 0 protocol=http
      metric middlewares_warnings 0 protocol=http
      metric certificates 2
      metric certificates_warnings 1
      metric certificates_errors 0
      metric router_error 1 protocol=http router=broken@file reason=the_service__not-there@file__does_not_exist
      metric router_error 1 protocol=http router=nomiddleware@file reason=middleware__no-such-middleware@file__does_not_exist
      metric cert_expires_days 4.99
      metric certs_expiring_30d 1

    Reading the results (starting points: tune them to your own):
      Healthy  routers_errors, services_errors and middlewares_errors 0;
               certificates_warnings 0.
      Watch    the warnings above 0; certs_expiring_30d above 0.
      Act      routers_errors above 0: router_error names it and why (a service
               that does not exist, a middleware missing, a rule that does not
               parse): it takes no traffic; cert_expires_days below 7.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when Traefik does not answer (up 0 is
      the reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'config'
. (Join-Path $PSScriptRoot '_traefik.ps1')

# Its read-only API: the version; every router, service and middleware and
# those in error or warning; the routers in error, named, with the reason;
# the certificates and their expiry.
$r = Get-Answer '/api/version'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/api/version: no such page (HTTP 404): is the API on (--api=true), and is TRAEFIK_URL its address?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
Write-Output "metric version 1 version=$(Safe ($r.Body | ConvertFrom-Json).Version)"
$o = Get-Answer '/api/overview'
if ($o.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/api/overview did not answer"); exit 1 }
$ov = $o.Body | ConvertFrom-Json
foreach ($k in 'http', 'tcp', 'udp') {
    foreach ($w in 'routers', 'services', 'middlewares') {
        $x = $ov.$k.$w
        if ($null -eq $x) { continue }
        Write-Output "metric $w $($x.total) protocol=$k"
        Write-Output "metric ${w}_errors $($x.errors) protocol=$k"
        Write-Output "metric ${w}_warnings $($x.warnings) protocol=$k"
    }
}
if ($ov.certificates) {
    Write-Output "metric certificates $($ov.certificates.total)"
    Write-Output "metric certificates_warnings $($ov.certificates.warnings)"
    Write-Output "metric certificates_errors $($ov.certificates.errors)"
}
# Each router in error, by name, with the first words of its error: the 20
# first by name.
$n = 0
foreach ($k in 'http', 'tcp', 'udp') {
    $b = Get-Answer "/api/$k/routers?status=disabled"
    if ($b.State -ne 'ok') { continue }
    $parsed = $b.Body | ConvertFrom-Json
    foreach ($rt in @($parsed | ForEach-Object { $_ } | Sort-Object -Property name -CaseSensitive)) {
        $n++
        if ($n -gt 20) { continue }
        $why = if ($rt.error) { [string]@($rt.error)[0] } else { 'none' }
        if ($why.Length -gt 80) { $why = $why.Substring(0, 80) }
        Write-Output "metric router_error 1 protocol=$k router=$(Safe $rt.name) reason=$(Safe $why)"
    }
}
Write-Output "metric router_errors_not_shown $(if ($n -gt 20) { $n - 20 } else { 0 })"
# The certificates: the soonest to expire, and those within 30 days.
$c = Get-Answer '/api/certificates'
if ($c.State -eq 'ok') {
    $left = @(@($c.Body | ConvertFrom-Json) | ForEach-Object { $_ } | ForEach-Object {
        ([DateTimeOffset]::Parse([string]$_.notAfter, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() - $script:Now) })
    if ($left.Count -gt 0) {
        $min = ($left | Measure-Object -Minimum).Minimum
        Write-Output "metric cert_expires_days $([Math]::Floor($min / 86400 * 100) / 100)"
        Write-Output "metric certs_expiring_30d $(@($left | Where-Object { $_ -lt 2592000 }).Count)"
    }
}
exit 0
