<#
.SYNOPSIS
    _@p@.ps1 - what the @p@ pack's scripts share on Windows: the settings, the login, one request to @P@'s REST API, and the helpers that print. Each job's script dot-sources it; it is never run as a job.
.NOTES
@NOTICE@
.DESCRIPTION
    Reads @P@ at @E@_URL (default https://localhost:9200)@AUTHDOC@

    It speaks HTTP itself, with .NET's own TCP and TLS: there is nothing to
    install, and the same on Windows PowerShell 5.1 and PowerShell 7. Over
    https, the certificate is checked against Windows' trusted CAs, or
    against @E@_CACERT, a CA file, when it is set, and against the
    server's name. Every request only reads.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Url = if ($env:@E@_URL) { $env:@E@_URL.TrimEnd('/') } else { 'https://localhost:9200' }
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
# The login, as a header made here: never on a command line.
$script:Auth = $null
@LOGIN@

function Get-InnerMessage($E) {
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# @E@_CACERT: the server's certificate must chain to this CA, and name the
# server. Called by .NET during the handshake, on this thread.
$script:Ca = $null
if ($env:@E@_CACERT) {
    try { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:@E@_CACERT }
    catch { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: @E@_CACERT: cannot read $($env:@E@_CACERT): $(Get-InnerMessage $_.Exception)"); exit 1 }
}
$script:CheckCert = [System.Net.Security.RemoteCertificateValidationCallback] {
    param($Sender, $Cert, $Chain, $Errors)
    if ($Errors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
    if ($Errors -ne [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) { return $false }
    $c = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $c.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $c.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    [void]$c.ChainPolicy.ExtraStore.Add($script:Ca)
    if (-not $c.Build((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cert))) { return $false }
    $top = $c.ChainElements[$c.ChainElements.Count - 1].Certificate
    if ($top.Thumbprint -ne $script:Ca.Thumbprint) { return $false }
    foreach ($s in $c.ChainStatus) {
        if ($s.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot) { return $false }
    }
    return $true
}

# Where a byte sequence starts in an array, from a position; -1 when it is not there.
function Find-Bytes([byte[]]$b, [byte[]]$what, [int]$from) {
    for ($i = $from; $i -le $b.Length - $what.Length; $i++) {
        $ok = $true
        for ($k = 0; $k -lt $what.Length; $k++) { if ($b[$i + $k] -ne $what[$k]) { $ok = $false; break } }
        if ($ok) { return $i }
    }
    return -1
}
# A body sent in chunks (Transfer-Encoding: chunked), put back together.
function Join-Chunks([byte[]]$b, [int]$i) {
    $ms = New-Object System.IO.MemoryStream
    $crlf = [byte[]](13, 10)
    while ($i -lt $b.Length) {
        $e = Find-Bytes $b $crlf $i
        if ($e -lt 0) { break }
        $line = [Text.Encoding]::ASCII.GetString($b, $i, $e - $i)
        $semi = $line.IndexOf(';')
        if ($semi -ge 0) { $line = $line.Substring(0, $semi) }
        $size = [Convert]::ToInt32($line.Trim(), 16)
        $i = $e + 2
        if ($size -eq 0) { break }
        $ms.Write($b, $i, [Math]::Min($size, $b.Length - $i))
        $i += $size + 2
    }
    return , $ms.ToArray()
}

# Get-Answer <path> [<request body>]: @{ State = ok, down, unsupported,
# forbidden, nomaster or failed; Head; Body; Why }. HTTP/1.1, one request
# a connection.
function Get-Answer([string]$path, [string]$body) {
    $u = [Uri]($script:Url + $path)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        try {
            $wait = $tcp.BeginConnect($u.Host, $u.Port, $null, $null)
            if (-not $wait.AsyncWaitHandle.WaitOne(10000)) { return @{ State = 'down'; Why = "no answer from $($u.Host):$($u.Port) in 10 seconds" } }
            $tcp.EndConnect($wait)
        } catch {
            return @{ State = 'down'; Why = (Get-InnerMessage $_.Exception) }
        }
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 30000
        $stream.WriteTimeout = 30000
        if ($u.Scheme -eq 'https') {
            if ($script:Ca) { $ssl = New-Object System.Net.Security.SslStream($stream, $false, $script:CheckCert) }
            else { $ssl = New-Object System.Net.Security.SslStream($stream, $false) }
            # Windows PowerShell's .NET offers TLS 1.2 only when asked;
            # PowerShell 7 takes what the system allows.
            $protocols = [System.Security.Authentication.SslProtocols]::Tls12
            if ($PSVersionTable.PSEdition -eq 'Core') { $protocols = [System.Security.Authentication.SslProtocols]::None }
            try { $ssl.AuthenticateAsClient($u.Host, $null, $protocols, $false) }
            catch { return @{ State = 'failed'; Why = "the TLS handshake with $($u.Host) failed: $(Get-InnerMessage $_.Exception)" } }
            $stream = $ssl
        }
        $req = "GET $($u.PathAndQuery) HTTP/1.1`r`nHost: $($u.Authority)`r`nUser-Agent: vigil-@p@`r`nAccept: application/json`r`nAccept-Encoding: identity`r`nConnection: close`r`n"
        if ($script:Auth) { $req += "Authorization: $($script:Auth)`r`n" }
        $data = $null
        if ($body) {
            $data = [Text.Encoding]::UTF8.GetBytes($body)
            $req += "Content-Type: application/json`r`nContent-Length: $($data.Length)`r`n"
        }
        $head = [Text.Encoding]::ASCII.GetBytes($req + "`r`n")
        $stream.Write($head, 0, $head.Length)
        if ($data) { $stream.Write($data, 0, $data.Length) }
        $stream.Flush()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        while ($true) {
            try { $n = $stream.Read($buf, 0, $buf.Length) }
            catch { if ($ms.Length -gt 0) { break } else { throw } }
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
    } catch {
        return @{ State = 'failed'; Why = "$($script:Url)${path}: $(Get-InnerMessage $_.Exception)" }
    } finally {
        $tcp.Close()
    }
    $all = $ms.ToArray()
    $end = Find-Bytes $all ([byte[]](13, 10, 13, 10)) 0
    if ($end -lt 0) { return @{ State = 'failed'; Why = "$($script:Url)$path answered, but not in HTTP" } }
    $lines = [Text.Encoding]::ASCII.GetString($all, 0, $end) -split "`r`n"
    if ($lines[0] -notmatch '^HTTP/\d(\.\d)? (\d{3})') { return @{ State = 'failed'; Why = "$($script:Url)$path answered, but not in HTTP" } }
    $status = [int]$Matches[2]
    $headers = @{}
    foreach ($l in $lines[1..($lines.Count - 1)]) {
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
    }
    if ($headers['transfer-encoding'] -match 'chunked') { $bytes = Join-Chunks $all ($end + 4) }
    else { $bytes = New-Object byte[] ($all.Length - $end - 4); [Array]::Copy($all, $end + 4, $bytes, 0, $bytes.Length) }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    switch ($status) {
        200 { return @{ State = 'ok'; Head = $headers; Body = $text } }
        401 { return @{ State = 'failed'; Why = "@P@ refused the login (HTTP 401): @LOGINWHAT@ wrong" } }
        403 { return @{ State = 'forbidden' } }
        { $_ -in 400, 404, 405, 501 } { return @{ State = 'unsupported' } }
        503 { return @{ State = 'nomaster' } }
        default { return @{ State = 'failed'; Why = "$($script:Url)$path answered HTTP $status" } }
    }
}

# Get-Page <path> [<request body>]: @{ State; Data }: the answer, as objects.
function Get-Page([string]$path, [string]$body) {
    $r = Get-Answer $path $body
    if ($r.State -eq 'failed') { [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
    if ($r.State -ne 'ok') { return @{ State = $r.State } }
    return @{ State = 'ok'; Data = ($r.Body | ConvertFrom-Json) }
}
# Need-Page <path> [<request body>]: the answer, as objects, or stop, saying why.
function Need-Page([string]$path, [string]$body) {
    $r = Get-Page $path $body
    if ($r.State -eq 'ok') { return , $r.Data }
    Stop-Why $r.State $path
}
# Stop-Why <Get-Page's state> <path>: stop, saying why.
function Stop-Why([string]$state, [string]$path) {
    switch ($state) {
        'down' { [Console]::Error.WriteLine("${Job}: @P@ stopped answering at $path") }
        'unsupported' { [Console]::Error.WriteLine("${Job}: @P@ has no $path here (an older version, or a feature that is off)") }
        'forbidden' { [Console]::Error.WriteLine("${Job}: this user may not read ${path}: give it the role packs/@p@/README.md shows") }
        'nomaster' { [Console]::Error.WriteLine("${Job}: @P@ answered $path with HTTP 503: the cluster has no elected @MW@") }
    }
    exit 1
}
# First: @P@'s own page (/), which every job reads first: up, and that it
# is @P@. Kept in $script:Root.
function Read-First {
    $r = Get-Answer '/?filter_path=name,cluster_name,version.number,version.distribution,tagline'
    switch ($r.State) {
        'ok' { }
        'down' { Write-Output 'metric up 0'; exit 0 }
        'failed' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
        'forbidden' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: this user may not read @P@'s own page (/): give it the role packs/@p@/README.md shows"); exit 1 }
        default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url) answers, but not as @P@"); exit 1 }
    }
    $root = $r.Body | ConvertFrom-Json
@PRODUCT@
    $script:Root = $root
    Write-Output 'metric up 1'
}

# A tag's value: no spaces, quotes or control characters, never empty, at
# most 120 characters.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A number from anything: nothing is 0, true is 1, '45.3%' is 45.3.
function N($v) {
    if ($null -eq $v) { return [double]0 }
    if ($v -is [bool]) { if ($v) { return [double]1 } else { return [double]0 } }
    if ($v -is [string]) {
        $d = [double]0
        if ([double]::TryParse($v.TrimEnd('%'), [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
        return [double]0
    }
    return [double]$v
}
# Two decimals at most, as jq prints them.
function R2($v) { return [Math]::Round((N $v), 2, [MidpointRounding]::AwayFromZero) }
function Pct($a, $b) { if ((N $b) -gt 0) { return (R2 (100 * (N $a) / (N $b))) } else { return [double]0 } }
function Code($s) { switch ([string]$s) { 'green' { 0 } 'yellow' { 1 } 'red' { 2 } default { 3 } } }
# metric <name> <value> [tags]
function M([string]$name, $v, [string]$tags) {
    $t = if ($tags) { ' ' + $tags } else { '' }
    "metric $name $((N $v).ToString('0.##', $script:Inv))$t"
}
# An object's properties' values (a JSON map's), never null.
function Values($o) { if ($null -eq $o) { return @() } else { return @($o.PSObject.Properties | ForEach-Object { $_.Value }) } }
function Props($o) { if ($null -eq $o) { return @() } else { return @($o.PSObject.Properties) } }
# Seconds since 1970, from an ISO time (PowerShell 7 makes it a date
# already); $null when there is none.
function Epoch($s) {
    if (-not $s) { return $null }
    if ($s -is [datetime]) { return ([DateTimeOffset]$s.ToUniversalTime()).ToUnixTimeSeconds() }
    return [DateTimeOffset]::Parse([string]$s, $script:Inv).ToUnixTimeSeconds()
}
