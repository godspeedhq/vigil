#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil schedule decisions - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Decides, for one job at one tick, what the supervisor does about its
    schedule (SPECIFICATION.md 7.9). A pure function of its inputs: nothing
    is read from the clock or written to disk here. Must produce exactly the
    same result as schedule.sh - tests/conformance/schedule holds the shared
    table.

      Get-VigilScheduleDecision -Index <index> -Id <job> -Now <now> -Prev <prev>
                                -Cursor <cursor> -Active <active>
        Now     local time and UTC offset, 2026-10-29T14:00:00+0100
        Prev    the previous tick in the same form, or -
        Cursor  the last slot dealt with: 2026-10-29T13:55:00Z for run_every,
                2026-10-29T20:00:00 (local, no offset) for run_at, or -
        Active  - (none), running or queued
      Returns { Decision; Slot; Next }. Decision is disabled, new, wait,
      missed, run, queue, skip, or error for malformed input. Slot is the due
      slot or -, Next the next slot after now and the cursor or -.

    Times are handled as whole seconds with the same civil-date arithmetic as
    schedule.sh rather than [DateTime], so both accept and reject exactly the
    same input. run_every slots are UTC seconds since the epoch; run_at slots
    are local seconds (the local date and time counted as if it were UTC), so
    a time that occurs twice is one slot.

    Requires Config.ps1 and Effective.ps1.
#>

$Script:VigilScheduleTimePattern = '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{4})?$'

# Integer division of non-negative numbers, truncating as bash does.
function Get-VigilQuotient {
    param([long]$A, [long]$B)
    $r = [long]0
    return [Math]::DivRem($A, $B, [ref]$r)
}

# Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil,
# for years from 1970).
function Get-VigilCivilDays {
    param([long]$Y, [long]$M, [long]$D)
    if ($M -le 2) { $Y--; $mp = $M + 9 } else { $mp = $M - 3 }
    $era = Get-VigilQuotient $Y 400
    $yoe = $Y - $era * 400
    $doe = $yoe * 365 + (Get-VigilQuotient $yoe 4) - (Get-VigilQuotient $yoe 100) + (Get-VigilQuotient (153 * $mp + 2) 5) + $D - 1
    return $era * 146097 + $doe - 719468
}

# Formats seconds as 2026-10-29T20:00:00, with a Z suffix for UTC.
function Format-VigilSlot {
    param([long]$Seconds, [bool]$Utc)
    $z = (Get-VigilQuotient $Seconds 86400) + 719468
    $era = Get-VigilQuotient $z 146097
    $doe = $z - $era * 146097
    $yoe = Get-VigilQuotient ($doe - (Get-VigilQuotient $doe 1460) + (Get-VigilQuotient $doe 36524) - (Get-VigilQuotient $doe 146096)) 365
    $y = $yoe + $era * 400
    $doy = $doe - (365 * $yoe + (Get-VigilQuotient $yoe 4) - (Get-VigilQuotient $yoe 100))
    $mp = Get-VigilQuotient (5 * $doy + 2) 153
    $d = $doy - (Get-VigilQuotient (153 * $mp + 2) 5) + 1
    if ($mp -lt 10) { $m = $mp + 3 } else { $m = $mp - 9 }
    if ($m -le 2) { $y++ }
    $s = $Seconds % 86400
    $text = '{0:D4}-{1:D2}-{2:D2}T{3:D2}:{4:D2}:{5:D2}' -f $y, $m, $d,
        (Get-VigilQuotient $s 3600), (Get-VigilQuotient ($s % 3600) 60), ($s % 60)
    if ($Utc) { $text += 'Z' }
    return $text
}

# Parses a time into { Kind (offset, utc or local); Secs (UTC seconds for
# offset and utc, local seconds for local); Off (offset seconds) }, or $null.
function ConvertFrom-VigilScheduleTime {
    param([string]$Text)
    $m = [regex]::Match($Text, $Script:VigilScheduleTimePattern)
    if (-not $m.Success) { return $null }
    $g = $m.Groups
    $y = [long]$g[1].Value; $mo = [long]$g[2].Value; $d = [long]$g[3].Value
    $hh = [long]$g[4].Value; $mi = [long]$g[5].Value; $ss = [long]$g[6].Value
    if ($y -lt 1970 -or $mo -lt 1 -or $mo -gt 12 -or $d -lt 1 -or $d -gt 31 -or
        $hh -gt 23 -or $mi -gt 59 -or $ss -gt 59) {
        return $null
    }
    $secs = (Get-VigilCivilDays $y $mo $d) * 86400 + $hh * 3600 + $mi * 60 + $ss
    $zone = $g[7].Value
    if ($zone -ceq '') { return @{ Kind = 'local'; Secs = $secs; Off = [long]0 } }
    if ($zone -ceq 'Z') { return @{ Kind = 'utc'; Secs = $secs; Off = [long]0 } }
    $off = [long]$zone.Substring(1, 2) * 3600 + [long]$zone.Substring(3, 2) * 60
    if ($zone[0] -ceq '-') { $off = -$off }
    return @{ Kind = 'offset'; Secs = $secs - $off; Off = $off }
}

# Seconds in a validated duration such as 30s, 5m, 2h or 7d.
function ConvertFrom-VigilDuration {
    param([string]$Text)
    $n = [long]$Text.Substring(0, $Text.Length - 1)
    switch -CaseSensitive ([string]$Text[$Text.Length - 1]) {
        's' { return $n }
        'm' { return $n * 60 }
        'h' { return $n * 3600 }
        'd' { return $n * 86400 }
    }
}

# A job's effective schedule settings, or $null when the job does not exist.
function Get-VigilScheduleJob {
    param([Parameter(Mandatory = $true)]$Index, [Parameter(Mandatory = $true)][string]$Id)

    if (-not $Index.Sections.ContainsKey("job.$Id")) { return $null }
    $job = @{
        Every   = [long]0
        Times   = New-Object 'System.Collections.Generic.List[long]'
        Mask    = '1111111'
        Window  = [long]0
        Overlap = 'skip'
        Enabled = 'true'
        Tick    = [long]60
    }
    $trim = [char[]]@(' ', "`t")
    foreach ($row in (Get-VigilEffectiveJob -Index $Index -Id $Id)) {
        switch -CaseSensitive ($row.Key) {
            'run_every' { $job.Every = ConvertFrom-VigilDuration $row.Value }
            'late_start_window' { $job.Window = ConvertFrom-VigilDuration $row.Value }
            'overlap' { $job.Overlap = $row.Value }
            'enabled' { $job.Enabled = $row.Value }
            'run_at' {
                foreach ($item in $row.Value.Split(',')) {
                    $t = $item.Trim($trim)
                    $job.Times.Add([long]$t.Substring(0, 2) * 3600 + [long]$t.Substring(3, 2) * 60)
                }
                $job.Times.Sort()
            }
            'run_on_days' {
                # A character per weekday, Sunday first.
                $mask = '0000000'.ToCharArray()
                foreach ($item in $row.Value.Split(',')) {
                    $k = @('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat').IndexOf($item.Trim($trim).ToLowerInvariant())
                    $mask[$k] = '1'
                }
                $job.Mask = -join $mask
            }
        }
    }
    $tick = Get-VigilIndexValue -Index $Index -Section 'scheduler' -Key 'tick'
    if ($tick.Found) { $job.Tick = ConvertFrom-VigilDuration $tick.Value }
    return $job
}

# Whether day number $Day (days since 1970-01-01, a Thursday) is allowed.
function Test-VigilScheduleDay {
    param($Job, [long]$Day)
    return $Job.Mask[[int](($Day + 4) % 7)] -ceq '1'
}

# The latest slot at or before $Now (schedule seconds), or -1. $Off is the UTC
# offset, used for the local day of run_every slots. Looks back eight days:
# every allowed weekday is within a week.
function Get-VigilLatestSlot {
    param($Job, [long]$Now, [long]$Off)
    $every = $Job.Every
    if ($every -gt 0) {
        $c = (Get-VigilQuotient $Now $every) * $every
        for ($k = 0; $k -lt 8; $k++) {
            $day = Get-VigilQuotient ($c + $Off) 86400
            if (Test-VigilScheduleDay $Job $day) { return $c }
            # The last slot before that local day began.
            $c = (Get-VigilQuotient ($day * 86400 - $Off - 1) $every) * $every
        }
    }
    else {
        $day = Get-VigilQuotient $Now 86400
        for ($k = 0; $k -lt 8; $k++) {
            if (Test-VigilScheduleDay $Job $day) {
                for ($i = $Job.Times.Count - 1; $i -ge 0; $i--) {
                    $c = $day * 86400 + $Job.Times[$i]
                    if ($c -le $Now) { return $c }
                }
            }
            $day--
        }
    }
    return [long]-1
}

# The first slot after $Now (schedule seconds), or -1.
function Get-VigilNextSlot {
    param($Job, [long]$Now, [long]$Off)
    $every = $Job.Every
    if ($every -gt 0) {
        $c = (Get-VigilQuotient $Now $every) * $every + $every
        for ($k = 0; $k -lt 8; $k++) {
            $day = Get-VigilQuotient ($c + $Off) 86400
            if (Test-VigilScheduleDay $Job $day) { return $c }
            # The first slot once the next local day begins.
            $c = (Get-VigilQuotient (($day + 1) * 86400 - $Off + $every - 1) $every) * $every
        }
    }
    else {
        $day = Get-VigilQuotient $Now 86400
        for ($k = 0; $k -lt 8; $k++) {
            if (Test-VigilScheduleDay $Job $day) {
                foreach ($t in $Job.Times) {
                    $c = $day * 86400 + $t
                    if ($c -gt $Now) { return $c }
                }
            }
            $day++
        }
    }
    return [long]-1
}

function Get-VigilScheduleDecision {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Now, [string]$Prev, [string]$Cursor, [string]$Active,
        $Job
    )

    $result = @{ Decision = 'error'; Slot = '-'; Next = '-'; Cursor = '-' }

    if ($null -eq $Job) { $Job = Get-VigilScheduleJob -Index $Index -Id $Id }
    if ($null -eq $Job) { return $result }
    $utc = $Job.Every -gt 0
    $kind = if ($utc) { 'utc' } else { 'local' }

    $t = ConvertFrom-VigilScheduleTime $Now
    if ($null -eq $t -or $t.Kind -cne 'offset') { return $result }
    $nowE = $t.Secs
    $nowOff = $t.Off
    $nowS = if ($utc) { $nowE } else { $nowE + $nowOff }

    $prevE = $null
    $prevS = $null
    if ($Prev -cne '-') {
        $t = ConvertFrom-VigilScheduleTime $Prev
        if ($null -eq $t -or $t.Kind -cne 'offset') { return $result }
        $prevE = $t.Secs
        $prevS = if ($utc) { $prevE } else { $prevE + $t.Off }
    }
    $cur = $null
    if ($Cursor -cne '-') {
        $t = ConvertFrom-VigilScheduleTime $Cursor
        if ($null -eq $t -or $t.Kind -cne $kind) { return $result }
        $cur = $t.Secs
    }
    if ($Active -cne '-' -and $Active -cne 'running' -and $Active -cne 'queued') { return $result }

    if ($Job.Enabled -ceq 'false') {
        $result.Decision = 'disabled'
        return $result
    }

    # The next slot that can run: after now and after the cursor, so a clock
    # set back does not report a slot that will be passed over.
    $from = if ($null -ne $cur -and $cur -gt $nowS) { $cur } else { $nowS }
    $next = Get-VigilNextSlot $Job $from $nowOff
    if ($next -ge 0) { $result.Next = Format-VigilSlot $next $utc }

    if ($null -eq $cur) {
        $result.Decision = 'new'
        $result.Cursor = Format-VigilSlot $nowS $utc
        return $result
    }

    $slot = Get-VigilLatestSlot $Job $nowS $nowOff
    if ($slot -lt 0 -or $slot -le $cur) {
        $result.Decision = 'wait'
        $result.Cursor = $Cursor
        return $result
    }
    $result.Slot = Format-VigilSlot $slot $utc
    # Every decision from here on moves the cursor to the slot.
    $result.Cursor = $result.Slot

    # Ticking normally and the slot came after the previous tick: this is the
    # first tick at or after it. Otherwise the late-start window applies.
    $onTime = $false
    if ($null -ne $prevE -and $nowE -ge $prevE -and ($nowE - $prevE) -le 2 * $Job.Tick -and $slot -gt $prevS) {
        $onTime = $true
    }
    else {
        $age = if ($utc) { $nowE - $slot } else { $nowS - $slot }
        if ($age -le $Job.Window) { $onTime = $true }
    }

    if (-not $onTime) { $result.Decision = 'missed' }
    elseif ($Active -ceq '-') { $result.Decision = 'run' }
    elseif ($Active -ceq 'running' -and $Job.Overlap -ceq 'queue_one') { $result.Decision = 'queue' }
    else { $result.Decision = 'skip' }
    return $result
}

# Splits a decisions-table line into its eight columns, as bash `read` does:
# blank lines and # comments give $null.
function Split-VigilScheduleRow {
    param([string]$Line)
    $fields = $Line.Trim(" `t`r".ToCharArray()) -split '[ \t]+'
    if ($fields[0] -ceq '' -or $fields[0].StartsWith('#')) { return $null }
    $cols = New-Object 'string[]' 8
    for ($i = 0; $i -lt 8; $i++) { $cols[$i] = if ($i -lt $fields.Count) { $fields[$i] } else { '' } }
    return ,$cols
}

# Reads a decisions table - one row per tick, whitespace-separated:
#   <job> <now> <prev> <cursor> <active> <decision> <slot> <next>
# blank lines and # comments ignored - and prints each row with the last
# three columns computed, single-space separated.
function Format-VigilScheduleTableDump {
    param([Parameter(Mandatory = $true)]$Parsed, [Parameter(Mandatory = $true)][string]$Path)

    $index = New-VigilConfigIndex -Parsed $Parsed
    $jobs = New-Object System.Collections.Hashtable  # case-sensitive, unlike @{}
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $c = Split-VigilScheduleRow $line
        if ($null -eq $c) { continue }
        if (-not $jobs.ContainsKey($c[0])) { $jobs[$c[0]] = Get-VigilScheduleJob -Index $index -Id $c[0] }
        $d = Get-VigilScheduleDecision -Index $index -Id $c[0] -Now $c[1] -Prev $c[2] -Cursor $c[3] -Active $c[4] -Job $jobs[$c[0]]
        [void]$sb.Append("$($c[0]) $($c[1]) $($c[2]) $($c[3]) $($c[4]) $($d.Decision) $($d.Slot) $($d.Next)`n")
    }
    return $sb.ToString()
}
