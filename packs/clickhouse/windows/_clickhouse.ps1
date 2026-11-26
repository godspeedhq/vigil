<#
.SYNOPSIS
    _clickhouse.ps1 - what the clickhouse pack's scripts share on Windows: the settings, the login, one SELECT over ClickHouse's HTTP interface, and the helpers that print. Each job's script dot-sources it; it is never run as a job.
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0
    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads the ClickHouse server at CLICKHOUSE_URL (default
    http://localhost:8123), its HTTP interface, as CLICKHOUSE_USER (default
    vigil) with the password in CLICKHOUSE_PASSWORD (a secret), sent as
    headers of the request made in memory, never on a command line.
    It speaks HTTP itself, with .NET's own TCP and TLS: there is nothing to
    install, and the same on Windows PowerShell 5.1 and PowerShell 7. Over
    https, the certificate is checked against Windows' trusted CAs, or
    against CLICKHOUSE_CACERT when it is set, and against the server's name.
    Every statement is a SELECT from the system tables, and the user is made
    read-only (readonly = 1), so the server itself refuses anything else.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Url = if ($env:CLICKHOUSE_URL) { $env:CLICKHOUSE_URL.TrimEnd('/') } else { 'http://localhost:8123' }
$script:User = if ($null -ne $env:CLICKHOUSE_USER) { $env:CLICKHOUSE_USER } else { 'vigil' }
$script:Most = if ($env:CLICKHOUSE_MOST) { $env:CLICKHOUSE_MOST } else { '50' }
$script:Ca = $null

function Get-InnerMessage($E) {
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# CLICKHOUSE_CACERT: the server's certificate must chain to this CA, and
# name the server. Called by .NET during the handshake, on this thread.
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
# Get-Answer <path> [<body>]: @{ State = ok, down or failed; Status; Body;
# Why }. A body makes it a POST. HTTP/1.1, one request a connection.
function Get-Answer([string]$path, [string]$body, [int]$timeout = 50000) {
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
        $stream.ReadTimeout = $timeout
        $stream.WriteTimeout = $timeout
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
        $method = if ($body) { 'POST' } else { 'GET' }
        $req = "$method $($u.PathAndQuery) HTTP/1.1`r`nHost: $($u.Authority)`r`nUser-Agent: vigil-clickhouse`r`nAccept-Encoding: identity`r`nConnection: close`r`n"
        if ($script:User) {
            $req += "X-ClickHouse-User: $($script:User)`r`n"
            if ($env:CLICKHOUSE_PASSWORD) { $req += "X-ClickHouse-Key: $($env:CLICKHOUSE_PASSWORD)`r`n" }
        }
        $data = $null
        if ($body) {
            $data = [Text.Encoding]::UTF8.GetBytes($body)
            $req += "Content-Type: text/plain; charset=utf-8`r`nContent-Length: $($data.Length)`r`n"
        }
        $head = [Text.Encoding]::UTF8.GetBytes($req + "`r`n")
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
        if ((Get-InnerMessage $_.Exception) -match 'timed out|period of time') { return @{ State = 'down'; Why = "$($script:Url)${path}: no answer in $($timeout / 1000) seconds" } }
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
    $chunked = $false
    foreach ($l in $lines[1..($lines.Count - 1)]) { if ($l -match '^transfer-encoding:.*chunked') { $chunked = $true } }
    if ($chunked) { $bytes = Join-Chunks $all ($end + 4) }
    else { $bytes = New-Object byte[] ($all.Length - $end - 4); [Array]::Copy($all, $end + 4, $bytes, 0, $bytes.Length) }
    return @{ State = 'ok'; Status = $status; Body = [Text.Encoding]::UTF8.GetString($bytes) }
}

# Up: "metric up 1" when the server answers /ping, else "metric up 0" and
# the run ends, successfully: a server down is a reading. The CA is read
# here, not as this file is dot-sourced: exit there would end only it.
function Up {
    if ($script:Most -notmatch '^\d+$') { [Console]::Error.WriteLine("${Job}: CLICKHOUSE_MOST is '$($script:Most)': a number"); exit 1 }
    if ($env:CLICKHOUSE_CACERT) {
        try { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:CLICKHOUSE_CACERT }
        catch { 'metric up 0'; [Console]::Error.WriteLine("${Job}: CLICKHOUSE_CACERT: cannot read $($env:CLICKHOUSE_CACERT): $(Get-InnerMessage $_.Exception)"); exit 1 }
    }
    $r = Get-Answer '/ping' '' 15000
    if ($r.State -eq 'down') { 'metric up 0'; exit 0 }
    if ($r.State -ne 'ok') { 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
    if ($r.Status -ne 200 -or $r.Body -cne "Ok.`n") { 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/ping answered HTTP $($r.Status), not as ClickHouse does"); exit 1 }
    'metric up 1'
}

# Get-Rows <statement>: its rows, each as an object, one by one (callers
# collect them with @()); $script:NoTable is set when the server has no
# such table or column (an older version). Else the run ends, saying why.
function Get-Rows([string]$sql) {
    $script:NoTable = $false
    $r = Get-Answer '/' "$sql FORMAT JSONEachRow"
    if ($r.State -eq 'down') { [Console]::Error.WriteLine("${Job}: ClickHouse stopped answering at $($script:Url)"); exit 1 }
    if ($r.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
    if ($r.Status -ne 200) {
        $m = ($r.Body -replace '\s+', ' ')
        if ($m.Length -gt 400) { $m = $m.Substring(0, 400) }
        if ($m -match 'Code: (60|47|16)\.') { $script:NoTable = $true; return }
        if ($m -match 'Code: (516|192|194)\.') { [Console]::Error.WriteLine("${Job}: ClickHouse refused the login: CLICKHOUSE_USER or CLICKHOUSE_PASSWORD is wrong"); exit 1 }
        if ($m -match 'Code: 497\.') { [Console]::Error.WriteLine("${Job}: $($script:User) may not read the system tables: GRANT SELECT ON system.* TO $($script:User) (packs/clickhouse/README.md)"); exit 1 }
        $m = $m -replace ' \(version.*', ''
        [Console]::Error.WriteLine("${Job}: $($script:Url) answered HTTP $($r.Status): $m")
        exit 1
    }
    foreach ($l in ($r.Body -split "`n")) {
        if ($l.Trim()) {
            try { $l | ConvertFrom-Json }
            catch { [Console]::Error.WriteLine("${Job}: $($script:Url) answered, but not with rows of JSON"); exit 1 }
        }
    }
}

# A tag's value: no spaces, quotes or control characters, never empty, at
# most 120 characters.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A number from anything: nothing is 0, true is 1. ClickHouse writes 64-bit
# numbers in quotes.
function N($v) {
    if ($null -eq $v) { return [double]0 }
    if ($v -is [bool]) { if ($v) { return [double]1 } else { return [double]0 } }
    if ($v -is [string]) {
        $d = [double]0
        if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
        return [double]0
    }
    return [double]$v
}
# metric <name> <value> [tags]: two decimals at most, as the scripts for
# Linux and macOS print them.
function M([string]$name, $v, [string]$tags) {
    $t = if ($tags) { ' ' + $tags } else { '' }
    "metric $name $((N $v).ToString('0.##', $script:Inv))$t"
}
