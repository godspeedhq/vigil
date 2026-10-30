#Requires -Version 5.1

<#
.SYNOPSIS
    vigil - the Vigil command on Windows (SPECIFICATION.md 18.5).
.DESCRIPTION
    vigil [-Root <dir>] run <job>
        Runs one job once now, in the foreground, for testing. Exits 0
        succeeded, 1 warning, 2 failed, 3 unknown, 4 not run.
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

foreach ($lib in @('Config', 'Validate', 'Effective', 'Command', 'Outcome', 'Metrics', 'Events', 'Worker')) {
    . (Join-Path $app "lib\$lib.ps1")
}

function Exit-Usage {
    [Console]::Error.WriteLine('usage: vigil [-Root <dir>] run <job>')
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
    'worker' {
        if (-not $Job -or $Rest.Count -ne 2 -or $Rest[0] -cne '--run-id') { Exit-Usage }
        $r = Invoke-VigilWorker -Root $Root -Job $Job -RunId $Rest[1]
        exit $r.Code
    }
    default { Exit-Usage }
}
