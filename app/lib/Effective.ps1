#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil effective job settings - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Resolves a job's settings from the job, [defaults], the global sections
    and built-in defaults, following SPECIFICATION.md 6.6. Assumes the config
    passed validation. Must produce exactly the same result as effective.sh -
    tests/conformance/effective holds the shared cases.

    Returns rows { Key; Value; Source } in a fixed key order. Source is one
    of: job, defaults, scheduler, log, tags, runners, runner, source,
    built-in. List keys (arg, tag, env, require_env) produce one row per
    item. List values (run_at, run_on_days, backends) are normalised to
    "a, b".

    Requires Config.ps1.
#>

# Builds the lookup used by Get-VigilEffectiveJob: section name -> entries.
function New-VigilConfigIndex {
    param([Parameter(Mandatory = $true)]$Parsed)

    $sections = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    foreach ($sec in $Parsed.Sections) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        for ($i = $sec.First; $i -lt $sec.First + $sec.Count; $i++) {
            $list.Add($Parsed.Entries[$i])
        }
        $sections[$sec.Name] = $list
    }

    # The default backend list: every backend not disabled, in file order.
    $all = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sec in $Parsed.Sections) {
        if (-not $sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal)) { continue }
        $enabled = Get-VigilIndexValue -Index @{ Sections = $sections } -Section $sec.Name -Key 'enabled'
        if ($enabled.Found -and $enabled.Value -ceq 'false') { continue }
        $all.Add($sec.Name.Substring(8))
    }

    return @{ Sections = $sections; AllBackends = ($all -join ', ') }
}

function Get-VigilIndexValue {
    param($Index, [string]$Section, [string]$Key)
    $entries = $null
    if ($Index.Sections.TryGetValue($Section, [ref]$entries)) {
        foreach ($e in $entries) {
            if ($e.Key -ceq $Key) { return @{ Found = $true; Value = $e.Value } }
        }
    }
    return @{ Found = $false; Value = '' }
}

function Get-VigilIndexValues {
    param($Index, [string]$Section, [string]$Key)
    $values = New-Object 'System.Collections.Generic.List[string]'
    $entries = $null
    if ($Index.Sections.TryGetValue($Section, [ref]$entries)) {
        foreach ($e in $entries) {
            if ($e.Key -ceq $Key) { $values.Add($e.Value) }
        }
    }
    return ,$values
}

function ConvertTo-VigilListText {
    param([string]$Value)
    $trim = [char[]]@(' ', "`t")
    return (($Value.Split(',') | ForEach-Object { $_.Trim($trim) }) -join ', ')
}

function Get-VigilEffectiveJob {
    param([Parameter(Mandatory = $true)]$Index, [Parameter(Mandatory = $true)][string]$Id)

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $job = "job.$Id"
    $add = { param($k, $v, $s) $rows.Add([pscustomobject]@{ Key = $k; Value = $v; Source = $s }) }

    # The job, then each "section:key" layer, then the built-in value.
    $single = {
        param([string]$Key, [string]$Builtin, [string[]]$Layers)
        $r = Get-VigilIndexValue -Index $Index -Section $job -Key $Key
        if ($r.Found) { & $add $Key $r.Value 'job'; return }
        foreach ($layer in $Layers) {
            $parts = $layer.Split(':')
            $r = Get-VigilIndexValue -Index $Index -Section $parts[0] -Key $parts[1]
            if ($r.Found) { & $add $Key $r.Value $parts[0]; return }
        }
        & $add $Key $Builtin 'built-in'
    }

    # NAME=value pairs: global rows first (a job value with the same name
    # replaces it in place), then the job's other pairs.
    $pairs = {
        param([string]$Key, [string]$GlobalSource, $Global)
        $jobPairs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($v in (Get-VigilIndexValues -Index $Index -Section $job -Key $Key)) {
            $eq = $v.IndexOf('=')
            $jobPairs.Add(@{ Name = $v.Substring(0, $eq); Value = $v.Substring($eq + 1) })
        }
        $globalNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($g in $Global) {
            [void]$globalNames.Add($g.Name)
            $match = $null
            foreach ($jp in $jobPairs) { if ($jp.Name -ceq $g.Name) { $match = $jp; break } }
            if ($match) { & $add $Key "$($g.Name)=$($match.Value)" 'job' }
            else { & $add $Key "$($g.Name)=$($g.Value)" $GlobalSource }
        }
        foreach ($jp in $jobPairs) {
            if (-not $globalNames.Contains($jp.Name)) { & $add $Key "$($jp.Name)=$($jp.Value)" 'job' }
        }
    }

    $file = (Get-VigilIndexValue -Index $Index -Section $job -Key 'file').Value
    & $add 'file' $file 'job'

    # A fetched script: its source, the ref it is taken from (the job's, else
    # the source's) and its digest. Rows appear only when set.
    $src = Get-VigilIndexValue -Index $Index -Section $job -Key 'source'
    if ($src.Found) {
        & $add 'source' $src.Value 'job'
        $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'ref'
        if ($r.Found) { & $add 'ref' $r.Value 'job' }
        else {
            $r = Get-VigilIndexValue -Index $Index -Section "source.$($src.Value)" -Key 'ref'
            if ($r.Found) { & $add 'ref' $r.Value 'source' }
        }
        $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'sha256'
        if ($r.Found) { & $add 'sha256' $r.Value 'job' }
    }

    # Runner: the job's key, else the file extension in [runners], else none
    # (the file is executed directly).
    $runner = ''
    $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'runner'
    if ($r.Found) {
        $runner = $r.Value
        & $add 'runner' $runner 'job'
    }
    else {
        $name = $file.Substring($file.LastIndexOfAny([char[]]@('/', '\')) + 1)
        $dot = $name.LastIndexOf('.')
        $r = @{ Found = $false; Value = '' }
        if ($dot -ge 0) {
            $r = Get-VigilIndexValue -Index $Index -Section 'runners' -Key ('.' + $name.Substring($dot + 1).ToLowerInvariant())
        }
        if ($r.Found) {
            $runner = $r.Value
            & $add 'runner' $runner 'runners'
        }
        else {
            & $add 'runner' '' 'built-in'
        }
    }

    foreach ($v in (Get-VigilIndexValues -Index $Index -Section $job -Key 'arg')) { & $add 'arg' $v 'job' }

    & $single 'metric_name' $Id @()

    $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'run_every'
    if ($r.Found) { & $add 'run_every' $r.Value 'job' }
    $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'run_at'
    if ($r.Found) { & $add 'run_at' (ConvertTo-VigilListText $r.Value) 'job' }
    $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'run_on_days'
    if ($r.Found) { & $add 'run_on_days' (ConvertTo-VigilListText $r.Value.ToLowerInvariant()) 'job' }

    & $single 'max_runtime' '' @('defaults:max_runtime')
    & $single 'grace' '30s' @('defaults:grace')
    & $single 'overlap' 'skip' @('defaults:overlap')
    & $single 'exit_codes' 'standard' @('defaults:exit_codes')
    & $single 'enabled' 'true' @('defaults:enabled')
    & $single 'on_uncertain' 'wait' @('defaults:on_uncertain')

    # Backends: an explicit list replaces the default of every enabled backend.
    $r = Get-VigilIndexValue -Index $Index -Section $job -Key 'backends'
    if ($r.Found) { & $add 'backends' (ConvertTo-VigilListText $r.Value) 'job' }
    else {
        $r = Get-VigilIndexValue -Index $Index -Section 'defaults' -Key 'backends'
        if ($r.Found) { & $add 'backends' (ConvertTo-VigilListText $r.Value) 'defaults' }
        else { & $add 'backends' $Index.AllBackends 'built-in' }
    }

    & $single 'late_start_window' '15m' @('defaults:late_start_window', 'scheduler:late_start_window')
    & $single 'log_retain_days' '7' @('defaults:log_retain_days', 'log:retain_days')
    & $single 'working_dir' '.' @('defaults:working_dir')

    $globalTags = New-Object 'System.Collections.Generic.List[object]'
    $entries = $null
    if ($Index.Sections.TryGetValue('tags', [ref]$entries)) {
        foreach ($e in $entries) { $globalTags.Add(@{ Name = $e.Key; Value = $e.Value }) }
    }
    & $pairs 'tag' 'tags' $globalTags

    $runnerEnv = New-Object 'System.Collections.Generic.List[object]'
    if ($runner.Length -gt 0) {
        foreach ($v in (Get-VigilIndexValues -Index $Index -Section "runner.$runner" -Key 'env')) {
            $eq = $v.IndexOf('=')
            $runnerEnv.Add(@{ Name = $v.Substring(0, $eq); Value = $v.Substring($eq + 1) })
        }
    }
    & $pairs 'env' 'runner' $runnerEnv

    # require_env: the runner's names, then the job's, each name once.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $trim = [char[]]@(' ', "`t")
    $layers = @()
    if ($runner.Length -gt 0) { $layers += , @("runner.$runner", 'runner') }
    $layers += , @($job, 'job')
    foreach ($layer in $layers) {
        foreach ($v in (Get-VigilIndexValues -Index $Index -Section $layer[0] -Key 'require_env')) {
            foreach ($item in $v.Split(',')) {
                $item = $item.Trim($trim)
                if ($seen.Add($item)) { & $add 'require_env' $item $layer[1] }
            }
        }
    }

    return ,$rows
}

# Formats the effective settings of every job that is not INVALID, one row
# per line:  <job> TAB <key> TAB <value> TAB <source>
# A rejected configuration (any parser error or ERROR record) prints nothing.
function Format-VigilEffectiveDump {
    param([Parameter(Mandatory = $true)]$Parsed, [Parameter(Mandatory = $true)]$Records)

    if ($Parsed.Errors.Count -gt 0) { return '' }
    $invalid = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($r in $Records) {
        if ($r.Kind -ceq 'ERROR') { return '' }
        if ($r.Kind -ceq 'INVALID') { [void]$invalid.Add($r.Job) }
    }

    $index = New-VigilConfigIndex -Parsed $Parsed
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $Parsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        $id = $sec.Name.Substring(4)
        if ($invalid.Contains($id)) { continue }
        foreach ($row in (Get-VigilEffectiveJob -Index $index -Id $id)) {
            [void]$sb.Append("$id`t$($row.Key)`t$($row.Value)`t$($row.Source)`n")
        }
    }
    return $sb.ToString()
}
