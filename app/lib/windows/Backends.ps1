#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    Vigil HTTP backends - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Datadog (Series API v2), OpenTelemetry (OTLP/HTTP, JSON encoding) and
    Splunk (HTTP Event Collector), SPECIFICATION.md 15.3. Builds one request from a batch of spool event
    files, sends it with the HTTPS client of Stores.ps1, and says what
    became of the batch. The twin of backends.sh, which documents the rules;
    tests/conformance/backend holds the shared cases.

    New-VigilBackendBody -Type <datadog | otel | splunk> -Now <epoch> -Events <file>... [-Totals <text>]
    returns @{ Body; Points; Drops; TotalsNew }, Drops a list of
    "<reason> <count>"; for otel, TotalsNew holds the running totals of
    counts after the batch.

    Send-VigilBackend -Root <dir> -Parsed <config> -Name <name> -Type <type> -Events <file>... [-Totals <text>]
    returns @{ Ok; Sent; Drops; Why; TotalsNew }: Ok when the batch is done
    with, otherwise Why says why it is to be retried later. For otel, the
    caller keeps TotalsNew once the batch is done with, and passes it back
    with the next batch.

    Requires Secrets.ps1, Stores.ps1 and Worker.ps1.
#>

# Datadog drops points older than this many seconds without an error.
$Script:VigilDatadogMaxAge = 3600

# The time requests are made at; replaced by the conformance runner.
function Get-VigilBackendNow {
    return [DateTimeOffset]::Now.ToUnixTimeSeconds()
}

# The name of a tag as a Splunk field: a name Splunk keeps for itself gets a
# prefix.
function ConvertTo-VigilSplunkKey {
    param([string]$Key)
    if ($Key -cmatch '^(metric_name|source|sourcetype|index|time|host|_.*)$') { return "tag_$Key" }
    return $Key
}

# OTLP counts are cumulative sums (15.3), as in backends.sh, which
# documents the rules: a series is a name and its tags sorted by key, and
# its running total on the backend is carried in -Totals, the lines
# "<series>`t<start ns>`t<total>`t<last ns>".
function Add-VigilBackendTotals {
    param($Counts, [string]$Totals, [long]$Now, [System.Text.StringBuilder]$Sb)
    $tot = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($l in $Totals.Split("`n")) {
        if ($l -cmatch '^([^\t]+)\t(-?[0-9]{1,19})\t([0-9]{1,19})\t([0-9]{1,19})$' -and -not $tot.Contains($Matches[1])) {
            $tot[$Matches[1]] = @([long]$Matches[2], [long]$Matches[3], [long]$Matches[4])
        }
    }
    foreach ($series in $Counts.Keys) {
        $c = $Counts[$series]
        if ($tot.Contains($series)) { $start, $total, $prev = $tot[$series] }
        else { $start = ($c.First - 1) * 1000000000; $total = [long]0; $prev = [long]0 }
        $total += $c.Sum
        $t = $c.Last * 1000000000
        if ($t -lt $prev + 1000000) { $t = $prev + 1000000 }
        $tot[$series] = @($start, $total, $t)
        if ($Sb.Length -gt 0) { [void]$Sb.Append(',') }
        [void]$Sb.Append("{`"name`":`"$($series.Split(' ')[0])`",`"sum`":{`"aggregationTemporality`":2,`"isMonotonic`":true,`"dataPoints`":[{`"startTimeUnixNano`":`"$start`",`"timeUnixNano`":`"$t`",`"asDouble`":$total,`"attributes`":[$($c.Attrs)]}]}}")
    }
    # Forget the series not counted for 7 days.
    $cutoff = ($Now - 604800) * 1000000000
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($series in $tot.Keys) {
        $v = $tot[$series]
        if ($v[2] -ge $cutoff) { $keep.Add("$series`t$($v[0])`t$($v[1])`t$($v[2])") }
    }
    return ($keep -join "`n")
}

function New-VigilBackendBody {
    param([string]$Type, [long]$Now, [string[]]$Events, [string]$Totals = '')
    $sb = New-Object System.Text.StringBuilder
    $points = 0
    $invalid = 0
    $old = 0
    # This batch's whole counts, by series, in the order first seen.
    $counts = New-Object System.Collections.Specialized.OrderedDictionary
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
                elseif ($Type -ceq 'splunk') {
                    if ($key -ceq 'host') { $res = "`"host`":$(& $q $val)," }
                    else { $tags.Add(",`"$(ConvertTo-VigilSplunkKey $key)`":$(& $q $val)") }
                }
                elseif ($key -ceq 'host') { $res = ",`"resources`":[{`"name`":$(& $q $val),`"type`":`"host`"}]" }
                else { $tags.Add((& $q "${key}:$val")) }
            }
            if ($Type -ceq 'otel' -and $kind -ceq 'count' -and $value -cmatch '^(0|[1-9][0-9]{0,14})$') {
                # A whole count joins its series' running total, sent once the
                # batch is read. The tags sorted by key, keeping their order
                # otherwise.
                $sortedTags = New-Object System.Collections.Generic.List[string]
                for ($t = 4; $t -lt $w.Length; $t++) {
                    $k = $w[$t].Substring(0, $w[$t].IndexOf('='))
                    $j = $sortedTags.Count
                    while ($j -gt 0 -and [string]::CompareOrdinal($sortedTags[$j - 1].Substring(0, $sortedTags[$j - 1].IndexOf('=')), $k) -gt 0) { $j-- }
                    $sortedTags.Insert($j, $w[$t])
                }
                $series = (@($name) + $sortedTags) -join ' '
                $attrs = @(foreach ($s in $sortedTags) {
                        $eq = $s.IndexOf('=')
                        "{`"key`":`"$($s.Substring(0, $eq))`",`"value`":{`"stringValue`":$(& $q $s.Substring($eq + 1))}}"
                    }) -join ','
                $e = [long]$epoch
                if ($counts.Contains($series)) {
                    $c = $counts[$series]
                    if ($e -gt $c.Last) { $c.Last = $e }
                    $c.Sum += [long]$value
                    $c.Attrs = $attrs
                }
                else { $counts[$series] = @{ First = $e; Last = $e; Sum = [long]$value; Attrs = $attrs } }
                $points++
                continue
            }
            # HEC takes events one after another, not as a list.
            if ($sb.Length -gt 0 -and $Type -cne 'splunk') { [void]$sb.Append(',') }
            if ($Type -ceq 'splunk') {
                [void]$sb.Append("{`"time`":$epoch,$res`"source`":`"vigil`",`"event`":`"metric`",`"fields`":{`"metric_name`":`"$name`",`"_value`":$value,`"metric_type`":`"$kind`"$($tags -join '')}}")
            }
            elseif ($Type -ceq 'datadog') {
                $n = if ($kind -ceq 'count') { 1 } else { 3 }
                [void]$sb.Append("{`"metric`":`"$name`",`"type`":$n,`"points`":[{`"timestamp`":$epoch,`"value`":$value}]$res,`"tags`":[$($tags -join ',')]}")
            }
            else {
                # A gauge, and a count that is not a whole number: a running
                # total of those would not be exact, so it goes as a gauge.
                $point = "{`"timeUnixNano`":`"${epoch}000000000`",`"asDouble`":$value,`"attributes`":[$($tags -join ',')]}"
                [void]$sb.Append("{`"name`":`"$name`",`"gauge`":{`"dataPoints`":[$point]}}")
            }
            $points++
        }
    }
    $totalsNew = $Totals
    if ($Type -ceq 'otel') { $totalsNew = Add-VigilBackendTotals -Counts $counts -Totals $Totals -Now $Now -Sb $sb }
    $body = if ($Type -ceq 'datadog') { "{`"series`":[$($sb.ToString())]}" }
    elseif ($Type -ceq 'splunk') { $sb.ToString() }
    else { "{`"resourceMetrics`":[{`"resource`":{`"attributes`":[{`"key`":`"service.name`",`"value`":{`"stringValue`":`"vigil`"}}]},`"scopeMetrics`":[{`"scope`":{`"name`":`"vigil`"},`"metrics`":[$($sb.ToString())]}]}]}" }
    $drops = New-Object System.Collections.Generic.List[string]
    if ($invalid -gt 0) { $drops.Add("invalid $invalid") }
    if ($old -gt 0) { $drops.Add("too_old $old") }
    return @{ Body = $body; Points = $points; Drops = $drops; TotalsNew = $totalsNew }
}

function Send-VigilBackend {
    param([string]$Root, $Parsed, [string]$Name, [string]$Type, [string[]]$Events, [string]$Totals = '')
    $fail = { param([string]$Why) @{ Ok = $false; Sent = 0; Drops = (New-Object System.Collections.Generic.List[string]); Why = $Why; TotalsNew = $Totals } }
    $endpoint = ''; $key = ''; $ca = ''; $timeout = 10
    $keyName = if ($Type -ceq 'splunk') { 'token' } else { 'api_key' }
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -cne "backend.$Name") { continue }
        switch -CaseSensitive ($e.Key) {
            'endpoint' { $endpoint = $e.Value }
            'api_key' { if ($keyName -ceq 'api_key') { $key = $e.Value } }
            'token' { if ($keyName -ceq 'token') { $key = $e.Value } }
            'ca_file' { $ca = $e.Value }
            'timeout' { $timeout = ConvertTo-VigilSeconds $e.Value }
        }
    }
    if ($ca -and -not ($ca.StartsWith('/') -or [System.IO.Path]::IsPathRooted($ca))) { $ca = Join-Path $Root $ca }
    if (-not $endpoint) {
        if ($Type -ceq 'splunk') { return & $fail "the backend needs 'endpoint'" }
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
    # Datadog's endpoint is the site; the others' is the full URL, or a bare
    # address that gets the standard path.
    $url = if ($endpoint.EndsWith('/')) { $endpoint.Substring(0, $endpoint.Length - 1) } else { $endpoint }
    if ($Type -ceq 'datadog') { $url += '/api/v2/series' }
    elseif ($url.Substring($url.IndexOf('://') + 3).IndexOf('/') -lt 0) { $url += $(if ($Type -ceq 'splunk') { '/services/collector/event' } else { '/v1/metrics' }) }

    $b = New-VigilBackendBody -Type $Type -Now (Get-VigilBackendNow) -Events $Events -Totals $Totals
    if ($b.Points -eq 0) { return @{ Ok = $true; Sent = 0; Drops = $b.Drops; Why = ''; TotalsNew = $b.TotalsNew } }

    $headers = @('Content-Type: application/json')
    if ($key) {
        $r = Resolve-VigilSecret -Root $Root -Parsed $Parsed -Reference $key
        if (-not $r.Ok) { return & $fail "$keyName ${key}: $($r.Why)" }
        if ($r.Value -match '[\x00-\x1f\x7f]') { return & $fail "$keyName ${key}: contains a control character" }
        if ($Type -ceq 'datadog') { $headers += "DD-API-KEY: $($r.Value)" }
        elseif ($Type -ceq 'splunk') { $headers += "Authorization: Splunk $($r.Value)" }
        else { $headers += "Authorization: Bearer $($r.Value)" }
        $r = $null
    }
    elseif ($Type -cne 'otel') { return & $fail "the backend needs '$keyName'" }

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
        return @{ Ok = $true; Sent = $b.Points - $rejected; Drops = $drops; Why = ''; TotalsNew = $b.TotalsNew }
    }
    if ($r.Status -eq 400 -or $r.Status -eq 413) {
        # Malformed or too large: sending it again cannot succeed.
        $drops.Add("rejected $($b.Points)")
        return @{ Ok = $true; Sent = 0; Drops = $drops; Why = ''; TotalsNew = $b.TotalsNew }
    }
    if ($r.Status -eq 401 -or $r.Status -eq 403) { return & $fail "permission denied (HTTP $($r.Status))" }
    return & $fail "HTTP $($r.Status) from $hostPart"
}
