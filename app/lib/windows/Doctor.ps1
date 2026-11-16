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
    Vigil doctor - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    What vigil doctor prints (SPECIFICATION.md 16.7): how well Vigil runs on
    this machine. Reads only; changes and fixes nothing. The twin of
    doctor.sh.

    Invoke-VigilDoctor -Root <dir>
        Returns @{ Code; Lines }: Code is 1 when any line is WARN, else 0.
    Test-VigilNativeImages
        Whether Windows PowerShell starts with .NET's native images (NGEN).
        Returns @{ Ok; Text }. Used by doctor and by precheck.
    Get-VigilRunsSince -Dir <job log dir> -Since <ISO 8601 UTC>
        The runs a job log records as ended since then: @{ Runs; Measured;
        Cpu; Wall; Unreadable }, Cpu summed over the Measured runs that
        recorded it, Unreadable the log files that could not be read.

    Requires Config.ps1, Effective.ps1, Command.ps1 and Fetch.ps1.
#>

$Script:VigilDoctorShells = @('powershell', 'pwsh', 'cmd', 'bash', 'sh')

function Test-VigilNativeImages {
    $fix = 'every start compiles .NET itself; from an elevated prompt run ngen.exe executeQueuedItems in %WINDIR%\Microsoft.NET\Framework64\v4.0.30319 and Framework\v4.0.30319'
    # A stand-in for a machine whose native images are missing or not yet
    # compiled, for the tests (22.4.6). It can only make the check fail.
    if ($env:VIGIL_TEST_NGEN_MISSING) { return @{ Ok = $false; Text = "Windows PowerShell starts without .NET's native images: $fix" } }
    $names = @()
    if ($PSVersionTable.PSEdition -ne 'Core') {
        try { $names = @([System.Diagnostics.Process]::GetCurrentProcess().Modules | ForEach-Object { $_.ModuleName }) } catch { }
    }
    else {
        # PowerShell 7 has no NGEN: ask a fresh Windows PowerShell.
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not [System.IO.File]::Exists($ps)) { return @{ Ok = $true; Text = '.NET native images: no Windows PowerShell here' } }
        try { $names = @(& $ps -NoProfile -NonInteractive -Command '[System.Diagnostics.Process]::GetCurrentProcess().Modules | ForEach-Object { $_.ModuleName }' 2>$null) } catch { }
    }
    if ($names.Count -eq 0) { return @{ Ok = $true; Text = ".NET native images: cannot tell from this session" } }
    if ($names -contains 'System.Management.Automation.ni.dll') { return @{ Ok = $true; Text = '.NET native images: Windows PowerShell loads them' } }
    return @{ Ok = $false; Text = "Windows PowerShell starts without .NET's native images: $fix" }
}

function Get-VigilRunsSince {
    param([string]$Dir, [string]$Since)
    $r = @{ Runs = 0; Measured = 0; Cpu = 0.0; Wall = 0; Unreadable = @() }
    if (-not [System.IO.Directory]::Exists($Dir)) { return $r }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $cutoff = [DateTime]::UtcNow.AddHours(-2)
    foreach ($f in [System.IO.Directory]::GetFiles($Dir, '*.log')) {
        if ([System.IO.File]::GetLastWriteTimeUtc($f) -lt $cutoff) { continue }
        # Shared for writing and deleting, as the log forwarder reads: a
        # reader allowing only reading would make a worker appending its
        # lines at that moment fail to write them (backlog 54).
        $reader = $null
        try {
            $reader = New-Object System.IO.StreamReader -ArgumentList (New-Object System.IO.FileStream -ArgumentList $f, 'Open', 'Read', ([System.IO.FileShare]'ReadWrite, Delete'))
            while ($null -ne ($l = $reader.ReadLine())) {
                # "<ISO> <run id> run end <outcome> ... in <n>s, cpu <s>s"
                # (13.1): the ISO times compare as text.
                if ($l -notmatch '^(\S+) \S+ run end .* in ([0-9]+)s(, cpu ([0-9]+\.[0-9]+)s)?$' -or [string]::CompareOrdinal($Matches[1], $Since) -lt 0) { continue }
                $r.Runs++
                $r.Wall += [int]$Matches[2]
                if ($Matches[4]) { $r.Measured++; $r.Cpu += [double]::Parse($Matches[4], $inv) }
            }
        }
        catch { $r.Unreadable += $f }
        finally { if ($reader) { $reader.Dispose() } }
    }
    return $r
}

# When the supervisor last started, from its log of today or yesterday
# ("<ISO> INFO supervisor supervisor started, pid <n>", 13.1): the ISO
# time, or '' when no log says.
function Get-VigilSupervisorStart {
    param([string]$Dir)
    $last = ''
    if (-not [System.IO.Directory]::Exists($Dir)) { return $last }
    $cutoff = [DateTime]::UtcNow.AddDays(-2)
    foreach ($f in [System.IO.Directory]::GetFiles($Dir, '*.log')) {
        if ([System.IO.File]::GetLastWriteTimeUtc($f) -lt $cutoff) { continue }
        $reader = $null
        try {
            $reader = New-Object System.IO.StreamReader -ArgumentList (New-Object System.IO.FileStream -ArgumentList $f, 'Open', 'Read', ([System.IO.FileShare]'ReadWrite, Delete'))
            while ($null -ne ($l = $reader.ReadLine())) {
                if ($l -cmatch '^(\S+) INFO supervisor supervisor started, pid ' -and [string]::CompareOrdinal($Matches[1], $last) -gt 0) { $last = $Matches[1] }
            }
        }
        catch { }
        finally { if ($reader) { $reader.Dispose() } }
    }
    return $last
}

# One bare start of a shell: @{ Cpu; Wall } in seconds, or $null.
function Measure-VigilShellStart {
    param([string]$Program)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Program).ToLowerInvariant()
    $argLine = if (@('powershell', 'pwsh') -ccontains $name) { '-NoProfile -NonInteractive -Command exit' } elseif ($name -ceq 'cmd') { '/d /c exit' } else { '-c exit' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo $Program, $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$p.StandardOutput.ReadToEnd()
        [void]$p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $clock.Stop()
        return @{ Cpu = $p.TotalProcessorTime.TotalSeconds; Wall = $clock.Elapsed.TotalSeconds }
    }
    catch { return $null }
}

function Invoke-VigilDoctor {
    param([string]$Root)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $n = @{ Warn = 0 }
    $ok = { param($What) $out.Add("  ok    $What") }
    $note = { param($What) $out.Add("  note  $What") }
    $warn = { param($What) $out.Add("  WARN  $What"); $n.Warn++ }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $path = Join-Path $Root 'config\vigil.config'
    # A configuration this account cannot read (a system install, from a
    # standard prompt) is never taken for a missing one (18.5): what it
    # cannot read is said, and the checks that need no configuration run.
    $configDenied = Get-VigilDenied $path
    $parsed = if ($configDenied) { [pscustomobject]@{ Entries = @(); Sections = @(); Errors = @() } } else { ConvertFrom-VigilConfig -Path $path }
    $dir = {
        param($Section, $Key, $Default)
        $v = Get-VigilConfigValue $parsed $Section $Key $Default
        if ([System.IO.Path]::IsPathRooted($v)) { return $v }
        return Join-Path $Root $v
    }
    # The state directory is always the local file's (6.8).
    $stateDir = & $dir 'vigil' 'state_dir' 'state'
    $logDir = & $dir 'log' 'dir' 'logs'
    # With sources, the jobs are the active configuration's.
    $jobsParsed = $parsed
    if (-not $configDenied -and (Test-VigilFetchMode -Parsed $parsed) -and (Get-VigilConfigValue $parsed 'vigil' 'config_source' '')) {
        $active = Read-VigilActive -Root $Root -State $stateDir
        if ($active -and [System.IO.File]::Exists($active.Config)) { $jobsParsed = ConvertFrom-VigilConfig -Path $active.Config }
    }

    # What Vigil's runs cost: what each run used (cpu_seconds, 12.2), from
    # the run end lines of the last hour (13.1).
    $out.Add("What Vigil's runs cost in the last hour")
    $jobLogs = Join-Path $logDir 'jobs'
    $denied = if ($configDenied) { $configDenied } else { Get-VigilDenied $jobLogs }
    if ($denied) { & $warn (Get-VigilDeniedMessage $denied) }
    else {
        $since = [DateTime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $dirs = if ([System.IO.Directory]::Exists($jobLogs)) { [System.IO.Directory]::GetDirectories($jobLogs) } else { @() }
        $unreadable = @()
        foreach ($d in $dirs) {
            $r = Get-VigilRunsSince -Dir $d -Since $since
            $unreadable += $r.Unreadable
            if ($r.Runs -eq 0) { continue }
            $rows.Add([pscustomobject]@{ Job = [System.IO.Path]::GetFileName($d); Runs = $r.Runs; Measured = $r.Measured; Cpu = $r.Cpu; Wall = $r.Wall })
        }
        if ($rows.Count -eq 0) { & $note 'no runs in the last hour' }
        else {
            $out.Add(('  {0,-24} {1,6} {2,10} {3,10} {4,10}' -f 'job', 'runs', 'CPU', 'CPU/run', 'time/run'))
            $cores = 0.0
            $unknown = 0
            foreach ($r in ($rows | Sort-Object -Property @{ Expression = 'Cpu'; Descending = $true }, Job)) {
                $cpuText = if ($r.Measured) { $r.Cpu.ToString('0.00', $inv) + ' s' } else { '-' }
                $perRun = if ($r.Measured) { ($r.Cpu / $r.Measured).ToString('0.00', $inv) + ' s' } else { '-' }
                $out.Add(('  {0,-24} {1,6} {2,10} {3,10} {4,10}' -f $r.Job, $r.Runs, $cpuText, $perRun, (($r.Wall / $r.Runs).ToString('0.0', $inv) + ' s')))
                $cores += $r.Cpu / 3600
                $unknown += $r.Runs - $r.Measured
            }
            $busy = "Vigil's runs keep $($cores.ToString('0.00', $inv)) of a core busy"
            if ($cores -gt 0.5) { & $warn "$busy, above half of one: the jobs above cost the most" }
            elseif ($cores -gt 0.25) { & $note "$busy, above a quarter of one" }
            else { & $ok $busy }
            if ($unknown) { & $note "$unknown run(s) show no CPU: they ended before Vigil recorded it" }
        }
        # A log it could not read is not a job with no runs (18.5).
        foreach ($f in $unreadable) { & $warn "cannot read ${f}: its runs are not counted above" }
        # Less than an hour of runs is still shown over an hour: said.
        $started = Get-VigilSupervisorStart -Dir (Join-Path $logDir 'supervisor')
        if ($started -and [string]::CompareOrdinal($started, $since) -gt 0) {
            $minutes = [int][Math]::Floor(([DateTime]::UtcNow - [DateTime]::ParseExact($started, 'yyyy-MM-ddTHH:mm:ssZ', $inv, [System.Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')).TotalMinutes)
            & $note "the supervisor started $minutes minute(s) ago: the figures above are those minutes of runs, over a full hour"
        }
    }

    # How long a bare start of each shell takes: every run starts one.
    $out.Add('')
    $out.Add('Starting a shell (median of 3)')
    $shells = New-Object 'System.Collections.Generic.List[string]'
    $self = (Get-Process -Id $PID).Path
    $shells.Add($self)
    $index = if ($configDenied) { $null } else { New-VigilConfigIndex -Parsed $jobsParsed }
    foreach ($sec in $jobsParsed.Sections) {
        if (-not $sec.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
        try { $cmd = Get-VigilJobCommand -Index $index -Id $sec.Name.Substring(4) -Platform 'windows' -Root $Root } catch { continue }
        if ($cmd.Error -or -not $cmd.Program) { continue }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($cmd.Program).ToLowerInvariant()
        if ($Script:VigilDoctorShells -cnotcontains $name) { continue }
        $prog = $cmd.Program
        if (-not $prog.Contains('\')) {
            $found = Get-Command $prog -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $found) { continue }
            $prog = $found.Source
        }
        if (-not ($shells | Where-Object { $_ -ieq $prog })) { $shells.Add($prog) }
    }
    foreach ($s in $shells) {
        $m = @(1..3 | ForEach-Object { Measure-VigilShellStart $s } | Where-Object { $_ })
        $label = [System.IO.Path]::GetFileName($s).ToLowerInvariant()
        if ($m.Count -eq 0) { & $note "${label}: could not be started"; continue }
        $cpu = @($m | ForEach-Object { $_.Cpu } | Sort-Object)[[int][math]::Floor(($m.Count - 1) / 2)]
        $wall = @($m | ForEach-Object { $_.Wall } | Sort-Object)[[int][math]::Floor(($m.Count - 1) / 2)]
        $text = "${label}: $($cpu.ToString('0.00', $inv)) CPU s, $($wall.ToString('0.00', $inv)) s"
        if ($wall -gt 1) { & $warn "$text, above 1 s: every run starts it" } else { & $ok $text }
    }

    $out.Add('')
    $out.Add('Windows')
    $ni = Test-VigilNativeImages
    if ($ni.Ok) { & $ok $ni.Text } else { & $warn $ni.Text }

    # Defender: what it does, never a recommendation (backlog 51).
    $status = $null
    $why = ''
    try { $status = Get-MpComputerStatus -ErrorAction Stop }
    catch [System.Management.Automation.CommandNotFoundException] { $why = 'not on this machine' }
    catch { $why = "cannot read its status from this session ($($_.Exception.Message.Trim()))" }
    if (-not $status) { & $note "Defender: $why" }
    elseif (-not $status.RealTimeProtectionEnabled) { & $ok 'Defender: real-time protection is off' }
    else {
        $ex = $null
        $exWhy = ''
        try { $ex = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ }) }
        catch { $exWhy = $_.Exception.Message.Trim() }
        $rootSlash = $Root.TrimEnd('\') + '\'
        # Unknown is said as unknown, with why (18.5), never as none.
        if ($exWhy) { $cover = "its exclusions cannot be read from this session ($exWhy)" }
        elseif (@($ex | Where-Object { $_ -like 'N/A*' }).Count) { $cover = 'its exclusions are shown only to administrators' }
        elseif (@($ex | Where-Object { $rootSlash.StartsWith($_.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) }).Count) { $cover = "an exclusion covers $Root" }
        else { $cover = "no exclusion covers $Root" }
        & $note "Defender: real-time protection is on and scans each script a run loads; $cover"
    }

    # PowerShell logging policies: each logs every script a run executes.
    $set = @()
    $unread = @()
    foreach ($ed in @(@('Windows\PowerShell', 'Windows PowerShell'), @('PowerShellCore', 'PowerShell 7'))) {
        foreach ($p in @(@('ScriptBlockLogging', 'EnableScriptBlockLogging', 'script block logging'), @('ModuleLogging', 'EnableModuleLogging', 'module logging'), @('Transcription', 'EnableTranscripting', 'transcription'))) {
            $v = $null
            try { $v = [Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\$($ed[0])\$($p[0])", $p[1], $null) }
            catch { $unread += "$($p[2]) ($($ed[1]))" }
            if ("$v" -ceq '1') { $set += "$($p[2]) ($($ed[1]))" }
        }
    }
    if ($set.Count) { & $note "PowerShell logging policies set: $($set -join ', '); each makes every script a run executes cost more" }
    # A policy it could not read is not one that is not set (18.5).
    if ($unread.Count) { & $note "PowerShell logging policies: cannot read $($unread -join ', ') from this session" }
    elseif (-not $set.Count) { & $ok 'PowerShell logging policies: none set' }

    $out.Add('')
    if ($n.Warn) { $out.Add("doctor: $($n.Warn) warning(s)") } else { $out.Add('doctor: no warnings') }
    return @{ Code = $(if ($n.Warn) { 1 } else { 0 }); Lines = $out }
}
