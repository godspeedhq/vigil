#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil pre-flight checks - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    What vigil precheck prints (SPECIFICATION.md 16.3, 16.4, 6.6). The twin
    of precheck.sh.

    Format-VigilConfigReport -Parsed <config> -Records <records>
        Pure: every parser error and validation record, one per line in file
        order, with its line and message. Tested by tests/conformance/report.
    Format-VigilEffectiveReport -Index <index> -Id <job>
        Pure: a job's effective settings and where each came from (6.6).
    Format-VigilPrecheckReportDump -Parsed <config> -Records <records>
        Pure, for the conformance suite: the configuration report, then the
        effective report of every valid job when the configuration is not
        rejected.
    Invoke-VigilPrecheck -Root <dir> [-Job <id>]
        Checks, without starting or changing anything, that everything a run
        needs is there (16.4). Returns @{ Code; Lines }: Code is 0 when
        nothing failed (warnings are allowed), 1 otherwise. Secrets are resolved and
        thrown away: only their references are printed.

    Requires Config.ps1, Validate.ps1, Effective.ps1, Command.ps1,
    Secrets.ps1, Stores.ps1 and Worker.ps1.
#>

function Format-VigilConfigRecord {
    param([string]$Kind, [string]$Job, $Line, [string]$Code, [string]$Message)
    $where = if ([int]$Line -gt 0) { "line ${Line}: " } else { '' }
    if ($Kind -ceq 'INVALID') { return "INVALID  job.$Job, $where$Message ($Code)" }
    return ('{0,-8} {1}{2} ({3})' -f $Kind, $where, $Message, $Code)
}

function Format-VigilConfigReport {
    param([Parameter(Mandatory = $true)]$Parsed, $Records)
    $all = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Parsed.Errors) {
        $all.Add([pscustomobject]@{ Line = [int]$e.Line; N = $all.Count; Text = (Format-VigilConfigRecord 'ERROR' '' $e.Line $e.Code $e.Message) })
    }
    foreach ($r in $Records) {
        $all.Add([pscustomobject]@{ Line = [int]$r.Line; N = $all.Count; Text = (Format-VigilConfigRecord $r.Kind $r.Job $r.Line $r.Code $r.Message) })
    }
    # In file order: by line, then as found.
    $sb = New-Object System.Text.StringBuilder
    foreach ($x in ($all | Sort-Object Line, N)) { [void]$sb.Append("$($x.Text)`n") }
    return $sb.ToString()
}

function Format-VigilEffectiveReport {
    param([Parameter(Mandatory = $true)]$Index, [string]$Id)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("job.$Id`n")
    foreach ($row in (Get-VigilEffectiveJob -Index $Index -Id $Id)) {
        $value = if ($row.Value) { $row.Value } else { 'none' }
        [void]$sb.Append(('  {0,-17} = {1,-22} ({2})' -f $row.Key, $value, $row.Source) + "`n")
    }
    return $sb.ToString()
}

function Format-VigilPrecheckReportDump {
    param([Parameter(Mandatory = $true)]$Parsed, $Records)
    $text = Format-VigilConfigReport -Parsed $Parsed -Records $Records
    if ($Parsed.Errors.Count -gt 0 -or @($Records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) { return $text }
    $index = New-VigilConfigIndex -Parsed $Parsed
    foreach ($sec in $Parsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        $id = $sec.Name.Substring(4)
        if (@($Records | Where-Object { $_.Kind -ceq 'INVALID' -and $_.Job -ceq $id }).Count -gt 0) { continue }
        $text += Format-VigilEffectiveReport -Index $index -Id $id
    }
    return $text
}

# Whether a directory Vigil writes to, or the nearest folder above it that
# exists, is writable: a probe file is created and deleted at once.
function Test-VigilWritableDir {
    param([string]$Path)
    $d = $Path
    while ($d -and -not [System.IO.Directory]::Exists($d)) { $d = [System.IO.Path]::GetDirectoryName($d) }
    if (-not $d) { return @{ Ok = $false; Dir = $Path } }
    $probe = Join-Path $d ".vigil-precheck.$PID"
    try {
        [System.IO.File]::WriteAllText($probe, '')
        [System.IO.File]::Delete($probe)
        return @{ Ok = $true; Dir = $d }
    }
    catch { return @{ Ok = $false; Dir = $d } }
}

function Invoke-VigilPrecheck {
    param([string]$Root, [string]$Job)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $n = @{ Failed = 0 }
    $ok = { param($What) $out.Add("  ok    $What") }
    $fail = { param($What) $out.Add("  FAIL  $What"); $n.Failed++ }

    $path = Join-Path $Root 'config\vigil.config'
    $parsed = ConvertFrom-VigilConfig -Path $path
    $records = Test-VigilConfig -Parsed $parsed
    $errors = $parsed.Errors.Count + @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count
    $invalid = @($records | Where-Object { $_.Kind -ceq 'INVALID' }).Count
    $warnings = @($records | Where-Object { $_.Kind -ceq 'WARN' }).Count
    $out.Add("Configuration $path")
    if ($errors + $invalid + $warnings -eq 0) { $out.Add('  no problems') }
    else {
        foreach ($l in (Format-VigilConfigReport -Parsed $parsed -Records $records).TrimEnd("`n").Split("`n")) { $out.Add("  $l") }
    }
    $n.Failed = $errors + $invalid
    if ($errors -gt 0) {
        $out.Add('')
        $out.Add('precheck failed: the configuration is rejected; nothing else was checked')
        return @{ Code = 1; Lines = $out }
    }

    $index = New-VigilConfigIndex -Parsed $parsed
    $isInvalid = { param($Id) @($records | Where-Object { $_.Kind -ceq 'INVALID' -and $_.Job -ceq $Id }).Count -gt 0 }
    if ($Job) {
        if (-not ($parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })) {
            $out.Add('')
            $out.Add("precheck failed: no job $Job in the configuration")
            return @{ Code = 1; Lines = $out }
        }
        $out.Add('')
        if (& $isInvalid $Job) { $out.Add("job.$Job is INVALID; its effective settings are not shown") }
        else { foreach ($l in (Format-VigilEffectiveReport -Index $index -Id $Job).TrimEnd("`n").Split("`n")) { $out.Add($l) } }
    }

    $out.Add('')
    $out.Add('Checks')
    # The state directory is always this file's (6.8).
    $stateDir = Get-VigilConfigValue $parsed 'vigil' 'state_dir' 'state'
    if (-not [System.IO.Path]::IsPathRooted($stateDir)) { $stateDir = Join-Path $Root $stateDir }

    # Everything one run of a job needs, as the worker checks it (4.3).
    $checkJob = {
        param($Index, $Parsed, [string]$Id, [string]$Cached)
        $before = $n.Failed
        $cmd = Get-VigilJobCommand -Index $Index -Id $Id -Platform 'windows' -Root $Root -Cached $Cached
        if ($cmd.Error) { & $fail "job.${Id}: $($cmd.Message)"; return }
        if (-not [System.IO.Directory]::Exists($cmd.Cwd)) { & $fail "job.${Id}: working directory not found: $($cmd.Cwd)" }
        if ($cmd.Program.Contains('\')) {
            if (-not [System.IO.File]::Exists($cmd.Program)) { & $fail "job.${Id}: not found: $($cmd.Program)" }
        }
        elseif (-not (Get-Command $cmd.Program -CommandType Application -ErrorAction SilentlyContinue)) { & $fail "job.${Id}: not found: $($cmd.Program)" }
        $file = Resolve-VigilPath -Path (Get-VigilIndexValue -Index $Index -Section "job.$Id" -Key 'file').Value -Platform 'windows' -Root $Root
        if ($Cached) { $file = $Cached }
        if (-not [System.IO.File]::Exists($file)) { & $fail "job.${Id}: file not found: $file" }
        $eff = Get-VigilEffectiveJob -Index $Index -Id $Id
        $provided = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($row in $eff) {
            if ($row.Key -cne 'secret') { continue }
            $eq = $row.Value.IndexOf('=')
            $ref = $row.Value.Substring($eq + 1)
            $r = Resolve-VigilSecret -Root $Root -Parsed $Parsed -Reference $ref
            if ($r.Ok) { [void]$provided.Add($row.Value.Substring(0, $eq)) }
            else { & $fail "job.${Id}: secret $ref unavailable: $($r.Why)" }
            $r = $null
        }
        foreach ($row in $eff) {
            if ($row.Key -cne 'require_env' -or $provided.Contains($row.Value)) { continue }
            if ($null -eq (Get-VigilFreshEnv $row.Value)) { & $fail "job.${Id}: missing environment variable $($row.Value)" }
        }
        if ($n.Failed -eq $before) { & $ok "job.$Id" }
    }

    # What each source needs on this host: its client program, or for a
    # local source its directory.
    $checkSources = {
        param($Parsed)
        foreach ($sec in $Parsed.Sections) {
            if (-not $sec.Name.StartsWith('source.', [System.StringComparison]::Ordinal)) { continue }
            $type = Get-VigilConfigValue $Parsed $sec.Name 'type' ''
            if (@('git', 'sftp') -ccontains $type) {
                if (Find-VigilProgram $type) { & $ok "$($sec.Name): $type" } else { & $fail "$($sec.Name): $type not found" }
            }
            elseif ($type -ceq 'local') {
                $d = (Get-VigilConfigValue $Parsed $sec.Name 'path' '').Replace('/', '\')
                if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Root $d }
                if ([System.IO.Directory]::Exists($d)) { & $ok "$($sec.Name): $d" } else { & $fail "$($sec.Name): not a directory: $d" }
            }
        }
    }

    $jobsParsed = $parsed
    $jobsIndex = $index
    $jobsRecords = $records
    $active = $null
    $checkJobs = $true
    if (Test-VigilFetchMode -Parsed $parsed) {
        # With sources (16.5): a pointer file's jobs are those of the active
        # configuration, once fetched; a local file's are its own, each
        # script from a source as the active record has it cached. Nothing
        # is fetched.
        & $checkSources $parsed
        $remote = Get-VigilConfigValue $parsed 'vigil' 'config_source' ''
        $active = Read-VigilActive -Root $Root -State $stateDir
        if ($active) {
            & $ok "configuration revision $($active.Revision) is active ($($active.Origin))"
            if ($remote) {
                $parsed = ConvertFrom-VigilConfig -Path $active.Config
                $jobsParsed = $parsed
                $jobsRecords = Test-VigilConfig -Parsed $parsed
                $jobsIndex = New-VigilConfigIndex -Parsed $parsed
                & $checkSources $parsed
            }
        }
        elseif ($remote) {
            & $ok "configuration: not fetched yet; the supervisor fetches it from source.$remote"
            $checkJobs = $false
        }
    }
    if ($checkJobs) {
        foreach ($sec in $jobsParsed.Sections) {
            if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            $id = $sec.Name.Substring(4)
            if ($Job -and $id -cne $Job) { continue }
            if (@($jobsRecords | Where-Object { $_.Kind -ceq 'INVALID' -and $_.Job -ceq $id }).Count -gt 0) { continue }
            $src = Get-VigilConfigValue $jobsParsed $sec.Name 'source' ''
            if (-not $src) { & $checkJob $jobsIndex $jobsParsed $id ''; continue }
            $cached = Get-VigilActiveScript -Root $Root -Active $active -Source $src -File (Get-VigilConfigValue $jobsParsed $sec.Name 'file' '')
            if ($cached -and [System.IO.File]::Exists($cached)) { & $checkJob $jobsIndex $jobsParsed $id $cached }
            else { & $ok "job.${id}: its script is fetched from source.$src when Vigil runs" }
        }
    }

    # Credentials of backends and secret stores: resolved, never shown.
    foreach ($sec in $parsed.Sections) {
        $isStore = $sec.Name.StartsWith('secret_store.', [System.StringComparison]::Ordinal)
        if (-not ($sec.Name.StartsWith('backend.', [System.StringComparison]::Ordinal) -or $isStore -or
                $sec.Name.StartsWith('source.', [System.StringComparison]::Ordinal) -or
                $sec.Name.StartsWith('log_destination.', [System.StringComparison]::Ordinal))) { continue }
        for ($i = $sec.First; $i -lt $sec.First + $sec.Count; $i++) {
            $e = $parsed.Entries[$i]
            if ($e.Value -cnotmatch '^(env|secret|store):') { continue }
            $r = Resolve-VigilSecret -Root $Root -Parsed $parsed -Reference $e.Value
            if ($r.Ok) { & $ok "$($sec.Name): $($e.Key) $($e.Value)" }
            else { & $fail "$($sec.Name): $($e.Key) $($e.Value) unavailable: $($r.Why)" }
            $r = $null
        }
        # Which client a cloud store uses: its CLI, or Vigil's own.
        if ($isStore) {
            $type = Get-VigilConfigValue $parsed $sec.Name 'type' ''
            if (@('azure_keyvault', 'aws_secrets_manager', 'gcp_secret_manager') -ccontains $type) {
                $c = Get-VigilStoreClientReport -Root $Root -Parsed $parsed -Store $sec.Name.Substring(13) -Type $type
                if ($c.Ok) { & $ok "$($sec.Name): $($c.Text)" } else { & $fail "$($sec.Name): $($c.Text)" }
            }
        }
    }

    $ctx = @{
        'state directory' = @('vigil', 'state_dir', 'state')
        'log directory'   = @('log', 'dir', 'logs')
        'spool directory' = @('spool', 'dir', 'spool')
    }
    foreach ($what in @('state directory', 'log directory', 'spool directory')) {
        $k = $ctx[$what]
        $d = Get-VigilConfigValue $parsed $k[0] $k[1] $k[2]
        if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Root $d }
        if ($what -ceq 'state directory') { $d = $stateDir }
        $w = Test-VigilWritableDir $d
        if ($w.Ok) { & $ok "${what}: $d" } else { & $fail "${what}: not writable: $($w.Dir)" }
    }
    if ($env:VIGIL_FAULT) { & $fail 'VIGIL_FAULT is set: fault injection is for tests only (22.4.1)' }
    if ($env:VIGIL_TEST_IMDS) { & $fail 'VIGIL_TEST_IMDS is set: the metadata endpoint override is for tests only (22.4.2)' }
    if ($env:VIGIL_TEST_SSH_CONFIG) { & $fail 'VIGIL_TEST_SSH_CONFIG is set: the ssh configuration override is for tests only (22.4.3)' }

    $out.Add('')
    if ($n.Failed -gt 0) { $out.Add("precheck failed: $($n.Failed) problem(s)") }
    elseif ($warnings -gt 0) { $out.Add("precheck passed with $warnings warning(s)") }
    else { $out.Add('precheck passed') }
    return @{ Code = $(if ($n.Failed -gt 0) { 1 } else { 0 }); Lines = $out }
}
