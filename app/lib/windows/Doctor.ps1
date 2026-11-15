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
        How many runs a job log records as started since then.

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
    $n = 0
    if (-not [System.IO.Directory]::Exists($Dir)) { return 0 }
    $cutoff = [DateTime]::UtcNow.AddHours(-2)
    foreach ($f in [System.IO.Directory]::GetFiles($Dir, '*.log')) {
        if ([System.IO.File]::GetLastWriteTimeUtc($f) -lt $cutoff) { continue }
        try {
            foreach ($l in [System.IO.File]::ReadAllLines($f)) {
                # "<ISO> <run id> run start": the ISO times compare as text.
                if ($l -cmatch '^(\S+) \S+ run start$' -and [string]::CompareOrdinal($Matches[1], $Since) -ge 0) { $n++ }
            }
        }
        catch { }
    }
    return $n
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

    # What Vigil costs: each job's last run (cpu_seconds, 12.2) times its
    # runs in the last hour, from its log.
    $out.Add("What Vigil costs (each job's last run, and its runs in the last hour)")
    $jobsDir = Join-Path $stateDir 'jobs'
    $jobLogs = Join-Path $logDir 'jobs'
    $denied = if ($configDenied) { $configDenied } else { Get-VigilDenied $jobsDir }
    if (-not $denied) { $denied = Get-VigilDenied $jobLogs }
    if ($denied) { & $warn (Get-VigilDeniedMessage $denied) }
    else {
        $since = [DateTime]::UtcNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $files = if ([System.IO.Directory]::Exists($jobsDir)) { [System.IO.Directory]::GetFiles($jobsDir, '*.state') } else { @() }
        foreach ($f in $files) {
            $job = [System.IO.Path]::GetFileNameWithoutExtension($f)
            $st = ConvertFrom-VigilConfig -Path $f
            $cpu = Get-VigilConfigValue $st 'state' 'cpu_seconds' ''
            $wall = Get-VigilConfigValue $st 'state' 'duration_seconds' ''
            $runs = Get-VigilRunsSince -Dir (Join-Path $jobLogs $job) -Since $since
            $c = 0.0
            $known = [double]::TryParse($cpu, [System.Globalization.NumberStyles]::Float, $inv, [ref]$c)
            $rows.Add([pscustomobject]@{ Job = $job; Runs = $runs; Cpu = $(if ($known) { $c } else { $null }); Wall = $wall; Cost = $(if ($known) { $runs * $c } else { 0 }) })
        }
        if ($rows.Count -eq 0) { & $note 'no runs recorded yet' }
        else {
            $out.Add(('  {0,-24} {1,6} {2,10} {3,10}' -f 'job', 'runs', 'CPU/run', 'wall/run'))
            $cores = 0.0
            $unknown = 0
            foreach ($r in ($rows | Sort-Object -Property @{ Expression = 'Cost'; Descending = $true }, Job)) {
                $cpuText = if ($null -eq $r.Cpu) { $unknown++; '-' } else { $r.Cpu.ToString('0.00', $inv) + ' s' }
                $wallText = if ($r.Wall) { "$($r.Wall) s" } else { '-' }
                $out.Add(('  {0,-24} {1,6} {2,10} {3,10}' -f $r.Job, $r.Runs, $cpuText, $wallText))
                $cores += $r.Cost / 3600
            }
            $busy = "Vigil keeps $($cores.ToString('0.00', $inv)) of a core busy"
            if ($cores -gt 0.5) { & $warn "$busy, above half of one: the jobs above cost the most" }
            elseif ($cores -gt 0.25) { & $note "$busy, above a quarter of one" }
            else { & $ok $busy }
            if ($unknown) { & $note "$unknown job(s) show no CPU: their last run was before Vigil recorded it" }
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
        try { $ex = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ }) } catch { }
        $rootSlash = $Root.TrimEnd('\') + '\'
        if ($null -eq $ex -or @($ex | Where-Object { $_ -like 'N/A*' }).Count) { $cover = 'its exclusions are shown only to administrators' }
        elseif (@($ex | Where-Object { $rootSlash.StartsWith($_.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) }).Count) { $cover = "an exclusion covers $Root" }
        else { $cover = "no exclusion covers $Root" }
        & $note "Defender: real-time protection is on and scans each script a run loads; $cover"
    }

    # PowerShell logging policies: each logs every script a run executes.
    $set = @()
    foreach ($ed in @(@('Windows\PowerShell', 'Windows PowerShell'), @('PowerShellCore', 'PowerShell 7'))) {
        foreach ($p in @(@('ScriptBlockLogging', 'EnableScriptBlockLogging', 'script block logging'), @('ModuleLogging', 'EnableModuleLogging', 'module logging'), @('Transcription', 'EnableTranscripting', 'transcription'))) {
            $v = $null
            try { $v = [Microsoft.Win32.Registry]::GetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\$($ed[0])\$($p[0])", $p[1], $null) } catch { }
            if ("$v" -ceq '1') { $set += "$($p[2]) ($($ed[1]))" }
        }
    }
    if ($set.Count) { & $note "PowerShell logging policies set: $($set -join ', '); each makes every script a run executes cost more" }
    else { & $ok 'PowerShell logging policies: none set' }

    $out.Add('')
    if ($n.Warn) { $out.Add("doctor: $($n.Warn) warning(s)") } else { $out.Add('doctor: no warnings') }
    return @{ Code = $(if ($n.Warn) { 1 } else { 0 }); Lines = $out }
}
