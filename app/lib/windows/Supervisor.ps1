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
    Schedule.ps1, Outcome.ps1, Metrics.ps1, Events.ps1, Recovery.ps1 and
    Worker.ps1.
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

function Invoke-VigilSupervisor {
    param([string]$Root, [string]$App, [switch]$Once)

    $sv = @{
        Root = $Root; Prev = '-'; Pending = New-Object 'System.Collections.Generic.List[string]'
        Queued = New-Object 'System.Collections.Generic.HashSet[string]'; Seq = 0; Sum = ''
        ReloadFailed = 0; Valid = ''; Parsed = $null; Records = $null; Index = $null
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

    # Loads the configuration when it changed. An invalid one is rejected
    # and the last valid one, kept in state\config.valid, stays active.
    $loadConfig = {
        $path = Join-Path $sv.Root 'config\vigil.config'
        $sum = ''
        try { $sum = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.IO.File]::ReadAllBytes($path))) } catch { }
        if ($sum -ceq $sv.Sum -and $sv.Parsed) { return $true }
        $sv.Sum = $sum
        $parsed = ConvertFrom-VigilConfig -Path $path
        $records = Test-VigilConfig -Parsed $parsed
        $err = ''
        if ($parsed.Errors.Count -gt 0 -or @($records | Where-Object { $_.Kind -ceq 'ERROR' }).Count -gt 0) {
            $err = 'the configuration has errors; run vigil precheck'
        }
        elseif ((Get-VigilConfigValue $parsed 'vigil' 'config_source' '').Length -gt 0) {
            $err = 'remote configuration needs the fetcher, which is not available yet'
        }
        if ($err) {
            $sv.Error = $err
            if ($sv.Parsed) {
                & $log 'ERROR' "configuration rejected, the last valid one stays active: $err"
                $sv.ReloadFailed = 1
                return $true
            }
            return $false
        }
        $sv.ReloadFailed = 0
        $sv.Parsed = $parsed
        $sv.Records = $records
        $sv.Index = New-VigilConfigIndex -Parsed $parsed
        $dir = {
            param($Section, $Key, $Default)
            $v = Get-VigilConfigValue $parsed $Section $Key $Default
            if ([System.IO.Path]::IsPathRooted($v)) { return $v }
            return Join-Path $sv.Root $v
        }
        $sv.State = & $dir 'vigil' 'state_dir' 'state'
        $sv.Logs = & $dir 'log' 'dir' 'logs'
        $sv.Spool = & $dir 'spool' 'dir' 'spool'
        $sv.Instance = Get-VigilConfigValue $parsed 'vigil' 'instance' 'vigil'
        $sv.Max = [int](Get-VigilConfigValue $parsed 'vigil' 'max_concurrent' '5')
        $sv.MaxPending = [int](Get-VigilConfigValue $parsed 'scheduler' 'max_pending' '20')
        $tick = Get-VigilConfigValue $parsed 'scheduler' 'tick' '60s'
        $n = [int]$tick.Substring(0, $tick.Length - 1)
        $sv.Tick = switch ($tick[-1]) { 's' { $n } 'm' { $n * 60 } 'h' { $n * 3600 } default { $n * 86400 } }
        [void](New-Item -ItemType Directory -Force -Path $sv.State)
        Write-VigilFileAtomic -Path (Join-Path $sv.State 'config.valid') -Text ([System.IO.File]::ReadAllText($path))
        $tags = "host=$($sv.HostName) os=windows instance=$($sv.Instance)"
        foreach ($e in $parsed.Entries) { if ($e.Section -ceq 'tags') { $tags += " $($e.Key)=$($e.Value)" } }
        $sv.Tags = $tags
        & $log 'INFO' 'configuration loaded'
        return $true
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
        param([string]$Job, [string]$RunId, [string]$Conclusion, $St, $Spool)
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
            $fields.reason = 'worker vanished'
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
        switch ($c) {
            { $_ -ceq 'alive' -or $_ -ceq 'launching' } {
                $active = 'running'
                if ($c -ceq 'alive' -and $st.Kind -ceq 'running' -and $st.Deadline -and $sv.Epoch -ge [long]$st.Deadline) {
                    & $timeout $Job $rid $st
                }
            }
            'uncertain' {
                $active = 'running'
                $sv.Uncertain.Add($Job)
                & $event $Job 'uncertain' '1' 'gauge'
            }
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
        if (-not $proven) {
            # Never kill what cannot be proven to be the run's (VIGIL-007).
            & $log 'WARN' "job ${Job}: run $RunId is past max_runtime, but its job process cannot be proven to be the run's; not stopping it"
            $sv.Uncertain.Add($Job)
            & $event $Job 'uncertain' '1' 'gauge'
            return
        }
        $marker = Join-Path $sv.State "locks\$Job.$RunId.timeout"
        if (-not [System.IO.File]::Exists($marker)) {
            Write-VigilFileAtomic -Path $marker -Text "term_epoch = $($sv.Epoch)`n"
            & $log 'WARN' "job ${Job}: run $RunId passed max_runtime; ending its process tree"
        }
        & taskkill.exe /T /F /PID $St.JobPid 2>&1 | Out-Null
    }

    # Starts a launched run as a detached worker.
    $start = {
        param([string]$Job)
        $sv.Seq++
        $rid = "$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture))-$PID-$($sv.Seq)"
        $locks = Join-Path $sv.State 'locks'
        [void](New-Item -ItemType Directory -Force -Path $locks)
        Write-VigilFileAtomic -Path (Join-Path $locks "$Job.$rid.launch") -Text (
            "[launch]`njob           = $Job`nrun_id        = $rid`nboot_id       = $($sv.Boot)`nlaunch_epoch  = $($sv.Epoch)`n")
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
        $sv.Crashed = New-Object 'System.Collections.Generic.List[string]'
        $status = @{ Running = @(); Waiting = @(); Disabled = @(); Invalid = @(); Last = @() }

        [void](& $loadConfig)

        foreach ($sec in $sv.Parsed.Sections) {
            if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
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
            if ($sv.Running -lt $sv.Max) { & $start $job; $status.Running += $job }
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
        $incoming = Join-Path $sv.Spool 'incoming'
        [void](New-Item -ItemType Directory -Force -Path $incoming)
        Write-VigilFileAtomic -Path (Join-Path $incoming "$($sv.Epoch)-vigil_supervisor.events") -Text (($sv.Events | ForEach-Object { "$_`n" }) -join '')

        # The sender (4.5): one at a time, started whenever the spool holds
        # anything. It is Vigil's own worker and does not count against
        # max_concurrent.
        $acc = & $account 'vigil_sender'
        if ($acc.Active -ceq '-') {
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

        # jobs.log (13.2), rewritten every tick.
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("Vigil $($sv.Instance) at $($sv.Iso)`r`n")
        if ($sv.ReloadFailed) { [void]$sb.Append("`r`nCONFIGURATION REJECTED - the last valid configuration is active`r`n") }
        foreach ($s in @(@('UNCERTAIN', $sv.Uncertain), @('CRASHED', $sv.Crashed), @('INVALID', $status.Invalid),
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
