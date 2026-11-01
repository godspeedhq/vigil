#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil log forwarder - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    The body of the vigil_logs worker (SPECIFICATION.md 13.4): sends what is
    new in Vigil's own logs to the [log_destination.*] in OTLP/HTTP JSON, one
    file and one request at a time, and moves each file's checkpoint only
    past what the destination accepted. Local logs are never changed. The
    twin of logs.sh.

    Invoke-VigilLogs -Ctx <worker context> -HostName <name> -Root <dir> -Log <file> -RunId <id>
        Called by the worker after its claim. Returns @{ Ok; Reason }.
    Test-VigilLogsEnabled -Parsed <parsed>
        Whether the configuration forwards logs.
    Get-VigilLogFiles -LogDir <dir>
        Every forwarded log file as @{ File; Size }, oldest first.
    Get-VigilLogsInclude -Parsed <parsed>
        The categories to forward.
    Test-VigilLogsOutput -Parsed <parsed> -Job <id>
        Whether a job's stdout and stderr may be forwarded.
    Remove-VigilOldLogs -Parsed <parsed> -LogDir <dir> -Epoch <time>
        Deletes the log files older than their retention (13.1).
    ConvertTo-VigilLogRecord -File <file> -Line <line> -Include <list> -Output <bool>
        Pure: the OTLP log record of one line of a log file (relative to
        the log directory, with / separators), or '' when it is not
        forwarded. The line is a string of bytes, one character each, and so
        is the record: Latin-1 turns one into the other. Must produce exactly
        what logs.sh does - tests/conformance/logs holds the shared cases.

    Requires Config.ps1, Worker.ps1, Secrets.ps1, Stores.ps1 and Fetch.ps1.
#>

$Script:VigilLogsLineMax = 65536
# The longest one forwarder runs: it stops starting requests after this, so
# it stays within its fixed 5 minutes (13.4.3).
$Script:VigilLogsRunSecs = 240
$Script:VigilLatin1 = [System.Text.Encoding]::GetEncoding(28591)

function Test-VigilLogsEnabled {
    param($Parsed)
    if (-not ($Parsed.Sections | Where-Object { $_.Name -ceq 'log_forward' })) { return $false }
    return (Get-VigilConfigValue $Parsed 'log_forward' 'enabled' 'true') -cne 'false'
}

# The status file and the forwarder's own log are never forwarded (13.4.2).
# Oldest first: by file name, so a day's files sort together.
function Get-VigilLogFiles {
    param([string]$LogDir)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $sup = Join-Path $LogDir 'supervisor'
    if ([System.IO.Directory]::Exists($sup)) {
        foreach ($f in [System.IO.Directory]::GetFiles($sup, '*.log')) {
            $n = [System.IO.Path]::GetFileName($f)
            if ($n -cne 'jobs.log') { $out.Add(@{ File = "supervisor/$n"; Base = $n; Size = (New-Object System.IO.FileInfo $f).Length }) }
        }
    }
    $jobs = Join-Path $LogDir 'jobs'
    if ([System.IO.Directory]::Exists($jobs)) {
        foreach ($d in [System.IO.Directory]::GetDirectories($jobs)) {
            $j = [System.IO.Path]::GetFileName($d)
            if ($j -ceq 'vigil_logs') { continue }
            foreach ($f in [System.IO.Directory]::GetFiles($d, '*.log')) {
                $n = [System.IO.Path]::GetFileName($f)
                $out.Add(@{ File = "jobs/$j/$n"; Base = $n; Size = (New-Object System.IO.FileInfo $f).Length })
            }
        }
    }
    $keyed = New-Object 'System.Collections.Generic.List[string]'
    $byKey = @{}
    foreach ($x in $out) { $k = "$($x.Base)`t$($x.File)"; $keyed.Add($k); $byKey[$k] = $x }
    $keyed.Sort([System.StringComparer]::Ordinal)
    $sorted = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $keyed) { $sorted.Add($byKey[$k]) }
    return , $sorted
}

function Get-VigilLogsTotal {
    param([string]$LogDir)
    $t = [long]0
    $files = Get-VigilLogFiles -LogDir $LogDir
    foreach ($x in $files) { $t += $x.Size }
    return $t
}

function Get-VigilLogsInclude {
    param($Parsed)
    return @((Get-VigilConfigValue $Parsed 'log_forward' 'include' 'supervisor, run').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Never for a job the configuration no longer names, since its
# forward_output is not known.
function Test-VigilLogsOutput {
    param($Parsed, [string]$Job)
    if (-not ($Parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })) { return $false }
    $d = Get-VigilConfigValue $Parsed 'defaults' 'forward_output' 'true'
    return (Get-VigilConfigValue $Parsed "job.$Job" 'forward_output' $d) -cne 'false'
}

# A byte string as the inside of a JSON string. Control characters and
# invalid UTF-8 are escaped, never sent raw (13.4.5).
function ConvertTo-VigilLogText {
    param([string]$Text)
    if ($Text -cmatch '^[\x20\x21\x23-\x5b\x5d-\x7e]*$') { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $b = [int]$Text[$i]
        $i++
        if ($b -lt 128) {
            if ($b -eq 34) { [void]$sb.Append('\"') }
            elseif ($b -eq 92) { [void]$sb.Append('\\') }
            elseif ($b -lt 32 -or $b -eq 127) { [void]$sb.Append(('\u{0:x4}' -f $b)) }
            else { [void]$sb.Append([char]$b) }
            continue
        }
        $more = 0; $low = 128; $high = 191
        if ($b -ge 194 -and $b -le 223) { $more = 1 }
        elseif ($b -eq 224) { $more = 2; $low = 160 }
        elseif ($b -eq 237) { $more = 2; $high = 159 }
        elseif ($b -ge 225 -and $b -le 239) { $more = 2 }
        elseif ($b -eq 240) { $more = 3; $low = 144 }
        elseif ($b -eq 244) { $more = 3; $high = 143 }
        elseif ($b -ge 241 -and $b -le 243) { $more = 3 }
        $j = 0
        while ($j -lt $more) {
            if ($i + $j -ge $n) { $more = 0; break }
            $c = [int]$Text[$i + $j]
            if ($c -lt $low -or $c -gt $high) { $more = 0; break }
            $low = 128; $high = 191
            $j++
        }
        if ($more -eq 0) { [void]$sb.Append('\' + 'ufffd') }
        else {
            [void]$sb.Append([char]$b).Append($Text, $i, $more)
            $i += $more
        }
    }
    return $sb.ToString()
}

function ConvertTo-VigilLogAttr {
    param([string]$Key, [string]$Value)
    return "{`"key`":`"$Key`",`"value`":{`"stringValue`":`"$(ConvertTo-VigilLogText $Value)`"}}"
}

# Days since 1970 of a date.
function Get-VigilLogDays {
    param([long]$Year, [long]$Month, [long]$Day)
    $y = $Year
    if ($Month -le 2) { $y-- }
    $era = [Math]::Floor($y / 400)
    $yoe = $y - $era * 400
    $doy = [Math]::Floor((153 * (($Month + 9) % 12) + 2) / 5) + $Day - 1
    $doe = $yoe * 365 + [Math]::Floor($yoe / 4) - [Math]::Floor($yoe / 100) + $doy
    return [long]($era * 146097 + $doe - 719468)
}

# Seconds since 1970 of a time as Vigil's logs write it, or -1.
function ConvertFrom-VigilLogTime {
    param([string]$Text)
    if ($Text -cnotmatch '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$') { return [long]-1 }
    $t = [long]$Matches[4] * 3600 + [long]$Matches[5] * 60 + [long]$Matches[6]
    return (Get-VigilLogDays $Matches[1] $Matches[2] $Matches[3]) * 86400 + $t
}

# Deletes dated log files older than their retention (13.1), whole, and
# never for the forwarder's sake (13.4.4). The status file has no date.
# Returns the number deleted.
function Remove-VigilOldLogs {
    param($Parsed, [string]$LogDir, [long]$Epoch)
    $today = [long][Math]::Floor($Epoch / 86400)
    $removed = 0
    $base = Get-VigilConfigValue $Parsed 'log' 'retain_days' '7'
    $dirs = New-Object 'System.Collections.Generic.List[object]'
    $sup = Join-Path $LogDir 'supervisor'
    if ([System.IO.Directory]::Exists($sup)) { $dirs.Add(@{ Dir = $sup; Keep = [long]$base }) }
    $jobs = Join-Path $LogDir 'jobs'
    if ([System.IO.Directory]::Exists($jobs)) {
        $dflt = Get-VigilConfigValue $Parsed 'defaults' 'log_retain_days' $base
        foreach ($d in [System.IO.Directory]::GetDirectories($jobs)) {
            $dirs.Add(@{ Dir = $d; Keep = [long](Get-VigilConfigValue $Parsed "job.$([System.IO.Path]::GetFileName($d))" 'log_retain_days' $dflt) })
        }
    }
    foreach ($x in $dirs) {
        foreach ($f in [System.IO.Directory]::GetFiles($x.Dir, '*.log')) {
            if ([System.IO.Path]::GetFileName($f) -cnotmatch '^([0-9]{4})-([0-9]{2})-([0-9]{2})([.][0-9]+)?[.]log$') { continue }
            if ($today - (Get-VigilLogDays $Matches[1] $Matches[2] $Matches[3]) -gt $x.Keep) {
                try { [System.IO.File]::Delete($f); $removed++ } catch { }
            }
        }
    }
    return $removed
}

function ConvertTo-VigilLogRecord {
    param([string]$File, [string]$Line, [string[]]$Include, [bool]$Output)
    if ($Line.EndsWith("`r")) { $Line = $Line.Substring(0, $Line.Length - 1) }
    $sp = $Line.IndexOf(' ')
    $when = if ($sp -ge 0) { $Line.Substring(0, $sp) } else { $Line }
    $rest = if ($sp -ge 0) { $Line.Substring($sp + 1) } else { '' }
    $sp2 = $rest.IndexOf(' ')
    $r2 = if ($sp2 -ge 0) { $rest.Substring($sp2 + 1) } else { '' }
    $msg = $Line
    $job = ''; $rid = ''; $sev = ''
    if ($File.StartsWith('supervisor/', [System.StringComparison]::Ordinal)) {
        $category = 'supervisor'
        if ($rest -cmatch '^(INFO|WARN|ERROR) supervisor ') {
            $sev = switch -CaseSensitive ($Matches[1]) { 'INFO' { 'info' } 'WARN' { 'warn' } 'ERROR' { 'error' } }
            $msg = $r2.Substring(11)
        }
        else { $when = '' }
    }
    else {
        $job = $File.Substring(5)
        $job = $job.Substring(0, $job.IndexOf('/'))
        $category = 'run'
        $sp3 = $r2.IndexOf(' ')
        $stream = if ($sp3 -ge 0) { $r2.Substring(0, $sp3) } else { $r2 }
        if (@('run', 'out', 'err') -ccontains $stream) {
            $rid = if ($sp2 -ge 0) { $rest.Substring(0, $sp2) } else { $rest }
            $msg = if ($sp3 -ge 0) { $r2.Substring($sp3 + 1) } else { '' }
            if ($stream -ceq 'out') { $category = 'stdout' }
            elseif ($stream -ceq 'err') { $category = 'stderr' }
            else {
                $sev = 'info'
                if ($msg -cmatch '^end ([^ ]*)') {
                    if ($Matches[1] -ceq 'warning') { $sev = 'warn' }
                    elseif (@('failed', 'unknown', 'timed_out', 'crashed') -ccontains $Matches[1]) { $sev = 'error' }
                }
            }
        }
        else {
            # Not a line in the job log format: kept, as it stands.
            $when = ''
            $sev = 'info'
        }
    }
    if ($Include -cnotcontains $category) { return '' }
    if (($category -ceq 'stdout' -or $category -ceq 'stderr') -and -not $Output) { return '' }
    $cut = $false
    if ($msg.Length -gt $Script:VigilLogsLineMax) {
        $msg = $msg.Substring(0, $Script:VigilLogsLineMax)
        $cut = $true
    }
    $epoch = ConvertFrom-VigilLogTime $when
    $sb = New-Object System.Text.StringBuilder
    if ($epoch -ge 0) { [void]$sb.Append("{`"timeUnixNano`":`"${epoch}000000000`",") }
    else { [void]$sb.Append('{"timeUnixNano":"0",') }
    switch -CaseSensitive ($sev) {
        'info' { [void]$sb.Append('"severityNumber":9,"severityText":"INFO",') }
        'warn' { [void]$sb.Append('"severityNumber":13,"severityText":"WARN",') }
        'error' { [void]$sb.Append('"severityNumber":17,"severityText":"ERROR",') }
    }
    [void]$sb.Append("`"body`":{`"stringValue`":`"$(ConvertTo-VigilLogText $msg)`"},`"attributes`":[")
    [void]$sb.Append((ConvertTo-VigilLogAttr 'component' $(if ($category -ceq 'supervisor') { 'supervisor' } else { 'job' })))
    [void]$sb.Append(',' + (ConvertTo-VigilLogAttr 'category' $category))
    if ($job) { [void]$sb.Append(',' + (ConvertTo-VigilLogAttr 'job' $job)) }
    if ($rid) { [void]$sb.Append(',' + (ConvertTo-VigilLogAttr 'run_id' $rid)) }
    [void]$sb.Append(',' + (ConvertTo-VigilLogAttr 'source_file' $File))
    if ($cut) { [void]$sb.Append(',' + (ConvertTo-VigilLogAttr 'truncated' 'true')) }
    [void]$sb.Append(']}')
    return $sb.ToString()
}

# The POSIX cksum of some bytes, and how many: a checkpoint's fingerprint.
function Get-VigilLogFingerprint {
    param([string]$Path, [int]$Count)
    $buf = New-Object byte[] $Count
    $n = 0
    $fs = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read', 'ReadWrite'
    try {
        while ($n -lt $Count) {
            $r = $fs.Read($buf, $n, $Count - $n)
            if ($r -le 0) { break }
            $n += $r
        }
    }
    finally { $fs.Dispose() }
    [uint32]$crc = 0
    $step = {
        param([uint32]$c, [int]$b)
        $c = $c -bxor ([uint32]$b -shl 24)
        for ($k = 0; $k -lt 8; $k++) {
            if ($c -band [uint32]2147483648) { $c = (([uint64]$c -shl 1) -band [uint32]::MaxValue) -bxor [uint32]79764919 }
            else { $c = (([uint64]$c -shl 1) -band [uint32]::MaxValue) }
        }
        return [uint32]$c
    }
    for ($i = 0; $i -lt $n; $i++) { $crc = & $step $crc $buf[$i] }
    for ($l = $n; $l -gt 0; $l = $l -shr 8) { $crc = & $step $crc ($l -band 255) }
    $crc = [uint32]($crc -bxor [uint32]::MaxValue)
    return @{ Crc = [string]$crc; N = $n }
}

# Reads whole lines of a log file from an offset. Each is a byte string,
# with the offset just past its newline; the file is opened for sharing, so
# whoever is writing it is never disturbed.
function New-VigilLogReader {
    param([string]$Path, [long]$Offset)
    $fs = New-Object System.IO.FileStream -ArgumentList $Path, 'Open', 'Read', 'ReadWrite'
    [void]$fs.Seek($Offset, 'Begin')
    return @{ Stream = $fs; Buf = (New-Object byte[] 65536); Pos = 0; Len = 0; At = $Offset }
}

function Read-VigilLogLine {
    param($R)
    $ms = $null
    while ($true) {
        if ($R.Pos -ge $R.Len) {
            $R.Len = $R.Stream.Read($R.Buf, 0, $R.Buf.Length)
            $R.Pos = 0
            if ($R.Len -le 0) { return $null }
        }
        $nl = [Array]::IndexOf($R.Buf, [byte]10, $R.Pos, $R.Len - $R.Pos)
        $end = if ($nl -ge 0) { $nl } else { $R.Len }
        if ($nl -ge 0 -and -not $ms) {
            $line = $Script:VigilLatin1.GetString($R.Buf, $R.Pos, $end - $R.Pos)
            $R.Pos = $end + 1
            $R.At += $line.Length + 1
            return $line
        }
        if (-not $ms) { $ms = New-Object System.IO.MemoryStream }
        $ms.Write($R.Buf, $R.Pos, $end - $R.Pos)
        if ($nl -ge 0) {
            $R.Pos = $end + 1
            $line = $Script:VigilLatin1.GetString($ms.ToArray())
            $R.At += $line.Length + 1
            return $line
        }
        $R.Pos = $R.Len
    }
}

function Invoke-VigilLogs {
    param($Ctx, [string]$HostName, [string]$Root, [string]$Log, [string]$RunId)
    $parsed = $Ctx.Parsed
    $dir = Join-Path $Ctx.State 'logs'
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $g = @{
        Now = [DateTimeOffset]::Now.ToUnixTimeSeconds(); Failed = ''; Sent = 0; SentBytes = [long]0; Read = [long]0
        Events = New-Object 'System.Collections.Generic.List[string]'; Header = ''
    }
    $tags = "host=$HostName os=windows instance=$(Get-VigilConfigValue $parsed 'vigil' 'instance' 'vigil')"
    foreach ($e in $parsed.Entries) { if ($e.Section -ceq 'tags') { $tags += " $($e.Key)=$($e.Value)" } }
    $include = Get-VigilLogsInclude -Parsed $parsed

    $dest = Get-VigilConfigValue $parsed 'log_forward' 'destination' ''
    $batchLines = [int](Get-VigilConfigValue $parsed 'log_forward' 'batch_lines' '500')
    $batchBytes = [long](Get-VigilConfigValue $parsed 'log_forward' 'batch_kb' '512') * 1024
    $maxBytes = [long](Get-VigilConfigValue $parsed 'log_forward' 'max_pending_mb' '64') * 1048576
    $sec = "log_destination.$dest"
    $url = Get-VigilConfigValue $parsed $sec 'endpoint' ''
    $secs = [int](ConvertTo-VigilSeconds (Get-VigilConfigValue $parsed $sec 'timeout' '10s'))
    $hname = Get-VigilConfigValue $parsed $sec 'header_name' ''
    $hvalue = Get-VigilConfigValue $parsed $sec 'header_value' ''
    $hostPart = ($url -replace '^[a-z]+://', '').Split('/')[0]
    $plain = $url.StartsWith('http://', [System.StringComparison]::Ordinal)

    $failures = 0; $nextTry = [long]0; $prev = ''
    $statePath = Join-Path $dir 'forwarder.state'
    if ([System.IO.File]::Exists($statePath)) {
        foreach ($l in [System.IO.File]::ReadAllLines($statePath)) {
            if ($l -cmatch '^destination = (.*)$') { $prev = $Matches[1] }
            elseif ($l -cmatch '^failures = ([0-9]+)$') { $failures = [int]$Matches[1] }
            elseif ($l -cmatch '^next_try = ([0-9]+)$') { $nextTry = [long]$Matches[1] }
        }
    }

    # The active revision (16.5).
    $active = if ($Ctx.Config) { Read-VigilActive -Root $Root -State $Ctx.State } else { $null }
    $revision = if ($active) { $active.Revision }
    else { (Get-VigilTextSha "config $(Get-VigilFileSha (Join-Path $Root 'config\vigil.config'))`n").Substring(0, 12) }
    $attrs = ConvertTo-VigilLogAttr 'service.name' 'vigil'
    foreach ($t in $tags.Split(' ')) {
        $eq = $t.IndexOf('=')
        $attrs += ',' + (ConvertTo-VigilLogAttr $t.Substring(0, $eq) $t.Substring($eq + 1))
    }
    $attrs += ',' + (ConvertTo-VigilLogAttr 'config.revision' $revision)
    $resource = "{`"attributes`":[$attrs]}"

    $gap = {
        param([string]$Reason, [long]$Bytes, [string]$What)
        $g.Events.Add("$($g.Now) vigil.logs.gaps 1 count $tags reason=$Reason")
        $g.Events.Add("$($g.Now) vigil.logs.gap_bytes $Bytes count $tags reason=$Reason")
        $iso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $where = if ($What) { $What } else { 'the logs' }
        try { [System.IO.File]::AppendAllText($Log, "$iso $RunId run gap in ${where}: $Bytes bytes ($Reason)`r`n") } catch { }
    }
    # A failed request; the run stops and backs off.
    $failed = {
        param([string]$Reason, [string]$Text)
        $g.Failed = $Text
        $g.Events.Add("$($g.Now) vigil.logs.failures 1 count $tags reason=$Reason")
    }
    $ckPath = {
        param([string]$File)
        return Join-Path $dir ('logs%2F' + $File.Replace('%', '%25').Replace('/', '%2F') + '.checkpoint')
    }
    $ckRead = {
        param([string]$Path)
        $c = @{ State = 'none'; Offset = [long]0; Crc = ''; N = 0; Size = [long]0; File = '' }
        if (-not [System.IO.File]::Exists($Path)) { return $c }
        $c.State = 'bad'
        $o = ''; $s = ''; $fp = $false
        try {
            foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
                if ($l -cmatch '^file += (.*)$') { $c.File = $Matches[1] }
                elseif ($l -cmatch '^fingerprint += ([0-9]+) ([0-9]+)$') { $c.Crc = $Matches[1]; $c.N = [int]$Matches[2]; $fp = $true }
                elseif ($l -cmatch '^offset += ([0-9]+)$') { $o = $Matches[1] }
                elseif ($l -cmatch '^size += ([0-9]+)$') { $s = $Matches[1] }
            }
        }
        catch { return $c }
        if ($o -and $s -and $fp) { $c.State = 'ok'; $c.Offset = [long]$o; $c.Size = [long]$s }
        return $c
    }
    $ckWrite = {
        param([string]$Path, [string]$File, [long]$Offset, [long]$Size)
        $fp = Get-VigilLogFingerprint (Join-Path $Ctx.Logs $File.Replace('/', '\')) 64
        Write-VigilFileAtomic -Path $Path -Text "[checkpoint]`nfile        = logs/$File`nfingerprint = $($fp.Crc) $($fp.N)`noffset      = $Offset`nsize        = $Size`n"
    }

    # Sends a batch. Returns the leading records accepted; anything short
    # of all has called $failed.
    $send = {
        param([string]$Batch, [int]$Count)
        $headers = @('Content-Type: application/json')
        if ($g.Header) { $headers += $g.Header }
        $body = "{`"resourceLogs`":[{`"resource`":$resource,`"scopeLogs`":[{`"scope`":{`"name`":`"vigil`"},`"logRecords`":[$Batch]}]}]}"
        # The body is a byte string of valid UTF-8; the sender encodes text.
        $body = [System.Text.Encoding]::UTF8.GetString($Script:VigilLatin1.GetBytes($body))
        $r = Invoke-VigilHttpSend -Timeout $secs -Method 'POST' -Url $url -CaFile '' -Metadata $plain -Headers $headers -Body $body
        $headers = $null
        if (-not $r.Ok) {
            switch ($r.Fail) {
                'timeout' { & $failed 'timeout' "no answer from $hostPart within ${secs}s" }
                'resolve' { & $failed 'unreachable' "cannot resolve $hostPart" }
                'connect' { & $failed 'unreachable' "cannot connect to $hostPart" }
                'untrusted' { & $failed 'unreachable' "the certificate of $hostPart is not trusted" }
                default { & $failed 'unreachable' "the request to $hostPart failed" }
            }
            return 0
        }
        $code = $r.Status
        if ($code -lt 200 -or $code -gt 299) {
            if ($code -eq 401 -or $code -eq 403) { & $failed 'auth' "permission denied (HTTP $code)" }
            elseif ($code -eq 408 -or $code -eq 429 -or ($code -ge 500 -and $code -le 599)) { & $failed 'unreachable' "HTTP $code from $hostPart" }
            elseif ($code -ge 400 -and $code -le 499) { & $failed 'rejected' "HTTP $code from $hostPart" }
            else { & $failed 'invalid_response' "HTTP $code from $hostPart" }
            return 0
        }
        # An empty answer or a JSON object; anything else is a failure,
        # never a success (13.4.5).
        $reply = $r.Body -replace '[ \t\r\n]', ''
        if ($reply -and -not ($reply.StartsWith('{') -and $reply.EndsWith('}'))) {
            & $failed 'invalid_response' "an answer from $hostPart that is not OTLP"
            return 0
        }
        $rejected = 0
        if ($r.Body -cmatch '"rejectedLogRecords"\s*:\s*"?([0-9]+)') {
            $rejected = if ($Matches[1].Length -gt 9) { $Count } else { [int]$Matches[1] }
        }
        if ($rejected -gt $Count) { $rejected = $Count }
        if ($rejected -gt 0) { & $failed 'rejected' "$hostPart rejected $rejected of $Count records" }
        return $Count - $rejected
    }

    # Forwards what is new in one log file. Returns $false to end the run.
    $forward = {
        param([string]$File, [long]$Size)
        $path = Join-Path $Ctx.Logs $File.Replace('/', '\')
        $ck = & $ckPath $File
        $c = & $ckRead $ck
        $offset = $c.Offset
        if ($c.State -ceq 'bad') { & $gap 'checkpoint_reset' 0 $File }
        elseif ($c.State -ceq 'ok') {
            # Nothing changed: the file need not even be opened.
            if ($Size -eq $c.Size -and $offset -ge $Size) { return $true }
            $fp = Get-VigilLogFingerprint $path $c.N
            if ($offset -gt $Size -or $fp.Crc -cne $c.Crc) {
                & $gap 'replaced' $offset $File
                $offset = 0
            }
        }
        $output = $true
        if ($File.StartsWith('jobs/', [System.StringComparison]::Ordinal)) { $output = Test-VigilLogsOutput -Parsed $parsed -Job $File.Split('/')[1] }
        while ($offset -lt $Size) {
            if ($g.Read -ge $maxBytes) { return $false }
            if ([DateTimeOffset]::Now.ToUnixTimeSeconds() - $g.Now -ge $Script:VigilLogsRunSecs) { return $false }
            $reader = New-VigilLogReader -Path $path -Offset $offset
            $pos = $offset
            $batch = New-Object System.Text.StringBuilder
            $n = 0
            $bytes = [long]0
            $ends = New-Object 'System.Collections.Generic.List[long]'
            try {
                while ($null -ne ($line = Read-VigilLogLine $reader)) {
                    $rec = ConvertTo-VigilLogRecord -File $File -Line $line -Include $include -Output $output
                    if ($rec) {
                        if ($n -gt 0 -and ($n -ge $batchLines -or $bytes + $rec.Length -gt $batchBytes)) { break }
                        if ($n -gt 0) { [void]$batch.Append(',') }
                        [void]$batch.Append($rec)
                        $n++
                        $bytes += $rec.Length
                        $ends.Add($reader.At)
                    }
                    $pos = $reader.At
                }
            }
            finally { $reader.Stream.Dispose() }
            # Only an incomplete last line left: it waits for the next run.
            if ($pos -le $offset) { break }
            if ($n -gt 0) {
                $accepted = & $send $batch.ToString() $n
                if ($accepted -lt $n) {
                    if ($accepted -gt 0) {
                        $g.Sent += $accepted
                        & $ckWrite $ck $File $ends[$accepted - 1] $Size
                    }
                    return $false
                }
                $g.Sent += $n
                $g.SentBytes += $bytes
            }
            $g.Read += $pos - $offset
            $offset = $pos
            if ($Size -lt $offset) { $Size = $offset }
            & $ckWrite $ck $File $offset $Size
        }
        return $true
    }

    $files = Get-VigilLogFiles -LogDir $Ctx.Logs

    # Files retention deleted: what was not delivered is gone (13.4.4).
    foreach ($p in [System.IO.Directory]::GetFiles($dir, '*.checkpoint')) {
        $c = & $ckRead $p
        if (-not $c.File) { continue }
        $rel = $c.File.Substring(5)
        if (-not [System.IO.File]::Exists((Join-Path $Ctx.Logs $rel.Replace('/', '\')))) {
            if ($c.State -ceq 'ok' -and $c.Size -gt $c.Offset) { & $gap 'deleted' ($c.Size - $c.Offset) $rel }
            [System.IO.File]::Delete($p)
        }
    }

    # A new destination starts from the end of every file (13.4.4).
    if ($prev -and $prev -cne $dest) {
        $lost = [long]0
        foreach ($x in $files) {
            $ck = & $ckPath $x.File
            $c = & $ckRead $ck
            $lost += $x.Size - $c.Offset
            & $ckWrite $ck $x.File $x.Size $x.Size
        }
        if ($lost -lt 0) { $lost = 0 }
        & $gap 'destination_changed' $lost ''
        $failures = 0
        $nextTry = 0
    }

    if ($g.Now -ge $nextTry) {
        $ok = $true
        if ($hname) {
            $r = Resolve-VigilSecret -Root $Root -Parsed $parsed -Reference $hvalue
            if (-not $r.Ok) { & $failed 'auth' "header_value $hvalue unavailable: $($r.Why)"; $ok = $false }
            elseif ($r.Value -cmatch '[\x00-\x1f\x7f]') { & $failed 'auth' "header_value $hvalue holds a control character"; $ok = $false }
            else { $g.Header = "${hname}: $($r.Value)" }
            $r = $null
        }
        if ($ok) {
            foreach ($x in $files) { if (-not (& $forward $x.File $x.Size)) { break } }
        }
        $g.Header = ''
        if ($g.Failed) {
            $failures++
            # Exponential backoff, capped at 15 minutes (13.4.5).
            $wait = [Math]::Min(900, 5 * [Math]::Pow(2, [Math]::Min($failures - 1, 10)))
            $nextTry = $g.Now + [long]$wait
        }
        else { $failures = 0; $nextTry = 0 }
    }

    # What is left, for the health metrics (13.4.6) and the supervisor.
    $pending = [long]0
    $total = [long]0
    $files = Get-VigilLogFiles -LogDir $Ctx.Logs
    foreach ($x in $files) {
        $total += $x.Size
        $c = & $ckRead (& $ckPath $x.File)
        if ($x.Size -gt $c.Offset) { $pending += $x.Size - $c.Offset }
    }
    if ($g.Sent -gt 0) {
        $g.Events.Add("$($g.Now) vigil.logs.records_sent $($g.Sent) count $tags")
        $g.Events.Add("$($g.Now) vigil.logs.bytes_sent $($g.SentBytes) count $tags")
    }
    $g.Events.Add("$($g.Now) vigil.logs.pending_bytes $pending gauge $tags")
    $in = Join-Path $Ctx.Spool 'incoming'
    [void](New-Item -ItemType Directory -Force -Path $in)
    Write-VigilFileAtomic -Path (Join-Path $in "$($g.Now)-vigil_logs.events") -Text (($g.Events | ForEach-Object { "$_`n" }) -join '')
    Write-VigilFileAtomic -Path $statePath -Text "[forwarder]`ndestination = $dest`nfailures = $failures`nnext_try = $nextTry`nchecked_epoch = $($g.Now)`ntotal = $total`n"
    if ($g.Failed) { return @{ Ok = $false; Reason = "delivery to $dest failed: $($g.Failed)" } }
    return @{ Ok = $true; Reason = '' }
}
