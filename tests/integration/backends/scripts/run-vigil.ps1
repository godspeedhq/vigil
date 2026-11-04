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
    run-vigil.ps1 - runs Vigil from this checkout, on Windows, against one
    running target. The twin of run-vigil.sh.
.DESCRIPTION
        .\scripts\run-vigil.ps1 lgtm

    Vigil is copied into a temporary folder, nothing is installed and the
    PATH is not touched. Its jobs are the workloads in ..\workloads (.ps1),
    plus a native program (hostname.exe), all every minute. The supervisor
    runs for about two and a half minutes. Then verify.sh asks the backend
    for this run's data, through bash (Git Bash or WSL) when there is one;
    otherwise the command to run is printed.

    The target's ports must answer on 127.0.0.1 here: Docker on this
    machine, or an SSH tunnel to the machine running it (see README.md).
    The endpoints are the same as common.sh's; keep the two in step.

    -PrecheckOnly stops after vigil precheck: the configuration for the
    target is checked without a backend, or Docker, at all.

    -Keep leaves the temporary folder, with Vigil's logs and state, in place
    afterwards, and prints where it is.

    Exit code: 0 when verify.sh passes, 1 otherwise.
#>

param(
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$PrecheckOnly,
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bk = Split-Path -Parent $here
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
$shell = (Get-Process -Id $PID).Path
. (Join-Path $here 'evidence.ps1')

# Credentials from .env, when there is one.
$envFile = Join-Path $bk '.env'
if (Test-Path -LiteralPath $envFile) {
    foreach ($l in [System.IO.File]::ReadAllLines($envFile)) {
        if ($l -cmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
    }
}

# How Vigil reaches each target: "<type> <endpoint>", as in common.sh.
$targets = @{
    'lgtm'            = @('otel http://127.0.0.1:4318/v1/metrics', 'otel http://127.0.0.1:4318/v1/logs')
    'prometheus'      = @('otel http://127.0.0.1:9090/api/v1/otlp/v1/metrics', '')
    'mimir'           = @('otel http://127.0.0.1:9009/otlp/v1/metrics', '')
    'loki'            = @('', 'otel http://127.0.0.1:3100/otlp/v1/logs')
    'otel-collector'  = @('otel http://127.0.0.1:24318/v1/metrics', 'otel http://127.0.0.1:24318/v1/logs')
    'alloy'           = @('otel http://127.0.0.1:34318/v1/metrics', 'otel http://127.0.0.1:34318/v1/logs')
    'splunk'          = @('splunk http://127.0.0.1:8088', 'splunk http://127.0.0.1:8088')
    'victoriametrics' = @('otel http://127.0.0.1:4458/v1/metrics', '')
    'victorialogs'    = @('', 'otel http://127.0.0.1:4458/v1/logs')
    'elastic'         = @('otel http://127.0.0.1:4418/v1/metrics', 'otel http://127.0.0.1:4418/v1/logs')
    'opensearch'      = @('', 'otel http://127.0.0.1:4428/v1/logs')
    'influxdb'        = @('otel http://127.0.0.1:4438/v1/metrics', '')
    'clickhouse'      = @('otel http://127.0.0.1:4448/v1/metrics', 'otel http://127.0.0.1:4448/v1/logs')
    'signoz'          = @('otel http://127.0.0.1:4318/v1/metrics', 'otel http://127.0.0.1:4318/v1/logs')
    'uptrace'         = @('otel http://127.0.0.1:14318/v1/metrics', 'otel http://127.0.0.1:14318/v1/logs')
}
if (-not $targets.ContainsKey($Target)) {
    Write-Output "$Target is not a target Vigil can send to (see common.sh for why); one of: $(($targets.Keys | Sort-Object) -join ', ')"
    exit 1
}
$metrics, $logs = $targets[$Target]

$tag = "bk$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))$PID"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-bk.$PID"
$root = Join-Path $work 'root'
$sup = $null

# A backend or log destination section for "<type> <endpoint>".
function Get-Section {
    param([string]$Kind, [string]$Spec)
    $type, $url = $Spec.Split(' ', 2)
    $s = "[$Kind.target]`ntype     = $type`nendpoint = $url`n"
    if ($type -ceq 'splunk') {
        $s += if ($Kind -ceq 'backend') { "token    = env:VIGIL_SPLUNK_METRICS_TOKEN`n" } else { "token    = env:VIGIL_SPLUNK_LOGS_TOKEN`n" }
    }
    # Uptrace's DSN: the backend's bearer credential, the log destination's
    # uptrace-dsn header.
    if ($Target -ceq 'uptrace') {
        $s += if ($Kind -ceq 'backend') { "api_key  = env:VIGIL_UPTRACE_DSN`n" } else { "header_name  = uptrace-dsn`nheader_value = env:VIGIL_UPTRACE_DSN`n" }
    }
    return "$s`n"
}

function Invoke-Vigil {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'app\vigil.ps1') -Root $root @args 2>&1 | ForEach-Object { "$_" }
}

try {
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $root 'scripts'), (Join-Path $root 'config'))
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    Start-Evidence "backend-$Target" $bk 'compose*.yaml' "$($MyInvocation.MyCommand.Path) $Target"
    Get-ChildItem -LiteralPath (Join-Path $bk 'workloads') -Filter '*.ps1' | Copy-Item -Destination (Join-Path $root 'scripts')

    $c = "[vigil]`ninstance = backend-test`n`n[scheduler]`ntick = 10s`n`n"
    $c += "[runner.ps]`ncommand = powershell.exe`narg = -NoProfile`narg = -NonInteractive`narg = -ExecutionPolicy`narg = Bypass`narg = -File`n`n[runners]`n.ps1 = ps`n`n"
    if ($metrics) { $c += Get-Section 'backend' $metrics } else { $c += "[backend.file]`npath = metrics\vigil.prom`n`n" }
    if ($logs) {
        $c += "[log_forward]`ndestination = target`ninclude     = supervisor, run, stdout, stderr`ncheck_every = 10s`n`n"
        $c += Get-Section 'log_destination' $logs
    }
    $c += "[job.bk_ok]`nfile = scripts\ok.ps1`nrun_every = 1m`n`n"
    $c += "[job.bk_fail]`nfile = scripts\fail.ps1`nrun_every = 1m`n`n"
    $c += "[job.bk_long]`nfile = scripts\long.ps1`nrun_every = 1m`nmax_runtime = 55s`n`n"
    $c += "[job.bk_overrun]`nfile = scripts\overrun.ps1`nrun_every = 1m`nmax_runtime = 10s`ngrace = 5s`n`n"
    $c += "[job.bk_missing]`nfile = scripts\missing.ps1`nrun_every = 1m`n`n"
    $c += "[job.bk_output]`nfile = scripts\output.ps1`nrun_every = 1m`nenv = BK_RUN=$tag`n`n"
    $c += "[job.bk_metrics]`nfile = scripts\metrics.ps1`nrun_every = 1m`nenv = BK_RUN=$tag`n`n"
    $c += "[job.bk_native]`nfile = $env:SystemRoot\System32\hostname.exe`nrun_every = 1m`n"
    [System.IO.File]::WriteAllText((Join-Path $root 'config\vigil.config'), $c)

    Write-Output "run tag: $tag"

    # This machine's clock against the backend's, from the Date its HTTP
    # answer carries. Telemetry is stamped with this machine's time: minutes
    # ahead, and a backend hides it until then (Loki) or refuses it
    # (Prometheus).
    $url = $(if ($metrics) { $metrics } else { $logs }).Split(' ', 2)[1]
    $base = $url.Substring(0, $url.IndexOf('/', $url.IndexOf('://') + 3))
    try {
        # Any answer has a Date, a 404 too.
        $req = [System.Net.WebRequest]::Create("$base/")
        $req.Timeout = 5000
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response }
        $date = if ($resp) { $resp.Headers['Date'] } else { $null }
        if ($resp) { $resp.Close() }
        if ($date) {
            $skew = [long]([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($date, [System.Globalization.CultureInfo]::InvariantCulture)).TotalSeconds
            if ([Math]::Abs($skew) -gt 60) {
                Write-Output "WARNING: this clock is $([Math]::Abs($skew))s $(if ($skew -gt 0) { 'ahead of' } else { 'behind' }) the backend's: set the time right, or its data may be hidden or refused"
            }
            else { Write-Output "clock: within $([Math]::Abs($skew))s of the backend's" }
        }
    }
    catch { }
    # bk_missing's file is missing on purpose, and precheck rightly says so;
    # any other problem stops the run.
    $pre = @(Invoke-Vigil precheck)
    $problems = @($pre | Where-Object { $_ -cmatch '^\s*(FAIL|INVALID|ERROR)' -and $_ -cnotmatch 'bk_missing' })
    if ($problems.Count -gt 0) {
        $pre | ForEach-Object { Write-Output $_ }
        Write-Output 'precheck failed: the configuration above is wrong, or a credential is missing from .env'
        exit 1
    }
    Write-Output 'precheck: passed, apart from bk_missing, whose file is missing on purpose'
    if ($PrecheckOnly) { exit 0 }

    $sup = Start-Process -FilePath $shell -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$root\app\vigil.ps1`"", '-Root', "`"$root`"", 'supervise')
    # Two whole minutes of runs, then time for the sender and forwarder.
    Start-Sleep -Seconds 150
    # The supervisor this script started, and nothing else.
    $sup.Kill(); $sup.WaitForExit(); $sup = $null
    Start-Sleep -Seconds 15

    Write-Output "`njobs.log at the end:"
    [System.IO.File]::ReadAllLines((Join-Path $root 'logs\supervisor\jobs.log')) | ForEach-Object { "  $_" }

    # Git Bash, not System32\bash.exe: that one is WSL, which would need the
    # path translated.
    $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    $verify = Join-Path $here 'verify.sh'
    if (Test-Path -LiteralPath $bash) {
        # Through PowerShell's output, so the evidence transcript has it: a
        # transcript misses what a program writes to the console itself.
        & $bash $verify.Replace('\', '/') $Target $tag 2>&1 | ForEach-Object { "$_" }
        exit $LASTEXITCODE
    }
    Write-Output "`nNo bash here: run this where one is, against the same backend:"
    Write-Output "  scripts/verify.sh $Target $tag"
    exit 1
}
finally {
    if ($sup -and -not $sup.HasExited) { $sup.Kill() }
    # What verify.sh got from the backend, with the rest.
    if ($script:evDir) { Copy-Item -LiteralPath (Join-Path $bk "reports\evidence\$Target-$tag.txt") -Destination (Join-Path $script:evDir 'backend-answers.txt') -ErrorAction SilentlyContinue }
    Save-Evidence $work $root @($env:VIGIL_SPLUNK_METRICS_TOKEN, $env:VIGIL_SPLUNK_LOGS_TOKEN)
    if ($Keep) { Write-Output "kept: $work" }
    else { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
