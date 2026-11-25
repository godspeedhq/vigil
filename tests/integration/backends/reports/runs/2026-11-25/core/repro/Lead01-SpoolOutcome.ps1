# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Lead 1, PowerShell engine: a run whose worker dies after writing its spool
# file and before its final state (crash point worker.after_spool) is
# concluded from the spool. Does a metric line the job printed change the
# outcome recorded? Throwaway roots only, under $env:TEMP\vv.
param([string]$Shell = 'powershell.exe', [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..\..\..\..')).Path)
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
function Get-StateValue($r, $key) {
    $f = "$r\state\jobs\j.state"
    if (-not (Test-Path $f)) { return '(no state file)' }
    foreach ($l in [IO.File]::ReadAllLines($f)) { if ($l -match "^$key\s*=\s*(.*)$") { return $Matches[1] } }
    return ''
}
function Test-One($label, $body, $expected) {
    $r = New-Root
    [IO.File]::WriteAllText("$r\scripts\j.ps1", $body + "`n")
    [IO.File]::AppendAllText("$r\config\vigil.config", "`n[job.j]`nfile = scripts/j.ps1`nmetric_name = app`nrun_every = 1h`n")
    "`n# $label"
    "the job: $body"
    $env:VIGIL_FAULT = 'worker.after_spool'
    [void](& $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r run j 2>&1)
    "vigil run (worker stopped at worker.after_spool): exit $LASTEXITCODE"
    Remove-Item Env:\VIGIL_FAULT
    "state before the supervisor looks: $(Get-StateValue $r 'status')"
    "the spool file's lines:"
    Get-ChildItem "$r\spool\incoming\*-j-*.events" -ErrorAction SilentlyContinue | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) | ForEach-Object { "    $_" } }
    [void](& $Shell -NoProfile -ExecutionPolicy Bypass -File "$r\app\vigil.ps1" -Root $r supervise --once 2>&1)
    "after one supervisor tick: status = $(Get-StateValue $r 'status'), reason = $(Get-StateValue $r 'reason')"
    "expected: $expected"
    Remove-Item -Recurse -Force $r -ErrorAction SilentlyContinue
}
"shell: $Shell, $(& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
Test-One 'Control: a job that fails (exit 2), no metric line' 'exit 2' 'failed'
Test-One 'A job that fails (exit 2) and printed: metric steps.succeeded 1' "Write-Output 'metric steps.succeeded 1'; exit 2" 'failed'
Test-One 'A job that succeeds (exit 0) and printed: metric rows.failures 0' "Write-Output 'metric rows.failures 0'; exit 0" 'succeeded'
