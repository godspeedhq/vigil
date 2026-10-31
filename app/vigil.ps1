#Requires -Version 5.1

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
    vigil [-Root <dir>] secret set <NAME> [--stdin] | secret list | secret delete <NAME>
        Vigil's own secret store (6.5.2), encrypted with DPAPI. set prompts
        without echo, or reads the value from stdin; list never shows values.
    vigil [-Root <dir>] supervise [--once]
        The supervisor (4.1): ticks until stopped, or once with --once.
        Running workers are never stopped with it.
    vigil [-Root <dir>] worker <job> --run-id <run id>
        Internal: the worker the supervisor starts for a launched run.

    The install root defaults to the folder that contains this app folder.
#>

param(
    [string]$Root,
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Job,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$app = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $app }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

foreach ($lib in @('Config', 'Validate', 'Effective', 'Command', 'Schedule', 'Outcome', 'Metrics', 'Events', 'Recovery', 'Prom', 'Secrets', 'Stores', 'Worker', 'Sender', 'Supervisor', 'Precheck')) {
    . (Join-Path $app "lib\windows\$lib.ps1")
}

function Exit-Usage {
    [Console]::Error.WriteLine("usage: vigil [-Root <dir>] run <job> | resolve <job> | precheck [<job>] | supervise [--once]`n       vigil [-Root <dir>] secret set <NAME> [--stdin] | secret list | secret delete <NAME>")
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
    'supervise' {
        # PowerShell binds "--once" to the remaining arguments.
        $flags = @(@($Job) + @($Rest) | Where-Object { $_ })
        if ($flags.Count -gt 1 -or ($flags.Count -eq 1 -and $flags[0] -cne '--once')) { Exit-Usage }
        exit (Invoke-VigilSupervisor -Root $Root -App $app -Once:($flags.Count -eq 1))
    }
    'worker' {
        if (-not $Job -or $Rest.Count -ne 2 -or $Rest[0] -cne '--run-id') { Exit-Usage }
        $r = Invoke-VigilWorker -Root $Root -Job $Job -RunId $Rest[1]
        exit $r.Code
    }
    default { Exit-Usage }
}
