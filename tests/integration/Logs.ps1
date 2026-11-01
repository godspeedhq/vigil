#Requires -Version 5.1

<#
.SYNOPSIS
    Integration test: forwarding Vigil's own logs (SPECIFICATION.md 13.4) on
    Windows.
.DESCRIPTION
    Runs against mock-backend.py as an OTLP/HTTP receiver on this host. What
    is forwarded and what stays local, checkpoints that move only on
    acceptance, every failure the destination can give, and every kind of
    gap. The twin of logs.sh.

    Needs Python.

    Exit code: 0 all passed, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$vigil = Join-Path $repo 'app\vigil.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-logs.$PID"
$shell = (Get-Process -Id $PID).Path
$script:pass = 0
$script:fail = 0

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    param([string[]]$Arguments)
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $vigil -Root $root @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Output = @($out | ForEach-Object { "$_" }) }
}

# One supervisor tick, then wait (up to 60s) for the workers it started.
function Invoke-Tick {
    [void](Invoke-Vigil @('supervise', '--once'))
    $locks = Join-Path $root 'state\locks'
    for ($i = 0; $i -lt 120; $i++) {
        if (-not (Get-ChildItem -LiteralPath $locks -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^vigil_(logs|sender)\.' })) { return }
        Start-Sleep -Milliseconds 500
    }
}

# A forwarder run now: its schedule and any backoff are forgotten.
function Invoke-Forward {
    $p = Join-Path $root 'state\logs\forwarder.state'
    if (Test-Path -LiteralPath $p) {
        $t = [System.IO.File]::ReadAllText($p)
        $t = $t -replace '(?m)^checked_epoch = .*$', 'checked_epoch = 0' -replace '(?m)^next_try = .*$', 'next_try = 0' -replace '(?m)^total = .*$', 'total = 0'
        [System.IO.File]::WriteAllText($p, $t)
    }
    Invoke-Tick
}

# How many requests the mock received holding the text.
function Get-Received {
    param([string]$Text)
    $n = 0
    foreach ($l in [System.IO.File]::ReadAllLines("$root\mock\requests.log")) { if ($l.Contains($Text)) { $n++ } }
    return [string]$n
}
function Clear-Requests { [System.IO.File]::WriteAllText("$root\mock\requests.log", '') }
function Get-Field {
    param([string]$Key)
    $p = Join-Path $root 'state\jobs\vigil_logs.state'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($p)) { if ($l -cmatch "^$Key +=( (.*))?$") { return $Matches[2] } }
    return ''
}
function Test-Prom {
    param([string]$Pattern)
    return [string]([System.IO.File]::ReadAllText("$root\metrics\vigil.prom") -cmatch "(?m)$Pattern")
}
function Get-JobLog {
    param([string]$Job)
    return @(Get-ChildItem -LiteralPath "$root\logs\jobs\$Job" -Filter '*.log' | Sort-Object Name)[-1].FullName
}
function Get-Checkpoint {
    return @(Get-ChildItem -LiteralPath "$root\state\logs" -Filter '*chatty*.checkpoint')[0].FullName
}
function Write-Text {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"))
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
$python = $null
foreach ($p in @('python3', 'python', 'py')) {
    if (Get-Command $p -CommandType Application -ErrorAction SilentlyContinue) {
        & $p -c 'import http.server' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $python = (Get-Command $p -CommandType Application | Select-Object -First 1).Source; break }
    }
}
if (-not $python) { Write-Host 'needs Python'; exit 1 }
foreach ($d in @('config', 'scripts', 'mock')) { [void](New-Item -ItemType Directory -Force -Path (Join-Path $root $d)) }
$root = (Resolve-Path -LiteralPath $root).ProviderPath
$mock = $null

try {
    $mock = Start-Process -FilePath $python -ArgumentList @("`"$here\mock-backend.py`"", "`"$root\mock`"") -PassThru -NoNewWindow -RedirectStandardError "$root\mock\stderr"
    $portFile = Join-Path $root 'mock\port'
    for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    $port = if (Test-Path -LiteralPath $portFile) { [System.IO.File]::ReadAllText($portFile).Trim() } else { '' }
    Test-Equal 'mock started' 'True' ([string][bool]$port)
    if (-not $port) { Get-Content -LiteralPath "$root\mock\stderr"; throw 'the mock did not start' }
    Clear-Requests

    $token = "logs-token-$PID"
    $env:VIGIL_IT_LOGS_AUTH = "Bearer $token"
    Set-Content -LiteralPath "$root\scripts\chatty.cmd" -Value @('@echo off', 'echo hello from chatty', 'echo chatty on stderr 1>&2')
    Set-Content -LiteralPath "$root\scripts\quiet.cmd" -Value @('@echo off', 'echo private output of quiet')

    $config = {
        param([string]$Dest, [string]$Extra)
        return @"
[vigil]
instance = lg

[scheduler]
tick = 1s

[backend.file]
path = metrics\vigil.prom

[log_forward]
destination = $Dest
include     = supervisor, run, stdout
check_every = 1s
$Extra

[log_destination.ops]
type         = otel
endpoint     = http://127.0.0.1:$port/v1/logs
header_name  = Authorization
header_value = env:VIGIL_IT_LOGS_AUTH
timeout      = 5s

[log_destination.other]
type     = otel
endpoint = http://127.0.0.1:$port/other/v1/logs

[job.chatty]
file      = scripts\chatty.cmd
run_every = 3650d

[job.quiet]
file           = scripts\quiet.cmd
run_every      = 3650d
forward_output = false
"@
    }
    $cfg = Join-Path $root 'config\vigil.config'
    Write-Text $cfg (& $config 'ops' '')

    Test-Equal 'precheck' '0' ([string](Invoke-Vigil @('precheck')).Code)
    [void](Invoke-Vigil @('run', 'chatty'))
    [void](Invoke-Vigil @('run', 'quiet'))
    Invoke-Tick
    Invoke-Tick

    # What reaches the destination.
    $sent = [System.IO.File]::ReadAllText("$root\mock\requests.log")
    Test-Equal 'delivered' 'succeeded' (Get-Field 'status')
    Test-Equal 'the OTLP logs path' 'True' ([string]$sent.Contains('"path": "/v1/logs"'))
    Test-Equal 'the credential in its header' 'True' ([string]$sent.Contains("`"Authorization`": `"Bearer $token`""))
    Test-Equal 'stdout, as asked' '1' (Get-Received 'hello from chatty')
    Test-Equal 'the job and run named' 'True' ([string]$sent.Contains('\"key\":\"job\",\"value\":{\"stringValue\":\"chatty\"}'))
    Test-Equal 'run lines' 'True' ([string]$sent.Contains('\"stringValue\":\"end succeeded in'))
    Test-Equal 'supervisor lines' 'True' ([string]$sent.Contains('\"category\",\"value\":{\"stringValue\":\"supervisor\"}'))
    Test-Equal 'the resource' 'True' ([string]$sent.Contains('\"key\":\"instance\",\"value\":{\"stringValue\":\"lg\"}'))
    Test-Equal 'the revision' 'True' ([string]$sent.Contains('\"key\":\"config.revision\"'))
    Test-Equal 'stderr stays local: not in include' '0' (Get-Received 'chatty on stderr')
    Test-Equal 'forward_output = false stays local' '0' (Get-Received 'private output of quiet')
    Test-Equal 'but the job''s run lines go' 'True' ([string]$sent.Contains('\"key\":\"job\",\"value\":{\"stringValue\":\"quiet\"}'))
    Test-Equal 'local logs untouched' 'True' ([string][System.IO.File]::ReadAllText((Get-JobLog 'quiet')).Contains('private output of quiet'))
    Test-Equal 'a checkpoint per file' 'True' ([string][bool](Get-Checkpoint))
    Test-Equal 'metrics: records sent' 'True' (Test-Prom '^vigil_logs_records_sent_total')
    Test-Equal 'metrics: enabled' 'True' (Test-Prom '^vigil_logs_enabled')

    # Nothing is sent twice.
    Invoke-Forward
    Test-Equal 'not sent twice' '1' (Get-Received 'hello from chatty')

    # The forwarder's own log is never forwarded.
    Test-Equal 'its own log stays local' '0' (Get-Received 'vigil_logs/')

    # A failing destination keeps what it has not taken, and backs off.
    $log = Get-JobLog 'chatty'
    $line = '2026-10-30T15:07:35Z 20261030T150733Z-1 out'
    [System.IO.File]::WriteAllText("$root\mock\status", '503')
    [System.IO.File]::AppendAllText($log, "$line after the outage`n")
    Invoke-Forward
    Test-Equal '503: fetch failed' 'failed' (Get-Field 'status')
    Test-Equal '503: reason' 'True' ([string](Get-Field 'reason').Contains('HTTP 503'))
    Test-Equal '503: backoff recorded' 'False' ([string]([System.IO.File]::ReadAllText("$root\state\logs\forwarder.state") -cmatch '(?m)^next_try = 0$'))
    Invoke-Tick
    Invoke-Tick
    Test-Equal '503: counted' 'True' (Test-Prom '^vigil_logs_failures_total.*reason="unreachable"')
    Test-Equal '503: pending' 'True' (Test-Prom '^vigil_logs_pending_bytes')
    Remove-Item -LiteralPath "$root\mock\status"
    Clear-Requests
    Invoke-Forward
    Test-Equal 'recovered: resent' '1' (Get-Received 'after the outage')

    # A rejected login is reported as such.
    [System.IO.File]::WriteAllText("$root\mock\status", '401')
    Invoke-Forward
    Test-Equal '401: reported' 'True' ([string](Get-Field 'reason').Contains('permission denied'))
    Remove-Item -LiteralPath "$root\mock\status"
    Invoke-Forward

    # Accepted in part: only the leading records count.
    [System.IO.File]::AppendAllText($log, "$line part one`n$line part two`n")
    [System.IO.File]::WriteAllText("$root\mock\reply", '{"partialSuccess":{"rejectedLogRecords":1}}')
    Clear-Requests
    Invoke-Forward
    Test-Equal 'partial: reported' 'True' ([string](Get-Field 'reason').Contains('rejected 1 of'))
    Remove-Item -LiteralPath "$root\mock\reply"
    Clear-Requests
    Invoke-Forward
    Test-Equal 'partial: the rest retried' '0' (Get-Received 'part one')
    Test-Equal 'partial: the last record resent' '1' (Get-Received 'part two')

    # An answer Vigil cannot interpret is a failure, never a success.
    [System.IO.File]::AppendAllText($log, "$line not understood`n")
    [System.IO.File]::WriteAllText("$root\mock\reply", '<html>ok</html>')
    Invoke-Forward
    Test-Equal 'invalid response: failed' 'True' ([string](Get-Field 'reason').Contains('not OTLP'))
    Remove-Item -LiteralPath "$root\mock\reply"
    Clear-Requests
    Invoke-Forward
    Test-Equal 'invalid response: resent' '1' (Get-Received 'not understood')

    # An incomplete last line waits for its newline.
    [System.IO.File]::AppendAllText($log, "$line half a")
    Clear-Requests
    Invoke-Forward
    Test-Equal 'incomplete line: held back' '0' (Get-Received 'half a')
    [System.IO.File]::AppendAllText($log, " line`n")
    Invoke-Forward
    Test-Equal 'incomplete line: sent whole' '1' (Get-Received 'half a line')

    # Gaps: an unreadable checkpoint sends the file again.
    Clear-Requests
    [System.IO.File]::WriteAllText((Get-Checkpoint), "garbage`n")
    Invoke-Forward
    Test-Equal 'checkpoint reset: sent again' 'True' ([string]((Get-Received 'hello from chatty') -cne '0'))
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'checkpoint reset: reported' 'True' (Test-Prom '^vigil_logs_gaps_total.*reason="checkpoint_reset"')

    # A file replaced under its checkpoint.
    Clear-Requests
    [System.IO.File]::WriteAllText($log, "$line a new first line`n")
    Invoke-Forward
    Test-Equal 'replaced: sent from the start' '1' (Get-Received 'a new first line')
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'replaced: reported' 'True' (Test-Prom '^vigil_logs_gaps_total.*reason="replaced"')

    # A file deleted before it was all delivered.
    [System.IO.File]::WriteAllText("$root\mock\status", '503')
    [System.IO.File]::AppendAllText($log, "$line never delivered`n")
    Invoke-Forward
    $ck = Get-Checkpoint
    [System.IO.File]::WriteAllText($ck, ([System.IO.File]::ReadAllText($ck) -replace '(?m)^size .*$', 'size        = 999999'))
    Remove-Item -LiteralPath $log, "$root\mock\status"
    Invoke-Forward
    Test-Equal 'deleted: checkpoint removed' 'False' ([string](Test-Path -LiteralPath $ck))
    Invoke-Tick
    Invoke-Tick
    Test-Equal 'deleted: reported' 'True' (Test-Prom '^vigil_logs_gaps_total.*reason="deleted"')

    # A new destination starts at the end of every file.
    [void](Invoke-Vigil @('run', 'chatty'))
    Write-Text $cfg (& $config 'other' '')
    Clear-Requests
    Invoke-Tick
    Invoke-Forward
    Test-Equal 'destination changed: no history' '0' (Get-Received 'hello from chatty')
    Invoke-Tick
    Test-Equal 'destination changed: reported' 'True' (Test-Prom '^vigil_logs_gaps_total.*reason="destination_changed"')
    [void](Invoke-Vigil @('run', 'chatty'))
    Invoke-Forward
    Test-Equal 'destination changed: new lines go there' 'True' ([string]([System.IO.File]::ReadAllText("$root\mock\requests.log").Contains('"path": "/other/v1/logs"')))

    # Turned off, nothing more is forwarded.
    Write-Text $cfg (& $config 'ops' 'enabled     = false')
    Invoke-Tick
    [void](Invoke-Vigil @('run', 'chatty'))
    Clear-Requests
    Invoke-Forward
    Test-Equal 'disabled: nothing sent' '0' ([string]@([System.IO.File]::ReadAllLines("$root\mock\requests.log")).Count)

    # The credential is only ever in a header.
    $leaks = foreach ($d in @('logs', 'state', 'spool', 'metrics')) {
        Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            [System.IO.File]::ReadAllText($_.FullName).Contains($token)
        } | ForEach-Object { $_.FullName }
    }
    Test-Equal 'no credential in logs, state, spool or metrics' '' ($leaks -join ' ')

    if ($script:fail -gt 0) {
        Write-Host "`nforwarder log:"
        Get-ChildItem -LiteralPath "$root\logs\jobs\vigil_logs" -Filter '*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Select-Object -Last 30
        Write-Host "`nforwarder state:"
        Get-Content -LiteralPath "$root\state\logs\forwarder.state", "$root\state\jobs\vigil_logs.state" -ErrorAction SilentlyContinue
    }
}
finally {
    if ($mock) { try { Stop-Process -Id $mock.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item Env:\VIGIL_IT_LOGS_AUTH -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
