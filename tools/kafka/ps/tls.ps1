    # The certificate each broker presents on the listener this pack connects
    # to: how many days until it expires, and whether it is trusted (by
    # KAFKA_CACERT, or Windows' trusted CAs) and names the broker. The brokers
    # are those the cluster lists, as it tells clients to reach them; or
    # KAFKA_TLS_ENDPOINTS, host:port, comma-separated. Without TLS: tls 0.
    if ($security -cne 'SSL' -and $security -cne 'SASL_SSL' -and -not $env:KAFKA_TLS_ENDPOINTS) { Write-Output 'metric tls 0'; return }
    if ($env:KAFKA_TLS_ENDPOINTS) { $eps = @($env:KAFKA_TLS_ENDPOINTS -split '[,\s]+' | Where-Object { $_ }) }
    else {
        # The brokers as the cluster lists them; when it cannot be asked (a
        # certificate it does not trust is what this job is for), the
        # bootstrap list.
        $rc = Invoke-BrokersList -Lenient
        if ($rc -eq 2) { return }
        if ($rc -eq 0) { $eps = @($script:out -split "`r?`n" | ForEach-Object { if ($_ -cmatch '^(\S+:\d+) \(id: ') { $Matches[1] } } | Sort-Object -Unique) }
        else { $eps = @($bootstrap -split ',' | Where-Object { $_ }) }
    }
    # The CAs KAFKA_CACERT gives, besides Windows' own.
    $cas = @()
    if ($env:KAFKA_CACERT) {
        $pem = [System.IO.File]::ReadAllText($env:KAFKA_CACERT)
        foreach ($m in [regex]::Matches($pem, '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', 'Singleline')) {
            $cas += New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', '')))
        }
    }
    Write-Output 'metric tls 1'
    foreach ($ep in $eps) {
        $i = $ep.LastIndexOf(':')
        $hostName = $ep.Substring(0, $i).Trim('[', ']'); $port = [int]$ep.Substring($i + 1)
        $tag = "endpoint=$(ConvertTo-Tag $ep)"
        $script:tlsCert = $null; $script:tlsErrors = $null
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            # Ten seconds to connect, and ten for the handshake.
            if (-not $tcp.ConnectAsync($hostName, $port).Wait(10000)) { throw 'timeout' }
            $tcp.ReceiveTimeout = 10000; $tcp.SendTimeout = 10000
            # The certificate is kept whatever its standing, so that an
            # untrusted one is still read; trust is judged below.
            $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $script:tlsCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $c; $script:tlsErrors = $e; return $true }
            $ssl = New-Object System.Net.Security.SslStream ($tcp.GetStream(), $false, $cb)
            $ssl.AuthenticateAsClient($hostName)
            $ssl.Dispose()
        }
        catch { }
        finally { $tcp.Dispose() }
        if (-not $script:tlsCert) { Write-Output "metric reachable 0 $tag"; continue }
        Write-Output "metric reachable 1 $tag"
        Write-Output "metric expires_days $([long][Math]::Floor(($script:tlsCert.NotAfter.ToUniversalTime() - [DateTime]::UtcNow).TotalDays)) $tag"
        $e = $script:tlsErrors
        $trusted = $e -eq [System.Net.Security.SslPolicyErrors]::None
        # Not trusted by Windows, but its name matches: trusted when its chain
        # ends at a CA KAFKA_CACERT gives.
        if (-not $trusted -and $cas.Count -and -not ($e -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)) {
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = 'NoCheck'
            $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
            foreach ($ca in $cas) { [void]$chain.ChainPolicy.ExtraStore.Add($ca) }
            if ($chain.Build($script:tlsCert)) {
                $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
                $trusted = [bool]($cas | Where-Object { $_.Thumbprint -ceq $root.Thumbprint })
            }
        }
        Write-Output "metric trusted $([int]$trusted) $tag"
    }
    Write-Output "metric endpoints $($eps.Count)"
