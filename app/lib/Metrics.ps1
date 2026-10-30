#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil job output parsing - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Reads a finished run's captured stdout and extracts its metrics: "metric"
    lines (SPECIFICATION.md 14.3) and, for Nagios jobs, performance data
    (14.4). A pure function of the file and its arguments. Must produce
    exactly the same result as metrics.sh - tests/conformance/metrics holds
    the shared cases.

    ConvertFrom-VigilJobOutput -Mode <standard|nagios> -Cap <n> -Path <file>
    returns @{ Records; Lines; Invalid; Dropped }. Records are, in output
    order, "METRIC <name> <value> <gauge|count>[ <key=value>...]" or
    "INVALID <line>"; <name> is relative to the job's metric_name.
    Format-VigilMetricsDump prints them, then the summary line.

    Numbers are handled as decimal strings and BigInteger, never as floating
    point, so unit conversion is exact and identical on both
    implementations.
#>

$Script:VigilMetricLinesMax = 1000
$Script:VigilMetricReservedTags = @('host', 'os', 'instance', 'job', 'label', 'uom', 'exit_code')

$Script:VigilMetRe = @{
    Name    = '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$'
    Num     = '^-?[0-9]+(\.[0-9]+)?$'
    Tag     = '^([A-Za-z0-9_]+)=(.+)$'
    PerfVal = '^(-?[0-9]+(\.[0-9]+)?)([A-Za-z%]*)$'
}

# Canonical form of a number: no leading zeros, no trailing fractional
# zeros, no "-0".
function ConvertTo-VigilCanonicalNumber {
    param([string]$Value)
    $sign = ''
    if ($Value.StartsWith('-')) { $sign = '-'; $Value = $Value.Substring(1) }
    $dot = $Value.IndexOf('.')
    if ($dot -ge 0) { $int = $Value.Substring(0, $dot); $frac = $Value.Substring($dot + 1) }
    else { $int = $Value; $frac = '' }
    $int = $int.TrimStart('0')
    if ($int.Length -eq 0) { $int = '0' }
    $frac = $frac.TrimEnd('0')
    $n = $int
    if ($frac.Length -gt 0) { $n = "$int.$frac" }
    if ($n -cne '0') { $n = $sign + $n }
    return $n
}

# Scales a number by 1024^Kilo and then by 10^-Shift, exactly.
function Get-VigilScaledNumber {
    param([string]$Value, [int]$Kilo, [int]$Shift)
    $sign = ''
    if ($Value.StartsWith('-')) { $sign = '-'; $Value = $Value.Substring(1) }
    $dot = $Value.IndexOf('.')
    if ($dot -ge 0) { $int = $Value.Substring(0, $dot); $frac = $Value.Substring($dot + 1) }
    else { $int = $Value; $frac = '' }
    $big = [System.Numerics.BigInteger]::Parse($int + $frac, [System.Globalization.CultureInfo]::InvariantCulture)
    $big = $big * [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]1024, $Kilo)
    $digits = $big.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $flen = $frac.Length + $Shift
    if ($digits.Length -le $flen) { $digits = $digits.PadLeft($flen + 1, '0') }
    $n = $digits.Length - $flen
    if ($flen -gt 0) { return ConvertTo-VigilCanonicalNumber "$sign$($digits.Substring(0, $n)).$($digits.Substring($n))" }
    return ConvertTo-VigilCanonicalNumber "$sign$digits"
}

function ConvertFrom-VigilJobOutput {
    param([string]$Mode, [int]$Cap, [string]$Path)

    $re = $Script:VigilMetRe
    $st = @{ Seen = 0; Lines = 0; Invalid = 0; Dropped = 0 }
    $records = New-Object 'System.Collections.Generic.List[string]'

    # Counts one candidate (a metric line or a perfdata item) against the
    # cap; false, counting it as dropped, when the cap is reached.
    $take = {
        if ($st.Seen -ge $Cap) { $st.Dropped++; return $false }
        $st.Seen++
        return $true
    }
    $invalid = {
        param($Line)
        $st.Invalid++
        $records.Add("INVALID $Line")
    }

    # One "metric <name> <value> [key=value ...]" line.
    $metricLine = {
        param([string]$Text, [int]$Line)
        $tok = @($Text.Split([char[]]@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries))
        if (-not (& $take)) { return }
        if ($tok.Count -lt 3 -or $tok[1] -cnotmatch $re.Name -or $tok[2] -cnotmatch $re.Num) {
            & $invalid $Line
            return
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $tags = ''
        for ($i = 3; $i -lt $tok.Count; $i++) {
            if ($tok[$i] -cnotmatch $re.Tag) { & $invalid $Line; return }
            $key = $Matches[1]
            if ($Script:VigilMetricReservedTags -ccontains $key -or -not $seen.Add($key)) { & $invalid $Line; return }
            $tags += " $($tok[$i])"
        }
        $st.Lines++
        $records.Add("METRIC $($tok[1]) $(ConvertTo-VigilCanonicalNumber $tok[2]) gauge$tags")
    }

    # One perfdata item: label and "value[UOM];warn;crit;min;max".
    $perfItem = {
        param([string]$Label, [string]$Spec, [int]$Line)
        # A value of U (undetermined) is not a measurement.
        if ($Spec -ceq 'U' -or $Spec.StartsWith('U;', [System.StringComparison]::Ordinal)) { return }
        if (-not (& $take)) { return }
        $fields = $Spec.Split(';')
        if ($Label.Length -eq 0 -or $fields.Count -gt 5 -or $fields[0] -cnotmatch $re.PerfVal) {
            & $invalid $Line
            return
        }
        $value = $Matches[1]
        $unit = $Matches[3]
        $k = 0; $d = 0; $uom = ''; $type = 'gauge'
        switch -CaseSensitive ($unit) {
            '' { } 's' { } 'B' { } '%' { }
            'ms' { $d = 3 }
            'us' { $d = 6 }
            'KB' { $k = 1 }
            'MB' { $k = 2 }
            'GB' { $k = 3 }
            'TB' { $k = 4 }
            'c' { $type = 'count' }
            default { $uom = " uom=$unit" }
        }
        # Tag values cannot contain spaces.
        $Label = $Label.Replace(' ', '_')
        $st.Lines++
        $records.Add("METRIC perf $(Get-VigilScaledNumber $value $k $d) $type label=$Label$uom")
        $names = @('warn', 'crit', 'min', 'max')
        for ($i = 1; $i -lt $fields.Count; $i++) {
            if ($fields[$i] -cmatch $re.Num) {
                $records.Add("METRIC perf.$($names[$i - 1]) $(Get-VigilScaledNumber $fields[$i] $k $d) gauge label=$Label$uom")
            }
        }
    }

    # The perfdata of one line (the text after its first "|"). Items are
    # separated by spaces; a label may be quoted to hold spaces or "=", with
    # '' for a literal quote.
    $perf = {
        param([string]$S, [int]$Line)
        $i = 0
        $len = $S.Length
        while ($true) {
            while ($i -lt $len -and ($S[$i] -eq ' ' -or $S[$i] -eq "`t")) { $i++ }
            if ($i -ge $len) { return }
            $label = New-Object System.Text.StringBuilder
            $ok = $true
            if ($S[$i] -eq "'") {
                $i++
                $ok = $false
                while ($i -lt $len) {
                    if ($S[$i] -eq "'") {
                        if ($i + 1 -lt $len -and $S[$i + 1] -eq "'") {
                            [void]$label.Append("'")
                            $i += 2
                            continue
                        }
                        $i++
                        $ok = $true
                        break
                    }
                    [void]$label.Append($S[$i])
                    $i++
                }
                if (-not $ok) {
                    # An unterminated quote takes the rest of the line with it.
                    if (& $take) { & $invalid $Line }
                    return
                }
                if ($i -ge $len -or $S[$i] -ne '=') { $ok = $false }
            }
            else {
                while ($i -lt $len -and $S[$i] -ne '=' -and $S[$i] -ne ' ' -and $S[$i] -ne "`t") {
                    [void]$label.Append($S[$i])
                    $i++
                }
                if ($i -ge $len -or $S[$i] -ne '=') { $ok = $false }
            }
            # The value part runs to the next space; a malformed item ends there too.
            if ($ok) { $i++ }
            $spec = New-Object System.Text.StringBuilder
            while ($i -lt $len -and $S[$i] -ne ' ' -and $S[$i] -ne "`t") {
                [void]$spec.Append($S[$i])
                $i++
            }
            if ($ok) { & $perfItem $label.ToString() $spec.ToString() $Line }
            elseif (& $take) { & $invalid $Line }
        }
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # Lines split on LF only, with a trailing CR removed, as bash's read.
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::GetEncoding(28591))
        $lines = $text.Split("`n")
        $count = $lines.Count
        if ($text.EndsWith("`n")) { $count-- }
        for ($n = 1; $n -le $count; $n++) {
            $line = $lines[$n - 1]
            if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
            if ($line -ceq 'metric' -or $line.StartsWith('metric ', [System.StringComparison]::Ordinal) -or
                $line.StartsWith("metric`t", [System.StringComparison]::Ordinal)) {
                & $metricLine $line $n
                continue
            }
            if ($Mode -ceq 'nagios') {
                $bar = $line.IndexOf('|')
                if ($bar -ge 0) { & $perf $line.Substring($bar + 1) $n }
            }
        }
    }

    return @{ Records = $records; Lines = $st.Lines; Invalid = $st.Invalid; Dropped = $st.Dropped }
}

function Format-VigilMetricsDump {
    param([Parameter(Mandatory = $true)]$Result)
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $Result.Records) { [void]$sb.Append("$r`n") }
    [void]$sb.Append("SUMMARY metric_lines=$($Result.Lines) invalid_lines=$($Result.Invalid) dropped_lines=$($Result.Dropped)`n")
    return $sb.ToString()
}
