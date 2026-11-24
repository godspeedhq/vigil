#Requires -Version 5.1

<#
.SYNOPSIS
    tls.ps1 - the certificates IIS serves, from HTTP.sys's bindings, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Finds IIS's https bindings in HTTP.sys (netsh http show sslcert, which any
    account may read) and makes a TLS handshake with each, on this machine: the
    certificate it serves, the days until it expires, whether it is within its
    dates, and whether it checks against the trusted CAs and its name. An
    address binding (0.0.0.0:443) is asked for the first name in its
    certificate; a name binding (www.example.com:443) for its name. Nothing is
    sent but the handshake. It only reads: it changes nothing.

    IIS_TLS, when set, lists the endpoints instead, separated by spaces:
    host:port, or host:port/name. IIS_CACERT, a CA file, checks a private CA.
    What the scripts share is in _iis.ps1, beside this one.

    Metrics:
      bindings_found     https bindings found in HTTP.sys (when IIS_TLS is not
                         set)
      tls_up             1 when the endpoint finished a TLS handshake, else 0;
                         tagged endpoint=<host:port, or host:port/name>
      cert_expires_days  days until the certificate it served expires (below 0:
                         expired), tagged endpoint
      cert_valid         1 when today is within its dates, else 0, tagged
                         endpoint
      cert_verified      1 when it checks against the trusted CAs (or
                         IIS_CACERT) and the name, else 0; tagged endpoint and
                         reason=<openssl's, or Windows' word>
      cert_info          always 1, tagged endpoint, issuer=<its CN> and
                         protocol=<the TLS version agreed>
      certs_not_shown    endpoints past the first 50, left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to the server):
      Healthy  tls_up 1; cert_expires_days above 30; cert_verified 1.
      Watch    cert_expires_days below 30: renewal should have happened by now.
      Act      cert_expires_days below 7, or cert_valid 0: clients will refuse
               it; cert_verified 0: clients that check refuse it now (reason
               says why); tls_up 0: the binding does not answer.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever the certificates
#>

$Job = 'tls'
. (Join-Path $PSScriptRoot '_iis.ps1')

if ($env:IIS_TLS) { $list = @($env:IIS_TLS -split '\s+' | Where-Object { $_ }) }
else {
    $list = @()
    $text = @(netsh http show sslcert 2>$null)
    $bind = $null; $hash = $null; $store = 'MY'
    foreach ($l in $text + @('')) {
        if ($l -match '^\s*(IP:port|Hostname:port)\s*:\s*(\S+)\s*$') { $bind = @($Matches[1], $Matches[2]); $hash = $null; $store = 'MY' }
        elseif ($l -match '^\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)') { $hash = $Matches[1] }
        elseif ($l -match '^\s*Certificate Store Name\s*:\s*(\S+)') {
            $store = $Matches[1]
            if ($bind) {
                $hp = $bind[1]; $port = $hp.Substring($hp.LastIndexOf(':') + 1)
                if ($bind[0] -eq 'Hostname:port') { $list += "127.0.0.1:$port/$($hp.Substring(0, $hp.LastIndexOf(':')))" }
                else {
                    $name = 'localhost'
                    try {
                        $c = Get-Item -LiteralPath "Cert:\LocalMachine\$store\$hash" -ErrorAction Stop
                        $dns = @($c.DnsNameList | Where-Object { $_ -and -not ([string]$_).StartsWith('*') })
                        if ($dns.Count) { $name = [string]$dns[0] }
                    } catch { }
                    $ip = $hp.Substring(0, $hp.LastIndexOf(':')).Trim('[', ']')
                    if ($ip -eq '0.0.0.0' -or $ip -eq '::') { $ip = '127.0.0.1' }
                    $list += "${ip}:$port/$name"
                }
                $bind = $null
            }
        }
    }
    M 'bindings_found' $list.Count
}
Read-Certs $list
exit 0
