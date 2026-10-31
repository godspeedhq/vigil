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
    Scp      = '^([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]{2,}:.+$'
    Sha256   = '^[0-9A-Fa-f]{64}$'
}
$Script:VigilSourceTypes = @('local', 'git', 'https', 'sftp')

# Whether a key applies to a source of the given type (spec 6.9).
# Checks a secret reference (6.5): env:NAME, secret:NAME or, when allowed,
# store:STORE/NAME. Returns @{ Code; Message }; never shows the value.
function Test-VigilSecretRef {
    param([string]$Key, [string]$Value, [bool]$AllowStore, $Stores)
    $re = $Script:VigilValRe
    if ($Value.StartsWith('env:', [System.StringComparison]::Ordinal)) {
        if ($Value -cnotmatch $re.Cred) { return @{ Code = 'E_ENV_NAME'; Message = "'$Key' must be env:NAME with a valid variable name" } }
    }
    elseif ($Value.StartsWith('secret:', [System.StringComparison]::Ordinal)) {
        if ($Value.Substring(7) -cnotmatch $re.EnvName) { return @{ Code = 'E_SECRET_REF'; Message = "'$Key' must be secret:NAME with a valid name" } }
    }
    elseif ($Value.StartsWith('store:', [System.StringComparison]::Ordinal)) {
        if (-not $AllowStore) { return @{ Code = 'E_SECRET_REF'; Message = "'$Key' of a secret store must be env: or secret:, never another store" } }
        $rest = $Value.Substring(6)
        $slash = $rest.IndexOf('/')
        if ($slash -lt 0 -or $slash -eq $rest.Length - 1 -or $rest.Substring(0, [Math]::Max($slash, 0)) -cnotmatch '^[a-z0-9_]+$') {
            return @{ Code = 'E_SECRET_REF'; Message = "'$Key' must be store:STORE/NAME" }
        }
        $store = $rest.Substring(0, $slash)
        if (-not $Stores.Contains($store)) { return @{ Code = 'E_SECRET_STORE_UNKNOWN'; Message = "no [secret_store.$store] section" } }
    }
    else {
        # Never echo the value: it may be a pasted secret.
        return @{ Code = 'E_SECRET_RAW'; Message = "'$Key' must be an env:, secret: or store: reference; the value is not shown" }
    }
    return @{ Code = ''; Message = '' }
}

# Whether a key applies to a secret store of the given type (6.5.3).
function Test-VigilStoreKey {
    param([string]$Type, [string]$Key)
    if ($Key -ceq 'type' -or $Key -ceq 'timeout') { return $true }
    return @('helper:command', 'helper:arg', 'azure_keyvault:vault', 'azure_keyvault:auth', 'azure_keyvault:tenant_id',
        'azure_keyvault:client_id', 'azure_keyvault:client_secret', 'azure_keyvault:authority', 'azure_keyvault:ca_file',
        'hashicorp_vault:url', 'hashicorp_vault:mount',
        'hashicorp_vault:field', 'hashicorp_vault:auth', 'hashicorp_vault:token', 'hashicorp_vault:role_id',
        'hashicorp_vault:secret_id', 'hashicorp_vault:ca_file', 'aws_secrets_manager:region', 'aws_secrets_manager:auth', 'aws_secrets_manager:field',
        'aws_secrets_manager:endpoint', 'aws_secrets_manager:ca_file',
        'aws_secrets_manager:access_key_id', 'aws_secrets_manager:secret_access_key', 'gcp_secret_manager:project',
        'gcp_secret_manager:auth', 'gcp_secret_manager:service_account_key', 'gcp_secret_manager:endpoint',
        'gcp_secret_manager:ca_file') -ccontains "${Type}:$Key"
}

function Test-VigilSourceKey {
    param([string]$Type, [string]$Key)
    if (@('type', 'check_every', 'timeout') -ccontains $Key) { return $true }
    return @('local:path', 'git:url', 'git:ref', 'https:url', 'https:header_name', 'https:header_value',
        'sftp:host', 'sftp:port', 'sftp:user', 'sftp:path') -ccontains "${Type}:$Key"
}

# The first value of a key in a section, or ''.
function Get-VigilFirstValue {
    param($Parsed, $Section, [string]$Key)
    for ($i = $Section.First; $i -lt $Section.First + $Section.Count; $i++) {
        if ($Parsed.Entries[$i].Key -ceq $Key) { return $Parsed.Entries[$i].Value }
    }
    return ''
}

# Checks the authority of a URL (after the scheme) for a host and for
# credentials. Returns @{ Code; Message }; never shows the URL.
function Test-VigilUrlAuthority {
    param([string]$Rest, [string]$Scheme)
    $auth = $Rest.Split('/')[0]
    if ($auth.Length -eq 0) { return @{ Code = 'E_URL'; Message = "'url' has no host" } }
    # As bash's "*:*@*": a ':' anywhere before an '@' is a password.
    $at = $auth.LastIndexOf('@')
    if ($at -ge 0 -and ($Scheme -ceq 'https' -or $auth.Substring(0, $at).Contains(':'))) {
        return @{ Code = 'E_URL'; Message = "'url' must not contain credentials; the value is not shown" }
    }
    return @{ Code = ''; Message = '' }
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
    param([string]$Kind, [string]$Key, [string]$JobSource = '')

    $t = ''
    $list = $false
    $credential = @('username', 'password', 'token', 'api_key', 'api_token', 'api_key_id',
        'header_value', 'access_key_id', 'client_id', 'tenant_id')
    $jobOnly = @('file', 'source', 'sha256', 'arg', 'metric_name', 'run_every', 'run_at',
        'run_on_days', 'runner', 'tag', 'env', 'secret', 'require_env')

    switch -CaseSensitive ($Kind) {
        'source' {
            switch -CaseSensitive ($Key) {
                'type' { $t = 'source_type' }
                'path' { $t = 'path' }
                'url' { $t = 'url' }
                'host' { $t = 'text' }
                'user' { $t = 'text' }
                'ref' { $t = 'text' }
                'header_name' { $t = 'text' }
                'port' { $t = 'port' }
                'check_every' { $t = 'dur' }
                'timeout' { $t = 'dur' }
                'header_value' { $t = 'credential' }
            }
        }
        'vigil' {
            switch -CaseSensitive ($Key) {
                'config_source' { $t = 'source_ref' }
                'config_file' { $t = 'srcpath' }
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
        'log_forward' {
            switch -CaseSensitive ($Key) {
                'enabled' { $t = 'bool' }
                'destination' { $t = 'destination_ref' }
                'include' { $t = 'log_include' }
                'check_every' { $t = 'dur' }
                'batch_lines' { $t = 'int1' }
                'batch_kb' { $t = 'int1' }
                'max_pending_mb' { $t = 'int1' }
            }
        }
        'secret_store' {
            switch -CaseSensitive ($Key) {
                'type' { $t = 'store_type' }
                'command' { $t = 'path' }
                'arg' { $t = 'arg'; $list = $true }
                'vault' { $t = 'https_url' }
                'url' { $t = 'https_url' }
                'authority' { $t = 'https_url' }
                'endpoint' { $t = 'https_url' }
                'ca_file' { $t = 'path' }
                'auth' { $t = 'store_auth' }
                'timeout' { $t = 'dur' }
                default {
                    if (@('mount', 'field', 'region', 'project', 'tenant_id', 'client_id', 'role_id', 'access_key_id') -ccontains $Key) { $t = 'text' }
                    elseif (@('client_secret', 'token', 'secret_id', 'secret_access_key', 'service_account_key') -ccontains $Key) { $t = 'credential' }
                }
            }
        }
        'log_destination' {
            switch -CaseSensitive ($Key) {
                'type' { $t = 'log_dest_type' }
                'endpoint' { $t = 'https_url' }
                'timeout' { $t = 'dur' }
                'header_name' { $t = 'text' }
                'header_value' { $t = 'credential' }
            }
        }
        'runner' {
            switch -CaseSensitive ($Key) {
                'command' { $t = 'path' }
                'arg' { $t = 'arg'; $list = $true }
                'env' { $t = 'envpair'; $list = $true }
                'secret' { $t = 'secretpair'; $list = $true }
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
                # Inside a source, file is a relative path in that source.
                'file' { if ($JobSource.Length -gt 0) { $t = 'srcpath' } else { $t = 'path' } }
                'source' { $t = 'source_ref' }
                'sha256' { $t = 'sha256' }
                'working_dir' { $t = 'path' }
                'runner' { $t = 'runner_ref' }
                'arg' { $t = 'arg'; $list = $true }
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
                'secret' { $t = 'secretpair'; $list = $true }
                'require_env' { $t = 'envnames'; $list = $true }
                'log_retain_days' { $t = 'int1' }
                'forward_output' { $t = 'bool' }
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

    # Arguments may be empty: some tools take an empty argument (spec 6.4).
    if ($Value.Length -eq 0 -and $Type -cne 'arg') {
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
        'destination_ref' {
            if (-not $Ctx.Destinations.Contains($Value)) {
                $r.Code = 'E_DESTINATION_UNKNOWN'; $r.Message = "no [log_destination.$Value] section"
            }
        }
        'log_include' {
            foreach ($item in (Split-VigilList $Value)) {
                if (@('supervisor', 'run', 'stdout', 'stderr') -cnotcontains $item) {
                    $r.Code = 'E_ENUM'; $r.Message = "'$Key' items must be supervisor, run, stdout or stderr: '$item'"
                    break
                }
            }
        }
        'log_dest_type' {
            if ($Value -cne 'otel') { $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be otel: $Value" }
        }
        'https_url' {
            # The URL itself is never shown, since a mistaken one may carry a password.
            if ($Value.StartsWith('https://', [System.StringComparison]::Ordinal)) {
                $a = Test-VigilUrlAuthority $Value.Substring(8) 'https'
                $r.Code = $a.Code; $r.Message = $a.Message
            }
            else { $r.Code = 'E_URL'; $r.Message = "'$Key' must start with https://" }
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
            elseif ($Matches[2].StartsWith('secret:', [System.StringComparison]::Ordinal) -or
                $Matches[2].StartsWith('store:', [System.StringComparison]::Ordinal)) {
                $r.Code = 'E_ENV_LITERAL'
                $r.Message = "'$Key' values are literal and never secrets; use secret = NAME=<reference>"
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
        'source_type' {
            if ($Script:VigilSourceTypes -cnotcontains $Value) {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be local, git, https or sftp: $Value"
            }
        }
        'port' {
            if ($Value -cnotmatch $re.Int -or [int]$Value -lt 1 -or [int]$Value -gt 65535) {
                $r.Code = 'E_INTEGER'; $r.Message = "'$Key' must be a port number from 1 to 65535: $Value"
            }
        }
        'url' {
            # Checked against the source's type; the URL itself is never
            # shown, since a mistaken one may carry a password.
            $u = @{ Code = ''; Message = '' }
            $gitForms = "a git 'url' must be https://, ssh:// or user@host:path"
            if ($Ctx.SType -ceq 'https') {
                if ($Value.StartsWith('https://', [System.StringComparison]::Ordinal)) {
                    $u = Test-VigilUrlAuthority $Value.Substring(8) 'https'
                }
                else { $u = @{ Code = 'E_URL'; Message = "the 'url' of an https source must start with https://" } }
            }
            elseif ($Ctx.SType -ceq 'git') {
                if ($Value.StartsWith('https://', [System.StringComparison]::Ordinal)) {
                    $u = Test-VigilUrlAuthority $Value.Substring(8) 'https'
                }
                elseif ($Value.StartsWith('ssh://', [System.StringComparison]::Ordinal)) {
                    $u = Test-VigilUrlAuthority $Value.Substring(6) 'ssh'
                }
                elseif ($Value.Contains('://') -or $Value -cnotmatch $re.Scp) {
                    $u = @{ Code = 'E_URL'; Message = $gitForms }
                }
            }
            $r.Code = $u.Code; $r.Message = $u.Message
        }
        'srcpath' {
            if ($Value.StartsWith('/') -or $Value.Contains('\') -or $Value -cmatch '^[A-Za-z]:' -or
                "/$Value/".Contains('/../')) {
                $r.Code = 'E_SOURCE_PATH'
                $r.Message = "'$Key' must be a relative path inside the source, with / separators and no .. segments: $Value"
            }
        }
        'source_ref' {
            if (-not $Ctx.Sources.ContainsKey($Value)) {
                $r.Code = 'E_SOURCE_UNKNOWN'; $r.Message = "no [source.$Value] section"
            }
        }
        'sha256' {
            if ($Value -cnotmatch $re.Sha256) {
                $r.Code = 'E_SHA256'; $r.Message = "'$Key' must be 64 hexadecimal digits"
            }
        }
        'credential' {
            # A secret store's own credentials cannot come from a store.
            $c = Test-VigilSecretRef -Key $Key -Value $Value -AllowStore ($Ctx.Kind -cne 'secret_store') -Stores $Ctx.Stores
            $r.Code = $c.Code; $r.Message = $c.Message
        }
        'secretpair' {
            if ($Value -cnotmatch $re.EnvPair) {
                $r.Code = 'E_ENV_SYNTAX'; $r.Message = "'$Key' must be NAME=<env:, secret: or store: reference>"
            }
            else {
                $c = Test-VigilSecretRef -Key $Key -Value $Matches[2] -AllowStore $true -Stores $Ctx.Stores
                $r.Code = $c.Code; $r.Message = $c.Message
            }
        }
        'store_type' {
            if (@('helper', 'azure_keyvault', 'hashicorp_vault', 'aws_secrets_manager', 'gcp_secret_manager') -cnotcontains $Value) {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' must be helper, azure_keyvault, hashicorp_vault, aws_secrets_manager or gcp_secret_manager: $Value"
            }
        }
        'store_auth' {
            $ok = @('azure_keyvault:managed_identity', 'azure_keyvault:service_principal', 'hashicorp_vault:token',
                'hashicorp_vault:approle', 'aws_secrets_manager:instance_profile', 'aws_secrets_manager:access_keys',
                'gcp_secret_manager:metadata', 'gcp_secret_manager:service_account_key')
            if ($ok -cnotcontains "$($Ctx.SSType):$Value") {
                $r.Code = 'E_ENUM'; $r.Message = "'$Key' is not an authentication method of a $($Ctx.SSType) secret store: $Value"
            }
        }
    }
    return $r
}

# Warns when two jobs' different base metric names become the same name in
# a backend that only allows underscores (spec 14.1): "a.b_c" and "a_b.c"
# are both a_b_c there. Only jobs sending to the same such backend clash.
function Test-VigilMetricCollisions {
    param($Parsed, $Disabled, [scriptblock]$Add)

    # Enabled backends whose format allows only underscores in names.
    $us = New-Object 'System.Collections.Generic.List[string]'
    $defList = ''
    foreach ($sec in $Parsed.Sections) {
        if ($sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal)) {
            $bname = $sec.Name.Substring(8)
            $type = Get-VigilFirstValue $Parsed $sec 'type'
            if ($type.Length -eq 0) { $type = $bname }
            if (-not $Disabled.Contains($bname) -and @('file', 'prometheus', 'victoriametrics') -ccontains $type) {
                $us.Add($bname)
            }
        }
        elseif ($sec.Name -ceq 'defaults') {
            $defList = Get-VigilFirstValue $Parsed $sec 'backends'
        }
    }
    if ($us.Count -eq 0) { return }

    $jobs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sec in $Parsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        $base = Get-VigilFirstValue $Parsed $sec 'metric_name'
        if ($base.Length -eq 0) { $base = $sec.Name.Substring(4) }
        if ($base -cnotmatch $Script:VigilValRe.Metric) { continue }
        $list = Get-VigilFirstValue $Parsed $sec 'backends'
        if ($list.Length -eq 0) { $list = $defList }
        # The underscore-only backends this job sends to.
        $set = New-Object 'System.Collections.Generic.List[string]'
        if ($list.Length -gt 0) {
            foreach ($item in (Split-VigilList $list)) {
                if ($us.Contains($item) -and -not $set.Contains($item)) { $set.Add($item) }
            }
        }
        else {
            foreach ($item in $us) { $set.Add($item) }
        }
        if ($set.Count -gt 0) {
            $jobs.Add(@{ Name = $sec.Name.Substring(4); Base = $base; Under = $base.Replace('.', '_'); Line = $sec.Line; Set = $set })
        }
    }

    for ($j = 1; $j -lt $jobs.Count; $j++) {
        $b = $jobs[$j]
        for ($i = 0; $i -lt $j; $i++) {
            $a = $jobs[$i]
            if ($a.Under -cne $b.Under -or $a.Base -ceq $b.Base) { continue }
            $shared = ''
            foreach ($item in $b.Set) {
                if ($a.Set.Contains($item)) { $shared = $item; break }
            }
            if ($shared.Length -gt 0) {
                & $Add 'WARN' '' $b.Line 'W_METRIC_COLLISION' "metric '$($b.Base)' becomes '$($b.Under)' in backend '$shared', the same as '$($a.Base)' of [job.$($a.Name)]"
                break
            }
        }
    }
}

function Test-VigilConfig {
    param([Parameter(Mandatory = $true)]$Parsed)

    $re = $Script:VigilValRe
    $records = New-Object 'System.Collections.Generic.List[object]'
    $state = @{ Job = '' }

    $add = {
        param([string]$Kind, [string]$Job, $Line, [string]$Code, [string]$Message)
        $records.Add([pscustomobject]@{ Kind = $Kind; Job = $Job; Line = $Line; Code = $Code; Message = $Message })
    }
    # Reports against the current section: INVALID inside a job, ERROR elsewhere.
    $report = {
        param($Line, [string]$Code, [string]$Message)
        if ($state.Job.Length -gt 0) { & $add 'INVALID' $state.Job $Line $Code $Message }
        else { & $add 'ERROR' '' $Line $Code $Message }
    }

    # Names that references may point at, and each source's type (empty when
    # not valid). SType, JSource and JType describe the current section.
    $ctx = @{
        Runners  = New-VigilNameSet @()
        Backends = New-VigilNameSet @()
        Destinations = New-VigilNameSet @()
        Stores       = New-VigilNameSet @()
        Kind         = ''
        SSType       = ''
        Disabled = New-VigilNameSet @()
        Sources  = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        SType    = ''
        JSource  = ''
        JType    = ''
    }
    $pointer = ''
    foreach ($sec in $Parsed.Sections) {
        if ($sec.Name -ceq 'vigil') {
            # A config_source makes this file a pointer to the real one.
            $pointer = Get-VigilFirstValue $Parsed $sec 'config_source'
        }
        elseif ($sec.Name.StartsWith('runner.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Runners.Add($sec.Name.Substring(7))
        }
        elseif ($sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Backends.Add($sec.Name.Substring(8))
        }
        elseif ($sec.Name.StartsWith('secret_store.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Stores.Add($sec.Name.Substring(13))
        }
        elseif ($sec.Name.StartsWith('log_destination.', [System.StringComparison]::Ordinal)) {
            [void]$ctx.Destinations.Add($sec.Name.Substring(16))
        }
        elseif ($sec.Name.StartsWith('source.', [System.StringComparison]::Ordinal)) {
            $type = Get-VigilFirstValue $Parsed $sec 'type'
            if ($Script:VigilSourceTypes -cnotcontains $type) { $type = '' }
            $ctx.Sources[$sec.Name.Substring(7)] = $type
        }
    }
    foreach ($en in $Parsed.Entries) {
        if ($en.Section.StartsWith('backend.', [System.StringComparison]::Ordinal) -and
            $en.Key -ceq 'enabled' -and $en.Value -ceq 'false') {
            [void]$ctx.Disabled.Add($en.Section.Substring(8))
        }
    }

    $singletons = @('vigil', 'scheduler', 'log', 'tags', 'spool', 'defaults', 'runners', 'log_forward')
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
        elseif ($dot -gt 0 -and @('backend', 'runner', 'job', 'source', 'log_destination', 'secret_store') -ccontains $name.Substring(0, $dot)) {
            $kind = $name.Substring(0, $dot)
            $sub = $name.Substring($dot + 1)
        }
        else {
            $kind = ''
        }
        if ($kind -ceq 'job') { $state.Job = $sub }

        $skip = $false
        if ($kind.Length -eq 0) {
            & $report $sline 'E_SECTION_UNKNOWN' "unknown section [$name]"
            $skip = $true
        }
        elseif ($pointer.Length -gt 0 -and $kind -cne 'vigil' -and $name -cne "source.$pointer") {
            # A pointer file holds only where the configuration is (6.8).
            & $report $sline 'E_POINTER_ONLY' "[$name] belongs in the configuration fetched from [source.$pointer], not in this file"
            $skip = $true
        }
        if ($skip) {
            # The section is rejected as a whole; its keys are not checked.
            while ($e -lt $count -and $entries[$e].Section -ceq $name) { $e++ }
            continue
        }

        # What the section's keys are checked against: a job's source and
        # its type, or a source's own type.
        $ctx.SType = ''
        $ctx.SSType = ''
        $ctx.Kind = $kind
        $ctx.JSource = ''
        $ctx.JType = ''
        if ($kind -ceq 'job') {
            $ctx.JSource = Get-VigilFirstValue $Parsed $sec 'source'
            if ($ctx.JSource.Length -gt 0 -and $ctx.Sources.ContainsKey($ctx.JSource)) {
                $ctx.JType = $ctx.Sources[$ctx.JSource]
            }
        }
        elseif ($kind -ceq 'secret_store') {
            $type = Get-VigilFirstValue $Parsed $sec 'type'
            if (@('helper', 'azure_keyvault', 'hashicorp_vault', 'aws_secrets_manager', 'gcp_secret_manager') -ccontains $type) { $ctx.SSType = $type }
        }
        elseif ($kind -ceq 'source') {
            $type = Get-VigilFirstValue $Parsed $sec 'type'
            if ($Script:VigilSourceTypes -ccontains $type) { $ctx.SType = $type }
        }

        $seen = New-VigilNameSet @()
        $tagKeys = New-VigilNameSet @()
        $envNames = New-VigilNameSet @()
        $has = @{ file = $false; run_every = $false; run_at = $false; run_on_days = $false; command = $false; type = $false; sha256 = $false; config_file = $false }

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
                $kt = Get-VigilKeyType -Kind $kind -Key $key -JobSource $ctx.JSource
            }

            if ($kt.Type.Length -eq 0) {
                & $report $line 'E_KEY_UNKNOWN' "unknown key '$key' in [$name]"
                continue
            }
            if ($pointer.Length -gt 0 -and $kind -ceq 'vigil' -and @('config_source', 'config_file', 'state_dir') -cnotcontains $key) {
                & $report $line 'E_POINTER_ONLY' "'$key' belongs in the configuration fetched from [source.$pointer], not in this file"
                continue
            }
            if ($ctx.SSType.Length -gt 0 -and -not (Test-VigilStoreKey $ctx.SSType $key)) {
                & $report $line 'E_KEY_UNKNOWN' "'$key' does not apply to a $($ctx.SSType) secret store"
                continue
            }
            if ($ctx.SType.Length -gt 0 -and -not (Test-VigilSourceKey $ctx.SType $key)) {
                & $report $line 'E_KEY_UNKNOWN' "'$key' does not apply to a $($ctx.SType) source"
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
                { $_ -ceq 'envpair' -or $_ -ceq 'secretpair' } {
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
                # Scripts from versionless sources are pinned by digest (6.9).
                if (-not $has.sha256) {
                    if ($ctx.JType -ceq 'https' -or $ctx.JType -ceq 'sftp') {
                        & $report $sline 'E_SHA256_REQUIRED' "[$name] needs 'sha256': scripts from $($ctx.JType) sources are pinned by digest"
                    }
                    elseif ($ctx.JType -ceq 'local') {
                        & $add 'WARN' '' $sline 'W_SCRIPT_UNPINNED' "[$name] has no 'sha256'; its script follows changes in the source, so hosts may briefly differ"
                    }
                }
            }
            'source' {
                $req = ''
                if (-not $has.type) { $req = 'type' }
                else {
                    $needed = @()
                    switch -CaseSensitive ($ctx.SType) {
                        'local' { $needed = @('path') }
                        'git' { $needed = @('url', 'ref') }
                        'https' { $needed = @('url') }
                        'sftp' { $needed = @('host', 'path') }
                    }
                    foreach ($k in $needed) {
                        if (-not $seen.Contains($k)) { $req = $k; break }
                    }
                }
                if ($req.Length -gt 0) {
                    & $report $sline 'E_KEY_REQUIRED' "[$name] needs '$req'"
                }
            }
            'secret_store' {
                # Required keys (6.5.3).
                $needed = switch ($ctx.SSType) {
                    'helper' { @('type', 'command') } 'azure_keyvault' { @('type', 'vault', 'auth') } 'hashicorp_vault' { @('type', 'url', 'auth') }
                    'aws_secrets_manager' { @('type', 'region', 'auth') } 'gcp_secret_manager' { @('type', 'project', 'auth') } default { @('type') }
                }
                $missing = $false
                foreach ($k in $needed) {
                    if (-not $seen.Contains($k)) { & $report $sline 'E_KEY_REQUIRED' "[$name] needs '$k'"; $missing = $true; break }
                }
                # And the keys its authentication method needs.
                if (-not $missing) {
                    $auth = Get-VigilFirstValue $Parsed $sec 'auth'
                    $needed = switch -CaseSensitive ("$($ctx.SSType):$auth") {
                        'azure_keyvault:service_principal' { @('tenant_id', 'client_id', 'client_secret') }
                        'hashicorp_vault:token' { @('token') }
                        'hashicorp_vault:approle' { @('role_id', 'secret_id') }
                        'aws_secrets_manager:access_keys' { @('access_key_id', 'secret_access_key') }
                        'gcp_secret_manager:service_account_key' { @('service_account_key') }
                        default { @() }
                    }
                    foreach ($k in $needed) {
                        if (-not $seen.Contains($k)) { & $report $sline 'E_KEY_REQUIRED' "[$name] needs '$k' for auth = $auth"; break }
                    }
                }
            }
            { $_ -ceq 'log_forward' -or $_ -ceq 'log_destination' } {
                # Required keys (13.4.1).
                $needed = if ($kind -ceq 'log_destination') { @('type', 'endpoint') } else { @('destination') }
                foreach ($k in $needed) {
                    if (-not $seen.Contains($k)) { & $report $sline 'E_KEY_REQUIRED' "[$name] needs '$k'"; break }
                }
            }
            'vigil' {
                # config_source and config_file go together.
                if ($pointer.Length -gt 0 -and -not $has.config_file) {
                    & $report $sline 'E_KEY_REQUIRED' "[$name] needs 'config_file' with 'config_source'"
                }
                elseif ($pointer.Length -eq 0 -and $has.config_file) {
                    & $report $sline 'E_KEY_REQUIRED' "[$name] needs 'config_source' with 'config_file'"
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

    Test-VigilMetricCollisions -Parsed $Parsed -Disabled $ctx.Disabled -Add $add

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
