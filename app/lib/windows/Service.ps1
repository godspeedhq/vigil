# Service.ps1 - registering the supervisor with Windows (SPECIFICATION.md 18).
#
# System mode (admin): an NSSM service named Vigil, running as LocalSystem.
# User mode (no admin): a per-user Run entry starting the supervisor hidden
# at logon; no automatic restart (18.1).
#
#   Install-VigilService -Root -App -Mode -HostName -Start
#   Remove-VigilService -Root
#   Invoke-VigilServiceControl -Root -Action start|stop|restart
#   Get-VigilServiceStatus -Root
#
# The host is a choice, never assumed: powershell (Windows PowerShell 5.1,
# the default) or pwsh (PowerShell 7). The supervisor starts its workers
# with its own host, so the choice covers them too.
#
# NSSM is told how to run the supervisor through its registry parameters,
# written here directly, so no path is ever quoted through its command
# line. Stopping the service stops only the supervisor (18.3):
# AppKillProcessTree = 0.

$Script:VigilServiceName = 'Vigil'
$Script:VigilServiceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\Vigil'
$Script:VigilRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Starts or stops the service and waits for it, at most 60 seconds: a
# service that does not get there is reported, never waited on forever.
function Set-VigilServiceState {
    param([string]$Want)
    $sc = Get-Service -Name $Script:VigilServiceName -ErrorAction Stop
    if ($sc.Status -eq $Want) { return }
    if ($Want -ceq 'Running') { $sc.Start() } else { $sc.Stop() }
    try { $sc.WaitForStatus($Want, [TimeSpan]::FromSeconds(60)) }
    catch { throw "the Vigil service did not reach $Want within 60s (it is $($sc.Status)); see logs\supervisor\service.log" }
}

function Test-VigilAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The full path of the host executable, or throws.
function Get-VigilHostPath {
    param([string]$HostName)
    switch ($HostName) {
        'powershell' {
            $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not [System.IO.File]::Exists($p)) { throw "Windows PowerShell 5.1 was not found at $p; use --host pwsh" }
            return $p
        }
        'pwsh' {
            $c = @(Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
            if ($c.Count -eq 0) { throw 'PowerShell 7 (pwsh) is not installed, or not on the PATH; install it, or use --host powershell' }
            return $c[0].Source
        }
        default { throw "unknown host '$HostName': use powershell or pwsh" }
    }
}

# The supervisor's command line, after the host.
function Get-VigilSupervisorArgs {
    param([string]$Root, [string]$App, [switch]$Hidden)
    $a = @('-NoProfile', '-NonInteractive')
    if ($Hidden) { $a += @('-WindowStyle', 'Hidden') }
    $a += @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'vigil.ps1'), '-Root', $Root, 'supervise')
    return ($a | ForEach-Object { ConvertTo-VigilQuotedArg -Arg $_ -Always $false }) -join ' '
}

# Which registration belongs to this root: 'system', 'user' or ''. Other
# is set to a description of a registration that belongs to another root.
function Find-VigilService {
    param([string]$Root)
    $r = @{ Mode = ''; Other = '' }
    $svc = Get-ItemProperty -LiteralPath "$Script:VigilServiceKey\Parameters" -ErrorAction SilentlyContinue
    if ($svc) {
        if ([string]$svc.AppDirectory -ieq $Root) { $r.Mode = 'system'; return $r }
        $r.Other = "the Vigil service for $($svc.AppDirectory)"
    }
    $run = Get-ItemProperty -LiteralPath $Script:VigilRunKey -Name 'Vigil' -ErrorAction SilentlyContinue
    if ($run) {
        if (([string]$run.Vigil).Contains((ConvertTo-VigilQuotedArg -Arg $Root -Always $false) + ' supervise')) { $r.Mode = 'user'; return $r }
        if (-not $r.Other) { $r.Other = 'the Vigil Run entry of another install' }
    }
    return $r
}

# The live supervisor of this root, proven: it holds supervisor.lock, the
# lock names its pid, and that process runs vigil.ps1 supervise for this
# root. $null when there is none.
function Get-VigilSupervisorProcess {
    param([string]$Root)
    $ctx = Get-VigilWorkerContext -Root $Root -Job 'vigil_sender'
    $state = if ($ctx.Error) { Join-Path $Root 'state' } else { $ctx.State }
    $lock = Join-Path $state 'supervisor.lock'
    if (-not [System.IO.File]::Exists($lock)) { return $null }
    try {
        $f = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')
        $f.Dispose()
        return $null
    }
    catch { }
    try {
        $fs = [System.IO.File]::Open($lock, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
    catch { return $null }
    if ($text -notmatch 'pid = (\d+)') { return $null }
    $p = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$Matches[1])" -ErrorAction SilentlyContinue)
    if ($p.Count -eq 0) { return $null }
    $cl = [string]$p[0].CommandLine
    if ($cl.IndexOf('vigil.ps1', [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        -not $cl.EndsWith((ConvertTo-VigilQuotedArg -Arg $Root -Always $false) + ' supervise', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $p[0]
}

# Only SYSTEM and Administrators may change the root (17); the service runs
# as LocalSystem. Entries set on purpose below the root, such as the secret
# store's owner-only ACL, are kept.
function Set-VigilRootAcl {
    param([string]$Root)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Root -AclObject $acl
}

function Install-VigilService {
    param([string]$Root, [string]$App, [string]$Mode, [string]$HostName, [bool]$Start)
    $admin = Test-VigilAdmin
    if (-not $Mode) { $Mode = if ($admin) { 'system' } else { 'user' } }
    if ($Mode -ceq 'system' -and -not $admin) { throw 'system mode needs an elevated (administrator) prompt; or use --user' }
    if ($Root.Contains('"')) { throw "the install root $Root may not contain a double quote" }
    $exe = Get-VigilHostPath -HostName $HostName

    $found = Find-VigilService -Root $Root
    if ($found.Mode -and $found.Mode -cne $Mode) { throw "this root is already registered in $($found.Mode) mode: run vigil service remove first" }
    if (-not $found.Mode -and $found.Other -and
        (($Mode -ceq 'system' -and $found.Other.StartsWith('the Vigil service')) -or ($Mode -ceq 'user' -and $found.Other.StartsWith('the Vigil Run')))) {
        throw "$($found.Other) is registered: remove that one first"
    }

    foreach ($d in @('config', 'scripts', 'state', 'spool', 'logs', 'logs\supervisor', 'cache', 'metrics')) {
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root $d))
    }

    # Nothing is registered unless pre-flight passes (18.7).
    Write-Output 'pre-flight checks:'
    $r = Invoke-VigilPrecheck -Root $Root -Job ''
    foreach ($l in $r.Lines) { Write-Output $l }
    if ($r.Code -ne 0) { throw 'pre-flight checks failed; the service was not registered' }

    $cl = Get-VigilSupervisorArgs -Root $Root -App $App -Hidden:($Mode -ceq 'user')
    if ($Mode -ceq 'system') {
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
        $nssm = Join-Path (Split-Path -Parent $App) "vendor\nssm\$arch\nssm.exe"
        if (-not [System.IO.File]::Exists($nssm)) { throw "NSSM was not found at $nssm" }
        Set-VigilRootAcl -Root $Root
        $svc = Get-Service -Name $Script:VigilServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -ne 'Stopped') { Set-VigilServiceState 'Stopped' }
            Set-ItemProperty -LiteralPath $Script:VigilServiceKey -Name 'ImagePath' -Value "`"$nssm`""
        }
        else {
            [void](New-Service -Name $Script:VigilServiceName -BinaryPathName "`"$nssm`"" -DisplayName 'Vigil' -StartupType Automatic `
                    -Description 'Vigil job scheduler and supervisor' -ErrorAction Stop)
        }
        $k = "$Script:VigilServiceKey\Parameters"
        [void](New-Item -Path $k -Force)
        $log = Join-Path $Root 'logs\supervisor\service.log'
        foreach ($v in @(
                @('Application', $exe, 'ExpandString'), @('AppParameters', $cl, 'ExpandString'), @('AppDirectory', $Root, 'ExpandString'),
                @('AppStdout', $log, 'ExpandString'), @('AppStderr', $log, 'ExpandString'),
                # Append (OPEN_ALWAYS); rotated when the service starts, once over
                # 10 MB. Never online: NSSM would then read the output through a
                # pipe and, on stop, wait for it to close - which the workers,
                # holding it open, never do.
                @('AppStdoutCreationDisposition', 4, 'DWord'), @('AppStderrCreationDisposition', 4, 'DWord'),
                @('AppRotateFiles', 1, 'DWord'), @('AppRotateOnline', 0, 'DWord'), @('AppRotateBytes', 10485760, 'DWord'),
                # Restart on failure, throttled (18.4).
                @('AppThrottle', 10000, 'DWord'), @('AppRestartDelay', 10000, 'DWord'),
                # Graceful stop: Ctrl+C, up to 15s to finish the tick.
                @('AppStopMethodSkip', 0, 'DWord'), @('AppStopMethodConsole', 15000, 'DWord'),
                # Stop only the supervisor; workers survive (18.3).
                @('AppKillProcessTree', 0, 'DWord'))) {
            New-ItemProperty -Path $k -Name $v[0] -Value $v[1] -PropertyType $v[2] -Force | Out-Null
        }
        [void](New-Item -Path "$k\AppExit" -Force)
        Set-ItemProperty -LiteralPath "$k\AppExit" -Name '(Default)' -Value 'Restart'
        Write-Output "registered the Vigil service (NSSM, LocalSystem, $exe)"
        if ($Start) {
            Set-VigilServiceState 'Running'
            Write-Output 'started vigil'
        }
    }
    else {
        New-ItemProperty -Path $Script:VigilRunKey -Name 'Vigil' -Value "$(ConvertTo-VigilQuotedArg -Arg $exe -Always $true) $cl" -PropertyType String -Force | Out-Null
        Write-Output "registered the Vigil Run entry ($exe)"
        if ($Start) {
            Invoke-VigilServiceControl -Root $Root -Action 'restart'
        }
        Write-Output 'note: user mode starts Vigil at logon and does not restart it if it stops; an administrator install (--system) does'
    }
}

function Remove-VigilService {
    param([string]$Root)
    $found = Find-VigilService -Root $Root
    switch ($found.Mode) {
        'system' {
            if (-not (Test-VigilAdmin)) { throw 'the service is registered in system mode: run it from an elevated prompt' }
            $svc = Get-Service -Name $Script:VigilServiceName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') { Set-VigilServiceState 'Stopped' }
            $out = & sc.exe delete $Script:VigilServiceName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe delete Vigil failed: $out" }
            Write-Output 'removed the Vigil service; running workers continue'
        }
        'user' {
            $p = Get-VigilSupervisorProcess -Root $Root
            if ($p) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            Remove-ItemProperty -LiteralPath $Script:VigilRunKey -Name 'Vigil'
            Write-Output 'removed the Vigil Run entry; running workers continue'
        }
        default { Write-Output "vigil is not registered as a service for $Root; nothing to do" }
    }
}

function Invoke-VigilServiceControl {
    param([string]$Root, [string]$Action)
    $found = Find-VigilService -Root $Root
    if (-not $found.Mode) { throw "vigil is not registered as a service for ${Root}: run vigil service install" }
    if ($found.Mode -ceq 'system') {
        if (-not (Test-VigilAdmin)) { throw 'the service runs in system mode: run it from an elevated prompt' }
        switch ($Action) {
            'start' { Set-VigilServiceState 'Running' }
            'stop' { Set-VigilServiceState 'Stopped' }
            'restart' { Set-VigilServiceState 'Stopped'; Set-VigilServiceState 'Running' }
        }
    }
    else {
        if ($Action -cne 'start') {
            # Stopping the proven supervisor process only; its workers are
            # separate processes and carry on (18.3).
            $p = Get-VigilSupervisorProcess -Root $Root
            if ($p) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                try { (Get-Process -Id $p.ProcessId -ErrorAction Stop).WaitForExit(30000) | Out-Null } catch { }
            }
        }
        if ($Action -cne 'stop' -and -not (Get-VigilSupervisorProcess -Root $Root)) {
            # Started through WMI, as logon would: detached from this
            # process, holding none of its handles, hidden.
            $run = [string](Get-ItemProperty -LiteralPath $Script:VigilRunKey -Name 'Vigil').Vigil
            $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine = $run; CurrentDirectory = $Root; ProcessStartupInformation = $si
            }
            if ($r.ReturnValue -ne 0) { throw "could not start the supervisor (Win32_Process.Create returned $($r.ReturnValue))" }
            # Started once it holds the lock.
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Get-VigilSupervisorProcess -Root $Root)) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'the supervisor did not start within 30s; see logs\supervisor' }
                Start-Sleep -Milliseconds 250
            }
        }
    }
    switch ($Action) {
        'start' { Write-Output 'started vigil' }
        'stop' { Write-Output 'stopped vigil; running workers continue' }
        'restart' { Write-Output 'restarted vigil; running workers continue' }
    }
}

# The service's state, then jobs.log (13.2).
function Get-VigilServiceStatus {
    param([string]$Root)
    $found = Find-VigilService -Root $Root
    $state = 'not registered'
    if ($found.Mode -ceq 'system') {
        $svc = Get-Service -Name $Script:VigilServiceName -ErrorAction SilentlyContinue
        $state = if (-not $svc) { 'unknown' } elseif ($svc.Status -eq 'Running') { 'active' } elseif ($svc.Status -eq 'Stopped') { 'inactive' } else { ([string]$svc.Status).ToLowerInvariant() }
        $p = Get-VigilSupervisorProcess -Root $Root
        if ($state -ceq 'active' -and $p) { $state += ", pid $($p.ProcessId)" }
        $state += ' (NSSM, system mode)'
    }
    elseif ($found.Mode -ceq 'user') {
        $p = Get-VigilSupervisorProcess -Root $Root
        $state = if ($p) { "active, pid $($p.ProcessId)" } else { 'inactive' }
        $state += ' (Run entry, user mode)'
    }
    Write-Output "service: $state"
    Write-Output ''
    $ctx = Get-VigilWorkerContext -Root $Root -Job 'vigil_sender'
    $logs = if ($ctx.Error) { Join-Path $Root 'logs' } else { $ctx.Logs }
    $jl = Join-Path $logs 'supervisor\jobs.log'
    if ([System.IO.File]::Exists($jl)) { foreach ($l in [System.IO.File]::ReadAllLines($jl)) { Write-Output $l } }
    else { Write-Output 'no jobs.log yet: the supervisor writes it every tick' }
}

# A value from a state file, or ''.
function Read-VigilServiceStateValue {
    param([string]$Path, [string]$Key)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if ($l -cmatch "^$Key *=( (.*))?$") { return $Matches[2] }
    }
    return ''
}

# The runs in progress, proven to be this root's (11.5): for each token in
# locks\, the worker whose command line names the run and this root, and
# the job process whose PID, name and start time match the state file and
# whose parent is that worker. Proven and Unproven list process ids.
function Get-VigilServiceRuns {
    param([string]$Root, [string]$State)
    $r = @{ Proven = New-Object System.Collections.Generic.List[int]; Unproven = New-Object System.Collections.Generic.List[int] }
    $locks = Join-Path $State 'locks'
    if (-not [System.IO.Directory]::Exists($locks)) { return $r }
    $rootArg = ConvertTo-VigilQuotedArg -Arg $Root -Always $false
    foreach ($t in [System.IO.Directory]::GetFiles($locks, '*.token')) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($t)
        $i = $base.LastIndexOf('.')
        if ($i -lt 1) { continue }
        $job = $base.Substring(0, $i)
        $rid = $base.Substring($i + 1)
        $st = Join-Path $State "jobs\$job.state"
        if ((Read-VigilServiceStateValue $st 'run_id') -cne $rid) { continue }
        $wpid = Read-VigilServiceStateValue $st 'worker_pid'
        $jpid = Read-VigilServiceStateValue $st 'job_pid'
        $w = if ($wpid) { @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$wpid)" -ErrorAction SilentlyContinue)[0] }
        $wOk = $w -and ([string]$w.CommandLine).Contains("$rootArg worker $job --run-id $rid")
        if ($w) { if ($wOk) { $r.Proven.Add([int]$wpid) } else { $r.Unproven.Add([int]$wpid) } }
        if ($jpid) {
            $p = @(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$jpid)" -ErrorAction SilentlyContinue)[0]
            if ($p) {
                $name = Read-VigilServiceStateValue $st 'job_name'
                $start = Read-VigilServiceStateValue $st 'job_start'
                $ok = $wOk -and $name -and $p.Name -ieq $name -and $p.ParentProcessId -eq [int]$wpid -and
                    ((-not $start) -or [Math]::Abs((ConvertTo-VigilEpoch $p.CreationDate) - [long]$start) -le 1)
                if ($ok) { $r.Proven.Add([int]$jpid) } else { $r.Unproven.Add([int]$jpid) }
            }
        }
    }
    return $r
}

# vigil uninstall (18.8): the service, the proven workers, then the root (all
# of it, or all but config\ and scripts\), and the PATH entries.
function Invoke-VigilUninstall {
    param([string]$Root, [string]$App, [bool]$Yes, [bool]$Keep)
    if (-not [System.IO.File]::Exists((Join-Path $Root 'app\vigil.ps1')) -or $Root.Length -le 3) {
        throw "$Root does not look like a Vigil install root (no app\vigil.ps1); nothing removed"
    }
    $ctx = Get-VigilWorkerContext -Root $Root -Job 'vigil_sender'
    $state = if ($ctx.Error) { Join-Path $Root 'state' } else { $ctx.State }
    $runs = Get-VigilServiceRuns -Root $Root -State $state
    $found = Find-VigilService -Root $Root
    $appDir = Join-Path $Root 'app'
    $paths = @(foreach ($scope in @('User', 'Machine')) {
            $v = [Environment]::GetEnvironmentVariable('Path', $scope)
            if ($v -and @($v.Split(';') | Where-Object { $_.TrimEnd('\') -ieq $appDir }).Count -gt 0) { $scope }
        })
    $scripts = Join-Path $Root 'scripts'
    $n = if ([System.IO.Directory]::Exists($scripts)) { @([System.IO.Directory]::GetFiles($scripts, '*', 'AllDirectories')).Count } else { 0 }

    Write-Output 'vigil uninstall will remove:'
    if ($found.Mode) { Write-Output "  the Vigil $(if ($found.Mode -ceq 'system') { 'service' } else { 'Run entry' }) ($($found.Mode) mode)" }
    if ($runs.Proven.Count -gt 0) { Write-Output "  running Vigil processes: $($runs.Proven -join ' ')" }
    if ($Keep) { Write-Output "  $Root, except config and scripts ($n scripts kept)" }
    else { Write-Output "  $Root, including config and scripts ($n scripts)" }
    foreach ($s in $paths) { Write-Output "  $appDir from the $($s.ToLowerInvariant()) PATH" }
    if ($runs.Unproven.Count -gt 0) { Write-Output "and leave running, since they cannot be proven to be Vigil's: $($runs.Unproven -join ' ')" }
    if (-not $Yes) {
        if ([Console]::IsInputRedirected) { throw 'not a console: confirm with --yes' }
        $a = Read-Host -Prompt 'Remove? [y/N]'
        if ($a -notmatch '^(y|yes)$') { Write-Output 'nothing removed'; return 1 }
    }

    if ($found.Mode -ceq 'system' -and -not (Test-VigilAdmin)) { throw 'the service is registered in system mode: run it from an elevated prompt' }
    if ($found.Mode) { [void](Remove-VigilService -Root $Root) }
    # Windows has no TERM for console programs: each proven tree ends at once.
    foreach ($p in $runs.Proven) { & taskkill.exe /T /F /PID $p 2>&1 | Out-Null }
    foreach ($s in $paths) {
        if ($s -ceq 'Machine' -and -not (Test-VigilAdmin)) { Write-Output "  left $appDir in the machine PATH: removing it needs an elevated prompt"; continue }
        $v = [Environment]::GetEnvironmentVariable('Path', $s)
        [Environment]::SetEnvironmentVariable('Path', ((@($v.Split(';') | Where-Object { $_ -and $_.TrimEnd('\') -ine $appDir })) -join ';'), $s)
    }

    # Everything but what is kept; files still held (a process just ended,
    # or this command itself) are retried, then left to a detached cleanup.
    $targets = @(Get-ChildItem -LiteralPath $Root -Force | Where-Object { -not ($Keep -and ($_.Name -ieq 'config' -or $_.Name -ieq 'scripts')) })
    $left = $targets
    for ($i = 0; $i -lt 10 -and $left.Count -gt 0; $i++) {
        foreach ($t in $left) { Remove-Item -LiteralPath $t.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $left = @($targets | Where-Object { Test-Path -LiteralPath $_.FullName })
        if ($left.Count -gt 0) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $Keep -and $left.Count -eq 0) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
    if ((-not $Keep -and (Test-Path -LiteralPath $Root)) -or $left.Count -gt 0) {
        # This command runs from app\, so app\ may only go once it exits: a
        # short-lived detached cmd.exe finishes the job.
        $what = if ($Keep) { ($left | ForEach-Object { "rmdir /s /q `"$($_.FullName)`" 2>nul & del /f /q `"$($_.FullName)`" 2>nul" }) -join ' & ' } else { "rmdir /s /q `"$Root`"" }
        $cl = "cmd.exe /d /c ping -n 4 127.0.0.1 >nul & $what"
        [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cl; CurrentDirectory = $env:SystemRoot })
        Write-Output 'removed Vigil; the last files go in a few seconds, once this command exits'
    }
    elseif ($Keep) { Write-Output "removed Vigil; kept $Root\config and $Root\scripts" }
    else { Write-Output 'removed Vigil' }
    return 0
}
