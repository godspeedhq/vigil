#Requires -Version 5.1

<#
.SYNOPSIS
    tls.ps1 - the certificates Caddy serves, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Makes a TLS handshake with each of Caddy's https endpoints and reports the
    certificate it serves: the days until it expires, whether it is within its
    dates, and whether it checks against the trusted CAs and the name asked for.
    It reads what clients get, so it also catches a certificate renewed on disk
    that Caddy has not loaded yet. With CADDY_TLS unset, it asks Caddy's admin
    API for the site names it serves and checks each one, and certificates from
    Caddy's own local CA check against that CA. Nothing is sent but the
    handshake. It only reads: it changes nothing.

    Reads Caddy's admin API at CADDY_ADMIN (default http://localhost:2019, where
    Caddy listens unless told otherwise), with GET only: the API could change
    Caddy's configuration, and this job never asks it to. CADDY_TLS lists the
    endpoints, separated by spaces: host:port, or host:port/name to ask for a
    name (SNI) other than the host (default every site name in Caddy's
    configuration, at CADDY_TLS_ADDRESS (default 127.0.0.1:443)). CADDY_CACERT,
    a CA file, checks a private CA.
    What the scripts share is in _caddy.ps1, beside this one.

    Metrics:
      up                 1 when Caddy's admin API answers, else 0 (only when
                         CADDY_TLS is not set: the job then asks it for the site
                         names)
      sites_found        site names found in Caddy's configuration (when
                         CADDY_TLS is not set)
      tls_up             1 when the endpoint finished a TLS handshake, else 0;
                         tagged endpoint=<host:port, or host:port/name>
      cert_expires_days  days until the certificate it served expires (below 0:
                         expired), tagged endpoint
      cert_valid         1 when today is within its dates, else 0, tagged
                         endpoint
      cert_verified      1 when it checks against the trusted CAs (or
                         CADDY_CACERT) and the name, else 0; tagged endpoint and
                         reason=<openssl's, or Windows' word>
      cert_info          always 1, tagged endpoint, issuer=<its CN> and
                         protocol=<the TLS version agreed>
      certs_not_shown    endpoints past the first 50, left out

    Example output (the rest are in the same form):
      metric sites_found 1
      metric tls_up 1 endpoint=127.0.0.1:18343/shop.test
      metric cert_expires_days 0 endpoint=127.0.0.1:18343/shop.test
      metric cert_valid 1 endpoint=127.0.0.1:18343/shop.test
      metric cert_verified 1 endpoint=127.0.0.1:18343/shop.test reason=ok
      metric cert_info 1 endpoint=127.0.0.1:18343/shop.test issuer=Caddy_Local_Authority_-_ECC_Intermediate protocol=TLSv1.3

    Reading the results (starting points: tune them to the server):
      Healthy  tls_up 1; cert_expires_days above 30; cert_valid 1; cert_verified
               1.
      Watch    cert_expires_days below 30: renewal should have happened by now.
      Act      cert_expires_days below 7, or cert_valid 0: clients will refuse
               it; cert_verified 0: clients that check (all browsers) refuse it
               now (reason says why); tls_up 0: nothing answers TLS there.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever the certificates
#>

$Job = 'tls'
. (Join-Path $PSScriptRoot '_caddy.ps1')

$list = @(Get-CaddyEndpoints)
Read-Certs $list
exit 0
