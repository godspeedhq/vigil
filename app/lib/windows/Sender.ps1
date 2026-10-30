#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil sender - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    The body of the vigil_sender worker (SPECIFICATION.md 4.5): fans spool
    files out to one queue per backend with the write-ahead protocol, keeps
    the spool within max_mb, and delivers each backend's queue in batches,
    backing off a failing backend without delaying the others. The twin of
    sender.sh, which documents the rules.

    Invoke-VigilSend -Ctx <worker context> -HostName <host>
    returns @{ Ok; Reason }.

    Requires Config.ps1, Effective.ps1, Worker.ps1 and Prom.ps1.
#>

$Script:VigilSendBatch = 500
$Script:VigilSendTypes = @('file')

function Invoke-VigilSend {
    param($Ctx, [string]$HostName, [string]$Root)

    $parsed = $Ctx.Parsed
    $index = New-VigilConfigIndex -Parsed $parsed
    $in = Join-Path $Ctx.Spool 'incoming'
    $fan = Join-Path $Ctx.Spool 'fanout'
    $be = Join-Path $Ctx.Spool 'backends'
    foreach ($d in @($in, $fan, $be)) { [void](New-Item -ItemType Directory -Force -Path $d) }
    $epoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $events = New-Object 'System.Collections.Generic.List[string]'
    $drops = New-Object 'System.Collections.Specialized.OrderedDictionary'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $tags = "host=$HostName os=windows instance=$(Get-VigilConfigValue $parsed 'vigil' 'instance' 'vigil')"
    foreach ($e in $parsed.Entries) { if ($e.Section -ceq 'tags') { $tags += " $($e.Key)=$($e.Value)" } }

    # Enabled backends: implemented, and not yet.
    $ok = New-Object 'System.Collections.Generic.List[string]'
    $todo = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sec in $parsed.Sections) {
        if (-not $sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal)) { continue }
        $name = $sec.Name.Substring(8)
        if ((Get-VigilConfigValue $parsed $sec.Name 'enabled' 'true') -ceq 'false') { continue }
        if ($Script:VigilSendTypes -ccontains (Get-VigilConfigValue $parsed $sec.Name 'type' $name)) { $ok.Add($name) } else { $todo.Add($name) }
    }

    $drop = {
        param([string]$Backend, [string]$Reason, [string[]]$Files)
        $n = 0
        foreach ($f in $Files) { if ([System.IO.File]::Exists($f)) { $n += @([System.IO.File]::ReadAllLines($f)).Count } }
        if ($n -eq 0) { return }
        $key = "backend=$Backend reason=$Reason"
        if ($drops.Contains($key)) { $drops[$key] += $n } else { $drops[$key] = $n }
    }

    $targets = {
        param([string]$Path)
        $file = [System.IO.Path]::GetFileName($Path)
        $job = $file.Substring($file.IndexOf('-') + 1)
        $dash = $job.IndexOf('-')
        if ($dash -ge 0) { $job = $job.Substring(0, $dash) } else { $job = $job -replace '\.events$', '' }
        $list = @()
        if ($parsed.Sections | Where-Object { $_.Name -ceq "job.$job" }) {
            foreach ($row in (Get-VigilEffectiveJob -Index $index -Id $job)) {
                if ($row.Key -ceq 'backends') { $list = @($row.Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            }
        }
        else { $list = @($ok) + @($todo) }
        $out = @()
        foreach ($b in $list) {
            if ($ok.Contains($b)) { $out += $b }
            elseif ($todo.Contains($b)) { & $drop $b 'not_implemented' @($Path) }
        }
        return , $out
    }

    $place = {
        param([string]$F)
        $base = [System.IO.Path]::GetFileName($F)
        foreach ($b in [System.IO.File]::ReadAllLines("$F.targets")) {
            if (-not $b) { continue }
            if ([System.IO.File]::Exists("$F.$b.done")) { continue }
            if (-not $ok.Contains($b)) {
                # The backend was removed or disabled since the targets were fixed.
                & $drop $b 'backend_removed' @($F)
                [System.IO.File]::WriteAllText("$F.$b.done", '')
                continue
            }
            $q = Join-Path $be $b
            [void](New-Item -ItemType Directory -Force -Path $q)
            $tmp = Join-Path $q ".$base.tmp.$PID"
            [System.IO.File]::Copy($F, $tmp, $true)
            if ([System.IO.File]::Exists((Join-Path $q $base))) { [System.IO.File]::Delete((Join-Path $q $base)) }
            [System.IO.File]::Move($tmp, (Join-Path $q $base))
            [System.IO.File]::WriteAllText("$F.$b.done", '')
        }
        [System.IO.File]::Delete($F)
        [System.IO.File]::Delete("$F.targets")
        foreach ($d in [System.IO.Directory]::GetFiles($fan, "$base.*.done")) { [System.IO.File]::Delete($d) }
    }

    $sorted = {
        param([string]$Dir, [string]$Pattern)
        if (-not [System.IO.Directory]::Exists($Dir)) { return , @() }
        $f = [System.IO.Directory]::GetFiles($Dir, $Pattern)
        [Array]::Sort($f, [System.StringComparer]::Ordinal)
        return , $f
    }

    # Unfinished fan-outs first, then new files (4.5).
    foreach ($f in (& $sorted $fan '*.events')) {
        if (-not [System.IO.File]::Exists("$f.targets")) {
            Write-VigilFileAtomic -Path "$f.targets" -Text ((& $targets $f | ForEach-Object { "$_`n" }) -join '')
        }
        & $place $f
    }
    foreach ($f in (& $sorted $in '*.events')) {
        $dest = Join-Path $fan ([System.IO.Path]::GetFileName($f))
        try { [System.IO.File]::Move($f, $dest) } catch { continue }
        Write-VigilFileAtomic -Path "$dest.targets" -Text ((& $targets $dest | ForEach-Object { "$_`n" }) -join '')
        & $place $dest
    }

    # Queues of removed or disabled backends are discarded.
    foreach ($d in [System.IO.Directory]::GetDirectories($be)) {
        $b = [System.IO.Path]::GetFileName($d)
        if ($ok.Contains($b)) { continue }
        & $drop $b 'backend_removed' ([System.IO.Directory]::GetFiles($d, '*.events'))
        [System.IO.Directory]::Delete($d, $true)
    }

    # The spool size cap: drop the oldest (or newest) queued files until the
    # queues fit in max_mb (4.5).
    $max = [long](Get-VigilConfigValue $parsed 'spool' 'max_mb' '100') * 1048576
    $when = Get-VigilConfigValue $parsed 'spool' 'when_full' 'drop_oldest'
    $queued = @(foreach ($d in [System.IO.Directory]::GetDirectories($be)) {
            foreach ($f in [System.IO.Directory]::GetFiles($d, '*.events')) {
                [pscustomobject]@{ Name = [System.IO.Path]::GetFileName($f); Path = $f; Size = (New-Object System.IO.FileInfo $f).Length
                    Backend = [System.IO.Path]::GetFileName($d) }
            }
        })
    $total = [long]0
    foreach ($q in $queued) { $total += $q.Size }
    if ($total -gt $max) {
        # Queue file names start with their epoch, so a name sort is oldest first.
        [string[]]$names = @($queued | ForEach-Object { "$($_.Name)`t$($_.Backend)" })
        $objs = [object[]]$queued
        [Array]::Sort($names, $objs, [System.StringComparer]::Ordinal)
        if ($when -ceq 'drop_newest') { [Array]::Reverse($objs) }
        foreach ($q in $objs) {
            if ($total -le $max) { break }
            & $drop $q.Backend 'spool_full' @($q.Path)
            [System.IO.File]::Delete($q.Path)
            $total -= $q.Size
        }
    }

    foreach ($b in $ok) {
        $q = Join-Path $be $b
        if (-not [System.IO.Directory]::Exists($q)) { continue }
        $sfile = Join-Path $Ctx.State "backends\$b.state"
        $next = [long]0; $failures = 0
        if ([System.IO.File]::Exists($sfile)) {
            foreach ($l in [System.IO.File]::ReadAllLines($sfile)) {
                if ($l -cmatch '^next_try = (\d+)') { $next = [long]$Matches[1] }
                elseif ($l -cmatch '^failures = (\d+)') { $failures = [int]$Matches[1] }
            }
        }
        if ($epoch -lt $next) { continue }
        # Assigned first: piping the call would pass its array as one item.
        $all = & $sorted $q '*.events'
        $batch = @($all | Select-Object -First $Script:VigilSendBatch)
        if ($batch.Count -eq 0) { continue }

        # file: merge the batch into the Prometheus text file, atomically.
        $path = Get-VigilConfigValue $parsed "backend.$b" 'path' 'metrics\vigil.prom'
        if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Root $path }
        try {
            [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path))
            Write-VigilFileAtomic -Path $path -Text (Merge-VigilProm -Old $path -Events $batch)
            foreach ($f in $batch) { [System.IO.File]::Delete($f) }
            if ([System.IO.File]::Exists($sfile)) { [System.IO.File]::Delete($sfile) }
        }
        catch {
            $failures++
            # Exponential backoff, capped at 5 minutes (4.5).
            $wait = [Math]::Min(300, 5 * [Math]::Pow(2, $failures - 1))
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $Ctx.State 'backends'))
            Write-VigilFileAtomic -Path $sfile -Text "[backend]`nfailures = $failures`nnext_try = $($epoch + [long]$wait)`n"
            $events.Add("$epoch vigil.backend.failures 1 count $tags backend=$b")
            $failed.Add($b)
        }
    }

    # The spool's own size, after delivery, and the sender's events: they are
    # delivered by the next run.
    $size = [long]0
    foreach ($d in @(@($in) + [System.IO.Directory]::GetDirectories($be))) {
        foreach ($f in [System.IO.Directory]::GetFiles($d, '*.events')) { $size += (New-Object System.IO.FileInfo $f).Length }
    }
    $events.Add("$epoch vigil.spool.bytes $size gauge $tags")
    foreach ($k in $drops.Keys) { $events.Add("$epoch vigil.spool.dropped $($drops[$k]) count $tags $k") }
    Write-VigilFileAtomic -Path (Join-Path $in "$epoch-vigil_sender.events") -Text (($events | ForEach-Object { "$_`n" }) -join '')

    if ($failed.Count -gt 0) { return @{ Ok = $false; Reason = "delivery failed: $($failed -join ' ')" } }
    return @{ Ok = $true; Reason = '' }
}
