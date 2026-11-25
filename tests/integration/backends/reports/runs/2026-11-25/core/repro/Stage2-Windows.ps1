# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Stage 2, PowerShell engine, three checks. Throwaway roots under
# $env:TEMP\vv; ends only processes whose command line names its own root.
param([string]$Shell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe", [string]$Only = '',
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..\..\..\..')).Path)
$base = Join-Path $env:TEMP 'vv'
[void](New-Item -ItemType Directory -Force -Path $base)
function New-Root {
    $r = Join-Path $base ("r-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $r)
    Copy-Item -Recurse (Join-Path $Repo 'app'), (Join-Path $Repo 'vendor') $r
    [void](& $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r init empty --instance t --backend file 2>&1)
    [void](New-Item -ItemType Directory -Force -Path "$r\scripts")
    return $r
}
function V($r) { & $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r @args 2>&1 | ForEach-Object { "$_" } }
function StateOf($r, $job, $key) {
    $f = "$r\state\jobs\$job.state"
    if (-not (Test-Path $f)) { return '(no state file)' }
    foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l -match "^$key\s*=\s*(.*)$") { return $Matches[1] } }
    return ''
}
function Stop-Mine($r, $extra) {
    if ($extra) { Stop-Process -Id $extra -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($r) -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force $r -ErrorAction SilentlyContinue
}
"shell: $Shell ($(& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))"

if (-not $Only -or $Only -eq 'octal') {
    "`n# (a) tick = 08m in the PowerShell engine"
    $r = New-Root
    [IO.File]::WriteAllText("$r\config\vigil.config", ([IO.File]::ReadAllText("$r\config\vigil.config") -replace '(?m)^tick\s*=.*$', 'tick = 08m'))
    "precheck: $(V $r precheck | Select-Object -Last 1)"
    [void](V $r supervise --once); "supervise --once exit $LASTEXITCODE"
    Stop-Mine $r $null
}

if (-not $Only -or $Only -eq 'waiting') {
    "`n# (b) V-04: a run with max_runtime = 20s, then a source that cannot be fetched is added"
    $r = New-Root
    [IO.File]::WriteAllText("$r\scripts\long.ps1", "Start-Sleep -Seconds 300`n")
    $cfg = [IO.File]::ReadAllText("$r\config\vigil.config") -replace '(?m)^tick\s*=.*$', 'tick = 5s'
    [IO.File]::WriteAllText("$r\config\vigil.config", $cfg + "`n[job.long]`nfile = scripts/long.ps1`nrun_every = 1m`nmax_runtime = 20s`n")
    $p = Start-Process -FilePath $Shell -PassThru -WindowStyle Hidden -RedirectStandardOutput "$r\sup.out" -RedirectStandardError "$r\sup.err" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$r\app\vigil.ps1`"", '-Root', "`"$r`"", 'supervise')
    $w = 60 - [DateTime]::UtcNow.Second; if ($w -lt 25) { $w += 60 }
    Start-Sleep -Seconds $w
    foreach ($i in 1..40) { if ((StateOf $r long status) -eq 'running') { break }; Start-Sleep -Milliseconds 500 }
    $started = [long](StateOf $r long started_epoch)
    "run started; state: $(StateOf $r long status); deadline_epoch - started_epoch = $([long](StateOf $r long deadline_epoch) - $started)"
    [IO.File]::AppendAllText("$r\config\vigil.config", "`n[source.extra]`ntype = local`npath = C:\nonexistent-vv-source`n`n[job.fromsource]`nsource = extra`nfile = check.ps1`nrun_every = 1h`n")
    "added: [source.extra] (local, a path that is not there) and [job.fromsource], $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $started) s into the run"
    Start-Sleep -Seconds 90
    "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $started) s after the run started (max_runtime 20s, tick 5s):"
    "  state: status = $(StateOf $r long status)"
    "  the job's process still running: $(@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains("$r\scripts\long.ps1") }).Count -gt 0)"
    "  timeout marker: $(@(Get-ChildItem "$r\state\locks\*.timeout" -ErrorAction SilentlyContinue).Count)"
    "  jobs.log:"; [IO.File]::ReadAllLines("$r\logs\supervisor\jobs.log") | Select-Object -First 10 | ForEach-Object { "    $_" }
    "  the supervisor's log:"; Get-ChildItem "$r\logs\supervisor\2*.log" | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } |
        Where-Object { $_ -notmatch 'vigil_sender|vigil_logs' } | Select-Object -Last 6 | ForEach-Object { "    " + ($_ -replace [regex]::Escape($r), '<root>') }
    Stop-Mine $r $p.Id
}

if (-not $Only -or $Only -eq 'spool') {
    "`n# (c) Lead 7: the spool's incoming folder cannot be written; a job that succeeds"
    $r = New-Root
    [IO.File]::WriteAllText("$r\scripts\ok.ps1", "exit 0`n")
    [IO.File]::AppendAllText("$r\config\vigil.config", "`n[job.ok]`nfile = scripts/ok.ps1`nrun_every = 1h`n")
    [void](V $r run ok); "control, spool writable: vigil run exit $LASTEXITCODE; state: $(StateOf $r ok status)"
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    [void](icacls "$r\spool\incoming" /deny "${me}:(WD,AD)" 2>&1)
    $out = V $r run ok; "spool not writable: vigil run exit $LASTEXITCODE"
    $out | Select-Object -First 4 | ForEach-Object { "    " + ($_ -replace [regex]::Escape($r), '<root>') }
    "  state after the run: status = $(StateOf $r ok status), run_id = $(StateOf $r ok run_id)"
    "  the job log's last lines:"; Get-ChildItem "$r\logs\jobs\ok\2*.log" | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) } | Select-Object -Last 3 | ForEach-Object { "    $_" }
    [void](icacls "$r\spool\incoming" /remove:d "$me" 2>&1)
    [void](V $r supervise --once)
    "  after one supervisor tick (spool writable again): status = $(StateOf $r ok status), reason = $(StateOf $r ok reason)"
    Stop-Mine $r $null
}
