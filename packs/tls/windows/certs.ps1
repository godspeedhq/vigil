#Requires -Version 5.1

<#
.SYNOPSIS
    certs.ps1 - TLS certificates, from a handshake with each target: expiry, validity, trust, the name, and how long the handshake took, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Makes a TLS handshake with each target in TLS_TARGETS, as a client
    would, and reports the certificate it is given: the days until it
    expires, whether today is within its dates, whether it checks against
    the trusted CAs (or TLS_CACERT), and whether it is for the name asked
    for; and the handshake itself: whether it finished, why not, how long
    it took, and the TLS version agreed. It reads what clients get, so it
    also catches a certificate renewed on disk that the server has not
    loaded yet.

    Nothing is sent but the handshake: no request, no login. Any service
    that speaks TLS from its first byte works (HTTPS, LDAPS, SMTPS, IMAPS, a
    database's TLS port, a Kubernetes API); a service that starts in plain
    text and turns to TLS (STARTTLS) does not. Each target has TLS_TIMEOUT
    seconds (10 by default) to finish. Trust is Windows' own: the machine's
    and this account's trusted roots.

    TLS_TARGETS lists the targets, separated by spaces: host, host:port, or
    either followed by /name to ask for a name (SNI) other than the host
    (port 443 when none is given; an IPv6 address in brackets, [::1]:443).
    TLS_CACERT, a CA file (PEM or DER), checks certificates from a private
    CA as well as the trusted ones.

    Metrics:
      targets              the targets in TLS_TARGETS
      targets_failed       of those, how many failed a check: the handshake,
                           the dates, trust or the name
      soonest_days         days until the first of their certificates
                           expires (below 0: one has expired); none when no
                           target answered
      up                   1 when the handshake finished, else 0; tagged
                           target=<as listed> and reason=<ok, refused,
                           no_such_host, unreachable, timeout,
                           handshake_failed>; the rest only when it finished
      handshake_ms         the time to connect and finish the handshake
      cert_expires_days    days until the certificate expires (below 0:
                           expired)
      cert_valid           1 when today is within its dates, else 0
      cert_trusted         1 when its chain checks against the trusted CAs
                           (or TLS_CACERT), else 0, tagged reason=<Windows'
                           words for what is wrong, or ok>
      cert_name_ok         1 when it is for the name asked for, else 0
      cert_info            always 1, tagged issuer=<its CN>, subject=<its
                           CN> and protocol=<the TLS version agreed>
      targets_not_shown    targets past the first 50, left out

    Example output (the rest are in the same form):
      metric up 1 target=example.com reason=ok
      metric handshake_ms 48 target=example.com
      metric cert_expires_days 74.21 target=example.com
      metric cert_valid 1 target=example.com
      metric cert_trusted 1 target=example.com reason=ok
      metric cert_name_ok 1 target=example.com
      metric cert_info 1 target=example.com issuer=R11 subject=example.com protocol=TLSv1.3
      metric up 0 target=old.example.com:8443 reason=refused
      metric targets 2
      metric targets_failed 1
      metric soonest_days 74.21

    Reading the results (starting points: tune them to how you renew):
      Healthy  up 1; cert_expires_days above 30; cert_valid, cert_trusted
               and cert_name_ok 1; targets_failed 0.
      Watch    cert_expires_days below 30: automatic renewal (Let's
               Encrypt, 30 days ahead) should have happened, so it is not
               working; handshake_ms well above its usual.
      Act      cert_expires_days below 7; cert_valid 0 (expired, or not yet
               valid); cert_trusted 0 (reason says why: clients that check,
               all browsers, refuse it now); cert_name_ok 0 (served for the
               wrong name); up 0 (reason says why).

    Requires: PowerShell 5.1 or later, nothing else
    Exit code: 0, whatever the certificates; 1 if TLS_CACERT cannot be read

    Example (vigil.config):
      [job.tls_certs]
      file        = packs\tls\certs.ps1
      metric_name = tls
      run_every   = 15m
      env         = TLS_TARGETS=example.com mail.example.com:993 10.0.0.5:8443/app.internal
#>

$ErrorActionPreference = 'Stop'
$Job = 'certs'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$Limit = 10
if ($env:TLS_TIMEOUT -match '^[0-9]+$') { $Limit = [int]$env:TLS_TIMEOUT }

function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
function Days([double]$d) { $d.ToString('0.00', $Inv) }

$Ca = $null
if ($env:TLS_CACERT) {
    try { $Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:TLS_CACERT }
    catch { [Console]::Error.WriteLine("${Job}: TLS_CACERT: cannot read $($env:TLS_CACERT)"); exit 1 }
}

# The handshake's callback: keeps what the server sent and what Windows
# thought of it, and lets every certificate through: the job reads it and
# sends nothing.
$script:Seen = $null
$script:Errors = $null
$script:Why = $null
$Keep = [System.Net.Security.RemoteCertificateValidationCallback] {
    param($Sender, $Cert, $Chain, $Errors)
    $script:Seen = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cert
    $script:Errors = $Errors
    $script:Why = ''
    if (($Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) -ne 0) {
        # The chain again, to say why in Windows' words (NotTimeValid,
        # UntrustedRoot, PartialChain), and with TLS_CACERT as a root.
        $c = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $c.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        if ($Ca) {
            $c.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
            [void]$c.ChainPolicy.ExtraStore.Add($Ca)
        }
        # The intermediates the server sent: .NET Framework has them in the
        # chain's elements, PowerShell 7's .NET in its extra store.
        foreach ($e in @($Chain.ChainElements)) { if ($e.Certificate.Thumbprint -ne $script:Seen.Thumbprint) { [void]$c.ChainPolicy.ExtraStore.Add($e.Certificate) } }
        foreach ($x in @($Chain.ChainPolicy.ExtraStore)) { if ($x) { [void]$c.ChainPolicy.ExtraStore.Add($x) } }
        $built = $c.Build($script:Seen)
        $caRoot = $Ca -and $c.ChainElements[$c.ChainElements.Count - 1].Certificate.Thumbprint -eq $Ca.Thumbprint
        if ($built -and $caRoot) {
            $script:Errors = $Errors -band (-bnot [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
        } else {
            $script:Why = @($c.ChainStatus | ForEach-Object { [string]$_.Status } | Where-Object { -not ($caRoot -and $_ -eq 'UntrustedRoot') } | Select-Object -Unique) -join '+'
        }
    }
    return $true
}

# The versions to offer: what the system allows on PowerShell 7; on 5.1,
# TLS 1.2 and 1.3 where this .NET knows 1.3 (and 1.2 alone, again, where
# Windows refuses to offer 1.3).
$P = [System.Security.Authentication.SslProtocols]
$Offer = @($P::Tls12)
if ($PSVersionTable.PSEdition -eq 'Core') { $Offer = @($P::None) }
elseif ([enum]::IsDefined($P, 'Tls13')) { $Offer = @(($P::Tls12 -bor $P::Tls13), $P::Tls12) }

# Try-Handshake: one handshake; returns why it failed, or '' when it did not.
function Try-Handshake([string]$Connect, [int]$Port, [string]$Name, $Protocols, $Clock) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        try {
            $wait = $tcp.BeginConnect($Connect, $Port, $null, $null)
            if (-not $wait.AsyncWaitHandle.WaitOne($Limit * 1000)) { return 'timeout' }
            $tcp.EndConnect($wait)
        } catch {
            $x = $_.Exception
            while ($x -and -not ($x -is [System.Net.Sockets.SocketException])) { $x = $x.InnerException }
            if (-not $x) { return 'handshake_failed' }
            switch ([string]$x.SocketErrorCode) {
                'ConnectionRefused' { return 'refused' }
                { $_ -in 'HostNotFound', 'NoData', 'TryAgain' } { return 'no_such_host' }
                { $_ -in 'HostUnreachable', 'NetworkUnreachable' } { return 'unreachable' }
                'TimedOut' { return 'timeout' }
                default { return 'handshake_failed' }
            }
        }
        $left = [Math]::Max(1000, $Limit * 1000 - [int]$Clock.ElapsedMilliseconds)
        $s = $tcp.GetStream(); $s.ReadTimeout = $left; $s.WriteTimeout = $left
        $ssl = New-Object System.Net.Security.SslStream($s, $false, $Keep)
        try {
            $ssl.AuthenticateAsClient($Name, $null, $Protocols, $false)
            $script:Proto = [string]$ssl.SslProtocol
            return ''
        } catch {
            if ($Clock.ElapsedMilliseconds -ge $Limit * 1000) { return 'timeout' }
            return 'handshake_failed'
        }
    } finally { $tcp.Close() }
}

$list = @(([string]$env:TLS_TARGETS) -split '\s+' | Where-Object { $_ })
$n = 0
$failed = 0
$soonest = $null
foreach ($e in $list) {
    if (++$n -gt 50) { continue }
    $t = "target=$(Safe $e)"
    $hp, $name = $e -split '/', 2
    if ($hp -match '^\[(.+)\]:([0-9]+)$') { $hostName = $Matches[1]; $port = [int]$Matches[2] }
    elseif ($hp -match '^\[(.+)\]$') { $hostName = $Matches[1]; $port = 443 }
    elseif ($hp -match '^(.+):([0-9]+)$') { $hostName = $Matches[1]; $port = [int]$Matches[2] }
    else { $hostName = $hp; $port = 443 }
    if (-not $name) { $name = $hostName }
    $script:Seen = $null; $script:Proto = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $down = ''
    foreach ($o in $Offer) {
        $down = Try-Handshake $hostName $port $name $o $clock
        if (-not $down -or $script:Seen -or $down -ne 'handshake_failed') { break }
    }
    $clock.Stop()
    if (-not $script:Seen) {
        "metric up 0 $t reason=$down"
        $failed++
        continue
    }
    "metric up 1 $t reason=ok"
    "metric handshake_ms $($clock.ElapsedMilliseconds) $t"
    $c = $script:Seen
    $end = ([DateTimeOffset]$c.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()
    $begin = ([DateTimeOffset]$c.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()
    $days = ($end - $Now) / 86400.0
    "metric cert_expires_days $(Days $days) $t"
    $valid = [int]($Now -lt $end -and $begin -le $Now)
    "metric cert_valid $valid $t"
    if ($null -eq $soonest -or $days -lt $soonest) { $soonest = $days }
    $E = [System.Net.Security.SslPolicyErrors]
    $trusted = [int](($script:Errors -band ($E::RemoteCertificateChainErrors -bor $E::RemoteCertificateNotAvailable)) -eq 0)
    $reason = if ($trusted) { 'ok' } elseif ($script:Why) { $script:Why } else { [string]$script:Errors -replace ', ', '+' }
    "metric cert_trusted $trusted $t reason=$(Safe $reason)"
    $nameOk = [int](($script:Errors -band $E::RemoteCertificateNameMismatch) -eq 0)
    "metric cert_name_ok $nameOk $t"
    $proto = switch ($script:Proto) { 'Tls13' { 'TLSv1.3' } 'Tls12' { 'TLSv1.2' } 'Tls11' { 'TLSv1.1' } 'Tls' { 'TLSv1' } default { 'unknown' } }
    $issuer = $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
    $subject = $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    "metric cert_info 1 $t issuer=$(Safe $issuer) subject=$(Safe $subject) protocol=$proto"
    if (-not ($valid -and $trusted -and $nameOk)) { $failed++ }
}
"metric targets $n"
"metric targets_failed $failed"
if ($null -ne $soonest) { "metric soonest_days $(Days $soonest)" }
if ($n -gt 50) { "metric targets_not_shown $($n - 50)" }
exit 0
