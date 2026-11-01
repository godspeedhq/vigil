#Requires -Version 5.1

<#
.SYNOPSIS
    Vigil supervisor - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    The long-running tick loop the service manager runs (SPECIFICATION.md
    4.1). Each tick it reloads the configuration when it changed, accounts
    for every job's latest run (11.3), reaches each job's schedule decision
    (7.9), admits due runs within max_concurrent (8), launches each as a
    detached worker (4.3), and writes jobs.log (13.2) and its own events.

    Invoke-VigilSupervisor -Root <dir> -App <app dir> [-Once]
        Returns 1 when another supervisor owns the state directory or the
        configuration cannot be loaded at startup, else 0.

    Windows only; supervisor.sh is the Linux and macOS supervisor. The
    supervisor lock is held open exclusively for its whole life (12.4).

    Requires Config.ps1, Validate.ps1, Effective.ps1, Command.ps1,
    Schedule.ps1, Outcome.ps1, Metrics.ps1, Events.ps1, Recovery.ps1,
    Worker.ps1 and Precheck.ps1.
#>

$Script:VigilLaunchGrace = 120

# Whether another process holds a file open: Windows refuses an exclusive
# open while it does. Returns yes, no or error.
function Test-VigilFileHeld {
    param([string]$Path)
    try {
        $s = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $s.Dispose()
        return 'no'
    }
    catch [System.IO.FileNotFoundException] { return 'no' }
    catch [System.IO.IOException] { return 'yes' }
    catch { return 'error' }
}

# Whether a process carries a run id on its command line: yes, no or error.
function Test-VigilRunProcess {
    param([string]$RunId)
    try {
        $p = @(Get-CimInstance -ClassName Win32_Process -Filter "CommandLine LIKE '%--run-id $RunId%'" -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID })
        if ($p.Count -gt 0) { return 'yes' }
        return 'no'
    }
    catch { return 'error' }
}

# Reads a state file: @{ Kind (missing, unreadable, running, final);
# Status; RunId; Boot; Started }.
function Read-VigilRunState {
    param([string]$Path)
    $r = @{ Kind = 'missing'; Status = ''; RunId = ''; Boot = ''; Started = ''; Deadline = ''; JobPid = ''; JobName = ''; JobStart = ''; WorkerPid = '' }
    if (-not [System.IO.File]::Exists($Path)) { return $r }
    $r.Kind = 'unreadable'
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return $r }
    if ($lines.Count -eq 0 -or $lines[0].TrimEnd() -cne '[state]') { return $r }
    foreach ($l in $lines) {
        $eq = $l.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $l.Substring(0, $eq).Trim()
        $v = $l.Substring($eq + 1).Trim()
        switch -CaseSensitive ($k) {
            'schema_version' { if ($v -cne '1') { return $r } }
            'status' { $r.Status = $v }
            'run_id' { $r.RunId = $v }
            'boot_id' { $r.Boot = $v }
            'started_epoch' { $r.Started = $v }
            'deadline_epoch' { $r.Deadline = $v }
            'job_pid' { $r.JobPid = $v }
            'job_name' { $r.JobName = $v }
            'job_start' { $r.JobStart = $v }
            'worker_pid' { $r.WorkerPid = $v }
        }
    }
    if ($r.Status -ceq 'running') { $r.Kind = 'running' }
    elseif (@('succeeded', 'warning', 'failed', 'unknown', 'timed_out', 'crashed') -ccontains $r.Status) { $r.Kind = 'final' }
    return $r
}

# The outcome in a run's spool file, if any: @{ Found; Outcome; File }.
function Find-VigilSpoolOutcome {
    param([string]$Spool, [string]$Job, [string]$RunId)
    $r = @{ Found = $false; Outcome = ''; File = '' }
    $dirs = @(Join-Path $Spool 'incoming')
    $backends = Join-Path $Spool 'backends'
    if ([System.IO.Directory]::Exists($backends)) { $dirs += [System.IO.Directory]::GetDirectories($backends) }
    foreach ($d in $dirs) {
        if (-not [System.IO.Directory]::Exists($d)) { continue }
        foreach ($f in [System.IO.Directory]::GetFiles($d, "*-$Job-$RunId.events")) {
            # The sender may move the file on between listing and reading.
            try { $lines = [System.IO.File]::ReadAllLines($f) } catch { continue }
            foreach ($l in $lines) {
                $name = ($l.Split(' '))[1]
                if ($name.EndsWith('.succeeded')) { $r.Outcome = 'succeeded' }
                elseif ($name.EndsWith('.warnings')) { $r.Outcome = 'warning' }
                elseif ($name.EndsWith('.failures')) { $r.Outcome = 'failed' }
            }
            if ($r.Outcome) { $r.Found = $true; $r.File = [System.IO.Path]::GetFileName($f); return $r }
        }
    }
    return $r
}

# Reads a job's recovery record (11.4) and any resolution vigil resolve left
# beside it: @{ RunId (empty when none); Conclusion; Reason; First; Policy;
# ResolvedBy; ResolvedAt }.
function Read-VigilRecoveryRecord {
    param([string]$State, [string]$Job)
    $r = @{ RunId = ''; Conclusion = ''; Reason = ''; First = ''; Policy = ''; ResolvedBy = ''; ResolvedAt = '' }
    foreach ($f in @((Join-Path $State "recovery\$Job.recovery"), (Join-Path $State "recovery\$Job.resolved"))) {
        if (-not [System.IO.File]::Exists($f)) { continue }
        try { $lines = [System.IO.File]::ReadAllLines($f) } catch { continue }
        foreach ($l in $lines) {
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $v = $l.Substring($eq + 1).Trim()
            switch -CaseSensitive ($l.Substring(0, $eq).Trim()) {
                'run_id' { $r.RunId = $v }
                'conclusion' { $r.Conclusion = $v }
                'reason' { $r.Reason = $v }
                'first_seen' { $r.First = $v }
                'policy' { $r.Policy = $v }
                'resolved_by' { $r.ResolvedBy = $v }
                'resolved_at' { $r.ResolvedAt = $v }
            }
        }
    }
    return $r
}

# Writes a job's recovery record, keeping first_seen and any resolution.
function Write-VigilRecoveryRecord {
    param([string]$State, [string]$Job, [string]$RunId, [string]$Conclusion, [string]$Reason, [string]$Policy, $Rec, [long]$Epoch)
    $dir = Join-Path $State 'recovery'
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $first = if ($Rec.First) { $Rec.First } else { "$Epoch" }
    Write-VigilFileAtomic -Path (Join-Path $dir "$Job.recovery") -Text (
        "[recovery]`njob          = $Job`nrun_id       = $RunId`nconclusion   = $Conclusion`nreason       = $Reason`n" +
        "first_seen   = $first`nlast_checked = $Epoch`npolicy       = $Policy`nresolved_by  = $($Rec.ResolvedBy)`nresolved_at  = $($Rec.ResolvedAt)`n")
}

function Invoke-VigilSupervisor {
    param([string]$Root, [string]$App, [switch]$Once)

    $sv = @{
        Root = $Root; Prev = '-'; Pending = New-Object 'System.Collections.Generic.List[string]'
        Queued = New-Object 'System.Collections.Generic.HashSet[string]'; Seq = 0; Sum = ''
        ReloadFailed = 0; Valid = ''; Parsed = $null; Records = $null; Index = $null; Report = @()
        HostName = $env:COMPUTERNAME.ToLowerInvariant(); Boot = Get-VigilBootId
    }
    $shell = (Get-Process -Id $PID).Path

    $log = {
        param([string]$Level, [string]$Message)
        try {
            $dir = Join-Path $sv.Logs 'supervisor'
            [void](New-Item -ItemType Directory -Force -Path $dir)
            [System.IO.File]::AppendAllText((Join-Path $dir "$($sv.Date).log"), "$($sv.Iso) $Level supervisor $Message`r`n")
        }
        catch { }
    }

    # The settings of the active configuration; the state directory is
    # always the local file's.
    $apply = {
        param($Parsed, $Records)
        $sv.Parsed = $Parsed
        $sv.Records = $Records
        $sv.Index = New-VigilConfigIndex -Parsed $Parsed
        $dir = {
            param($Section, $Key, $Default)
            $v = Get-VigilConfigValue $Parsed $Section $Key $Default
            if ([System.IO.Path]::IsPathRooted($v)) { return $v }
            return Join-Path $sv.Root $v
        }
        $sv.Logs = & $dir 'log' 'dir' 'logs'
        $sv.Spool = & $dir 'spool' 'dir' 'spool'
        $sv.Instance = Get-VigilConfigValue $Parsed 'vigil' 'instance' 'vigil'
        $sv.Max = [int](Get-VigilConfigValue $Parsed 'vigil' 'max_concurrent' '5')
        $sv.MaxPending = [int](Get-VigilConfigValue $Parsed 'scheduler' 'max_pending' '20')
        $tick = Get-VigilConfigValue $Parsed 'scheduler' 'tick' '60s'
        $n = [int]$tick.Substring(0, $tick.Length - 1)
        $sv.Tick = switch ($tick[-1]) { 's' { $n } 'm' { $n * 60 } 'h' { $n * 3600 } default { $n * 86400 } }
        $tags = "host=$($sv.HostName) os=windows instance=$($sv.Instance)"
        foreach ($e in $Parsed.Entries) { if ($e.Section -ceq 'tags') { $tags += " $($e.Key)=$($e.Value)" } }
        $sv.Tags = $tags
    }

    # Loads the configuration when it changed. An invalid one is rejected
    # and the last valid one stays active (16.3): kept in state\config.valid,
    # or with sources, the one state\config.active names (16.5).
    $loadConfig = {
        $path = Join-Path $sv.Root 'config\vigil.config'
        $sum = ''
        try { $sum = Get-VigilFileSha $path } catch { }
        if ($sum -cne $sv.Sum -or -not $sv.Mode) {
            $sv.Sum = $sum
            $parsed = ConvertFrom-VigilConfig -Path $path
            $records = Test-VigilConfig -Parsed $parsed
            if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
                $err = 'the configuration has errors; run vigil precheck'
                $sv.Error = $err
                # Every problem, each on its own line (16.3).
                $sv.Report = @((Format-VigilConfigReport -Parsed $parsed -Records $records).Split("`n") | Where-Object { $_ })
                if (-not $sv.Mode) { return $false }
                & $log 'ERROR' "configuration rejected, the last valid one stays active: $err"
                foreach ($l in $sv.Report) { & $log 'ERROR' "  $l" }
                $sv.ReloadFailed = 1
                return $true
            }
            $sv.ReloadFailed = 0
            $sv.State = Get-VigilConfigValue $parsed 'vigil' 'state_dir' 'state'
            if (-not [System.IO.Path]::IsPathRooted($sv.State)) { $sv.State = Join-Path $sv.Root $sv.State }
            [void](New-Item -ItemType Directory -Force -Path $sv.State)
            if (Test-VigilFetchMode -Parsed $parsed) {
                # What the fetcher last saw of this file tells whether it
                # must look again.
                $sv.Mode = 'fetch'
                $sv.LocalParsed = $parsed
                $sv.LocalRecords = $records
                $sv.ActSum = '-'
            }
            else {
                $sv.Mode = 'local'
                $sv.Waiting = $false
                # A purely local configuration has a revision too (16.5).
                $sv.Revision = (Get-VigilTextSha "config $sum`n").Substring(0, 12)
                & $apply $parsed $records
                Write-VigilFileAtomic -Path (Join-Path $sv.State 'config.valid') -Text ([System.IO.File]::ReadAllText($path))
                & $log 'INFO' 'configuration loaded'
                return $true
            }
        }
        if ($sv.Mode -cne 'fetch') { return $true }
        $asum = ''
        try { $asum = Get-VigilFileSha (Join-Path $sv.State 'config.active') } catch { }
        if ($asum -ceq $sv.ActSum) { return $true }
        $sv.ActSum = $asum
        $active = Read-VigilActive -Root $sv.Root -State $sv.State
        $ok = $false
        if ($active) {
            $p = ConvertFrom-VigilConfig -Path $active.Config
            $r = Test-VigilConfig -Parsed $p
            $ok = $p.Errors.Count -eq 0 -and @($r | Where-Object { $_.Kind -ceq 'ERROR' }).Count -eq 0
        }
        if ($ok) {
            $sv.Active = $active
            $sv.Waiting = $false
            & $apply $p $r
            if ($active.Revision -cne $sv.Revision) {
                $sv.Revision = $active.Revision
                & $log 'INFO' "configuration revision $($sv.Revision) loaded ($($active.Origin))"
            }
        }
        else {
            # Nothing fetched yet: no job runs until everything it needs is
            # present and verified (16.5).
            $sv.Active = $null
            $sv.Waiting = $true
            & $apply $sv.LocalParsed $sv.LocalRecords
            & $log 'INFO' 'waiting for the first fetch from the configuration''s sources'
        }
        return $true
    }

    # A job's cached script, when its file comes from a source: @{ Ok;
    # Path }, Path empty for a local file.
    $scriptOf = {
        param([string]$Job)
        if ($sv.Mode -cne 'fetch') { return @{ Ok = $true; Path = '' } }
        $src = Get-VigilConfigValue $sv.Parsed "job.$Job" 'source' ''
        if (-not $src) { return @{ Ok = $true; Path = '' } }
        $p = Get-VigilActiveScript -Root $sv.Root -Active $sv.Active -Source $src -File (Get-VigilConfigValue $sv.Parsed "job.$Job" 'file' '')
        if ($p -and [System.IO.File]::Exists($p)) { return @{ Ok = $true; Path = $p } }
        return @{ Ok = $false; Path = '' }
    }

    # Whether the fetcher should run: when no fetch has been made, when the
    # local file changed since the last, or when a source is due (16.5).
    $fetchDue = {
        $p = Join-Path $sv.State 'fetch.next'
        if (-not [System.IO.File]::Exists($p)) { return $true }
        $next = ''; $local = ''
        foreach ($l in [System.IO.File]::ReadAllLines($p)) {
            if ($l -cmatch '^next_epoch = (.*)$') { $next = $Matches[1] }
            elseif ($l -cmatch '^local = (.*)$') { $local = $Matches[1] }
        }
        if ($local -cne $sv.Sum) { return $true }
        return (-not $next) -or $sv.Epoch -ge [long]$next
    }

    $event = {
        param([string]$Job, [string]$Name, [string]$Value, [string]$Type)
        if ($Job) {
            $m = (Get-VigilIndexValue -Index $sv.Index -Section "job.$Job" -Key 'metric_name').Value
            if (-not $m) { $m = $Job }
            $sv.Events.Add("$($sv.Epoch) $m.$Name $Value $Type $($sv.Tags) job=$Job")
        }
        else { $sv.Events.Add("$($sv.Epoch) vigil.supervisor.$Name $Value $Type $($sv.Tags)") }
    }

    # Records a concluded run whose worker can no longer write (12.3).
    $record = {
        param([string]$Job, [string]$RunId, [string]$Conclusion, $St, $Spool, [string]$Why)
        $path = Join-Path $sv.State "jobs\$Job.state"
        if ($St.Kind -ceq 'unreadable') {
            $q = Join-Path $sv.State 'quarantine'
            [void](New-Item -ItemType Directory -Force -Path $q)
            try { [System.IO.File]::Move($path, (Join-Path $q "$Job.$($sv.Epoch).state")) } catch { }
            & $event $Job 'state_corrupt' '1' 'count'
            & $log 'WARN' "job ${Job}: unreadable state file quarantined"
        }
        $fields = [ordered]@{ schema_version = 1; job = $Job; run_id = $RunId; instance = $sv.Instance }
        if ($Conclusion -ceq 'finished') {
            $fields.status = $Spool.Outcome
            $fields.reason = 'reconciled from the spool file'
            $fields.spool_file = $Spool.File
            & $log 'INFO' "job ${Job}: run $RunId finished ($($Spool.Outcome)), reconciled from its spool file"
        }
        elseif ([System.IO.File]::Exists((Join-Path $sv.State "locks\$Job.$RunId.timeout"))) {
            # Stopped for max_runtime, and its worker went too.
            $fields.status = 'timed_out'
            $fields.reason = 'stopped after max_runtime; its worker exited without a final state'
            & $event $Job 'timeouts' '1' 'count'
            & $log 'WARN' "job ${Job}: run $RunId timed out"
        }
        else {
            $fields.status = 'crashed'
            $fields.reason = $(if ($Why) { $Why } else { 'worker vanished' })
            & $event $Job 'crashes' '1' 'count'
            & $log 'WARN' "job ${Job}: run $RunId crashed: worker vanished without an outcome"
            $sv.Crashed.Add($Job)
        }
        $fields.boot_id = $St.Boot
        $fields.started_epoch = $St.Started
        $fields.ended_epoch = $sv.Epoch
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $sv.State 'jobs'))
        Write-VigilStateFile -Path $path -Fields $fields
    }

    # Accounts for a job's latest run (11.3). Returns @{ Active; State }.
    $account = {
        param([string]$Job)
        $locks = Join-Path $sv.State 'locks'
        $launch = $null; $token = $null
        if ([System.IO.Directory]::Exists($locks)) {
            $launch = @([System.IO.Directory]::GetFiles($locks, "$Job.*.launch"))[0]
            $token = @([System.IO.Directory]::GetFiles($locks, "$Job.*.token"))[0]
        }
        $st = Read-VigilRunState (Join-Path $sv.State "jobs\$Job.state")
        $lstate = 'none'; $tstate = 'none'; $boot = 'same'; $proc = '-'; $rid = ''
        if ($launch) {
            $rid = [System.IO.Path]::GetFileName($launch).Substring($Job.Length + 1) -replace '\.launch$', ''
            $epoch = ''; $lboot = ''; $unread = $false
            # A worker holds the record exclusively while it claims it, then
            # deletes it: either makes the read fail, and both mean held.
            try { $llines = [System.IO.File]::ReadAllLines($launch) } catch { $llines = @(); $unread = $true }
            foreach ($l in $llines) {
                if ($l -cmatch '^launch_epoch *= *(\S*)') { $epoch = $Matches[1] }
                elseif ($l -cmatch '^boot_id *= *(\S*)') { $lboot = $Matches[1] }
            }
            if ($unread) { $lstate = 'held' }
            elseif ($lboot -and $lboot -cne $sv.Boot) { $lstate = 'prevboot' }
            elseif ($epoch -and ($sv.Epoch - [long]$epoch) -lt $Script:VigilLaunchGrace) {
                # A young launch is never opened: probing it could make a
                # claiming worker's exclusive open fail.
                $lstate = 'young'
            }
            elseif ((Test-VigilFileHeld $launch) -ceq 'yes') { $lstate = 'held' }
            else { $lstate = 'old'; $proc = Test-VigilRunProcess $rid }
        }
        else {
            if ($token) {
                $rid = [System.IO.Path]::GetFileName($token).Substring($Job.Length + 1) -replace '\.token$', ''
                $h = Test-VigilFileHeld $token
                if ($h -ceq 'yes') { $tstate = 'held' } elseif ($h -ceq 'no') { $tstate = 'free' } else { $tstate = 'free'; $proc = 'error' }
            }
            else { $rid = $st.RunId }
            # A readable state of an earlier run says nothing about this one.
            if (($st.Kind -ceq 'running' -or $st.Kind -ceq 'final') -and $st.RunId -cne $rid) { $st.Kind = 'missing' }
            if ($st.Boot -and $st.Boot -cne $sv.Boot -and $st.Kind -cne 'missing') { $boot = 'changed' }
            if ($proc -ceq '-' -and $tstate -cne 'held' -and $boot -ceq 'same' -and
                ($tstate -cne 'none' -or $st.Kind -ceq 'running' -or $st.Kind -ceq 'unreadable')) {
                $proc = Test-VigilRunProcess $rid
            }
        }
        $spool = Find-VigilSpoolOutcome $sv.Spool $Job $rid
        $c = Get-VigilRecoveryConclusion -Launch $lstate -Token $tstate -Process $proc -Boot $boot -State $st.Kind `
            -Spool $(if ($spool.Found) { 'yes' } else { 'no' })
        $active = '-'
        $reason = ''
        if ($c -ceq 'alive' -and $st.Kind -ceq 'running' -and $st.Deadline -and $sv.Epoch -ge [long]$st.Deadline) {
            if (-not (& $timeout $Job $rid $st)) {
                # Never kill what cannot be proven to be the run's (VIGIL-007).
                $c = 'uncertain'
                $reason = "past max_runtime, but its job process cannot be proven to be the run's"
            }
        }
        if ($c -ceq 'uncertain' -and -not $reason) { $reason = 'its liveness cannot be established: a probe failed or the evidence conflicts' }

        # Uncertain runs (11.4): a supervisor-owned recovery record holds the
        # job, survives restarts, and is resolved by the evidence or by
        # vigil resolve.
        $recPath = Join-Path $sv.State "recovery\$Job.recovery"
        $rec = Read-VigilRecoveryRecord $sv.State $Job
        $hold = $false
        if ($c -ceq 'uncertain') {
            if ($rec.ResolvedAt -and $rec.RunId -ceq $rid) {
                # An operator confirmed the run is over. Nothing is killed.
                if ($st.Kind -cne 'final') {
                    if ($spool.Found) { & $record $Job $rid 'finished' $st $spool }
                    else { & $record $Job $rid 'crashed' $st $spool "concluded by vigil resolve ($($rec.ResolvedBy))" }
                }
                if ($token) { try { [System.IO.File]::Delete($token) } catch { } }
                foreach ($f in @((Join-Path $sv.State "locks\$Job.$rid.timeout"), $recPath, (Join-Path $sv.State "recovery\$Job.resolved"))) {
                    if ([System.IO.File]::Exists($f)) { try { [System.IO.File]::Delete($f) } catch { } }
                }
                & $log 'INFO' "job ${Job}: uncertain run $rid concluded, resolved by $($rec.ResolvedBy)"
                return @{ Active = '-'; State = $st }
            }
            $policy = 'wait'
            foreach ($row in (Get-VigilEffectiveJob -Index $sv.Index -Id $Job)) { if ($row.Key -ceq 'on_uncertain') { $policy = $row.Value } }
            if ($rec.RunId -cne $rid) { $rec.First = '' }
            if (-not $rec.First) { & $log 'WARN' "job ${Job}: run $rid is uncertain ($reason); holding it, killing nothing (on_uncertain = $policy)" }
            Write-VigilRecoveryRecord $sv.State $Job $rid 'uncertain' $reason $policy $rec $sv.Epoch
            $sv.Uncertain.Add("${Job}: $reason")
            & $event $Job 'uncertain' '1' 'gauge'
            if ($policy -ceq 'replace') { [void]$sv.Replacing.Add($Job) } else { $active = 'running' }
            return @{ Active = $active; State = $st }
        }
        if ($rec.RunId) {
            if ($rec.Policy -ceq 'manual' -and -not $rec.ResolvedAt) {
                # The evidence cleared; the run is concluded below, but the job
                # stays held until an operator confirms it (11.4).
                $hold = $true
            }
            else {
                if ($rec.ResolvedAt) { & $log 'INFO' "job ${Job}: hold on run $($rec.RunId) released, resolved by $($rec.ResolvedBy)" }
                foreach ($f in @($recPath, (Join-Path $sv.State "recovery\$Job.resolved"))) {
                    if ([System.IO.File]::Exists($f)) { try { [System.IO.File]::Delete($f) } catch { } }
                }
            }
        }

        switch ($c) {
            { $_ -ceq 'alive' -or $_ -ceq 'launching' } { $active = 'running' }
            'abandon' {
                # Abandon by deleting the launch record: Windows refuses while
                # a worker holds it, so only one of the two can win (11.2).
                try {
                    [System.IO.File]::Delete($launch)
                    & $event $Job 'abandoned_launches' '1' 'count'
                    & $log 'WARN' "job ${Job}: launch $rid abandoned: its worker never claimed it"
                }
                catch { $active = 'running' }
            }
            { $_ -ceq 'finished' -or $_ -ceq 'crashed' } {
                if ($st.Kind -cne 'final') { & $record $Job $rid $c $st $spool }
                if ($token) { try { [System.IO.File]::Delete($token) } catch { } }
                $marker = Join-Path $sv.State "locks\$Job.$rid.timeout"
                if ([System.IO.File]::Exists($marker)) { try { [System.IO.File]::Delete($marker) } catch { } }
            }
        }
        if ($hold) {
            if ($c -cne 'alive' -and $c -cne 'launching') {
                Write-VigilRecoveryRecord $sv.State $Job $rec.RunId $c $rec.Reason 'manual' $rec $sv.Epoch
            }
            $active = 'running'
            $sv.Uncertain.Add("${Job}: run $($rec.RunId) $c; held until vigil resolve (on_uncertain = manual)")
            & $event $Job 'uncertain' '1' 'gauge'
        }
        return @{ Active = $active; State = $st }
    }

    # Stops a run past its deadline (10.3, 11.5, 11.6), only once its job
    # process is proven to be the run's: its PID, name and start time match
    # the state file and, while the worker lives, its parent is the worker.
    # A marker written first tells the worker its job timed out. Windows has
    # no TERM for console programs: the process tree is ended at once.
    $timeout = {
        param([string]$Job, [string]$RunId, $St)
        $proven = $false
        try {
            $p = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$St.JobPid)" -ErrorAction Stop)[0]
            if ($p -and $St.JobName -and $p.Name -ieq $St.JobName) {
                $startOk = (-not $St.JobStart) -or ([Math]::Abs((ConvertTo-VigilEpoch $p.CreationDate) - [long]$St.JobStart) -le 1)
                $w = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$St.WorkerPid)" -ErrorAction Stop)[0]
                $parentOk = (-not $w) -or ($w.CommandLine -notlike "*--run-id $RunId*") -or ($p.ParentProcessId -eq [int]$St.WorkerPid)
                $proven = $startOk -and $parentOk
            }
        }
        catch { $proven = $false }
        # Unproven: the caller holds the run as uncertain.
        if (-not $proven) { return $false }
        $marker = Join-Path $sv.State "locks\$Job.$RunId.timeout"
        if (-not [System.IO.File]::Exists($marker)) {
            Write-VigilFileAtomic -Path $marker -Text "term_epoch = $($sv.Epoch)`n"
            & $log 'WARN' "job ${Job}: run $RunId passed max_runtime; ending its process tree"
        }
        & taskkill.exe /T /F /PID $St.JobPid 2>&1 | Out-Null
        return $true
    }

    # Starts a launched run as a detached worker.
    $start = {
        param([string]$Job, [string]$Script)
        $sv.Seq++
        $rid = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture))-$PID-$($sv.Seq)"
        $locks = Join-Path $sv.State 'locks'
        [void](New-Item -ItemType Directory -Force -Path $locks)
        $text = "[launch]`njob           = $Job`nrun_id        = $rid`nboot_id       = $($sv.Boot)`nlaunch_epoch  = $($sv.Epoch)`n"
        # The configuration and script the run uses (16.5), whatever is
        # activated while it runs.
        if ($sv.Mode -ceq 'fetch' -and $Job -cne 'vigil_fetch') {
            $text += "config        = $($sv.Active.Config)`n"
            if ($Script) { $text += "script        = $Script`n" }
        }
        Write-VigilFileAtomic -Path (Join-Path $locks "$Job.$rid.launch") -Text $text
        $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'vigil.ps1'),
            '-Root', $sv.Root, 'worker', $Job, '--run-id', $rid)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $shell
        $psi.Arguments = ($argv | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        [void][System.Diagnostics.Process]::Start($psi)
        $sv.Running++
        if ($Job -cne 'vigil_sender') { & $log 'INFO' "job ${Job}: run $rid started" }
        # Started beside an uncertain run under on_uncertain = replace (11.4).
        if ($sv.Replacing.Contains($Job)) {
            & $event $Job 'possible_duplicates' '1' 'count'
            & $log 'WARN' "job ${Job}: run $rid started beside an uncertain run (on_uncertain = replace)"
        }
    }

    $tick = {
        $now = [DateTimeOffset]::Now
        $sv.Epoch = $now.ToUnixTimeSeconds()
        $sv.Now = $now.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + $now.ToString('zzz').Replace(':', '')
        $sv.Date = $now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $sv.Iso = $now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $sv.Events = New-Object 'System.Collections.Generic.List[string]'
        $sv.Running = 0
        $sv.Uncertain = New-Object 'System.Collections.Generic.List[string]'
        $sv.Replacing = New-Object 'System.Collections.Generic.HashSet[string]'
        $sv.Crashed = New-Object 'System.Collections.Generic.List[string]'
        $status = @{ Running = @(); Waiting = @(); Disabled = @(); Invalid = @(); Last = @(); Missing = @() }

        [void](& $loadConfig)

        foreach ($sec in $sv.Parsed.Sections) {
            if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            if ($sv.Waiting) { break }
            $job = $sec.Name.Substring(4)
            $inv = @($sv.Records | Where-Object { $_.Kind -ceq 'INVALID' -and $_.Job -ceq $job })
            if ($inv.Count -gt 0) {
                & $event $job 'invalid_config' '1' 'gauge'
                $status.Invalid += "${job}: $($inv[0].Message)"
                continue
            }

            $acc = & $account $job
            $active = $acc.Active
            if ($active -ceq 'running') {
                $sv.Running++
                $status.Running += $job
                if ($acc.State.Kind -ceq 'running' -and $acc.State.Started) {
                    & $event $job 'running' "$($sv.Epoch - [long]$acc.State.Started)" 'gauge'
                }
            }
            else {
                # A run held by queue_one is admitted once the active run ends.
                if ($sv.Queued.Remove($job)) { $sv.Pending.Add($job) }
                if ($acc.State.Kind -ceq 'final') { $status.Last += "${job}: $($acc.State.Status)" }
            }
            if ($sv.Queued.Contains($job)) { $active = 'queued' }
            if ($sv.Pending.Contains($job)) { $active = 'running' }

            # A script from a source that is not cached: FILE MISSING until
            # it is fetched again (16.3, 16.5).
            if (-not (& $scriptOf $job).Ok) {
                & $event $job 'file_missing' '1' 'gauge'
                $status.Missing += $job
                continue
            }

            $cfile = Join-Path $sv.State "schedule\$job.cursor"
            $cursor = '-'
            if ([System.IO.File]::Exists($cfile)) { $cursor = ([System.IO.File]::ReadAllText($cfile)).Trim() }
            $d = Get-VigilScheduleDecision -Index $sv.Index -Id $job -Now $sv.Now -Prev $sv.Prev -Cursor $cursor -Active $active
            if ($d.Decision -ceq 'error' -and $cursor -cne '-') {
                # A cursor of the other kind (run_every changed to run_at): new.
                $cursor = '-'
                $d = Get-VigilScheduleDecision -Index $sv.Index -Id $job -Now $sv.Now -Prev $sv.Prev -Cursor $cursor -Active $active
            }
            switch ($d.Decision) {
                'disabled' {
                    if ([System.IO.File]::Exists($cfile)) { [System.IO.File]::Delete($cfile) }
                    $status.Disabled += $job
                    continue
                }
                'error' { continue }
                'missed' {
                    & $event $job 'missed' '1' 'count'
                    & $log 'INFO' "job ${job}: slot $($d.Slot) missed"
                }
                'skip' {
                    & $event $job 'skipped' '1' 'count'
                    & $log 'INFO' "job ${job}: slot $($d.Slot) skipped: a run is still active"
                }
                'run' { $sv.Pending.Add($job) }
                'queue' { [void]$sv.Queued.Add($job) }
            }
            if ($d.Decision -ceq 'disabled' -or $d.Decision -ceq 'error') { continue }
            if ($d.Cursor -cne $cursor) {
                [void](New-Item -ItemType Directory -Force -Path (Join-Path $sv.State 'schedule'))
                Write-VigilFileAtomic -Path $cfile -Text "$($d.Cursor)`n"
            }
            if ($d.Next -cne '-') { $status.Waiting += "${job}: next $($d.Next)" }
        }

        # Admission (8): oldest pending first, within max_concurrent; beyond
        # max_pending, runs are skipped.
        $next = New-Object 'System.Collections.Generic.List[string]'
        foreach ($job in $sv.Pending) {
            if ($sv.Running -lt $sv.Max) {
                $sc = & $scriptOf $job
                if (-not $sc.Ok) { continue }
                & $start $job $sc.Path
                $status.Running += $job
            }
            else { $next.Add($job) }
        }
        $sv.Pending = New-Object 'System.Collections.Generic.List[string]'
        foreach ($job in $next) {
            if ($sv.Pending.Count -lt $sv.MaxPending) { $sv.Pending.Add($job) }
            else {
                & $event $job 'skipped' '1' 'count'
                & $log 'WARN' "job ${job}: skipped: more than $($sv.MaxPending) runs pending"
            }
        }

        & $event '' 'up' '1' 'gauge'
        & $event '' 'workers' "$($sv.Running)" 'gauge'
        & $event '' 'pending' "$($sv.Pending.Count)" 'gauge'
        & $event '' 'config_reload_failed' "$($sv.ReloadFailed)" 'gauge'
        # The active revision, and how long since each source was last
        # checked successfully (14.5).
        if (-not $sv.Waiting) { $sv.Events.Add("$($sv.Epoch) vigil.config.info 1 gauge $($sv.Tags) revision=$($sv.Revision)") }
        $srcDir = Join-Path $sv.State 'sources'
        if ($sv.Mode -ceq 'fetch' -and [System.IO.Directory]::Exists($srcDir)) {
            foreach ($p in [System.IO.Directory]::GetFiles($srcDir, '*.state')) {
                $okAt = @([System.IO.File]::ReadAllLines($p) | Where-Object { $_ -cmatch '^ok_epoch += \d+$' } | ForEach-Object { $_ -creplace '^ok_epoch += ', '' })[0]
                if ($okAt) { $sv.Events.Add("$($sv.Epoch) vigil.source.check_age $($sv.Epoch - [long]$okAt) gauge $($sv.Tags) source=$([System.IO.Path]::GetFileNameWithoutExtension($p))") }
            }
        }
        $incoming = Join-Path $sv.Spool 'incoming'
        [void](New-Item -ItemType Directory -Force -Path $incoming)
        Write-VigilFileAtomic -Path (Join-Path $incoming "$($sv.Epoch)-vigil_supervisor.events") -Text (($sv.Events | ForEach-Object { "$_`n" }) -join '')

        # The sender (4.5): one at a time, started whenever the spool holds
        # anything. It is Vigil's own worker and does not count against
        # max_concurrent.
        $acc = & $account 'vigil_sender'
        if ($acc.Active -ceq '-' -and -not $sv.Waiting) {
            $queued = $false
            foreach ($d in @((Join-Path $sv.Spool 'incoming'), (Join-Path $sv.Spool 'fanout'))) {
                if ([System.IO.Directory]::Exists($d) -and [System.IO.Directory]::GetFiles($d, '*.events').Count -gt 0) { $queued = $true }
            }
            $be = Join-Path $sv.Spool 'backends'
            if (-not $queued -and [System.IO.Directory]::Exists($be)) {
                foreach ($d in [System.IO.Directory]::GetDirectories($be)) {
                    if ([System.IO.Directory]::GetFiles($d, '*.events').Count -gt 0) { $queued = $true; break }
                }
            }
            if ($queued) { & $start 'vigil_sender' }
        }

        # The fetcher (16.5): like the sender, one at a time, outside
        # max_concurrent, so a slow source never delays a tick.
        if ($sv.Mode -ceq 'fetch') {
            $acc = & $account 'vigil_fetch'
            if ($acc.Active -ceq '-' -and (& $fetchDue)) { & $start 'vigil_fetch' }
        }

        # jobs.log (13.2), rewritten every tick.
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("Vigil $($sv.Instance) at $($sv.Iso)`r`n")
        if ($sv.ReloadFailed) { [void]$sb.Append("`r`nCONFIGURATION REJECTED - the last valid configuration is active`r`n") }
        if ($sv.Mode -ceq 'fetch') {
            [void]$sb.Append("`r`nSOURCES`r`n")
            if ($sv.Waiting) { [void]$sb.Append("  waiting for the first fetch`r`n") }
            else { [void]$sb.Append("  revision $($sv.Revision) ($($sv.Active.Origin))`r`n") }
            $fst = Join-Path $sv.State 'jobs\vigil_fetch.state'
            if ([System.IO.File]::Exists($fst)) {
                $fl = [System.IO.File]::ReadAllLines($fst)
                if (@($fl | Where-Object { $_ -cmatch '^status +=( failed)$' }).Count -gt 0) {
                    $why = @($fl | Where-Object { $_ -cmatch '^reason +=' } | ForEach-Object { $_ -creplace '^reason +=\s?', '' })[0]
                    [void]$sb.Append("  last fetch failed: $why`r`n")
                }
            }
        }
        foreach ($s in @(@('FILE MISSING', $status.Missing), @('UNCERTAIN', $sv.Uncertain), @('CRASHED', $sv.Crashed), @('INVALID', $status.Invalid),
                @('RUNNING', $status.Running), @('PENDING', $sv.Pending), @('WAITING', $status.Waiting),
                @('DISABLED', $status.Disabled), @('LAST RUN', $status.Last))) {
            if (@($s[1]).Count -eq 0) { continue }
            [void]$sb.Append("`r`n$($s[0])`r`n")
            foreach ($item in $s[1]) { [void]$sb.Append("  $item`r`n") }
        }
        $dir = Join-Path $sv.Logs 'supervisor'
        [void](New-Item -ItemType Directory -Force -Path $dir)
        Write-VigilFileAtomic -Path (Join-Path $dir 'jobs.log') -Text $sb.ToString()

        $sv.Prev = $sv.Now
    }

    $sv.Iso = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $sv.Date = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not (& $loadConfig)) {
        [Console]::Error.WriteLine("vigil: $($sv.Error)")
        foreach ($l in $sv.Report) { [Console]::Error.WriteLine("  $l") }
        return 1
    }

    # One supervisor per state directory (12.4).
    try {
        $lock = [System.IO.File]::Open((Join-Path $sv.State 'supervisor.lock'), 'OpenOrCreate', 'ReadWrite', 'Read')
    }
    catch {
        [Console]::Error.WriteLine("vigil: another supervisor owns $($sv.State)")
        return 1
    }
    try {
        $lock.SetLength(0)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("pid = $PID`r`n")
        $lock.Write($bytes, 0, $bytes.Length)
        $lock.Flush()
        # Temporary files a killed supervisor left mid-write (12.3). Only the
        # supervisor writes these, and it now holds the lock, so none is live.
        foreach ($p in @(@((Join-Path $sv.State 'schedule'), '*.tmp.*'), @($sv.State, 'config.valid.tmp.*'),
                @((Join-Path $sv.State 'locks'), '*.launch.tmp.*'),
                @((Join-Path $sv.Logs 'supervisor'), 'jobs.log.tmp.*'), @((Join-Path $sv.Spool 'incoming'), '*-vigil_supervisor.events.tmp.*'))) {
            if ([System.IO.Directory]::Exists($p[0])) {
                foreach ($f in [System.IO.Directory]::GetFiles($p[0], $p[1])) { try { [System.IO.File]::Delete($f) } catch { } }
            }
        }
        & $log 'INFO' "supervisor started, pid $PID"
        while ($true) {
            # A failing tick is logged, never fatal: the supervisor keeps
            # ticking (13.3).
            try { & $tick }
            catch { & $log 'ERROR' "tick failed: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" }
            if ($Once) { break }
            $wait = $sv.Epoch + $sv.Tick - [DateTimeOffset]::Now.ToUnixTimeSeconds()
            if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        }
    }
    finally {
        & $log 'INFO' 'supervisor stopped; running workers continue'
        $lock.Dispose()
    }
    return 0
}
