#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil HTTP backends - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Datadog (Series API v2) and OpenTelemetry (OTLP/HTTP, JSON encoding),
    SPECIFICATION.md 15.3. Builds one request from a batch of spool event
    files, sends it with the HTTPS client of Stores.ps1, and says what
    became of the batch. The twin of backends.sh, which documents the rules;
    tests/conformance/backend holds the shared cases.

    New-VigilBackendBody -Type <datadog | otel> -Now <epoch> -Events <file>...
    returns @{ Body; Points; Drops }, Drops a list of "<reason> <count>".

    Send-VigilBackend -Root <dir> -Parsed <config> -Name <name> -Type <type> -Events <file>...
    returns @{ Ok; Sent; Drops; Why }: Ok when the batch is done with,
    otherwise Why says why it is to be retried later.

    Requires Secrets.ps1, Stores.ps1 and Worker.ps1.
#>

# Datadog drops points older than this many seconds without an error.
$Script:VigilDatadogMaxAge = 3600

# The time requests are made at; replaced by the conformance runner.
function Get-VigilBackendNow {
    return [DateTimeOffset]::Now.ToUnixTimeSeconds()
}

function New-VigilBackendBody {
    param([string]$Type, [long]$Now, [string[]]$Events)
    $sb = New-Object System.Text.StringBuilder
    $points = 0
    $invalid = 0
    $old = 0
    $q = { param([string]$s) if ($s.IndexOf('"') -ge 0 -or $s.IndexOf('\') -ge 0) { ConvertTo-VigilJsonQuoted $s } else { "`"$s`"" } }
    foreach ($f in $Events) {
        if (-not [System.IO.File]::Exists($f)) { continue }
        # Split on newlines only, as bash reads them.
        $lines = [System.IO.File]::ReadAllText($f).Split("`n")
        $count = $lines.Length
        if ($count -gt 0 -and $lines[$count - 1] -ceq '') { $count-- }
        for ($l = 0; $l -lt $count; $l++) {
            $line = $lines[$l]
            if ($line -ceq '') { continue }
            if ($line -match '[\x00-\x1f\x7f]') { $invalid++; continue }
            $w = $line.Split([char[]]@(' '), [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($w.Length -lt 4) { $invalid++; continue }
            $epoch = $w[0]; $name = $w[1]; $value = $w[2]; $kind = $w[3]
            if (($kind -cne 'gauge' -and $kind -cne 'count') -or $epoch -cnotmatch '^(0|[1-9][0-9]{0,11})$' -or
                $value -cnotmatch '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$' -or $name -cnotmatch '^[A-Za-z0-9_.]+$') { $invalid++; continue }
            # Tags are key=value, keys [A-Za-z0-9_]+ and values non-empty.
            $bad = $false
            for ($t = 4; $t -lt $w.Length; $t++) {
                $eq = $w[$t].IndexOf('=')
                if ($eq -lt 1 -or $eq -eq $w[$t].Length - 1 -or $w[$t].Substring(0, $eq) -cnotmatch '^[A-Za-z0-9_]+$') { $bad = $true; break }
            }
            if ($bad) { $invalid++; continue }
            if ($Type -ceq 'datadog' -and $Now - [long]$epoch -gt $Script:VigilDatadogMaxAge) { $old++; continue }
            $tags = New-Object System.Collections.Generic.List[string]
            $res = ''
            for ($t = 4; $t -lt $w.Length; $t++) {
                $eq = $w[$t].IndexOf('=')
                $key = $w[$t].Substring(0, $eq)
                $val = $w[$t].Substring($eq + 1)
                if ($Type -ceq 'otel') { $tags.Add("{`"key`":`"$key`",`"value`":{`"stringValue`":$(& $q $val)}}") }
                elseif ($key -ceq 'host') { $res = ",`"resources`":[{`"name`":$(& $q $val),`"type`":`"host`"}]" }
                else { $tags.Add((& $q "${key}:$val")) }
            }
            if ($points -gt 0) { [void]$sb.Append(',') }
            if ($Type -ceq 'datadog') {
                $n = if ($kind -ceq 'count') { 1 } else { 3 }
                [void]$sb.Append("{`"metric`":`"$name`",`"type`":$n,`"points`":[{`"timestamp`":$epoch,`"value`":$value}]$res,`"tags`":[$($tags -join ',')]}")
            }
            else {
                $start = if ($kind -ceq 'count') { "`"startTimeUnixNano`":`"${epoch}000000000`"," } else { '' }
                $point = "{$start`"timeUnixNano`":`"${epoch}000000000`",`"asDouble`":$value,`"attributes`":[$($tags -join ',')]}"
                if ($kind -ceq 'count') { [void]$sb.Append("{`"name`":`"$name`",`"sum`":{`"aggregationTemporality`":1,`"isMonotonic`":true,`"dataPoints`":[$point]}}") }
                else { [void]$sb.Append("{`"name`":`"$name`",`"gauge`":{`"dataPoints`":[$point]}}") }
            }
            $points++
        }
    }
    $body = if ($Type -ceq 'datadog') { "{`"series`":[$($sb.ToString())]}" }
    else { "{`"resourceMetrics`":[{`"resource`":{`"attributes`":[{`"key`":`"service.name`",`"value`":{`"stringValue`":`"vigil`"}}]},`"scopeMetrics`":[{`"scope`":{`"name`":`"vigil`"},`"metrics`":[$($sb.ToString())]}]}]}" }
    $drops = New-Object System.Collections.Generic.List[string]
    if ($invalid -gt 0) { $drops.Add("invalid $invalid") }
    if ($old -gt 0) { $drops.Add("too_old $old") }
    return @{ Body = $body; Points = $points; Drops = $drops }
}

function Send-VigilBackend {
    param([string]$Root, $Parsed, [string]$Name, [string]$Type, [string[]]$Events)
    $fail = { param([string]$Why) @{ Ok = $false; Sent = 0; Drops = (New-Object System.Collections.Generic.List[string]); Why = $Why } }
    $endpoint = ''; $key = ''; $ca = ''; $timeout = 10
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -cne "backend.$Name") { continue }
        switch -CaseSensitive ($e.Key) {
            'endpoint' { $endpoint = $e.Value }
            'api_key' { $key = $e.Value }
            'ca_file' { $ca = $e.Value }
            'timeout' { $timeout = ConvertTo-VigilSeconds $e.Value }
        }
    }
    if ($ca -and -not ($ca.StartsWith('/') -or [System.IO.Path]::IsPathRooted($ca))) { $ca = Join-Path $Root $ca }
    if (-not $endpoint) {
        $endpoint = if ($Type -ceq 'datadog') { 'https://api.datadoghq.com' } else { 'http://localhost:4318/v1/metrics' }
    }

    # https only; plain http only to a collector on this host, never
    # through a proxy (the request does not leave the machine).
    $hostPart = if ($endpoint.IndexOf('://') -ge 0) { $endpoint.Substring($endpoint.IndexOf('://') + 3) } else { $endpoint }
    $hostPart = $hostPart.Split('/')[0].Split('?')[0]
    $meta = $false
    if ($endpoint -cmatch '^http://(localhost|127\.0\.0\.1|\[::1\])([:/].*)?$') { $meta = $true }
    elseif (-not $endpoint.StartsWith('https://', [System.StringComparison]::Ordinal)) { return & $fail 'endpoint must be https (plain http only to this host)' }
    if ($hostPart.IndexOf('@') -ge 0) { return & $fail 'endpoint must not hold credentials' }
    # Datadog's endpoint is the site; OTLP's is the full URL, or a bare
    # collector address that gets the standard path.
    $url = if ($endpoint.EndsWith('/')) { $endpoint.Substring(0, $endpoint.Length - 1) } else { $endpoint }
    if ($Type -ceq 'datadog') { $url += '/api/v2/series' }
    elseif ($url.Substring($url.IndexOf('://') + 3).IndexOf('/') -lt 0) { $url += '/v1/metrics' }

    $b = New-VigilBackendBody -Type $Type -Now (Get-VigilBackendNow) -Events $Events
    if ($b.Points -eq 0) { return @{ Ok = $true; Sent = 0; Drops = $b.Drops; Why = '' } }

    $headers = @('Content-Type: application/json')
    if ($key) {
        $r = Resolve-VigilSecret -Root $Root -Parsed $Parsed -Reference $key
        if (-not $r.Ok) { return & $fail "api_key ${key}: $($r.Why)" }
        if ($r.Value -match '[\x00-\x1f\x7f]') { return & $fail "api_key ${key}: contains a control character" }
        if ($Type -ceq 'datadog') { $headers += "DD-API-KEY: $($r.Value)" } else { $headers += "Authorization: Bearer $($r.Value)" }
        $r = $null
    }
    elseif ($Type -ceq 'datadog') { return & $fail "the backend needs 'api_key'" }

    $r = Invoke-VigilHttpSend -Timeout $timeout -Method 'POST' -Url $url -CaFile $ca -Metadata $meta -Headers $headers -Body $b.Body
    $headers = $null
    if (-not $r.Ok) {
        $why = switch ($r.Fail) {
            'resolve' { "cannot resolve $hostPart" }
            'connect' { "cannot connect to $hostPart" }
            'timeout' { "no answer from $hostPart within ${timeout}s" }
            'untrusted' { "the certificate of $hostPart is not trusted" }
            'tls' { "no secure connection to $hostPart" }
            'cafile' { "cannot read ca_file $ca" }
            default { "the request to $hostPart failed" }
        }
        return & $fail $why
    }
    $drops = $b.Drops
    if ($r.Status -ge 200 -and $r.Status -le 299) {
        # OTLP's partial success: the points it refused will never be
        # accepted, so they are dropped, not retried.
        $rejected = 0
        if ($Type -ceq 'otel' -and $r.Body -cmatch '"rejectedDataPoints"\s*:\s*"?([0-9]+)') {
            $rejected = if ($Matches[1].Length -gt 9) { $b.Points } else { [int]$Matches[1] }
        }
        if ($rejected -gt $b.Points) { $rejected = $b.Points }
        if ($rejected -gt 0) { $drops.Add("rejected $rejected") }
        return @{ Ok = $true; Sent = $b.Points - $rejected; Drops = $drops; Why = '' }
    }
    if ($r.Status -eq 400 -or $r.Status -eq 413) {
        # Malformed or too large: sending it again cannot succeed.
        $drops.Add("rejected $($b.Points)")
        return @{ Ok = $true; Sent = 0; Drops = $drops; Why = '' }
    }
    if ($r.Status -eq 401 -or $r.Status -eq 403) { return & $fail "permission denied (HTTP $($r.Status))" }
    return & $fail "HTTP $($r.Status) from $hostPart"
}
