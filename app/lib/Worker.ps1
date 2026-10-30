#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil worker - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    Runs one job once, end to end (SPECIFICATION.md 4.3): claims its launch
    record, records its state, runs the job through its runner, captures its
    output to the job log, classifies the outcome, writes the run's events
    to the spool, writes the final state and releases its run token.

    New-VigilLaunch -Root <dir> -Job <id>
        Writes a launch record for a new run, as the supervisor does before
        it starts a worker. Returns the run id, or $null with a message on
        stderr.
    Invoke-VigilWorker -Root <dir> -Job <id> -RunId <run id>
        Returns @{ Code; Outcome; Reason; Duration }. Code is 0 succeeded,
        1 warning, 2 failed, 3 unknown, and 4 when the launch was abandoned
        or the configuration could not be read (the job did not run).

    Windows only; worker.sh is the Linux and macOS worker. The run token is
    held open exclusively for the worker's whole life (11.2).

    Requires Config.ps1, Validate.ps1, Effective.ps1, Command.ps1,
    Outcome.ps1, Metrics.ps1 and Events.ps1.
#>

# Single-line, at most 500 characters (12.2).
function Get-VigilStateValue {
    param([string]$Value)
    $v = $Value.Replace("`r", ' ').Replace("`n", ' ')
    if ($v.Length -gt 500) { $v = $v.Substring(0, 500) }
    return $v
}

# Atomically writes a [state] file from an ordered dictionary (12.3): a
# temporary file in the same directory, flushed to disk, then renamed over
# the target.
function Write-VigilStateFile {
    param([string]$Path, $Fields)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("[state]`n")
    foreach ($k in $Fields.Keys) {
        [void]$sb.Append(('{0,-16} = {1}' -f $k, (Get-VigilStateValue ([string]$Fields[$k]))).TrimEnd() + "`n")
    }
    Write-VigilFileAtomic -Path $Path -Text $sb.ToString()
}

function Write-VigilFileAtomic {
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp.$PID"
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
    $fs = [System.IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    }
    finally { $fs.Dispose() }
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $Path) }
}

function Get-VigilNow {
    $now = [DateTime]::UtcNow
    $epoch = ConvertTo-VigilEpoch $now
    return @{ Epoch = $epoch; Iso = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
}

function ConvertTo-VigilEpoch {
    param([DateTime]$Time)
    $epoch0 = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [long][Math]::Floor(($Time.ToUniversalTime() - $epoch0).TotalSeconds)
}

# Windows has no kernel boot id; it is derived from the boot time (11.1).
function Get-VigilBootId {
    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        return "boot-$(ConvertTo-VigilEpoch $boot)"
    }
    catch { return '' }
}

# The first value of a key in a section, or a default.
function Get-VigilConfigValue {
    param($Parsed, [string]$Section, [string]$Key, [string]$Default)
    foreach ($e in $Parsed.Entries) {
        if ($e.Section -ceq $Section -and $e.Key -ceq $Key) { return $e.Value }
    }
    return $Default
}

# Loads and validates the configuration and resolves the directories.
# Returns @{ Error } or the context the worker needs.
function Get-VigilWorkerContext {
    param([string]$Root, [string]$Job)
    $parsed = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
    $records = Test-VigilConfig -Parsed $parsed
    if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
        return @{ Error = 'the configuration has errors; run vigil precheck' }
    }
    if ((Get-VigilConfigValue $parsed 'vigil' 'config_source' '').Length -gt 0) {
        return @{ Error = 'remote configuration needs the fetcher, which is not available yet' }
    }
    if ($Job -cne 'vigil_sender' -and -not ($parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })) {
        return @{ Error = "no job '$Job' in the configuration" }
    }
    foreach ($r in $records) {
        if ($r.Kind -ceq 'INVALID' -and $r.Job -ceq $Job) { return @{ Error = "job '$Job' is invalid: $($r.Message)" } }
    }
    $dir = {
        param($Section, $Key, $Default)
        $v = Get-VigilConfigValue $parsed $Section $Key $Default
        if ([System.IO.Path]::IsPathRooted($v)) { return $v }
        return Join-Path $Root $v
    }
    return @{
        Error  = ''
        Parsed = $parsed
        State  = & $dir 'vigil' 'state_dir' 'state'
        Logs   = & $dir 'log' 'dir' 'logs'
        Spool  = & $dir 'spool' 'dir' 'spool'
    }
}

function New-VigilLaunch {
    param([string]$Root, [string]$Job)
    $ctx = Get-VigilWorkerContext -Root $Root -Job $Job
    if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); return $null }
    $now = Get-VigilNow
    $rid = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture))-$PID"
    $locks = Join-Path $ctx.State 'locks'
    [void](New-Item -ItemType Directory -Force -Path $locks)
    $text = "[launch]`njob           = $Job`nrun_id        = $rid`nboot_id       = $(Get-VigilBootId)`nlaunch_epoch  = $($now.Epoch)`nlaunch_at     = $($now.Iso)`n"
    Write-VigilFileAtomic -Path (Join-Path $locks "$Job.$rid.launch") -Text $text
    return $rid
}

function Invoke-VigilWorker {
    param([string]$Root, [string]$Job, [string]$RunId)

    $ctx = Get-VigilWorkerContext -Root $Root -Job $Job
    if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); return @{ Code = 4 } }
    $launch = Join-Path $ctx.State "locks\$Job.$RunId.launch"
    $token = Join-Path $ctx.State "locks\$Job.$RunId.token"

    # Claim (11.2), hand over hand: hold the launch record exclusively,
    # create and hold the token exclusively, then close and delete the
    # launch record. If the supervisor deleted the launch first, the job
    # does not run.
    $tokenStream = $null
    try {
        # Another process may have the launch record open for a moment (an
        # antivirus scan, a supervisor probe): retry briefly. A missing
        # record means the launch was abandoned, and fails at once.
        $launchStream = $null
        for ($try = 1; -not $launchStream; $try++) {
            try { $launchStream = [System.IO.File]::Open($launch, 'Open', 'Read', 'None') }
            catch [System.IO.FileNotFoundException] { throw }
            catch [System.IO.IOException] { if ($try -ge 20) { throw }; Start-Sleep -Milliseconds 100 }
        }
        try { $tokenStream = [System.IO.File]::Open($token, 'CreateNew', 'ReadWrite', 'None') }
        finally { $launchStream.Dispose() }
        [System.IO.File]::Delete($launch)
    }
    catch {
        if ($tokenStream) { $tokenStream.Dispose(); [System.IO.File]::Delete($token) }
        [Console]::Error.WriteLine("vigil: launch $RunId of $Job was abandoned; not running")
        return @{ Code = 4 }
    }

    $jobs = Join-Path $ctx.State 'jobs'
    $jobLogs = Join-Path $ctx.Logs "jobs\$Job"
    $incoming = Join-Path $ctx.Spool 'incoming'
    foreach ($d in @($jobs, $jobLogs, $incoming)) { [void](New-Item -ItemType Directory -Force -Path $d) }
    $log = Join-Path $jobLogs "$((Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).log"
    $statePath = Join-Path $jobs "$Job.state"
    $hostName = $env:COMPUTERNAME.ToLowerInvariant()
    $now = Get-VigilNow
    $started = $now.Epoch
    $self = Get-Process -Id $PID

    # Vigil's own workers run a function, not a job command (4.5).
    if ($Job -ceq 'vigil_sender') {
        $state = [ordered]@{
            schema_version = 1; job = $Job; run_id = $RunId; status = 'running'; reason = ''
            boot_id = Get-VigilBootId; started_epoch = $started; started_at = $now.Iso
            worker_pid = $PID; worker_name = "$($self.ProcessName).exe"; worker_start = ConvertTo-VigilEpoch $self.StartTime
        }
        Write-VigilStateFile -Path $statePath -Fields $state
        [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId run start`r`n")
        try { $r = Invoke-VigilSend -Ctx $ctx -HostName $hostName -Root $Root }
        catch { $r = @{ Ok = $false; Reason = "sender error: $($_.Exception.Message)" } }
        $status = if ($r.Ok) { 'succeeded' } else { 'failed' }
        $now = Get-VigilNow
        $duration = $now.Epoch - $started
        $state.status = $status
        $state.reason = $r.Reason
        $state.ended_epoch = $now.Epoch
        $state.ended_at = $now.Iso
        $state.duration_seconds = $duration
        Write-VigilStateFile -Path $statePath -Fields $state
        $why = if ($r.Reason) { " ($($r.Reason))" } else { '' }
        [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId run end $status$why in ${duration}s`r`n")
        $tokenStream.Dispose()
        [System.IO.File]::Delete($token)
        return @{ Code = $(if ($r.Ok) { 0 } else { 2 }); Outcome = $status; Reason = $r.Reason; Duration = $duration }
    }

    $index = New-VigilConfigIndex -Parsed $ctx.Parsed
    $eff = Get-VigilEffectiveJob -Index $index -Id $Job
    $exitCodes = 'standard'
    $missing = @()
    $envPairs = @()
    foreach ($row in $eff) {
        switch -CaseSensitive ($row.Key) {
            'exit_codes' { $exitCodes = $row.Value }
            'require_env' {
                if ($null -eq [Environment]::GetEnvironmentVariable($row.Value)) { $missing += $row.Value }
            }
            'env' { $envPairs += $row.Value }
        }
    }
    $mode = if ($exitCodes -ceq 'nagios') { 'nagios' } else { 'standard' }

    $state = [ordered]@{
        schema_version = 1
        job            = $Job
        run_id         = $RunId
        instance       = Get-VigilConfigValue $ctx.Parsed 'vigil' 'instance' 'vigil'
        status         = 'running'
        reason         = ''
        boot_id        = Get-VigilBootId
        started_epoch  = $started
        started_at     = $now.Iso
        worker_pid     = $PID
        worker_name    = "$($self.ProcessName).exe"
        worker_start   = ConvertTo-VigilEpoch $self.StartTime
    }
    Write-VigilStateFile -Path $statePath -Fields $state
    $logLines = New-Object System.Text.StringBuilder
    [void]$logLines.Append("$($now.Iso) $RunId run start`r`n")
    [System.IO.File]::AppendAllText($log, $logLines.ToString())

    $code = '-'
    $outcome = 'failed'
    $reason = ''
    $stdout = ''
    $stderr = ''
    $cmd = Get-VigilJobCommand -Index $index -Id $Job -Platform 'windows' -Root $Root
    $file = (Get-VigilIndexValue -Index $index -Section "job.$Job" -Key 'file').Value
    $filePath = Resolve-VigilPath -Path $file -Platform 'windows' -Root $Root
    if ($cmd.Error) { $reason = $cmd.Message }
    elseif ($missing.Count -gt 0) { $reason = "missing environment variable $($missing -join ' ')" }
    elseif (-not [System.IO.Directory]::Exists($cmd.Cwd)) { $reason = "working directory not found: $($cmd.Cwd)" }
    elseif (-not [System.IO.File]::Exists($filePath)) { $reason = "file not found: $filePath" }
    elseif ($cmd.Program.Contains('\') -and -not [System.IO.File]::Exists($cmd.Program)) { $reason = "not found: $($cmd.Program)" }
    elseif (-not $cmd.Program.Contains('\') -and -not (Get-Command $cmd.Program -CommandType Application -ErrorAction SilentlyContinue)) {
        $reason = "not found: $($cmd.Program)"
    }

    if ($reason.Length -eq 0) {
        # Run the job directly, never through a shell, with its environment.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $cmd.Program
        $psi.Arguments = $cmd.Line
        $psi.WorkingDirectory = $cmd.Cwd
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['VIGIL_RUN_ID'] = $RunId
        foreach ($pair in $envPairs) {
            $eq = $pair.IndexOf('=')
            $psi.EnvironmentVariables[$pair.Substring(0, $eq)] = $pair.Substring($eq + 1)
        }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $startError = ''
        try { [void]$p.Start() }
        catch { $startError = $_.Exception.InnerException.Message; if (-not $startError) { $startError = $_.Exception.Message } }
        if ($startError) { $reason = "could not start: $startError" }
        else {
            $p.StandardInput.Close()
            # Both streams are read concurrently, so a job filling one cannot
            # block on the other.
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            $state.job_pid = $p.Id
            $state.job_name = [System.IO.Path]::GetFileName($cmd.Program)
            try { $state.job_start = ConvertTo-VigilEpoch $p.StartTime } catch { $state.job_start = '' }
            Write-VigilStateFile -Path $statePath -Fields $state
            $p.WaitForExit()
            $stdout = $outTask.Result
            $stderr = $errTask.Result
            $code = "$($p.ExitCode)"
            $outcome = Get-VigilOutcome -ExitCodes $exitCodes -Code $code
            if ($outcome -cne 'succeeded') { $reason = "exit code $code" }
        }
    }

    $now = Get-VigilNow
    $duration = $now.Epoch - $started

    # The job log (13.1): its output, then how it ended.
    $out = Join-Path $jobLogs "$RunId.out"
    [System.IO.File]::WriteAllText($out, $stdout, (New-Object System.Text.UTF8Encoding $false))
    $logLines = New-Object System.Text.StringBuilder
    foreach ($pair in @(@('out', $stdout), @('err', $stderr))) {
        if ($pair[1].Length -eq 0) { continue }
        foreach ($l in $pair[1].TrimEnd("`n").Split("`n")) { [void]$logLines.Append("$($now.Iso) $RunId $($pair[0]) $($l.TrimEnd("`r"))`r`n") }
    }

    $output = ConvertFrom-VigilJobOutput -Mode $mode -Cap $Script:VigilMetricLinesMax -Path $out
    $events = Get-VigilRunEvents -Parsed $ctx.Parsed -Id $Job -Epoch "$($now.Epoch)" -Outcome $outcome -ExitCode $code `
        -Duration "$duration" -HostName $hostName -Os 'windows' -Output $output

    # Events before the final state (4.3, step 7).
    $stem = "$($now.Epoch)-$Job-$RunId.events"
    Write-VigilFileAtomic -Path (Join-Path $incoming $stem) -Text (($events | ForEach-Object { "$_`n" }) -join '')

    $state.status = $outcome
    $state.reason = $reason
    $state.ended_epoch = $now.Epoch
    $state.ended_at = $now.Iso
    $state.duration_seconds = $duration
    $state.exit_code = if ($code -ceq '-') { '' } else { $code }
    $state.metric_lines = $output.Lines
    $state.invalid_lines = $output.Invalid
    $state.dropped_lines = $output.Dropped
    $state.spool_file = $stem
    Write-VigilStateFile -Path $statePath -Fields $state
    if ($reason) { [void]$logLines.Append("$($now.Iso) $RunId run end $outcome ($reason) in ${duration}s`r`n") }
    else { [void]$logLines.Append("$($now.Iso) $RunId run end $outcome in ${duration}s`r`n") }
    [System.IO.File]::AppendAllText($log, $logLines.ToString())
    [System.IO.File]::Delete($out)

    # Release the token: close it, then delete it (4.3, step 9).
    $tokenStream.Dispose()
    [System.IO.File]::Delete($token)

    $rc = switch ($outcome) { 'succeeded' { 0 } 'warning' { 1 } 'unknown' { 3 } default { 2 } }
    return @{ Code = $rc; Outcome = $outcome; Reason = $reason; Duration = $duration }
}
