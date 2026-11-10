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
    vigil - the Vigil command on Windows (SPECIFICATION.md 18.5).
.DESCRIPTION
    vigil [-Root <dir>] run <job>
        Runs one job once now, in the foreground, for testing. Exits 0
        succeeded, 1 warning, 2 failed, 3 unknown, 4 not run.
    vigil [-Root <dir>] resolve <job>
        Confirms that the uncertain run holding <job> is over (11.4). Never
        kills anything; the supervisor concludes the run at its next tick.
    vigil [-Root <dir>] precheck [<job>]
        Pre-flight checks (16.4), changing nothing: the configuration's
        problems, then everything runs need. With a job, also its effective
        settings (6.6). Exits 0 when nothing failed, 1 otherwise.
    vigil [-Root <dir>] config
        Edits the configuration as crontab -e does (16.6): a copy opens in
        %VISUAL%, %EDITOR% or Notepad, and is saved only when it has no
        ERROR or INVALID line. Exits 0 saved or unchanged, 1 not saved.
    vigil [-Root <dir>] secret set <NAME> [--stdin] | secret list | secret delete <NAME>
        Vigil's own secret store (6.5.2), encrypted with DPAPI. set prompts
        without echo, or reads the value from stdin; list never shows values.
    vigil [-Root <dir>] service install [--user | --system] [--host powershell | pwsh] [--no-start]
        Registers the supervisor (18.1) after the pre-flight checks pass, and
        starts it: an NSSM service running as LocalSystem (--system, needs an
        elevated prompt), or a per-user Run entry (--user). The default mode
        is system when elevated, user otherwise. --host picks Windows
        PowerShell 5.1 (the default) or PowerShell 7 for the supervisor and
        its workers.
    vigil [-Root <dir>] service remove
        Unregisters it. Running workers continue.
    vigil [-Root <dir>] start | stop | restart
        Service control. Stopping leaves running workers alone (18.3).
    vigil [-Root <dir>] status
        The service's state, then jobs.log.
    vigil [-Root <dir>] pack list | enable <what> | disable <what> | update [--check]
        The packs of scripts and jobs (18.10). What is a pack or a pack_job.
    vigil [-Root <dir>] init [empty] [--instance <name>] [--backend file,datadog,otel] [--no-pack]
        Writes a starting configuration (19): runners for the PowerShell
        hosts found here, the backends, and the base pack's jobs; empty for neither;
        job. Asks for what is not given when run at a console. Never
        overwrites a configuration, never asks for a secret value.
    vigil [-Root <dir>] uninstall [--yes] [--keep-config]
        Removes Vigil (18.8): the service, the running workers proven to be
        Vigil's, the root (or all but config and scripts) and the PATH
        entries. Lists what it will remove and asks first, unless --yes.
    vigil [-Root <dir>] version
        The installed version.
    vigil [-Root <dir>] about
        What Vigil is, who made it and where it runs.
    vigil [-Root <dir>] self update [--check] [--version <version>]
        Upgrades this install to the latest release, or the one given (18.7).
        --check only says whether there is a newer one.
    vigil [-Root <dir>] supervise [--once]
        The supervisor (4.1): ticks until stopped, or once with --once.
        Running workers are never stopped with it.
    vigil [-Root <dir>] worker <job> --run-id <run id>
        Internal: the worker the supervisor starts for a launched run.

    The install root is -Root, else $env:VIGIL_ROOT, else the root a package
    names in app\PACKAGED, else the folder that contains this app folder.
#>

param(
    [string]$Root,
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Job,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$app = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($lib in @('Config', 'Validate', 'Effective', 'Command', 'Schedule', 'Outcome', 'Metrics', 'Events', 'Recovery', 'Prom', 'Secrets', 'Stores', 'Worker', 'Backends', 'Sender', 'Fetch', 'Logs', 'Format', 'Supervisor', 'Precheck', 'Service', 'Init', 'SelfUpdate', 'Pack', 'ConfigEdit')) {
    . (Join-Path $app "lib\windows\$lib.ps1")
}

# The root (18.6): -Root, else VIGIL_ROOT, else a package's, else the folder
# above app\. Only a package's may not exist yet: vigil init makes it.
$packaged = Get-VigilPackaged -App $app
if (-not $Root -and -not $env:VIGIL_ROOT -and $packaged -and $packaged.Root) {
    $Root = [System.IO.Path]::GetFullPath($packaged.Root)
}
else {
    if (-not $Root) { $Root = if ($env:VIGIL_ROOT) { $env:VIGIL_ROOT } else { Split-Path -Parent $app } }
    $Root = (Resolve-Path -LiteralPath $Root).ProviderPath
}

function Exit-Usage {
    [Console]::Error.WriteLine("usage: vigil [-Root <dir>] run <job> | resolve <job> | precheck [<job>] | config | supervise [--once]`n       vigil [-Root <dir>] secret set <NAME> [--stdin] | secret list | secret delete <NAME>`n       vigil [-Root <dir>] service install [--user | --system] [--host powershell | pwsh] [--no-start] | service remove`n       vigil [-Root <dir>] start | stop | restart | status`n       vigil [-Root <dir>] init [empty] [--instance <name>] [--backend <list>] [--no-pack] | uninstall [--yes] [--keep-config]`n       vigil [-Root <dir>] pack list | enable <what> | disable <what> | update [--check]`n       vigil [-Root <dir>] version | about | self update [--check] [--version <version>]")
    exit 64
}

switch ($Command) {
    'run' {
        if (-not $Job -or $Rest) { Exit-Usage }
        # Refuse while any run of the job may be in progress.
        $ctx = Get-VigilWorkerContext -Root $Root -Job $Job
        $locks = if ($ctx.Error) { Join-Path $Root 'state\locks' } else { Join-Path $ctx.State 'locks' }
        if (Test-Path -LiteralPath $locks) {
            $busy = Get-ChildItem -LiteralPath $locks -File | Where-Object {
                $_.Name.StartsWith("$Job.", [System.StringComparison]::Ordinal) -and ($_.Name.EndsWith('.launch') -or $_.Name.EndsWith('.token'))
            } | Select-Object -First 1
            if ($busy) {
                [Console]::Error.WriteLine("vigil: a run of $Job may be in progress ($($busy.FullName)); not starting")
                exit 4
            }
        }
        $rid = New-VigilLaunch -Root $Root -Job $Job
        if (-not $rid) { exit 4 }
        $r = Invoke-VigilWorker -Root $Root -Job $Job -RunId $rid
        if ($r.Code -le 3) {
            if ($r.Reason) { Write-Output "${Job}: $($r.Outcome) ($($r.Reason)) in $($r.Duration)s, run $rid" }
            else { Write-Output "${Job}: $($r.Outcome) in $($r.Duration)s, run $rid" }
        }
        exit $r.Code
    }
    'resolve' {
        if (-not $Job -or $Rest) { Exit-Usage }
        $ctx = Get-VigilWorkerContext -Root $Root -Job $Job
        if ($ctx.Error) { [Console]::Error.WriteLine("vigil: $($ctx.Error)"); exit 1 }
        $rec = Read-VigilRecoveryRecord $ctx.State $Job
        if (-not $rec.RunId) { [Console]::Error.WriteLine("vigil: $Job is not held: there is no uncertain run to resolve"); exit 1 }
        $who = $env:USERNAME
        $at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        # A file of its own, so the supervisor rewriting the record cannot
        # lose it (11.4). Nothing is killed.
        Write-VigilFileAtomic -Path (Join-Path $ctx.State "recovery\$Job.resolved") -Text "[resolved]`nresolved_by = $who`nresolved_at = $at`n"
        Write-Output "${Job}: run $($rec.RunId) marked as over by $who; the supervisor concludes it and releases the job at its next tick"
        exit 0
    }
    'precheck' {
        if ($Rest) { Exit-Usage }
        $r = Invoke-VigilPrecheck -Root $Root -Job $Job
        foreach ($l in $r.Lines) { Write-Output $l }
        exit $r.Code
    }
    'config' {
        if ($Job -or $Rest) { Exit-Usage }
        exit (Invoke-VigilConfigEdit -Root $Root)
    }
    'secret' {
        # Vigil's own secret store (6.5.2). Values are read from the console
        # without echo, or from stdin with --stdin; never from arguments.
        # PowerShell binds the subcommand to Job and the rest to Rest.
        $argv = @($Rest | Where-Object { $null -ne $_ })
        if ($Job -ceq 'set' -and ($argv.Count -eq 1 -or ($argv.Count -eq 2 -and $argv[1] -ceq '--stdin'))) {
            $name = $argv[0]
            if ($argv.Count -eq 2) {
                $text = Remove-VigilTrailingNewline ([Console]::In.ReadToEnd())
                $value = New-Object System.Security.SecureString
                foreach ($c in $text.ToCharArray()) { $value.AppendChar($c) }
                $text = $null
            }
            else {
                if ([Console]::IsInputRedirected) { [Console]::Error.WriteLine('vigil: not a console; use --stdin'); exit 64 }
                $value = Read-Host -AsSecureString -Prompt "Value for $name (not echoed)"
            }
            try { Set-VigilSecret -Root $Root -Name $name -Value $value }
            catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
            Write-Output "$name set; runs started from now on use it"
            exit 0
        }
        if ($Job -ceq 'list' -and $argv.Count -eq 0) { Get-VigilSecretList -Root $Root; exit 0 }
        if ($Job -ceq 'delete' -and $argv.Count -eq 1) {
            try { Remove-VigilSecret -Root $Root -Name $argv[0] }
            catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
            exit 0
        }
        Exit-Usage
    }
    'service' {
        $argv = @($Rest | Where-Object { $null -ne $_ })
        try {
            if ($Job -ceq 'install') {
                $mode = ''
                $hostName = 'powershell'
                $start = $true
                for ($i = 0; $i -lt $argv.Count; $i++) {
                    switch -CaseSensitive ($argv[$i]) {
                        '--user' { $mode = 'user' }
                        '--system' { $mode = 'system' }
                        '--no-start' { $start = $false }
                        '--host' {
                            if ($i + 1 -ge $argv.Count) { Exit-Usage }
                            $i++
                            $hostName = $argv[$i]
                        }
                        default { Exit-Usage }
                    }
                }
                Install-VigilService -Root $Root -App $app -Mode $mode -HostName $hostName -Start $start
                exit 0
            }
            if ($Job -ceq 'remove' -and $argv.Count -eq 0) { Remove-VigilService -Root $Root; exit 0 }
        }
        catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
        Exit-Usage
    }
    { $_ -ceq 'start' -or $_ -ceq 'stop' -or $_ -ceq 'restart' } {
        if ($Job -or $Rest) { Exit-Usage }
        try { Invoke-VigilServiceControl -Root $Root -Action $Command }
        catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
        exit 0
    }
    'init' {
        # PowerShell binds the first flag to Job and the rest to Rest.
        $argv = @(@($Job) + @($Rest) | Where-Object { $_ })
        $instance = ''
        $backends = ''
        $pack = 'base'
        $empty = $false
        $secrets = New-Object System.Collections.Generic.List[string]
        $refs = @{}
        if ($argv.Count -gt 0 -and $argv[0] -ceq 'empty') {
            $empty = $true
            $pack = ''
            $argv = @($argv | Select-Object -Skip 1)
        }
        for ($i = 0; $i -lt $argv.Count; $i++) {
            switch -CaseSensitive ($argv[$i]) {
                { $_ -ceq '--instance' -or $_ -ceq '--backend' } {
                    if ($i + 1 -ge $argv.Count) { Exit-Usage }
                    if ($argv[$i] -ceq '--instance') { $instance = $argv[$i + 1] } else { $backends = $argv[$i + 1] }
                    $i++
                }
                '--no-pack' { $pack = '' }
                default { Exit-Usage }
            }
        }
        # Defaults: the computer name, and the file backend.
        $hostName = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '-').ToLowerInvariant()
        $asked = $false
        if (-not [Console]::IsInputRedirected -and -not $instance) { $instance = Read-Host -Prompt "Instance name [$hostName]"; $asked = $true }
        if (-not [Console]::IsInputRedirected -and -not $backends -and -not $empty) {
            $backends = Read-Host -Prompt 'Backends, comma-separated: file, datadog, otel [file]'
            $asked = $true
            # The credential: a name is asked for, and a secret's value only by
            # vigil secret set, which does not show it.
            foreach ($b in @($backends.Replace(' ', '').Split(',') | Where-Object { $_ -ceq 'datadog' -or $_ -ceq 'otel' })) {
                $name = if ($b -ceq 'datadog') { 'DATADOG_API_KEY' } else { 'OTEL_API_KEY' }
                $how = Read-Host -Prompt "Credential for ${b}: (e)nvironment variable, (s)ecret store$(if ($b -ceq 'otel') { ', (n)one' }) [e]"
                if ($how -cmatch '^[sS]') {
                    $given = Read-Host -Prompt "Secret name [$name]"
                    if ($given) { $name = $given }
                    $refs[$b] = "secret:$name"
                    $secrets.Add($name)
                }
                elseif ($how -cmatch '^[nN]') {
                    if ($b -cne 'otel') { [Console]::Error.WriteLine('vigil: datadog needs a credential'); exit 1 }
                    $refs[$b] = 'none'
                }
                else {
                    $given = Read-Host -Prompt "Environment variable [$name]"
                    if ($given) { $name = $given }
                    $refs[$b] = "env:$name"
                }
            }
        }
        if (-not $instance) { $instance = $hostName }
        if (-not $backends -and -not $empty) { $backends = 'file' }
        if ($asked) { Write-Output '' }
        try { Invoke-VigilInit -Root $Root -Instance $instance -Backends @($backends.Replace(' ', '').Split(',') | Where-Object { $_ }) -Refs $refs }
        catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
        if ((Copy-VigilPackSeed -Root $Root -App $app) -ne 0) { exit 1 }
        foreach ($n in $secrets) {
            Write-Output "The value of $n, which is not shown:"
            & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'vigil.ps1') -Root $Root secret set $n
            if ($LASTEXITCODE -ne 0) { Write-Output "not stored: run vigil secret set $n" }
        }
        if ($pack -and [System.IO.File]::Exists((Join-Path $Root "packs\$pack\pack.config"))) {
            $code = 0
            Enable-VigilPack -Root $Root -What $pack | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } }
            if ($code -ne 0) { exit 1 }
        }
        # A package registers its own service, and its install says how to
        # start it: vigil service install would refuse (18.6).
        if (-not $packaged) {
            Write-Output ''
            Write-Output 'Next: vigil precheck, then vigil service install'
        }
        exit 0
    }
    'uninstall' {
        $argv = @(@($Job) + @($Rest) | Where-Object { $_ })
        $yes = $false
        $keep = $false
        foreach ($a in $argv) {
            if ($a -ceq '--yes') { $yes = $true } elseif ($a -ceq '--keep-config') { $keep = $true } else { Exit-Usage }
        }
        if ($packaged) {
            [Console]::Error.WriteLine("vigil: Vigil was installed by $($packaged.Manager): remove it with that, which stops the service and keeps $Root")
            exit 1
        }
        $code = 1
        try { Invoke-VigilUninstall -Root $Root -App $app -Yes $yes -Keep $keep | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } } }
        catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
        exit $code
    }
    'status' {
        if ($Job -or $Rest) { Exit-Usage }
        try { Get-VigilServiceStatus -Root $Root }
        catch { [Console]::Error.WriteLine("vigil: $($_.Exception.Message)"); exit 1 }
        Show-VigilUpdateNotice -Root $Root -App $app
        exit 0
    }
    'version' {
        # PowerShell binds "--supervisor" to the remaining arguments.
        $flags = @(@($Job) + @($Rest) | Where-Object { $_ })
        if ($flags.Count -eq 1 -and $flags[0] -ceq '--supervisor') {
            $running = Get-VigilSupervisorVersion -Root $Root
            if (-not $running) { exit 1 }
            $running
            exit 0
        }
        if ($flags.Count -gt 0) { Exit-Usage }
        Get-VigilVersion -App $app
        Show-VigilUpdateNotice -Root $Root -App $app
        exit 0
    }
    'about' {
        if ($Job -or $Rest) { Exit-Usage }
        Get-VigilAbout -Root $Root -App $app
        Show-VigilUpdateNotice -Root $Root -App $app
        exit 0
    }
    'pack' {
        $argv = @($Rest | Where-Object { $_ })
        $code = 0
        if ($Job -ceq 'list' -and $argv.Count -eq 0) { Get-VigilPackList -Root $Root }
        elseif ($Job -ceq 'enable' -and $argv.Count -eq 1) { Enable-VigilPack -Root $Root -What $argv[0] | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } } }
        elseif ($Job -ceq 'disable' -and $argv.Count -eq 1) { Disable-VigilPack -Root $Root -What $argv[0] | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } } }
        elseif ($Job -ceq 'update' -and ($argv.Count -eq 0 -or ($argv.Count -eq 1 -and $argv[0] -ceq '--check'))) {
            Update-VigilPack -Root $Root -App $app -Check ($argv.Count -eq 1) | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } }
        }
        else { Exit-Usage }
        exit $code
    }
    'self' {
        if ($Job -ceq 'refresh-check' -and -not $Rest) {
            Update-VigilUpdateCache -Root $Root -App $app
            exit 0
        }
        if ($Job -ceq 'update-by' -and $Rest.Count -eq 1) {
            # Run by install.ps1 -UpdateBy (18.7).
            try { Install-VigilUpdateTask -Root $Root -App $app -Who $Rest[0] }
            catch {
                [Console]::Error.WriteLine("vigil: $($_.Exception.Message)")
                exit 1
            }
            exit 0
        }
        if ($Job -cne 'update') { Exit-Usage }
        $argv = @($Rest | Where-Object { $_ })
        if ($argv.Count -eq 1 -and $argv[0] -ceq '--task') { exit (Invoke-VigilSelfUpdateTask -Root $Root -App $app) }
        $configured = Get-VigilConfigVersion -Root $Root
        # Internal (18.11): what the vigil_update worker and the task of install
        # -UpdateBy run to follow the configuration. The version is read here,
        # never given; the exit code tells the worker what went wrong.
        if ($argv.Count -eq 1 -and $argv[0] -ceq '--from-config') {
            if (-not $configured) {
                [Console]::Error.WriteLine('vigil: the configuration names no version')
                exit 1
            }
            $code = 0
            Invoke-VigilSelfUpdate -Root $Root -App $app -Check $false -Want $configured -FromConfig $true |
                ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } }
            if ($code -eq 0) { exit 0 }
            if ($Script:VigilUpdateKind -ceq 'download') { exit 2 }
            if ($Script:VigilUpdateKind -ceq 'install') { exit 3 }
            exit 1
        }
        $check = $false
        $want = ''
        for ($i = 0; $i -lt $argv.Count; $i++) {
            if ($argv[$i] -ceq '--check') { $check = $true }
            elseif ($argv[$i] -ceq '--version' -and $i + 1 -lt $argv.Count) { $i++; $want = $argv[$i].TrimStart('v') }
            else { Exit-Usage }
        }
        # The configuration decides the version when it names one (18.11): an
        # update here would be undone at its next load.
        # A package's program is refused whatever the configuration says.
        if (-not $check -and $configured -and -not $packaged) {
            [Console]::Error.WriteLine("vigil: the version is set in the configuration (version = $configured): change it there to update, or remove it to use vigil self update")
            exit 1
        }
        $code = 0
        Invoke-VigilSelfUpdate -Root $Root -App $app -Check $check -Want $want | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } }
        exit $code
    }
    'format-migrate' {
        # Run by a supervisor under its lock, before it reloads (18.7).
        if (-not $Job -or $Rest.Count -ne 2) { Exit-Usage }
        $r = Invoke-VigilFormatMigrate -App $app -State $Job -Spool $Rest[0] -Logs $Rest[1]
        if ($r.Ok) { exit 0 }
        [Console]::Error.WriteLine($r.Error)
        exit 1
    }
    'supervise' {
        # PowerShell binds "--once" to the remaining arguments.
        $flags = @(@($Job) + @($Rest) | Where-Object { $_ })
        if ($flags.Count -gt 1 -or ($flags.Count -eq 1 -and $flags[0] -cne '--once')) { Exit-Usage }
        $code = Invoke-VigilSupervisor -Root $Root -App $app -Once:($flags.Count -eq 1)
        # A new version: this process carries on as it (18.7).
        if ($code -eq $Script:VigilReloadCode) {
            & (Join-Path $app 'vigil.ps1') -Root $Root supervise
            exit $LASTEXITCODE
        }
        exit $code
    }
    'worker' {
        if (-not $Job -or $Rest.Count -ne 2 -or $Rest[0] -cne '--run-id') { Exit-Usage }
        $r = Invoke-VigilWorker -Root $Root -Job $Job -RunId $Rest[1]
        exit $r.Code
    }
    default { Exit-Usage }
}
