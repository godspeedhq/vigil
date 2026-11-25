<#
.SYNOPSIS
    _victorialogs.ps1 - what the victorialogs pack's scripts share on Windows: one request, and the readings taken from a page of metrics in Prometheus' text format. Each job's script dot-sources it; it is never run as a job.
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads VictoriaLogs at VICTORIALOGS_URL (default http://localhost:9428). VICTORIALOGS_USER and VICTORIALOGS_PASSWORD log in
    with basic authentication, or VICTORIALOGS_TOKEN sends a bearer token; keep the
    password or the token in Vigil's secret store
    (secret = VICTORIALOGS_PASSWORD=secret:...).

    It speaks HTTP itself, with .NET's own TCP and TLS: there is nothing to
    install, and the same on Windows PowerShell 5.1 and PowerShell 7. Over
    https, the certificate is checked against Windows' trusted CAs, or
    against VICTORIALOGS_CACERT, a CA file, when it is set, and against the server's
    name. Every request is a GET.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Url = if ($env:VICTORIALOGS_URL) { $env:VICTORIALOGS_URL.TrimEnd('/') } else { 'http://localhost:9428' }
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$script:Body = ''
# The login, as a header made here: never on a command line.
$script:Auth = $null
if ($env:VICTORIALOGS_TOKEN) { $script:Auth = 'Bearer ' + $env:VICTORIALOGS_TOKEN }
elseif ($env:VICTORIALOGS_USER) { $script:Auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:VICTORIALOGS_USER + ':' + $env:VICTORIALOGS_PASSWORD)) }

function Get-InnerMessage($E) {
    while ($E.InnerException) { $E = $E.InnerException }
    return $E.Message
}
# VICTORIALOGS_CACERT: the server's certificate must chain to this CA, and name the
# server. Called by .NET during the handshake, on this thread.
$script:Ca = $null
if ($env:VICTORIALOGS_CACERT) {
    try { $script:Ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $env:VICTORIALOGS_CACERT }
    catch { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: VICTORIALOGS_CACERT: cannot read $($env:VICTORIALOGS_CACERT): $(Get-InnerMessage $_.Exception)"); exit 1 }
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

# Get-Answer <path>: @{ State = ok, down, missing (404), forbidden (401,
# 403), notready (503) or failed; Body; Why }. HTTP/1.1, one request a
# connection.
function Get-Answer([string]$path) {
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
        $stream.ReadTimeout = 20000
        $stream.WriteTimeout = 20000
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
        $req = "GET $($u.PathAndQuery) HTTP/1.1`r`nHost: $($u.Authority)`r`nUser-Agent: vigil-victorialogs`r`nAccept: text/plain, */*`r`nAccept-Encoding: identity`r`nConnection: close`r`n"
        if ($script:Auth) { $req += "Authorization: $($script:Auth)`r`n" }
        $head = [Text.Encoding]::ASCII.GetBytes($req + "`r`n")
        $stream.Write($head, 0, $head.Length)
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
        return @{ State = 'down'; Why = "$($script:Url)${path}: $(Get-InnerMessage $_.Exception)" }
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
        200 { return @{ State = 'ok'; Body = $text } }
        404 { return @{ State = 'missing' } }
        { $_ -in 401, 403 } { return @{ State = 'forbidden'; Why = "$($script:Url)$path answered HTTP ${status}: this login may not read it (VICTORIALOGS_USER and VICTORIALOGS_PASSWORD, or VICTORIALOGS_TOKEN)" } }
        503 { return @{ State = 'notready' } }
        default { return @{ State = 'failed'; Why = "$($script:Url)$path answered HTTP $status" } }
    }
}

# Read-Page <path>: the page of metrics at <path>, kept in $script:Body, with
# "up": 1 when VictoriaLogs answered it. When it did not, the job ends there: "up 0"
# is its reading, and the run succeeds.
function Read-Page([string]$path) {
    $r = Get-Answer $path
    switch ($r.State) {
        'ok' { $script:Body = $r.Body; Write-Output 'metric up 1'; return }
        'down' { Write-Output 'metric up 0'; exit 0 }
        'notready' { Write-Output 'metric up 0'; exit 0 }
        'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)${path}: no such page (HTTP 404): is VICTORIALOGS_URL VictoriaLogs's address?"); exit 0 }
        default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
    }
}
# Get-Extra <path>: another page of metrics, as text; $null when VictoriaLogs does
# not give it (said on stderr when it answered wrong).
function Get-Extra([string]$path) {
    $r = Get-Answer $path
    if ($r.State -eq 'ok') { return $r.Body }
    if ($r.State -eq 'failed' -or $r.State -eq 'forbidden') { [Console]::Error.WriteLine("${Job}: $($r.Why)") }
    return $null
}
# Test-Answers <name> <path>: "<name> 1" when the page answers 200, else 0 (a
# health or readiness page: not ready is a reading).
function Test-Answers([string]$name, [string]$path) {
    $r = Get-Answer $path
    if ($r.State -eq 'ok') { Write-Output "metric $name 1" } else { Write-Output "metric $name 0" }
}

# A tag's value: no spaces, quotes or control characters, never empty, at
# most 120 characters.
function Safe($s) {
    $s = ([string]$s) -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring(0, 120) }
    return $s
}
# A number as the bash scripts print it: whole when it is, else six
# decimals at most.
function Fmt([double]$v) {
    # Never with an exponent: 15 significant digits at most (all a double
    # holds for certain, and what awk, Windows PowerShell and PowerShell 7
    # agree on), and 6 decimals at most.
    $a = [Math]::Abs($v)
    if ($a -ge 1e15) {
        $s = $a.ToString('E14', $script:Inv)
        $e = [int]$s.Substring($s.IndexOf('E') + 1)
        $digits = $s.Substring(0, 1) + $s.Substring(2, 14)
        if ($digits.Length -lt $e + 1) { $digits = $digits.PadRight($e + 1, '0') }
        if ($v -lt 0) { return '-' + $digits }
        return $digits
    }
    if ($v -eq [Math]::Truncate($v)) { return $v.ToString('0', $script:Inv) }
    $d = 15 - [Math]::Truncate($a).ToString('0', $script:Inv).Length
    if ($d -gt 6) { $d = 6 }
    if ($d -lt 1) { return [Math]::Round($v).ToString('0', $script:Inv) }
    return [Math]::Round($v, $d).ToString('0.' + ('#' * $d), $script:Inv)
}
function Test-Value([double]$v, [string]$t) {
    if (-not $t) { return $true }
    if ($t.StartsWith('!=')) { return $v -ne [double]::Parse($t.Substring(2), $script:Inv) }
    $n = [double]::Parse($t.Substring(1), $script:Inv)
    switch ($t[0]) {
        '=' { return $v -eq $n }
        '>' { return $v -gt $n }
        '<' { return $v -lt $n }
    }
    return $true
}

# Whether a series' labels pass a reading's filters.
function Test-Labels($r, $lab) {
    foreach ($t in $r.Filters) {
        $have = if ($lab.ContainsKey($t.K)) { $lab[$t.K] } else { '' }
        switch ($t.O) {
            '=' { if ($have -cne $t.V) { return $false } }
            '!=' { if ($have -ceq $t.V) { return $false } }
            '~' { if ($have -cnotmatch $t.V) { return $false } }
            '!~' { if ($have -cmatch $t.V) { return $false } }
        }
    }
    return $true
}

# Get-Readings <table> [<text>]: takes the readings the table lists from a
# page of metrics ($script:Body by default), in one pass. One reading a
# line:
#
#   name|op|metric|filters|arg
#
# A name starting with "_" is worked out and not printed (for the ones
# after it). The filters are label tests, separated by commas, all of which
# must hold: label=value, label!=value, label~regex, label!~regex.
#
#   sum, max, min   of the series' values; arg, a number to multiply by.
#                   A metric that is not on the page: sum is 0, max and min
#                   print nothing.
#   minpos          the smallest value above 0 (nothing when there is none)
#   maxpct          the largest of 100*a/b, a and b being the series of this
#                   metric and of the one in arg that carry the same labels
#                   (a queue's size and its capacity): how full the fullest
#                   is. Nothing when no pair has a b above 0.
#   count           how many series; arg, a test of the value (=0 >0 <1 !=1)
#   age, oldest     seconds since the latest (age) or the earliest
#                   (oldest) of the series' values, which are times (arg
#                   "ms": in milliseconds). Nothing when the metric is not
#                   there, or is 0.
#   by              one line for each value of the label in arg, tagged with
#                   it (label, or label:tag), the series summed; the 20
#                   largest, and <name>_not_shown for the rest
#   countby         the same, counting the series that pass the test after
#                   the label (arg: "label:tag =0")
#   info            1, tagged with labels of the first series (arg:
#                   label:tag,label:tag)
#   pct, div, sub, add, mul   of two readings above, or numbers: 100*a/b,
#                   a/b, a-b, a+b, a*b (nothing when one is missing; pct
#                   and div are 0 when b is 0)
#
# An op ending in "?" prints nothing when its metric is not on the page.
function Get-Readings([string]$table, [string]$text) {
    if (-not $PSBoundParameters.ContainsKey('text')) { $text = $script:Body }
    $rows = New-Object System.Collections.Generic.List[object]
    $wanted = @{}
    $wantedB = @{}
    $derived = @('pct', 'div', 'sub', 'add', 'mul')
    foreach ($line in ($table -split "`r?`n")) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $f = $line.Split('|')
        $r = @{ Name = $f[0]; Op = $f[1]; A = $f[2]; B = $(if ($f.Count -ge 4) { $f[3] } else { '' }); Arg = $(if ($f.Count -ge 5) { $f[4] } else { '' })
            Quiet = $false; Filters = @(); Has = $false; Acc = [double]0; Groups = (New-Object System.Collections.Specialized.OrderedDictionary); Info = $null
            By = ''; Tag = ''; Test = ''; Num = (New-Object System.Collections.Specialized.OrderedDictionary); Den = @{} }
        if ($r.Op.EndsWith('?')) { $r.Quiet = $true; $r.Op = $r.Op.Substring(0, $r.Op.Length - 1) }
        $rows.Add($r)
        if ($derived -ccontains $r.Op) { continue }
        if (-not $wanted.ContainsKey($r.A)) { $wanted[$r.A] = New-Object System.Collections.Generic.List[object] }
        $wanted[$r.A].Add($r)
        if ($r.Op -ceq 'maxpct') {
            if (-not $wantedB.ContainsKey($r.Arg)) { $wantedB[$r.Arg] = New-Object System.Collections.Generic.List[object] }
            $wantedB[$r.Arg].Add($r)
        }
        if ($r.B) {
            $fl = New-Object System.Collections.Generic.List[object]
            foreach ($t in $r.B.Split(',')) {
                if (($p = $t.IndexOf('!~')) -gt 0) { $o = '!~'; $w = 2 }
                elseif (($p = $t.IndexOf('!=')) -gt 0) { $o = '!='; $w = 2 }
                elseif (($p = $t.IndexOf('~')) -gt 0) { $o = '~'; $w = 1 }
                else { $p = $t.IndexOf('='); $o = '='; $w = 1 }
                $fl.Add(@{ K = $t.Substring(0, $p); O = $o; V = $t.Substring($p + $w) })
            }
            $r.Filters = $fl
        }
        if ($r.Op -ceq 'by' -or $r.Op -ceq 'countby') {
            $s = $r.Arg
            if (($p = $s.IndexOf(' ')) -gt 0) { $r.Test = $s.Substring($p + 1); $s = $s.Substring(0, $p) }
            $r.By = $s; $r.Tag = $s
            if (($p = $s.IndexOf(':')) -gt 0) { $r.By = $s.Substring(0, $p); $r.Tag = $s.Substring($p + 1) }
        }
    }
    $labelRx = New-Object regex '([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"'
    foreach ($line in ($text -split "`n")) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
        $p = $line.IndexOf('{'); $q = $line.IndexOf(' ')
        $lab = $null
        $lt = ''
        if ($p -gt 0 -and ($q -lt 0 -or $p -lt $q)) {
            $nm = $line.Substring(0, $p)
            if (-not $wanted.ContainsKey($nm) -and -not $wantedB.ContainsKey($nm)) { continue }
            # The closing brace: the first one outside a quoted value.
            $e = -1; $inq = $false
            for ($i = $p + 1; $i -lt $line.Length; $i++) {
                $c = $line[$i]
                if ($c -eq '\' -and $inq) { $i++; continue }
                if ($c -eq '"') { $inq = -not $inq }
                elseif ($c -eq '}' -and -not $inq) { $e = $i; break }
            }
            if ($e -lt 0) { continue }
            $lab = @{}
            $lt = $line.Substring($p + 1, $e - $p - 1)
            foreach ($m in $labelRx.Matches($lt)) {
                $lab[$m.Groups[1].Value] = ($m.Groups[2].Value -replace '\\(.)', '$1')
            }
            $vs = $line.Substring($e + 1).Trim()
        }
        else {
            if ($q -lt 0) { continue }
            $nm = $line.Substring(0, $q)
            if (-not $wanted.ContainsKey($nm) -and -not $wantedB.ContainsKey($nm)) { continue }
            $lab = @{}
            $vs = $line.Substring($q + 1).Trim()
        }
        if (($sp = $vs.IndexOf(' ')) -gt 0) { $vs = $vs.Substring(0, $sp) }
        if (-not $vs -or $vs -ceq 'NaN' -or $vs -ceq '+Inf' -or $vs -ceq 'Inf' -or $vs -ceq '-Inf') { continue }
        $v = [double]0
        if (-not [double]::TryParse($vs, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { continue }
        # The other half of a maxpct: what each series is a share of.
        if ($wantedB.ContainsKey($nm)) {
            foreach ($r in $wantedB[$nm]) { if (Test-Labels $r $lab) { $r.Den[$lt] = $v } }
        }
        if (-not $wanted.ContainsKey($nm)) { continue }
        foreach ($r in $wanted[$nm]) {
            $ok = $true
            foreach ($t in $r.Filters) {
                $have = if ($lab.ContainsKey($t.K)) { $lab[$t.K] } else { '' }
                switch ($t.O) {
                    '=' { if ($have -cne $t.V) { $ok = $false } }
                    '!=' { if ($have -ceq $t.V) { $ok = $false } }
                    '~' { if ($have -cnotmatch $t.V) { $ok = $false } }
                    '!~' { if ($have -cmatch $t.V) { $ok = $false } }
                }
                if (-not $ok) { break }
            }
            if (-not $ok) { continue }
            # Here, not in the switch: there, continue would only leave the switch.
            if ($r.Op -ceq 'minpos' -and $v -le 0) { continue }
            switch ($r.Op) {
                'sum' { $r.Acc += $v }
                { $_ -ceq 'max' -or $_ -ceq 'age' } { if (-not $r.Has -or $v -gt $r.Acc) { $r.Acc = $v } }
                { $_ -ceq 'min' -or $_ -ceq 'oldest' -or $_ -ceq 'minpos' } { if (-not $r.Has -or $v -lt $r.Acc) { $r.Acc = $v } }
                'count' { if (Test-Value $v $r.Arg) { $r.Acc++ } }
                'maxpct' { $r.Num[$lt] = $v }
                { $_ -ceq 'by' -or $_ -ceq 'countby' } {
                    $key = if ($lab.ContainsKey($r.By)) { $lab[$r.By] } else { '' }
                    if (-not $r.Groups.Contains($key)) { $r.Groups[$key] = [double]0 }
                    if ($r.Op -ceq 'by') { $r.Groups[$key] = $r.Groups[$key] + $v }
                    elseif (Test-Value $v $r.Test) { $r.Groups[$key] = $r.Groups[$key] + 1 }
                }
                'info' {
                    if (-not $r.Has) {
                        $out = ''
                        foreach ($pr in $r.Arg.Split(',')) {
                            $lk = $pr; $lt = $pr
                            if (($pp = $pr.IndexOf(':')) -gt 0) { $lk = $pr.Substring(0, $pp); $lt = $pr.Substring($pp + 1) }
                            $out += ' ' + $lt + '=' + (Safe $(if ($lab.ContainsKey($lk)) { $lab[$lk] } else { '' }))
                        }
                        $r.Info = $out
                    }
                }
            }
            $r.Has = $true
        }
    }
    $val = @{}
    foreach ($r in $rows) {
        $show = -not $r.Name.StartsWith('_')
        if ($derived -ccontains $r.Op) {
            $x = $null; $y = $null
            foreach ($pair in @(@('x', $r.A), @('y', $r.B))) {
                $n = $null
                if ($val.ContainsKey($pair[1])) { $n = $val[$pair[1]] }
                elseif ($pair[1] -match '^-?[0-9.]+$') { $n = [double]::Parse($pair[1], $script:Inv) }
                if ($pair[0] -eq 'x') { $x = $n } else { $y = $n }
            }
            if ($null -eq $x -or $null -eq $y) { continue }
            switch ($r.Op) {
                'pct' { $v = if ($y -eq 0) { [double]0 } else { [Math]::Round(100 * $x / $y, 2, [MidpointRounding]::AwayFromZero) } }
                'div' { $v = if ($y -eq 0) { [double]0 } else { $x / $y } }
                'sub' { $v = $x - $y }
                'add' { $v = $x + $y }
                'mul' { $v = $x * $y }
            }
            $val[$r.Name] = [double]$v
            if ($show) { "metric $($r.Name) $(Fmt $v)" }
            continue
        }
        if (-not $r.Has -and $r.Quiet) { continue }
        switch ($r.Op) {
            { $_ -ceq 'sum' -or $_ -ceq 'count' } {
                $v = $r.Acc
                if ($r.Op -ceq 'sum' -and $r.Arg) { $v *= [double]::Parse($r.Arg, $script:Inv) }
                $val[$r.Name] = $v
                if ($show) { "metric $($r.Name) $(Fmt $v)" }
            }
            { $_ -ceq 'max' -or $_ -ceq 'min' -or $_ -ceq 'minpos' } {
                if ($r.Has) {
                    $v = $r.Acc
                    if ($r.Arg) { $v *= [double]::Parse($r.Arg, $script:Inv) }
                    $val[$r.Name] = $v
                    if ($show) { "metric $($r.Name) $(Fmt $v)" }
                }
            }
            'maxpct' {
                $best = [double]-1
                foreach ($k in @($r.Num.Keys)) {
                    if ($r.Den.ContainsKey($k) -and $r.Den[$k] -gt 0) { $x = 100 * $r.Num[$k] / $r.Den[$k]; if ($x -gt $best) { $best = $x } }
                }
                if ($best -ge 0) {
                    $v = [Math]::Round($best, 2, [MidpointRounding]::AwayFromZero)
                    $val[$r.Name] = [double]$v
                    if ($show) { "metric $($r.Name) $(Fmt $v)" }
                }
            }
            { $_ -ceq 'age' -or $_ -ceq 'oldest' } {
                if ($r.Has -and $r.Acc -gt 0) {
                    $v = $r.Acc
                    if ($r.Arg -ceq 'ms') { $v /= 1000 }
                    $v = $script:Now - $v
                    if ($v -lt 0) { $v = 0 }
                    $v = [Math]::Truncate($v)
                    $val[$r.Name] = $v
                    if ($show) { "metric $($r.Name) $(Fmt $v)" }
                }
            }
            'info' { if ($null -ne $r.Info) { "metric $($r.Name) 1$($r.Info)" } }
            { $_ -ceq 'by' -or $_ -ceq 'countby' } {
                $keys = @($r.Groups.Keys)
                $done = @{}
                $shown = 0
                while ($shown -lt 20 -and $shown -lt $keys.Count) {
                    $best = $null
                    foreach ($k in $keys) {
                        if ($done.ContainsKey($k)) { continue }
                        if ($null -eq $best -or $r.Groups[$k] -gt $r.Groups[$best]) { $best = $k }
                    }
                    $done[$best] = $true; $shown++
                    "metric $($r.Name) $(Fmt $r.Groups[$best]) $($r.Tag)=$(Safe $best)"
                }
                "metric $($r.Name)_not_shown $($keys.Count - $shown)"
            }
        }
    }
}
