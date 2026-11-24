<#
.SYNOPSIS
    _caddy.ps1 - what the caddy pack's scripts share on Windows: one request, the tags and numbers, the access log and the certificates. Each job's script dot-sources it; it is never run as a job.
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
$ProgressPreference = 'SilentlyContinue'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Get-InnerMessage($E) {
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# Stop the run, saying why.
function Stop-Run([string]$why) {
    [Console]::Error.WriteLine("${Job}: $why")
    exit 1
}
# Get-Http <url>: @{ State = ok, down or failed; Body; Why }. Nothing
# answering is down (a reading); an answer other than 200 has failed.
function Get-Http([string]$url) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0
        $b = $r.Content
        if ($b -is [byte[]]) { $b = [Text.Encoding]::UTF8.GetString($b) }
        return @{ State = 'ok'; Body = [string]$b }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { return @{ State = 'failed'; Why = "$url answered HTTP $([int]$resp.StatusCode)" } }
        return @{ State = 'down'; Why = "$url`: $(Get-InnerMessage $_.Exception)" }
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
# A number from anything: nothing is 0, true is 1, '45.3%' is 45.3.
function N($v) {
    if ($null -eq $v) { return [double]0 }
    if ($v -is [bool]) { if ($v) { return [double]1 } else { return [double]0 } }
    if ($v -is [string]) {
        $d = [double]0
        if ([double]::TryParse($v.Trim().TrimEnd('%'), [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
        return [double]0
    }
    return [double]$v
}
# metric <name> <value> [tags]
function M([string]$name, $v, [string]$tags) {
    $t = if ($tags) { ' ' + $tags } else { '' }
    "metric $name $((N $v).ToString('0.##', $script:Inv))$t"
}
function Props($o) { if ($null -eq $o) { return @() } else { return @($o.PSObject.Properties) } }

# Get-ChangedSince <epoch> <folder>: how many files under it changed after
# that time (those this account may not read are not counted).
function Get-ChangedSince([long]$epoch, [string]$dir) {
    $t = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
    return @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $t }).Count
}

# Times kept (milliseconds), as an average, percentiles and the longest.
function Write-Times($v, [string]$n) {
    if (-not $v.Count) { return }
    $s = @($v | Sort-Object)
    $c = $s.Count
    $p = { param($q) $s[[Math]::Max([int][Math]::Floor($c * $q + 0.999) - 1, 0)] }
    M "${n}_avg_ms" ([Math]::Round((($s | Measure-Object -Sum).Sum / $c), 1))
    M "${n}_p50_ms" (& $p 0.50)
    M "${n}_p90_ms" (& $p 0.90)
    M "${n}_p99_ms" (& $p 0.99)
    M "${n}_max_ms" $s[$c - 1]
}

# Read-LogMinute <file> <max MB>: the access log's last whole minute, from
# its last <max MB> only. Shared with other writers: the server keeps
# writing while it is read.
function Read-LogMinute([string]$f, [int]$cap) {
    if (-not (Test-Path -LiteralPath $f)) {
        M 'log_found' 0
        [Console]::Error.WriteLine("${Job}: no access log at $f`: set the job's CADDY_ACCESS_LOG")
        return
    }
    M 'log_found' 1
    try { $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete') }
    catch {
        M 'log_readable' 0
        [Console]::Error.WriteLine("${Job}: this account may not read $f (packs/caddy/README.md says how to allow it), or turn this job off")
        return
    }
    try {
        M 'log_readable' 1
        $size = $fs.Length
        M 'log_bytes' $size
        $max = [long]$cap * 1048576
        $cut = $size -gt $max
        $from = if ($cut) { $size - $max } else { 0 }
        [void]$fs.Seek($from, 'Begin')
        $buf = New-Object byte[] ($size - $from)
        $got = 0
        while ($got -lt $buf.Length) { $n = $fs.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
    } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $got) -split "`r?`n"
    if ($cut -and $lines.Count) { $lines = @($lines | Select-Object -Skip 1) }
    $start = ([long][Math]::Floor($script:Now / 60) - 1) * 60
    $want = '[' + [DateTimeOffset]::FromUnixTimeSeconds($start).LocalDateTime.ToString('dd/MMM/yyyy:HH:mm', $script:Inv) + ':'
    $n = 0; $bytes = [double]0; $before = $false; $inside = $false
    $cls = @{}; $code = @{}; $meth = @{}; $ips = @{}; $rt = New-Object System.Collections.Generic.List[double]; $urt = New-Object System.Collections.Generic.List[double]
    foreach ($l in $lines) {
        $i = $l.IndexOf('[')
        if ($i -lt 0 -or $l.Length -lt $i + 19) { continue }
        if ($l.Substring($i, 19) -ne $want) { if (-not $inside) { $before = $true }; continue }
        $inside = $true
        $m = [regex]::Match($l, '" (\d{3}) (\d+|-)')
        if (-not $m.Success) { continue }
        $st = $m.Groups[1].Value
        $n++
        $bytes += N $m.Groups[2].Value
        $code[$st] = 1 + [int]$code[$st]
        $cls[$st.Substring(0, 1)] = 1 + [int]$cls[$st.Substring(0, 1)]
        $q = $l.IndexOf('"')
        $me = if ($q -ge 0) { ($l.Substring($q + 1) -split ' ')[0] } else { '' }
        if ($me -notmatch '^(GET|POST|HEAD|PUT|DELETE|PATCH|OPTIONS)$') { $me = 'other' }
        $meth[$me] = 1 + [int]$meth[$me]
        $ips[$l.Substring(0, [Math]::Max($l.IndexOf(' '), 0))] = 1
        foreach ($tok in $l -split ' ') {
            if ($tok -match '^rt=([0-9.]+)$') { $rt.Add((N $Matches[1]) * 1000) }
            elseif ($tok -match '^rtus=([0-9]+)$') { $rt.Add((N $Matches[1]) / 1000) }
            elseif ($tok -match '^urt=([0-9.]+)') { $urt.Add((N $Matches[1]) * 1000) }
        }
    }
    M 'window_complete' $(if (-not $cut -or ($before -and $n -gt 0)) { 1 } else { 0 })
    M 'requests' $n
    foreach ($c in 1..5) { M "status_${c}xx" ([int]$cls[[string]$c]) }
    M 'errors_4xx_pct' $(if ($n) { [Math]::Round(100 * [int]$cls['4'] / $n, 2) } else { 0 })
    M 'errors_5xx_pct' $(if ($n) { [Math]::Round(100 * [int]$cls['5'] / $n, 2) } else { 0 })
    M 'bytes_sent' $bytes
    M 'clients' $ips.Count
    foreach ($k in @($code.Keys | Sort-Object | Select-Object -First 40)) { M 'status' $code[$k] "code=$k" }
    foreach ($k in @($meth.Keys | Sort-Object)) { M 'method' $meth[$k] "method=$k" }
    Write-Times $rt 'response'
    Write-Times $urt 'upstream'
}

# Read-Certs <endpoint>...: each endpoint's certificate, from a TLS
# handshake (host:port, or host:port/name to ask for another name). Nothing
# is sent but the handshake. CADDY_CACERT, a CA file, checks a private CA.
$script:Ca = $null
if ($env:CADDY_CACERT) {
    try { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:CADDY_CACERT }
    catch { Stop-Run "CADDY_CACERT: cannot read $($env:CADDY_CACERT): $(Get-InnerMessage $_.Exception)" }
}
$script:Seen = $null
$script:SeenErrors = $null
$script:Keep = [System.Net.Security.RemoteCertificateValidationCallback] {
    param($Sender, $Cert, $Chain, $Errors)
    $script:Seen = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cert
    $script:SeenErrors = $Errors
    if ($Errors -eq [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors -and $script:Ca) {
        $c = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $c.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $c.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
        [void]$c.ChainPolicy.ExtraStore.Add($script:Ca)
        # The intermediates the server sent (Caddy's local CA has one): .NET
        # Framework has them in the chain's elements, PowerShell 7's .NET in
        # its extra store.
        if ($Chain) {
            foreach ($e in @($Chain.ChainElements)) { if ($e.Certificate.Thumbprint -ne $script:Seen.Thumbprint) { [void]$c.ChainPolicy.ExtraStore.Add($e.Certificate) } }
            foreach ($x in @($Chain.ChainPolicy.ExtraStore)) { if ($x) { [void]$c.ChainPolicy.ExtraStore.Add($x) } }
        }
        if ($c.Build($script:Seen) -and $c.ChainElements[$c.ChainElements.Count - 1].Certificate.Thumbprint -eq $script:Ca.Thumbprint) {
            $script:SeenErrors = [System.Net.Security.SslPolicyErrors]::None
        }
    }
    # Every certificate is let through: the job reads it, and sends nothing.
    return $true
}
function Read-Certs($list) {
    # Caddy's: whether its admin API answered, asked for the site names.
    if ($null -ne $script:CaddyUp) { M 'up' $script:CaddyUp; if (-not $script:CaddyUp) { return } }
    if ($null -ne $script:SitesFound) { M 'sites_found' $script:SitesFound }
    $list = @($list | Where-Object { $_ })
    $i = 0
    foreach ($e in $list) {
        if (++$i -gt 50) { M 'certs_not_shown' ($list.Count - 50); return }
        $t = "endpoint=$(Safe $e)"
        $hp, $name = ([string]$e) -split '/', 2
        $h = $hp.Substring(0, $hp.LastIndexOf(':')); $port = [int]$hp.Substring($hp.LastIndexOf(':') + 1)
        if (-not $name) { $name = $h }
        $script:Seen = $null
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $wait = $tcp.BeginConnect($h, $port, $null, $null)
            if (-not $wait.AsyncWaitHandle.WaitOne(10000)) { M 'tls_up' 0 $t; continue }
            $tcp.EndConnect($wait)
            $s = $tcp.GetStream(); $s.ReadTimeout = 10000; $s.WriteTimeout = 10000
            $ssl = New-Object System.Net.Security.SslStream($s, $false, $script:Keep)
            $protocols = [System.Security.Authentication.SslProtocols]::Tls12
            if ($PSVersionTable.PSEdition -eq 'Core') { $protocols = [System.Security.Authentication.SslProtocols]::None }
            $ssl.AuthenticateAsClient($name, $null, $protocols, $false)
            $proto = [string]$ssl.SslProtocol
        } catch {
            if (-not $script:Seen) { M 'tls_up' 0 $t; continue }
            $proto = 'unknown'
        } finally { $tcp.Close() }
        $c = $script:Seen
        M 'tls_up' 1 $t
        $end = ([DateTimeOffset]$c.NotAfter.ToUniversalTime()).ToUnixTimeSeconds()
        $begin = ([DateTimeOffset]$c.NotBefore.ToUniversalTime()).ToUnixTimeSeconds()
        M 'cert_expires_days' ([Math]::Floor(($end - $script:Now) / 86400)) $t
        M 'cert_valid' $(if ($script:Now -lt $end -and $begin -le $script:Now) { 1 } else { 0 }) $t
        $ok = $script:SeenErrors -eq [System.Net.Security.SslPolicyErrors]::None
        $why = if ($ok) { 'ok' } else { ([string]$script:SeenErrors) -replace ', ', '+' }
        M 'cert_verified' $(if ($ok) { 1 } else { 0 }) "$t reason=$(Safe $why)"
        $issuer = if ($c.Issuer -match 'CN=([^,]+)') { $Matches[1] } else { $c.Issuer }
        Write-Output "metric cert_info 1 $t issuer=$(Safe $issuer) protocol=$(Safe $proto)"
    }
}

# Every handler's name in Caddy's servers, however deep (subroutes too).
function Get-Handlers($o) {
    foreach ($x in @($o)) {
        if ($null -eq $x -or $x -is [string] -or $x -is [ValueType]) { continue }
        foreach ($p in $x.PSObject.Properties) {
            if ($p.Name -eq 'handler') { [string]$p.Value }
            elseif ($null -ne $p.Value -and -not ($p.Value -is [string]) -and -not ($p.Value -is [ValueType])) { Get-Handlers $p.Value }
        }
    }
}
# 1 when Caddy's HTTP metrics are on in its configuration (the global option,
# or a server's own), else 0.
function Test-CaddyMetrics($c) {
    if (-not $c) { return 0 }
    if ($null -ne $c.apps.http.metrics) { return 1 }
    foreach ($s in @(Props $c.apps.http.servers)) { if ($null -ne $s.Value.metrics) { return 1 } }
    return 0
}
# The sum of a Prometheus metric's samples, among some lines.
function Sum-Prom($lines, [string]$m) {
    $s = [double]0
    foreach ($x in @($lines)) { if ($x.StartsWith("$m{") -or $x.StartsWith("$m ")) { $s += [double](($x -split ' ')[-1]) } }
    return $s
}
# The endpoints the tls job checks: CADDY_TLS, or every site name in
# Caddy's configuration at CADDY_TLS_ADDRESS. Certificates from Caddy's own
# local CA check against it.
$script:SitesFound = $null
$script:CaddyUp = $null
function Get-CaddyEndpoints {
    $admin = if ($env:CADDY_ADMIN) { $env:CADDY_ADMIN.TrimEnd('/') } else { 'http://localhost:2019' }
    if (-not $script:Ca) {
        $r = Get-Http "$admin/pki/ca/local"
        if ($r.State -eq 'ok') {
            try {
                $pem = ($r.Body | ConvertFrom-Json).root_certificate
                if ($pem) { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($pem)) }
            } catch { $script:Ca = $null }
        }
    }
    if ($env:CADDY_TLS) { return @($env:CADDY_TLS -split '\s+' | Where-Object { $_ }) }
    $r = Get-Http "$admin/config/"
    if ($r.State -eq 'down') { $script:CaddyUp = 0; return @() }
    if ($r.State -ne 'ok') { Stop-Run $r.Why }
    $c = $r.Body | ConvertFrom-Json
    $names = @()
    if ($c -and $c.apps.http.servers) {
        foreach ($s in @(Props $c.apps.http.servers)) {
            foreach ($rt in @($s.Value.routes)) { foreach ($m in @($rt.match)) { $names += @($m.host) } }
        }
    }
    if ($c -and $c.apps.tls.automation.policies) { foreach ($p in @($c.apps.tls.automation.policies)) { $names += @($p.subjects) } }
    $names = @($names | Where-Object { $_ -and -not ([string]$_).StartsWith('*') } | Sort-Object -Unique)
    $script:CaddyUp = 1
    $script:SitesFound = $names.Count
    $addr = if ($env:CADDY_TLS_ADDRESS) { $env:CADDY_TLS_ADDRESS } else { '127.0.0.1:443' }
    return @($names | ForEach-Object { "$addr/$_" })
}
