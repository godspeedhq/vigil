#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil run events - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Builds the spool events of one finished run (SPECIFICATION.md 4.5, 14):
    the per-job metrics of 14.2 and the metrics the job printed (14.3,
    14.4), each with its tags. A pure function of the configuration, the run
    and the parsed output. Must produce exactly the same result as
    events.sh - tests/conformance/events holds the shared cases.

    Get-VigilRunEvents -Parsed <config> -Id <job> -Epoch <ended> -Outcome
    <outcome> -ExitCode <code or -> -Duration <seconds> -HostName <host>
    -Os <os> -Output <ConvertFrom-VigilJobOutput result> returns the event
    lines, "<epoch> <name> <value> <gauge|count> <key=value>...".

    Tags, in order: host, os, instance, job, then the [tags] section and the
    job's tags (as merged in 6.6), then any added by the event itself. A
    line's own tag replaces one of the same key in place.

    Requires Config.ps1, Effective.ps1 and Metrics.ps1.
#>

# Tags with one key=value applied: replaced in place when the key is
# present, appended otherwise.
function Set-VigilEventTag {
    param([string]$Tags, [string]$Tag)
    $key = $Tag.Split('=')[0]
    $out = New-Object 'System.Collections.Generic.List[string]'
    $found = $false
    foreach ($t in $Tags.Split(' ')) {
        if ($t.Length -eq 0) { continue }
        if ($t.Split('=')[0] -ceq $key) { $out.Add($Tag); $found = $true }
        else { $out.Add($t) }
    }
    if (-not $found) { $out.Add($Tag) }
    return ($out -join ' ')
}

function Get-VigilRunEvents {
    param($Parsed, [string]$Id, [string]$Epoch, [string]$Outcome, [string]$ExitCode,
        [string]$Duration, [string]$HostName, [string]$Os, $Output)

    $instance = 'vigil'
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -ceq 'vigil' -and $e.Key -ceq 'instance') { $instance = $e.Value; break }
    }

    $index = New-VigilConfigIndex -Parsed $Parsed
    $base = "host=$HostName os=$Os instance=$instance job=$Id"
    $m = $Id
    foreach ($row in (Get-VigilEffectiveJob -Index $index -Id $Id)) {
        if ($row.Key -ceq 'metric_name') { $m = $row.Value }
        elseif ($row.Key -ceq 'tag') { $base = Set-VigilEventTag $base $row.Value }
    }

    $events = New-Object 'System.Collections.Generic.List[string]'
    $add = { param($Name, $Value, $Type, $Tags) $events.Add("$Epoch $m.$Name $Value $Type $Tags") }

    # The per-job metrics of the run (14.2).
    & $add 'duration_seconds' $Duration 'gauge' $base
    & $add 'runs' '1' 'count' $base
    if ($Outcome -ceq 'succeeded') { & $add 'succeeded' '1' 'count' $base }
    elseif ($Outcome -ceq 'warning') { & $add 'warnings' '1' 'count' $base }
    elseif ($ExitCode -ceq '-') { & $add 'failures' '1' 'count' $base }
    else { & $add 'failures' '1' 'count' "$base exit_code=$ExitCode" }

    # What the job printed: "METRIC <name> <value> <type> [tags]".
    foreach ($rec in $Output.Records) {
        if (-not $rec.StartsWith('METRIC ', [System.StringComparison]::Ordinal)) { continue }
        $f = $rec.Split(' ')
        $tags = $base
        for ($i = 4; $i -lt $f.Count; $i++) { $tags = Set-VigilEventTag $tags $f[$i] }
        & $add $f[1] $f[2] $f[3] $tags
    }

    if ($Output.Invalid -gt 0) { & $add 'invalid_metric_lines' "$($Output.Invalid)" 'count' $base }
    if ($Output.Dropped -gt 0) { & $add 'dropped_metric_lines' "$($Output.Dropped)" 'count' $base }
    return ,$events
}
