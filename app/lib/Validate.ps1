#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil configuration validation - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Checks the result of ConvertFrom-VigilConfig against SPECIFICATION.md 6
    and 16.3. It is a pure function of the parsed entries: it never touches
    the filesystem or the environment (pre-flight does that). It must produce
    exactly the same records as validate.sh - tests/conformance/validate
    holds the shared cases.

    Returns a list of records { Kind; Job; Line; Code; Message }:
      Kind  ERROR (whole config rejected), INVALID (only that job is
            skipped) or WARN
      Job   the job id for INVALID, otherwise empty
      Line  line number (a section header line for missing keys)
      Message never contains a credential value

    Order: sections in file order; within a section its entries in file
    order, then the section-level checks. At most one record per entry.

    PS 5.1 notes: all matching is case-sensitive (-cmatch, -ceq, ordinal
    sets) to agree with bash; requires Config.ps1.
#>

$Script:VigilBackendTypes = @(
    'file', 'datadog', 'otel', 'prometheus', 'victoriametrics', 'influxdb', 'splunk',
    'graphite', 'statsd', 'elasticsearch', 'opensearch', 'azuremonitor', 'cloudwatch',
    'gcp', 'newrelic', 'dynatrace', 'webhook')
$Script:VigilReservedTags = @('host', 'os', 'instance', 'job', 'label', 'uom', 'exit_code')

$Script:VigilValRe = @{
    Dur      = '^[0-9]{1,6}[smhd]$'
    ZeroDur  = '^0+[smhd]$'
    Int      = '^[0-9]{1,6}$'
    Zero     = '^0+$'
    Name     = '^[A-Za-z0-9_.-]+$'
    Metric   = '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$'
    Time     = '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    Code     = '^([0-9]{1,3})(-([0-9]{1,3}))?$'
    EnvName  = '^[A-Za-z_][A-Za-z0-9_]*$'
    EnvPair  = '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    TagKey   = '^[a-z0-9_]+$'
    TagValue = '^[^\s]+$'
    TagPair  = '^([a-z0-9_]+)=([^\s]+)$'
    Cred     = '^env:([A-Za-z_][A-Za-z0-9_]*)$'
    Ext      = '^\.[a-z0-9_]+$'
}

function New-VigilNameSet {
    param([string[]]$Items)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($i in $Items) { [void]$set.Add($i) }
    return ,$set
}

# Splits a comma-separated value, each item trimmed of spaces and tabs.
function Split-VigilList {
    param([string]$Value)
    $trim = [char[]]@(' ', "`t")
    return ,@($Value.Split(',') | ForEach-Object { $_.Trim($trim) })
}

# Returns @{ Type; List } for a key in a section kind; Type '' = unknown.
function Get-VigilKeyType {
    param([string]$Kind, [string]$Key)

    $t = ''
    $list = $false
    $credential = @('username', 'password', 'token', 'api_key', 'api_token', 'api_key_id',
        'header_value', 'access_key_id', 'client_id', 'tenant_id')
    $jobOnly = @('file', 'arg', 'metric_name', 'run_every', 'run_at', 'run_on_days',
        'runner', 'tag', 'env', 'require_env')

    switch -CaseSensitive ($Kind) {
        'vigil' {
            switch -CaseSensitive ($Key) {
                'instance' { $t = 'name' }
                'state_dir' { $t = 'path' }
                'max_concurrent' { $t = 'int1' }
            }
        }
        'scheduler' {
            switch -CaseSensitive ($Key) {
                'tick' { $t = 'dur' }
                'late_start_window' { $t = 'dur0' }
                'max_pending' { $t = 'int' }
            }
        }
        'log' {
            switch -CaseSensitive ($Key) {
                'dir' { $t = 'path' }
                'stdout' { $t = 'bool' }
                'retain_days' { $t = 'int1' }
                'max_file_mb' { $t = 'int1' }
            }
        }
        'spool' {
            switch -CaseSensitive ($Key) {
                'dir' { $t = 'path' }
                'max_mb' { $t = 'int1' }
                'when_full' { $t = 'when_full' }
            }
        }
        'runner' {
            switch -CaseSensitive ($Key) {
                'command' { $t = 'path' }
                'arg' { $t = 'text'; $list = $true }
                'env' { $t = 'envpair'; $list = $true }
                'require_env' { $t = 'envnames'; $list = $true }
            }
        }
        'backend' {
            if ($Key -ceq 'type') { $t = 'backend_type' }
            elseif ($Key -ceq 'enabled') { $t = 'bool' }
            elseif ($Key -ceq 'timeout') { $t = 'dur' }
            elseif ($credential -ccontains $Key -or $Key -cmatch '(_secret|_key|_token|_password)$') {
                $t = 'credential'
            }
            else { $t = 'text' }
        }
        { $_ -ceq 'job' -or $_ -ceq 'defaults' } {
            if ($Kind -ceq 'defaults' -and $jobOnly -ccontains $Key) {
                $t = 'job_only'
                break
            }
            switch -CaseSensitive ($Key) {
                'file' { $t = 'path' }
                'working_dir' { $t = 'path' }
                'runner' { $t = 'runner_ref' }
                'arg' { $t = 'text'; $list = $true }
                'metric_name' { $t = 'metric' }
                'run_every' { $t = 'dur' }
                'max_runtime' { $t = 'dur' }
                'run_at' { $t = 'times' }
                'run_on_days' { $t = 'days' }
                'grace' { $t = 'dur0' }
                'late_start_window' { $t = 'dur0' }
                'overlap' { $t = 'overlap' }
                'exit_codes' { $t = 'exit_codes' }
                'enabled' { $t = 'bool' }
                'on_uncertain' { $t = 'on_uncertain' }
                'backends' { $t = 'backend_refs' }
                'tag' { $t = 'tagpair'; $list = $true }
                'env' { $t = 'envpair'; $list = $true }
                'require_env' { $t = 'envnames'; $list = $true }
                'log_retain_days' { $t = 'int1' }
            }
        }
    }
    return @{ Type = $t; List = $list }
}

# Checks one value. Returns @{ Code; Message; Warn } - Code '' when valid;
# Warn is the first disabled backend named by backend_refs.
function Test-VigilValue {
    param([string]$Type, [string]$Key, [string]$Value, $Ctx)

    $re = $Script:VigilValRe
    $r = @{ Code = ''; Message = ''; Warn = '' }

    if ($Value.Length -eq 0) {
        $r.Code = 'E_VALUE_EMPTY'; $r.Message = "'$Key' has no value"
        return $r
    }

    switch -CaseSensitive ($Type) {
        { $_ -ceq 'dur' -or $_ -ceq 'dur0' } {
            if ($Value -cnotmatch $re.Dur) {
                $r.Code = 'E_DURATION'; $r.Message = "'$Key' must be a duration such as 30s, 5m, 2h or 7d: $Value"
            }
            elseif ($Type -ceq 'dur' -and $Value -cmatch $re.ZeroDur) {
                $r.Code = 'E_DURATION'; $r.Message = "'$Key' must be greater than zero"
            }
        }
        { $_ -ceq 'int' -or $_ -ceq 'int1' } {
            if ($Value -cnotmatch $re.Int) {
                $r.Code = 'E_INTEGER'; $r.Message = "'$Key' must be a whole number: $Value"
            }
            elseif ($Type -ceq 'int1' -and $Value -cmatch $re.Zero) {
                $r.Code = 'E_INTEGER'; $r.Message = "'$Key' must be at least 1"
            }
        }
        'bool' {
            if ($Value -cne 'true' -and $Value -cne 'false') {
                $r.Code = 'E_BOOLEAN'; $r.Message = "'$Key' must be true or false: $Value"
            }
        }
        'name' {
            if ($Value -cnotmatch $re.Name) {
                $r.Code = 'E_NAME'; $r.Message = "'$Key' may contain only letters, digits, '_', '.' and '-': $Value"
            }
        }
        'metric' {
            if ($Value -cnotmatch $re.Metric) {
                $r.Code = 'E_METRIC_NAME'; $r.Message = "'$Key' must be dotted words of letters, digits and '_': $Value"
            }
        }
        'times' {
            foreach ($item in (Split-VigilList $Value)) {
                if ($item -cnotmatch $re.Time) {
                    $r.Code = 'E_TIME'; $r.Message = "'$Key' times must be HH:MM, 24-hour: '$item'"
                    break
                }
            }
        }
        'days' {
            $days = @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
            foreach ($item in (Split-VigilList $Value)) {
                if ($days -cnotcontains $item.ToLowerInvariant()) {
                    $r.Code = 'E_DAY'; $r.Message = "'$Key' days must be mon, tue, wed, thu, fri, sat or sun: '$item'"
                    break
                }
            }
        }
        'exit_codes' {
            if ($Value -ceq 'standard' -or $Value -ceq 'nagios') { break }
            foreach ($item in (Split-VigilList $Value)) {
                if ($item -cmatch $re.Code) {
                    $lo = [int]$Matches[1]
                    $hi = $lo
                    if ($Matches[3]) { $hi = [int]$Matches[3] }
                    if ($lo -le 255 -and $hi -le 255 -and $lo -le $hi) { continue }
                }
                $r.Code = 'E_EXIT_CODES'
                $r.Message = "'$Key' must be standard, nagios or a list of codes 0-255 such as 0,1 or 0-7: '$item'"
                break
            }
        }
        'overlap' {
            if ($Value -cne 'skip' -and $Value -cne 'queue_one') {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be skip or queue_one: $Value"
            }
        }
        'on_uncertain' {
            if (@('wait', 'replace', 'manual') -cnotcontains $Value) {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be wait, replace or manual: $Value"
            }
        }
        'when_full' {
            if ($Value -cne 'drop_oldest' -and $Value -cne 'drop_newest') {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be drop_oldest or drop_newest: $Value"
            }
        }
        'backend_type' {
            if ($Script:VigilBackendTypes -cnotcontains $Value) {
                $r.Code = 'E_BACKEND_TYPE'; $r.Message = "unknown backend type: $Value"
            }
        }
        'runner_ref' {
            if (-not $Ctx.Runners.Contains($Value)) {
                $r.Code = 'E_RUNNER_UNKNOWN'; $r.Message = "no [runner.$Value] section"
            }
        }
        'backend_refs' {
            foreach ($item in (Split-VigilList $Value)) {
                if (-not $Ctx.Backends.Contains($item)) {
                    $r.Code = 'E_BACKEND_UNKNOWN'; $r.Message = "no [backend.$item] section"
                    break
                }
                if ($r.Warn.Length -eq 0 -and $Ctx.Disabled.Contains($item)) { $r.Warn = $item }
            }
        }
        'tagpair' {
            if ($Value -cnotmatch $re.TagPair) {
                $r.Code = 'E_TAG_SYNTAX'; $r.Message = "'$Key' must be key=value with a lowercase key and no spaces: $Value"
            }
            elseif ($Script:VigilReservedTags -ccontains $Matches[1]) {
                $r.Code = 'E_TAG_RESERVED'; $r.Message = "tag '$($Matches[1])' is set by Vigil and cannot be declared"
            }
        }
        'envpair' {
            if ($Value -cnotmatch $re.EnvPair) {
                $r.Code = 'E_ENV_SYNTAX'; $r.Message = "'$Key' must be NAME=value"
            }
            elseif ($Matches[2].StartsWith('env:', [System.StringComparison]::Ordinal)) {
                $r.Code = 'E_ENV_LITERAL'
                $r.Message = "'$Key' values are literal; the job already inherits $($Matches[2].Substring(4)) from the service environment"
            }
        }
        'envnames' {
            foreach ($item in (Split-VigilList $Value)) {
                if ($item -cnotmatch $re.EnvName) {
                    $r.Code = 'E_ENV_NAME'; $r.Message = "'$Key' must list environment variable names: '$item'"
                    break
                }
            }
        }
        'credential' {
            if ($Value.StartsWith('env:', [System.StringComparison]::Ordinal)) {
                if ($Value -cnotmatch $re.Cred) {
                    $r.Code = 'E_ENV_NAME'; $r.Message = "'$Key' must be env:NAME with a valid variable name"
                }
            }
            else {
                # Never echo the value: it may be a pasted secret.
                $r.Code = 'E_SECRET_RAW'; $r.Message = "'$Key' must be an env:NAME reference; the value is not shown"
            }
        }
    }
    return $r
}

function Test-VigilConfig {
    param([Parameter(Mandatory = $true)]$Parsed)

    $re = $Script:VigilValRe
    $records = New-Object 'System.Collections.Generic.List[object]'
    $state = @{ Job = '' }

    $add = {
        param([string]$Kind, [string]$Job, [int]$Line, [string]$Code, [string]$Message)
        $records.Add([pscustomobject]@{ Kind = $Kind; Job = $Job; Line = $Line; Code = $Code; Message = $Message })
    }
    # Reports against the current section: INVALID inside a job, ERROR elsewhere.
    $report = {
        param([int]$Line, [string]$Code, [string]$Message)
        if ($state.Job.Length -gt 0) { & $add 'INVALID' $state.Job $Line $Code $Message }
        else { & $add 'ERROR' '' $Line $Code $Message }
    }

    # Names that references may point at.
    $ctx = @{
        Runners  = New-VigilNameSet @()
        Backends = New-VigilNameSet @()
        Disabled = New-VigilNameSet @()
    }
    foreach ($sec in $Parsed.Sections) {
        if ($sec.Name.StartsWith('runner.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Runners.Add($sec.Name.Substring(7))
        }
        elseif ($sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Backends.Add($sec.Name.Substring(8))
        }
    }
    foreach ($en in $Parsed.Entries) {
        if ($en.Section.StartsWith('backend.', [System.StringComparison]::Ordinal) -and
            $en.Key -ceq 'enabled' -and $en.Value -ceq 'false') {
            [void]$ctx.Disabled.Add($en.Section.Substring(8))
        }
    }

    $singletons = @('vigil', 'scheduler', 'log', 'tags', 'spool', 'defaults', 'runners')
    $entries = $Parsed.Entries
    $count = $entries.Count
    $e = 0

    foreach ($sec in $Parsed.Sections) {
        $name = $sec.Name
        $sline = $sec.Line
        $sub = ''
        $state.Job = ''
        $dot = $name.IndexOf('.')
        if ($singletons -ccontains $name) {
            $kind = $name
        }
        elseif ($dot -gt 0 -and @('backend', 'runner', 'job') -ccontains $name.Substring(0, $dot)) {
            $kind = $name.Substring(0, $dot)
            $sub = $name.Substring($dot + 1)
        }
        else {
            $kind = ''
        }
        if ($kind -ceq 'job') { $state.Job = $sub }

        if ($kind.Length -eq 0) {
            & $report $sline 'E_SECTION_UNKNOWN' "unknown section [$name]"
            while ($e -lt $count -and $entries[$e].Section -ceq $name) { $e++ }
            continue
        }

        $seen = New-VigilNameSet @()
        $tagKeys = New-VigilNameSet @()
        $envNames = New-VigilNameSet @()
        $has = @{ file = $false; run_every = $false; run_at = $false; run_on_days = $false; command = $false; type = $false }

        while ($e -lt $count -and $entries[$e].Section -ceq $name) {
            $key = $entries[$e].Key
            $value = $entries[$e].Value
            $line = $entries[$e].Line
            $e++

            if ($has.ContainsKey($key)) { $has[$key] = $true }

            if ($kind -ceq 'tags') {
                if ($key -cnotmatch $re.TagKey) {
                    & $report $line 'E_TAG_SYNTAX' "invalid tag key: '$key'"
                    continue
                }
                if ($Script:VigilReservedTags -ccontains $key) {
                    & $report $line 'E_TAG_RESERVED' "tag '$key' is set by Vigil and cannot be declared"
                    continue
                }
                $kt = @{ Type = 'tagvalue'; List = $false }
            }
            elseif ($kind -ceq 'runners') {
                if ($key -cnotmatch $re.Ext) {
                    & $report $line 'E_EXTENSION' "[runners] keys must be file extensions such as .sql: '$key'"
                    continue
                }
                $kt = @{ Type = 'runner_ref'; List = $false }
            }
            else {
                $kt = Get-VigilKeyType -Kind $kind -Key $key
            }

            if ($kt.Type.Length -eq 0) {
                & $report $line 'E_KEY_UNKNOWN' "unknown key '$key' in [$name]"
                continue
            }
            if ($kt.Type -ceq 'job_only') {
                & $report $line 'E_KEY_NOT_DEFAULTABLE' "'$key' must be set on each job, not in [defaults]"
                continue
            }
            if (-not $kt.List) {
                if (-not $seen.Add($key)) {
                    & $report $line 'E_KEY_DUPLICATE' "'$key' is set more than once in [$name]"
                    continue
                }
            }

            if ($kt.Type -ceq 'tagvalue') {
                $r = @{ Code = ''; Message = ''; Warn = '' }
                if ($value.Length -eq 0) {
                    $r.Code = 'E_VALUE_EMPTY'; $r.Message = "'$key' has no value"
                }
                elseif ($value -cnotmatch $re.TagValue) {
                    $r.Code = 'E_TAG_SYNTAX'; $r.Message = "tag values cannot contain spaces: '$key'"
                }
            }
            else {
                $r = Test-VigilValue -Type $kt.Type -Key $key -Value $value -Ctx $ctx
            }
            if ($r.Code.Length -gt 0) {
                & $report $line $r.Code $r.Message
                continue
            }

            $pairName = $value.Split('=')[0]
            switch -CaseSensitive ($kt.Type) {
                'tagpair' {
                    if (-not $tagKeys.Add($pairName)) {
                        & $report $line 'E_TAG_DUPLICATE' "tag '$pairName' is set more than once in [$name]"
                    }
                }
                'envpair' {
                    if (-not $envNames.Add($pairName)) {
                        & $report $line 'E_ENV_DUPLICATE' "env '$pairName' is set more than once in [$name]"
                    }
                }
                'backend_refs' {
                    if ($r.Warn.Length -gt 0) {
                        & $add 'WARN' '' $line 'W_BACKEND_DISABLED' "backend '$($r.Warn)' is disabled"
                    }
                }
            }
        }

        switch -CaseSensitive ($kind) {
            'job' {
                if ($sub.StartsWith('vigil_', [System.StringComparison]::Ordinal)) {
                    & $report $sline 'E_JOB_ID_RESERVED' 'job ids starting with vigil_ are reserved'
                }
                if (-not $has.file) {
                    & $report $sline 'E_KEY_REQUIRED' "[$name] needs 'file'"
                }
                if ($has.run_every -and $has.run_at) {
                    & $report $sline 'E_SCHEDULE_BOTH' 'use run_every or run_at, not both; list the times in run_at'
                }
                elseif (-not $has.run_every -and -not $has.run_at) {
                    if ($has.run_on_days) {
                        & $report $sline 'E_SCHEDULE_DAYS_ONLY' 'run_on_days needs run_every or run_at'
                    }
                    else {
                        & $report $sline 'E_SCHEDULE_NONE' "[$name] needs run_every or run_at"
                    }
                }
            }
            'runner' {
                if (-not $has.command) {
                    & $report $sline 'E_KEY_REQUIRED' "[$name] needs 'command'"
                }
            }
            'backend' {
                if (-not $has.type -and $Script:VigilBackendTypes -cnotcontains $sub) {
                    & $report $sline 'E_BACKEND_TYPE' "[$name] needs 'type': '$sub' is not a backend type"
                }
            }
        }
    }

    return ,$records
}

# Formats parser errors and validation records in the conformance format:
#   ERROR TAB <line> TAB <code>                 parser errors, then validation
#   INVALID TAB <job> TAB <line> TAB <code>
#   WARN TAB <line> TAB <code>
function Format-VigilValidationDump {
    param([Parameter(Mandatory = $true)]$Parsed, [Parameter(Mandatory = $true)]$Records)

    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $Parsed.Errors) {
        [void]$sb.Append("ERROR`t$($e.Line)`t$($e.Code)`n")
    }
    foreach ($r in $Records) {
        if ($r.Kind -ceq 'INVALID') {
            [void]$sb.Append("INVALID`t$($r.Job)`t$($r.Line)`t$($r.Code)`n")
        }
        else {
            [void]$sb.Append("$($r.Kind)`t$($r.Line)`t$($r.Code)`n")
        }
    }
    return $sb.ToString()
}
