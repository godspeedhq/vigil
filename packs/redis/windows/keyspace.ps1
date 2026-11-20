#Requires -Version 5.1

<#
.SYNOPSIS
    keyspace.ps1 - the keys in each of a Redis or Valkey server's databases, on Windows
.DESCRIPTION
    Asks the server for its INFO, as a user that may run nothing else, and
    reports how many keys each database holds, and how many of them expire.
    It reads the server's own counts: it never lists or reads a key.
    The server may be anywhere this machine can reach. Connects to REDIS_HOST
    and REDIS_PORT as REDIS_USER, with the password in REDISCLI_AUTH, all set
    by the job; never on a command line. With no password, it sends no user:
    the server's default user. REDIS_TLS=1 connects with TLS, the server's
    certificate checked against Windows' trusted CAs or REDIS_CACERT, a CA
    file. It speaks the server's protocol itself, with .NET's own TCP and TLS:
    there is no client to install. A client certificate (REDIS_CERT) is for
    Linux and macOS only.

    Metrics:
        keys     keys in a database, tagged db=<db0, db1 and so on>; an
                 empty server reports keys 0 for db0
        expires  of those, the keys with a time to live, tagged db=

    Example output:
      metric keys 1520 db=db0
      metric expires 1200 db=db0
      metric keys 12 db=db3
      metric expires 0 db=db3

    Reading the results (starting points: tune them to the server):
      Healthy  keys steady, or rising and falling with the work; on a
               cache, expires close to keys.
      Watch    keys growing without end, with expires flat: keys written
               without a time to live, which only eviction or a person will
               remove.
      Act      keys falling to 0 when they should not: a FLUSHALL, or a
               restart that loaded nothing (redis.uptime_seconds says which).

    When the server does not answer, it prints nothing and succeeds:
    redis_status reports that, as redis.up 0.
    A Sentinel has none of this: it prints nothing there, and redis_status
    reports the Sentinel (mode=sentinel).

    Requires: Windows PowerShell 5.1 or PowerShell 7, and a user that may
      run INFO (Redis 6 or Valkey on)
    Exit code: 0 on success, or when the server does not answer; 1 if the
      server refuses the login or INFO
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

# The server's INFO, asked for in its own protocol (RESP) over a TCP
# connection, with TLS when REDIS_TLS says so. Returns State: up, with Info
# (name -> value); down, when the server could not be reached at all; or
# failed, with Why.
$script:RespBuf = New-Object byte[] 16384
$script:RespLen = 0
$script:RespPos = 0
$script:RespStream = $null
function Send-Resp {
    param([string[]]$Words)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $ms = New-Object System.IO.MemoryStream
    $b = $enc.GetBytes("*$($Words.Count)`r`n")
    $ms.Write($b, 0, $b.Length)
    foreach ($w in $Words) {
        $v = $enc.GetBytes($w)
        $b = $enc.GetBytes("`$$($v.Length)`r`n")
        $ms.Write($b, 0, $b.Length)
        $ms.Write($v, 0, $v.Length)
        $ms.Write([byte[]](13, 10), 0, 2)
    }
    $script:RespStream.Write($ms.ToArray(), 0, [int]$ms.Length)
    $script:RespStream.Flush()
}
function Read-RespChunk {
    $script:RespLen = $script:RespStream.Read($script:RespBuf, 0, $script:RespBuf.Length)
    $script:RespPos = 0
    if ($script:RespLen -le 0) { throw 'the server closed the connection' }
}
# n bytes, or with -1 a line, without its CR LF.
function Read-RespBytes {
    param([int]$Count)
    $ms = New-Object System.IO.MemoryStream
    if ($Count -lt 0) {
        while ($true) {
            if ($script:RespPos -ge $script:RespLen) { Read-RespChunk }
            $i = [Array]::IndexOf($script:RespBuf, [byte]10, $script:RespPos, $script:RespLen - $script:RespPos)
            if ($i -lt 0) {
                $ms.Write($script:RespBuf, $script:RespPos, $script:RespLen - $script:RespPos)
                $script:RespPos = $script:RespLen
                continue
            }
            $ms.Write($script:RespBuf, $script:RespPos, $i - $script:RespPos)
            $script:RespPos = $i + 1
            break
        }
        return [System.Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimEnd("`r")
    }
    $left = $Count + 2
    while ($left -gt 0) {
        if ($script:RespPos -ge $script:RespLen) { Read-RespChunk }
        $n = [Math]::Min($left, $script:RespLen - $script:RespPos)
        $ms.Write($script:RespBuf, $script:RespPos, $n)
        $script:RespPos += $n
        $left -= $n
    }
    return [System.Text.Encoding]::UTF8.GetString($ms.ToArray(), 0, $Count)
}
# One reply: Ok and Text. An error reply is Ok $false, its text the reason.
function Read-Resp {
    $line = Read-RespBytes -1
    if ($line.Length -lt 1) { throw 'the server sent an empty line' }
    $rest = $line.Substring(1)
    switch ($line[0]) {
        '+' { return @{ Ok = $true; Text = $rest } }
        '-' { return @{ Ok = $false; Text = $rest } }
        ':' { return @{ Ok = $true; Text = $rest } }
        '$' {
            $n = 0
            if (-not [int]::TryParse($rest, [ref]$n)) { throw "the server sent a length this script cannot read: $line" }
            if ($n -lt 0) { return @{ Ok = $true; Text = '' } }
            return @{ Ok = $true; Text = (Read-RespBytes $n) }
        }
    }
    throw "the server sent a reply this script cannot read: $line"
}
function Get-InnerMessage {
    param($E)
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# REDIS_CACERT: the server's certificate must chain to this CA, and name the
# server. Called by .NET during the handshake, on this thread.
$script:RedisCa = $null
$script:CheckCert = [System.Net.Security.RemoteCertificateValidationCallback] {
    param($Sender, $Cert, $Chain, $Errors)
    if ($Errors -eq [System.Net.Security.SslPolicyErrors]::None) { return $true }
    if ($Errors -ne [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) { return $false }
    $c = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $c.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $c.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    [void]$c.ChainPolicy.ExtraStore.Add($script:RedisCa)
    if (-not $c.Build((New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cert))) { return $false }
    $top = $c.ChainElements[$c.ChainElements.Count - 1].Certificate
    if ($top.Thumbprint -ne $script:RedisCa.Thumbprint) { return $false }
    foreach ($s in $c.ChainStatus) {
        if ($s.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot) { return $false }
    }
    return $true
}
function Get-RedisInfo {
    $server = if ($env:REDIS_HOST) { $env:REDIS_HOST } else { '127.0.0.1' }
    $port = 6379
    if ($env:REDIS_PORT -and -not [int]::TryParse($env:REDIS_PORT, [ref]$port)) {
        return @{ State = 'failed'; Why = "REDIS_PORT is '$($env:REDIS_PORT)', not a port" }
    }
    $tls = $false
    switch -regex ("$env:REDIS_TLS") {
        '^(1|yes|true)$' { $tls = $true }
        '^(|0|no|false)$' { }
        default { return @{ State = 'failed'; Why = "REDIS_TLS is '$($env:REDIS_TLS)': set it to 1 for TLS, or 0" } }
    }
    if ($env:REDIS_CERT) { return @{ State = 'failed'; Why = 'REDIS_CERT: a client certificate is for Linux and macOS only' } }
    if ($tls -and $env:REDIS_CACERT) {
        try { $script:RedisCa = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:REDIS_CACERT }
        catch { return @{ State = 'failed'; Why = "REDIS_CACERT: cannot read $($env:REDIS_CACERT): $(Get-InnerMessage $_.Exception)" } }
    }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        # Not reached at all, within 5 seconds: down, a reading.
        try {
            $wait = $tcp.BeginConnect($server, $port, $null, $null)
            if (-not $wait.AsyncWaitHandle.WaitOne(5000)) { return @{ State = 'down'; Why = "no answer from ${server}:$port in 5 seconds" } }
            $tcp.EndConnect($wait)
        } catch {
            return @{ State = 'down'; Why = (Get-InnerMessage $_.Exception) }
        }
        try {
            $stream = $tcp.GetStream()
            $stream.ReadTimeout = 10000
            $stream.WriteTimeout = 10000
            if ($tls) {
                if ($script:RedisCa) { $ssl = New-Object System.Net.Security.SslStream($stream, $false, $script:CheckCert) }
                else { $ssl = New-Object System.Net.Security.SslStream($stream, $false) }
                # Windows PowerShell's .NET offers TLS 1.2 only when asked;
                # PowerShell 7 takes what the system allows.
                $protocols = [System.Security.Authentication.SslProtocols]::Tls12
                if ($PSVersionTable.PSEdition -eq 'Core') { $protocols = [System.Security.Authentication.SslProtocols]::None }
                try { $ssl.AuthenticateAsClient($server, $null, $protocols, $false) }
                catch { return @{ State = 'failed'; Why = "the TLS handshake failed: $(Get-InnerMessage $_.Exception)" } }
                $stream = $ssl
            }
            $script:RespStream = $stream
            if ($env:REDISCLI_AUTH) {
                $user = if ($env:REDIS_USER) { $env:REDIS_USER } else { 'vigil_monitor' }
                Send-Resp @('AUTH', $user, $env:REDISCLI_AUTH)
                $r = Read-Resp
                if (-not $r.Ok) { return @{ State = 'failed'; Why = "the server refused the login: $($r.Text)" } }
            }
            Send-Resp @('INFO')
            $r = Read-Resp
            if (-not $r.Ok) { return @{ State = 'failed'; Why = "INFO failed: $($r.Text)" } }
        } catch {
            return @{ State = 'failed'; Why = "INFO failed: $(Get-InnerMessage $_.Exception)" }
        }
        $info = @{}
        foreach ($l in ($r.Text -split "`r?`n")) {
            $i = $l.IndexOf(':')
            if ($i -gt 0 -and -not $l.StartsWith('#')) { $info[$l.Substring(0, $i)] = $l.Substring($i + 1) }
        }
        return @{ State = 'up'; Info = $info }
    } finally {
        $tcp.Close()
    }
}

$r = Get-RedisInfo
if ($r.State -eq 'down') { exit 0 }
if ($r.State -ne 'up') {
    [Console]::Error.WriteLine("keyspace: $($r.Why)")
    exit 1
}
$v = $r.Info
function Test-Number { param($X) return ("$X" -match '^-?[0-9]+(\.[0-9]+)?$') }
function Write-Metric {
    param([string]$Name, [string]$Key)
    if ($v.ContainsKey($Key) -and (Test-Number $v[$Key])) { Write-Output "metric $Name $($v[$Key])" }
}
function ConvertTo-Tag {
    param([string]$X)
    $X = $X -replace '[^A-Za-z0-9_.-]', '_'
    if ($X) { return $X } else { return 'unknown' }
}
# A Sentinel has none of this: redis_status reports it.
if ($v['redis_mode'] -eq 'sentinel' -or $v['server_mode'] -eq 'sentinel') { exit 0 }
# db0:keys=1520,expires=1200,avg_ttl=0, in the order of the numbers.
$dbs = @($v.Keys | Where-Object { $_ -match '^db[0-9]+$' } | Sort-Object { [int]$_.Substring(2) })
if ($dbs.Count -eq 0) {
    Write-Output 'metric keys 0 db=db0'
    Write-Output 'metric expires 0 db=db0'
}
foreach ($db in $dbs) {
    foreach ($p in $v[$db].Split(',')) {
        $e = $p.IndexOf('=')
        if ($e -lt 1) { continue }
        $k = $p.Substring(0, $e)
        $x = $p.Substring($e + 1)
        if (($k -eq 'keys' -or $k -eq 'expires') -and (Test-Number $x)) { Write-Output "metric $k $x db=$db" }
    }
}
