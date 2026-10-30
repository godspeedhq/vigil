#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil file backend - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Merges spool events into a Prometheus text file, as node_exporter's
    textfile collector (or windows_exporter's) reads it (SPECIFICATION.md
    15.3). The file holds the current value of every series: a gauge's
    latest value, and a count's running total as a counter. A pure function
    of the old file and the events. Must produce exactly the same result as
    prom.sh - tests/conformance/prom holds the shared cases; prom.sh
    documents the naming rules.

    Merge-VigilProm -Old <.prom file or -> -Events <events file>...
    returns the new file's text.
#>

function ConvertTo-VigilPromName {
    param([string]$Name)
    $n = $Name.Replace('.', '_')
    if ($n -cmatch '^[0-9]') { $n = "_$n" }
    return $n
}

function Merge-VigilProm {
    param([string]$Old, [string[]]$Events)

    $order = New-Object 'System.Collections.Generic.List[string]'
    $types = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    $apply = {
        param([string]$Name, [string]$Labels, [string]$Type, [string]$Value, [bool]$Event)
        $key = "$Name`t$Labels"
        if (-not $types.ContainsKey($key)) { $order.Add($key); $types[$key] = $Type }
        if ($Type -ceq 'counter' -and $Event -and $values.ContainsKey($key)) {
            $values[$key] = ([decimal]::Parse($values[$key], [System.Globalization.CultureInfo]::InvariantCulture) +
                [decimal]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('0', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        else { $values[$key] = $Value }
    }

    # The old file's series first; an old total is the starting point.
    if ($Old -cne '-' -and [System.IO.File]::Exists($Old)) {
        $t = 'gauge'
        foreach ($line in [System.IO.File]::ReadAllLines($Old)) {
            if ($line.StartsWith('# TYPE ', [System.StringComparison]::Ordinal)) { $t = $line.Substring($line.LastIndexOf(' ') + 1); continue }
            if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
            $sp = $line.LastIndexOf(' ')
            $v = $line.Substring($sp + 1)
            $s = $line.Substring(0, $sp)
            $brace = $s.IndexOf('{')
            if ($brace -ge 0) { $n = $s.Substring(0, $brace); $l = $s.Substring($brace + 1).TrimEnd('}') }
            else { $n = $s; $l = '' }
            & $apply $n $l $t $v $false
        }
    }

    foreach ($f in $Events) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            $p = @($line.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries))
            if ($p.Count -lt 4) { continue }
            $name = ConvertTo-VigilPromName $p[1]
            $v = $p[2]
            $t = $p[3]
            if ($t -ceq 'count') {
                if ($v -cmatch '^-?[0-9]+$') {
                    $t = 'counter'
                    if (-not $name.EndsWith('_total')) { $name += '_total' }
                }
                else { $t = 'gauge' }
            }
            elseif ($t -cne 'gauge') { continue }
            # Labels sorted by key, as bytes.
            [string[]]$tags = @($p | Select-Object -Skip 4)
            [string[]]$tagKeys = @($tags | ForEach-Object { $_.Split('=')[0] })
            if ($tags.Count -gt 1) { [Array]::Sort($tagKeys, $tags, [System.StringComparer]::Ordinal) }
            $labels = foreach ($tag in $tags) {
                $eq = $tag.IndexOf('=')
                $k = $tag.Substring(0, $eq)
                if ($k -cmatch '^[0-9]') { $k = "_$k" }
                "$k=`"$($tag.Substring($eq + 1).Replace('\', '\\').Replace('"', '\"'))`""
            }
            & $apply $name (@($labels) -join ',') $t $v $true
        }
    }

    $keys = $order.ToArray()
    [Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $sb = New-Object System.Text.StringBuilder
    $last = $null
    foreach ($key in $keys) {
        $tab = $key.IndexOf("`t")
        $name = $key.Substring(0, $tab)
        $labels = $key.Substring($tab + 1)
        if ($name -cne $last) { [void]$sb.Append("# TYPE $name $($types[$key])`n"); $last = $name }
        if ($labels.Length -gt 0) { [void]$sb.Append("$name{$labels} $($values[$key])`n") }
        else { [void]$sb.Append("$name $($values[$key])`n") }
    }
    return $sb.ToString()
}
