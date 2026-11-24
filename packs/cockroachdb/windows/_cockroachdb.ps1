<#
.SYNOPSIS
    _cockroachdb.ps1 - what the cockroachdb pack's scripts share on Windows: the settings, the node's metrics, the login, one read of CockroachDB's HTTP API, and the helpers that print. Each job's script dot-sources it; it is never run as a job.
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0
    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads the CockroachDB node at COCKROACH_URL (default
    https://localhost:8080), its HTTP port (the DB Console's). A node's own
    metrics (/_status/vars) and health need no login. The cluster's nodes and
    jobs do: COCKROACH_USER with the password in COCKROACH_PASSWORD (a
    secret), sent in the request's body, never on a command line; an
    insecure cluster needs none.
    It speaks HTTP itself, with .NET's own TCP and TLS: there is nothing to
    install, and the same on Windows PowerShell 5.1 and PowerShell 7. Over
    https, the certificate is checked against Windows' trusted CAs, or
    against COCKROACH_CACERT, the cluster's CA file (ca.crt), when it is set,
    and against the node's name. Every request only reads: the SQL the jobs
    send is SELECT and SHOW.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Url = if ($env:COCKROACH_URL) { $env:COCKROACH_URL.TrimEnd('/') } else { 'https://localhost:8080' }
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$script:Session = $null

function Get-InnerMessage($E) {
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# COCKROACH_CACERT: the node's certificate must chain to this CA, and name
# the node. Called by .NET during the handshake, on this thread.
$script:Ca = $null
if ($env:COCKROACH_CACERT) {
    try { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:COCKROACH_CACERT }
    catch { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: COCKROACH_CACERT: cannot read $($env:COCKROACH_CACERT): $(Get-InnerMessage $_.Exception)"); exit 1 }
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
# Get-Answer <path> [<body> [<content type>]]: @{ State = ok, down,
# unready, forbidden or failed; Body; Why }. A body makes it a POST.
# HTTP/1.1, one request a connection.
function Get-Answer([string]$path, [string]$body, [string]$type = 'application/json') {
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
        $method = if ($body) { 'POST' } else { 'GET' }
        $req = "$method $($u.PathAndQuery) HTTP/1.1`r`nHost: $($u.Authority)`r`nUser-Agent: vigil-cockroachdb`r`nAccept: application/json`r`nAccept-Encoding: identity`r`nConnection: close`r`n"
        if ($script:Session) { $req += "X-Cockroach-API-Session: $($script:Session)`r`n" }
        $data = $null
        if ($body) {
            $data = [Text.Encoding]::UTF8.GetBytes($body)
            $req += "Content-Type: $type`r`nContent-Length: $($data.Length)`r`n"
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
        if ((Get-InnerMessage $_.Exception) -match 'timed out|period of time') { return @{ State = 'down'; Why = "$($script:Url)${path}: no answer in 30 seconds" } }
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
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    switch ($status) {
        200 { return @{ State = 'ok'; Body = $text } }
        401 { return @{ State = 'failed'; Why = 'CockroachDB refused the login (HTTP 401): COCKROACH_USER or COCKROACH_PASSWORD is wrong' } }
        403 { return @{ State = 'forbidden' } }
        503 { return @{ State = 'unready' } }
        default { return @{ State = 'failed'; Why = "$($script:Url)$path answered HTTP $status" } }
    }
}

# Read-Vars: the node's metrics (/_status/vars), each name's values, and
# "metric up". A node that does not answer is up 0, and the run succeeds.
$script:Vars = @{}
function Read-Vars {
    $r = Get-Answer '/_status/vars'
    switch ($r.State) {
        'ok' { }
        'down' { Write-Output 'metric up 0'; exit 0 }
        'failed' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
        default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/_status/vars answered, but not with its metrics"); exit 1 }
    }
    foreach ($l in ($r.Body -split "`n")) {
        if ($l.Length -eq 0 -or $l[0] -eq '#') { continue }
        $sp = $l.LastIndexOf(' ')
        if ($sp -lt 1) { continue }
        $br = $l.IndexOf('{')
        $name = if ($br -gt 0 -and $br -lt $sp) { $l.Substring(0, $br) } else { $l.Substring(0, $sp) }
        $v = [double]0
        if (-not [double]::TryParse($l.Substring($sp + 1), [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { continue }
        if (-not $script:Vars.ContainsKey($name)) { $script:Vars[$name] = New-Object 'System.Collections.Generic.List[object]' }
        $script:Vars[$name].Add(@{ Line = $l; Value = $v })
    }
    if (-not $script:Vars.ContainsKey('build_timestamp')) {
        Write-Output 'metric up 0'
        [Console]::Error.WriteLine("${Job}: $($script:Url) answers, but not as a CockroachDB node (no build_timestamp in /_status/vars)")
        exit 1
    }
    Write-Output 'metric up 1'
}
# Series <name>: a metric's series, @{ Line; Value } each, as a plain array
# (none when the node has no such metric).
function Series([string]$name) {
    if (-not $script:Vars.ContainsKey($name)) { return , @() }
    return , $script:Vars[$name].ToArray()
}
# Prom <name> [sum|max|min]: a metric of the node's, every series of it
# together (the sum: a node with two stores counts both), or the largest or
# smallest; $null when the node has no such metric.
function Prom([string]$name, [string]$how = 'sum') {
    if (-not $script:Vars.ContainsKey($name)) { return $null }
    $r = $null
    foreach ($s in $script:Vars[$name]) {
        if ($null -eq $r) { $r = $s.Value }
        elseif ($how -eq 'max') { if ($s.Value -gt $r) { $r = $s.Value } }
        elseif ($how -eq 'min') { if ($s.Value -lt $r) { $r = $s.Value } }
        else { $r += $s.Value }
    }
    return $r
}
# Say <name> <metric> [sum|max|min] [divide by] [times]: "metric <name> <v>"
# when the node has it, divided or multiplied, two decimals when it is not
# whole.
function Say([string]$out, [string]$name, [string]$how = 'sum', [double]$div = 1, [double]$times = 1) {
    $v = Prom $name $how
    if ($null -eq $v) { return }
    M $out ($v * $times / $div)
}

# Connect-Cockroach: a session for COCKROACH_USER, when it is set (POST
# /api/v2/login/, the password in the body). An insecure cluster needs none.
function Connect-Cockroach {
    if (-not $env:COCKROACH_USER) { return }
    if (-not $env:COCKROACH_PASSWORD) { [Console]::Error.WriteLine("${Job}: COCKROACH_USER is set, and COCKROACH_PASSWORD is not: secret = COCKROACH_PASSWORD=secret:COCKROACH_PASSWORD, then vigil secret set COCKROACH_PASSWORD"); exit 1 }
    $form = 'username=' + [Uri]::EscapeDataString($env:COCKROACH_USER) + '&password=' + [Uri]::EscapeDataString($env:COCKROACH_PASSWORD)
    $r = Get-Answer '/api/v2/login/' $form 'application/x-www-form-urlencoded'
    switch ($r.State) {
        'ok' { }
        'down' { Write-Output 'metric up 0'; exit 0 }
        'failed' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
        default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/api/v2/login/ refused the login"); exit 1 }
    }
    $s = ($r.Body | ConvertFrom-Json).session
    if (-not $s) { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/api/v2/login/ gave no session"); exit 1 }
    $script:Session = [string]$s
}
# Disconnect-Cockroach: the session ended, so none is left open.
function Disconnect-Cockroach {
    if (-not $script:Session) { return }
    try { [void](Get-Answer '/api/v2/logout/' ' ' 'text/plain') } catch { }
    $script:Session = $null
}

# Get-Rows <statement>: its rows, read through the SQL API (/api/v2/sql/),
# each as an object; else stops: a missing privilege names the README.
function Get-Rows([string]$sql) {
    $body = @{ statements = @(@{ sql = $sql }); execute = $true; max_result_size = 1000000 } | ConvertTo-Json -Depth 4 -Compress
    $r = Get-Answer '/api/v2/sql/' $body
    switch ($r.State) {
        'ok' { }
        'down' { [Console]::Error.WriteLine("${Job}: CockroachDB stopped answering at /api/v2/sql/"); Disconnect-Cockroach; exit 1 }
        'unready' { [Console]::Error.WriteLine("${Job}: CockroachDB answered /api/v2/sql/ with HTTP 503: the cluster is not available"); Disconnect-Cockroach; exit 1 }
        'forbidden' { [Console]::Error.WriteLine("${Job}: this user may not use the SQL API: give it the privileges packs/cockroachdb/README.md shows"); Disconnect-Cockroach; exit 1 }
        default { [Console]::Error.WriteLine("${Job}: $($r.Why)"); Disconnect-Cockroach; exit 1 }
    }
    $o = $r.Body | ConvertFrom-Json
    if ($o.error) {
        $m = ([string]$o.error.message) -replace '^executing stmt 1: run-query-via-api: ', ''
        if ($m -match 'privilege|does not have|not allowed') { $m += ': packs/cockroachdb/README.md shows the privileges to grant' }
        [Console]::Error.WriteLine("${Job}: $m")
        Disconnect-Cockroach
        exit 1
    }
    # One by one: callers collect them with @(), so that Windows PowerShell
    # 5.1 and PowerShell 7 give the same.
    foreach ($row in @($o.execution.txn_results[0].rows)) { if ($null -ne $row) { $row } }
}

# A tag's value: no spaces, quotes or control characters, never empty, at
# most 120 characters.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A number from anything: nothing is 0, true is 1.
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
