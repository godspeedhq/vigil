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
    Secrets.ps1 and Worker.ps1.
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
    $failed = 0
    $ok = { param($What) $out.Add("  ok    $What") }
    $fail = { param($What) $out.Add("  FAIL  $What"); Set-Variable -Name failed -Scope 1 -Value ($failed + 1) }

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
    $failed = $errors + $invalid
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
    if ((Get-VigilConfigValue $parsed 'vigil' 'config_source' '').Length -gt 0) {
        & $fail 'remote configuration needs the fetcher, which is not available yet'
    }
    else {
        foreach ($sec in $parsed.Sections) {
            if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            $id = $sec.Name.Substring(4)
            if (($Job -and $id -cne $Job) -or (& $isInvalid $id)) { continue }
            # Everything one run needs, as the worker checks it (4.3).
            $before = $failed
            $cmd = Get-VigilJobCommand -Index $index -Id $id -Platform 'windows' -Root $Root
            if ($cmd.Error) { & $fail "job.${id}: $($cmd.Message)"; continue }
            if (-not [System.IO.Directory]::Exists($cmd.Cwd)) { & $fail "job.${id}: working directory not found: $($cmd.Cwd)" }
            if ($cmd.Program.Contains('\')) {
                if (-not [System.IO.File]::Exists($cmd.Program)) { & $fail "job.${id}: not found: $($cmd.Program)" }
            }
            elseif (-not (Get-Command $cmd.Program -CommandType Application -ErrorAction SilentlyContinue)) { & $fail "job.${id}: not found: $($cmd.Program)" }
            $file = Resolve-VigilPath -Path (Get-VigilIndexValue -Index $index -Section "job.$id" -Key 'file').Value -Platform 'windows' -Root $Root
            if (-not [System.IO.File]::Exists($file)) { & $fail "job.${id}: file not found: $file" }
            $eff = Get-VigilEffectiveJob -Index $index -Id $id
            $provided = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($row in $eff) {
                if ($row.Key -cne 'secret') { continue }
                $eq = $row.Value.IndexOf('=')
                $ref = $row.Value.Substring($eq + 1)
                $r = Resolve-VigilSecret -Root $Root -Parsed $parsed -Reference $ref
                if ($r.Ok) { [void]$provided.Add($row.Value.Substring(0, $eq)) }
                else { & $fail "job.${id}: secret $ref unavailable: $($r.Why)" }
                $r = $null
            }
            foreach ($row in $eff) {
                if ($row.Key -cne 'require_env' -or $provided.Contains($row.Value)) { continue }
                if ($null -eq (Get-VigilFreshEnv $row.Value)) { & $fail "job.${id}: missing environment variable $($row.Value)" }
            }
            if ($failed -eq $before) { & $ok "job.$id" }
        }
    }

    # Credentials of backends and secret stores: resolved, never shown.
    foreach ($e in $parsed.Entries) {
        if (-not ($e.Section.StartsWith('backend.', [System.StringComparison]::Ordinal) -or $e.Section.StartsWith('secret_store.', [System.StringComparison]::Ordinal))) { continue }
        if ($e.Value -cnotmatch '^(env|secret|store):') { continue }
        $r = Resolve-VigilSecret -Root $Root -Parsed $parsed -Reference $e.Value
        if ($r.Ok) { & $ok "$($e.Section): $($e.Key) $($e.Value)" }
        else { & $fail "$($e.Section): $($e.Key) $($e.Value) unavailable: $($r.Why)" }
        $r = $null
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
        $w = Test-VigilWritableDir $d
        if ($w.Ok) { & $ok "${what}: $d" } else { & $fail "${what}: not writable: $($w.Dir)" }
    }
    if ($env:VIGIL_FAULT) { & $fail 'VIGIL_FAULT is set: fault injection is for tests only (22.4.1)' }
    if ($env:VIGIL_TEST_IMDS) { & $fail 'VIGIL_TEST_IMDS is set: the metadata endpoint override is for tests only (22.4.2)' }

    $out.Add('')
    if ($failed -gt 0) { $out.Add("precheck failed: $failed problem(s)") }
    elseif ($warnings -gt 0) { $out.Add("precheck passed with $warnings warning(s)") }
    else { $out.Add('precheck passed') }
    return @{ Code = $(if ($failed -gt 0) { 1 } else { 0 }); Lines = $out }
}
