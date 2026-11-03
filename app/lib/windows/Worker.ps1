#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

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
    Outcome.ps1, Metrics.ps1, Events.ps1 and Secrets.ps1.
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
        # To disk before the rename, so a power cut leaves the old file or the new
        # one, never an empty one.
        $fs.Flush($true)
    }
    finally { $fs.Dispose() }
    # Windows refuses to replace a file while another process has it open
    # without delete sharing, as the supervisor does for a moment while it
    # reads a state file, or a virus scanner might. Retried for up to five
    # seconds: a write given up on here would be lost without a trace, since
    # the callers run with ErrorActionPreference Continue.
    for ($try = 1; ; $try++) {
        try {
            # Replace, not Move: on .NET Framework, which Windows PowerShell 5.1
            # runs on, Move cannot overwrite.
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        }
        catch [System.IO.IOException] {
            if ($try -ge 50) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Seconds in a validated duration (30s, 5m, 2h, 7d).
function ConvertTo-VigilSeconds {
    param([string]$Duration)
    $n = [long]$Duration.Substring(0, $Duration.Length - 1)
    switch -CaseSensitive ($Duration[-1]) {
        's' { return $n }
        'm' { return $n * 60 }
        'h' { return $n * 3600 }
    }
    return $n * 86400
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

# The log file of a day in a directory to write to: the last one, or the
# next in sequence once it has reached [log] max_file_mb (13.1). Log files
# are never truncated or renamed.
function Get-VigilLogFile {
    param($Parsed, [string]$Dir, [string]$Day)
    $max = [long](Get-VigilConfigValue $Parsed 'log' 'max_file_mb' '50') * 1048576
    $n = 0
    $f = Join-Path $Dir "$Day.log"
    while ([System.IO.File]::Exists((Join-Path $Dir "$Day.$($n + 1).log"))) {
        $n++
        $f = Join-Path $Dir "$Day.$n.log"
    }
    if ([System.IO.File]::Exists($f) -and (New-Object System.IO.FileInfo $f).Length -ge $max) { $f = Join-Path $Dir "$Day.$($n + 1).log" }
    return $f
}

# Decodes a job's raw output with the encoding its console used, and writes
# it to a file as UTF-8, a piece at a time. With no raw file (the job never
# started), the file is written empty.
function Copy-VigilJobText {
    param([string]$Raw, $Encoding, [string]$To)
    $writer = New-Object System.IO.StreamWriter($To, $false, (New-Object System.Text.UTF8Encoding $false))
    try {
        if (-not $Encoding -or -not [System.IO.File]::Exists($Raw)) { return }
        # Byte order marks are honoured, as the console's own reader does.
        $reader = New-Object System.IO.StreamReader($Raw, $Encoding, $true)
        try {
            $buf = New-Object char[] 65536
            while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) { $writer.Write($buf, 0, $n) }
        }
        finally { $reader.Dispose() }
    }
    finally { $writer.Dispose() }
}

# Writes a job's output to its log, one "<prefix> <line>" each, a piece at a
# time: lines end at LF, a line's trailing CRs are dropped, and empty lines at
# the very end are left out.
function Write-VigilJobLines {
    param([string]$Path, $Encoding, [string]$Prefix, $Writer)
    if (-not $Encoding -or -not [System.IO.File]::Exists($Path)) { return }
    $reader = New-Object System.IO.StreamReader($Path, $Encoding, $true)
    try {
        $buf = New-Object char[] 65536
        $carry = ''
        # Empty lines are held back until a line with text follows them.
        $blank = 0
        $any = $false
        $wrote = $false
        while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) {
            $any = $true
            $parts = ($carry + [string]::new($buf, 0, $n)).Split("`n")
            $carry = $parts[$parts.Count - 1]
            for ($i = 0; $i -lt $parts.Count - 1; $i++) {
                if ($parts[$i].Length -eq 0) { $blank++; continue }
                for (; $blank -gt 0; $blank--) { $Writer.Write("$Prefix `r`n") }
                $Writer.Write("$Prefix $($parts[$i].TrimEnd("`r"))`r`n")
                $wrote = $true
            }
        }
        if ($carry.Length -gt 0) {
            for (; $blank -gt 0; $blank--) { $Writer.Write("$Prefix `r`n") }
            $Writer.Write("$Prefix $($carry.TrimEnd("`r"))`r`n")
        }
        # Output of nothing but line ends is one empty line.
        elseif ($any -and -not $wrote) { $Writer.Write("$Prefix `r`n") }
    }
    finally { $reader.Dispose() }
}

# Loads and validates the configuration and resolves the directories.
# Returns @{ Error } or the context the worker needs. With sources, a run
# uses the active configuration and its cached scripts (16.5): the ones it
# was launched with (-RunId), else those active now. The fetcher itself
# works from the local file.
function Get-VigilWorkerContext {
    param([string]$Root, [string]$Job, [string]$RunId)
    $parsed = ConvertFrom-VigilConfig -Path (Join-Path $Root 'config\vigil.config')
    $records = Test-VigilConfig -Parsed $parsed
    if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
        return @{ Error = 'the configuration has errors; run vigil precheck' }
    }
    $dir = {
        param($Section, $Key, $Default)
        $v = Get-VigilConfigValue $parsed $Section $Key $Default
        if ([System.IO.Path]::IsPathRooted($v)) { return $v }
        return Join-Path $Root $v
    }
    # The state directory is always the local file's (6.8).
    $state = & $dir 'vigil' 'state_dir' 'state'
    $config = ''
    $script = ''
    if ($Job -cne 'vigil_fetch' -and (Test-VigilFetchMode -Parsed $parsed)) {
        $launch = Join-Path $state "locks\$Job.$RunId.launch"
        if ($RunId -and [System.IO.File]::Exists($launch)) {
            foreach ($l in [System.IO.File]::ReadAllLines($launch)) {
                if ($l -cmatch '^config +=( (.*))?$') { $config = $Matches[2] }
                elseif ($l -cmatch '^script +=( (.*))?$') { $script = $Matches[2] }
            }
        }
        $active = Read-VigilActive -Root $Root -State $state
        if (-not $config) {
            if (-not $active) { return @{ Error = 'no configuration is active yet: the supervisor fetches it from its sources' } }
            $config = $active.Config
        }
        $parsed = ConvertFrom-VigilConfig -Path $config
        $records = Test-VigilConfig -Parsed $parsed
        if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
            return @{ Error = "the active configuration $config cannot be read" }
        }
        $src = Get-VigilConfigValue $parsed "job.$Job" 'source' ''
        if ($src -and -not $script) {
            if ($active) { $script = Get-VigilActiveScript -Root $Root -Active $active -Source $src -File (Get-VigilConfigValue $parsed "job.$Job" 'file' '') }
            if (-not $script) { return @{ Error = "the script of job '$Job' from source.$src is not fetched yet" } }
        }
    }
    if (@('vigil_sender', 'vigil_fetch', 'vigil_logs') -cnotcontains $Job -and -not ($parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })) {
        return @{ Error = "no job '$Job' in the configuration" }
    }
    foreach ($r in $records) {
        if ($r.Kind -ceq 'INVALID' -and $r.Job -ceq $Job) { return @{ Error = "job '$Job' is invalid: $($r.Message)" } }
    }
    return @{
        Error  = ''
        Parsed = $parsed
        State  = $state
        Logs   = & $dir 'log' 'dir' 'logs'
        Spool  = & $dir 'spool' 'dir' 'spool'
        Config = $config
        Script = $script
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
    if ($ctx.Config) { $text += "config        = $($ctx.Config)`n" }
    if ($ctx.Script) { $text += "script        = $($ctx.Script)`n" }
    Write-VigilFileAtomic -Path (Join-Path $locks "$Job.$rid.launch") -Text $text
    return $rid
}

function Invoke-VigilWorker {
    param([string]$Root, [string]$Job, [string]$RunId)

    $ctx = Get-VigilWorkerContext -Root $Root -Job $Job -RunId $RunId
    if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); return @{ Code = 4 } }
    $launch = Join-Path $ctx.State "locks\$Job.$RunId.launch"
    $token = Join-Path $ctx.State "locks\$Job.$RunId.token"
    $timeoutMarker = Join-Path $ctx.State "locks\$Job.$RunId.timeout"

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
        # CreateNew fails if a token already exists, and share mode None makes the
        # supervisor's probe see it held for as long as this worker lives.
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
    $log = Get-VigilLogFile -Parsed $ctx.Parsed -Dir $jobLogs -Day (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $statePath = Join-Path $jobs "$Job.state"
    $hostName = $env:COMPUTERNAME.ToLowerInvariant()
    $now = Get-VigilNow
    $started = $now.Epoch
    $self = Get-Process -Id $PID

    # Vigil's own workers run a function, not a job command (4.5).
    if (@('vigil_sender', 'vigil_fetch', 'vigil_logs') -ccontains $Job) {
        $state = [ordered]@{
            schema_version = 1; job = $Job; run_id = $RunId; status = 'running'; reason = ''
            boot_id = Get-VigilBootId; started_epoch = $started; started_at = $now.Iso
            worker_pid = $PID; worker_name = "$($self.ProcessName).exe"; worker_start = ConvertTo-VigilEpoch $self.StartTime
        }
        Write-VigilStateFile -Path $statePath -Fields $state
        [System.IO.File]::AppendAllText($log, "$($now.Iso) $RunId run start`r`n")
        try {
            if ($Job -ceq 'vigil_fetch') { $r = Invoke-VigilFetch -Ctx $ctx -HostName $hostName -Root $Root -Log $log -RunId $RunId }
            elseif ($Job -ceq 'vigil_logs') { $r = Invoke-VigilLogs -Ctx $ctx -HostName $hostName -Root $Root -Log $log -RunId $RunId }
            else { $r = Invoke-VigilSend -Ctx $ctx -HostName $hostName -Root $Root }
        }
        catch { $r = @{ Ok = $false; Reason = "$($Job.Substring(6)) error: $($_.Exception.Message)" } }
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
    $maxRuntime = ''
    $missing = @()
    $envPairs = @()
    $required = @()
    $secretRows = @()
    foreach ($row in $eff) {
        switch -CaseSensitive ($row.Key) {
            'exit_codes' { $exitCodes = $row.Value }
            'max_runtime' { $maxRuntime = $row.Value }
            'require_env' { $required += $row.Value }
            'secret' { $secretRows += $row.Value }
            'env' { $envPairs += $row.Value }
        }
    }

    # Secrets for the job (6.5.4), resolved now, for this run only. A secret
    # that cannot be resolved fails the run before it starts; the reason
    # names the reference, never a value.
    $secretValues = [ordered]@{}
    $secretError = ''
    foreach ($s in $secretRows) {
        $eq = $s.IndexOf('=')
        $ref = $s.Substring($eq + 1)
        $r = Resolve-VigilSecret -Root $Root -Parsed $ctx.Parsed -Reference $ref
        if (-not $r.Ok) { $secretError = "secret $ref unavailable: $($r.Why)"; break }
        $secretValues[$s.Substring(0, $eq)] = $r.Value
    }
    # require_env counts the variables those secrets provide, and reads the
    # registry now, so a variable set since Vigil started is seen (6.5.1).
    $freshEnv = [ordered]@{}
    foreach ($name in $required) {
        if ($secretValues.Contains($name)) { continue }
        $v = Get-VigilFreshEnv $name
        if ($null -eq $v) { $missing += $name } else { $freshEnv[$name] = $v }
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
        deadline_epoch = $(if ($maxRuntime) { $started + (ConvertTo-VigilSeconds $maxRuntime) } else { '' })
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
    $rawOut = Join-Path $jobLogs "$RunId.out.raw"
    $rawErr = Join-Path $jobLogs "$RunId.err.raw"
    $outEncoding = $null
    $errEncoding = $null
    # A script from a source runs from its cached copy (16.5).
    $cmd = Get-VigilJobCommand -Index $index -Id $Job -Platform 'windows' -Root $Root -Cached $ctx.Script
    $file = (Get-VigilIndexValue -Index $index -Section "job.$Job" -Key 'file').Value
    $filePath = Resolve-VigilPath -Path $file -Platform 'windows' -Root $Root
    if ($ctx.Script) { $filePath = $ctx.Script }
    if ($cmd.Error) { $reason = $cmd.Message }
    elseif ($secretError) { $reason = $secretError }
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
        foreach ($k in $freshEnv.Keys) { $psi.EnvironmentVariables[$k] = $freshEnv[$k] }
        foreach ($pair in $envPairs) {
            $eq = $pair.IndexOf('=')
            $psi.EnvironmentVariables[$pair.Substring(0, $eq)] = $pair.Substring($eq + 1)
        }
        # Secrets last: only in this process's environment, never on its
        # command line or on disk.
        foreach ($k in $secretValues.Keys) { $psi.EnvironmentVariables[$k] = $secretValues[$k] }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $startError = ''
        try { [void]$p.Start() }
        catch { $startError = $_.Exception.InnerException.Message; if (-not $startError) { $startError = $_.Exception.Message } }
        if ($startError) { $reason = "could not start: $startError" }
        else {
            # No input: a job that asks for some gets end of file at once instead of
            # waiting for ever.
            $p.StandardInput.Close()
            # Output goes to files as it comes, as on Linux and macOS, so a job
            # that prints a lot never costs the worker that much memory. Both
            # streams are copied at once, so a job filling one cannot block on
            # the other. The bytes are kept as they are and decoded once the job
            # ends, with the encoding the console would have used.
            $outEncoding = $p.StandardOutput.CurrentEncoding
            $errEncoding = $p.StandardError.CurrentEncoding
            $outFile = [System.IO.File]::Open($rawOut, 'Create', 'Write', 'Read')
            $errFile = [System.IO.File]::Open($rawErr, 'Create', 'Write', 'Read')
            $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outFile)
            $errTask = $p.StandardError.BaseStream.CopyToAsync($errFile)
            $state.job_pid = $p.Id
            # The process's own name (cmd.exe for a .cmd file), which is what
            # ownership is checked against before any kill (11.5).
            try { $state.job_name = "$($p.ProcessName).exe" } catch { $state.job_name = [System.IO.Path]::GetFileName($cmd.Program) }
            try { $state.job_start = ConvertTo-VigilEpoch $p.StartTime } catch { $state.job_start = '' }
            Write-VigilStateFile -Path $statePath -Fields $state
            $p.WaitForExit()
            try { $outTask.Wait(); $errTask.Wait() }
            finally { $outFile.Dispose(); $errFile.Dispose() }
            $code = "$($p.ExitCode)"
            $outcome = Get-VigilOutcome -ExitCodes $exitCodes -Code $code
            if ($outcome -cne 'succeeded') { $reason = "exit code $code" }
            # The supervisor writes a marker before it stops a run for
            # overrunning max_runtime (11.6): whatever the exit code, it timed out.
            if ([System.IO.File]::Exists($timeoutMarker)) { $outcome = 'timed_out'; $reason = "stopped after max_runtime $maxRuntime" }
        }
    }

    $now = Get-VigilNow
    $duration = $now.Epoch - $started

    # Standard output as UTF-8 text, for the metrics parser and the job log.
    $out = Join-Path $jobLogs "$RunId.out"
    Copy-VigilJobText -Raw $rawOut -Encoding $outEncoding -To $out

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
    # The job log (13.1): its output, then how it ended.
    $writer = New-Object System.IO.StreamWriter($log, $true, (New-Object System.Text.UTF8Encoding $false))
    try {
        Write-VigilJobLines -Path $out -Encoding (New-Object System.Text.UTF8Encoding $false) -Prefix "$($now.Iso) $RunId out" -Writer $writer
        Write-VigilJobLines -Path $rawErr -Encoding $errEncoding -Prefix "$($now.Iso) $RunId err" -Writer $writer
        if ($reason) { $writer.Write("$($now.Iso) $RunId run end $outcome ($reason) in ${duration}s`r`n") }
        else { $writer.Write("$($now.Iso) $RunId run end $outcome in ${duration}s`r`n") }
    }
    finally { $writer.Dispose() }
    foreach ($f in @($out, $rawOut, $rawErr)) { if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) } }
    if ([System.IO.File]::Exists($timeoutMarker)) { [System.IO.File]::Delete($timeoutMarker) }

    # Release the token: close it, then delete it (4.3, step 9).
    $tokenStream.Dispose()
    [System.IO.File]::Delete($token)

    $rc = switch ($outcome) { 'succeeded' { 0 } 'warning' { 1 } 'unknown' { 3 } default { 2 } }
    return @{ Code = $rc; Outcome = $outcome; Reason = $reason; Duration = $duration }
}
