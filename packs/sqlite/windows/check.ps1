#Requires -Version 5.1

<#
.SYNOPSIS
    check.ps1 - SQLite databases checked for damage, with PRAGMA quick_check: off until SQLITE_CHECK=quick, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Checks each database in SQLITE_FILES with PRAGMA quick_check, opened
    read-only with the sqlite3 program: every page and every row read, which
    finds a damaged page, a broken index structure, a row out of place. It
    changes nothing and repairs nothing.

    It does nothing (checked 0) until SQLITE_CHECK=quick, because it costs:
    it reads the whole file, so it takes seconds a gigabyte and fills the
    cache with it, and in rollback mode (not WAL) it holds a shared lock
    while it runs, so the application's writes wait for it (and fail with
    "database is locked" when they wait longer than the application
    allows). In WAL mode writers do not wait. Once a day, at a quiet hour,
    is plenty. A database that stays locked by a writer for 30 seconds is
    not checked: busy 1.

    Reads with sqlite3.exe (SQLITE3, its full path, else the one on the
    PATH), as this account: it needs read access to the database and, in WAL
    mode, to its -wal and -shm files, and the folder they are in. Missing
    databases are skipped: the status job reports them.

    Metrics:
      checked          databases checked; 0 while SQLITE_CHECK is not quick
      ok               1 when the check found nothing wrong, else 0, tagged
                       db=<path, with / for \>
      problems         what it found wrong (at most 100): 0 when ok
      check_seconds    how long the check took
      busy             1 when the database stayed locked and could not be
                       checked
      not_ok           databases whose check found something wrong

    Example output (the rest are in the same form):
      metric ok 1 db=C:/ProgramData/app/data.db
      metric problems 0 db=C:/ProgramData/app/data.db
      metric check_seconds 0.12 db=C:/ProgramData/app/data.db
      metric checked 1
      metric not_ok 0

    Reading the results (starting points: tune them to the application):
      Healthy  not_ok 0; check_seconds steady.
      Watch    busy 1 on two days running (a writer holds the database most
               of the time: pick another hour); check_seconds near
               max_runtime.
      Act      not_ok above 0: copy the database aside (with its -wal), and
               run sqlite3 <file> "PRAGMA integrity_check" on the copy to
               see what is wrong; restore from a backup, or .recover what
               can be.

    Requires: PowerShell 5.1 or later, and sqlite3.exe when SQLITE_CHECK=quick
    Exit code: 0 on success, damaged or not; 1 if sqlite3.exe is missing, or
      a database cannot be opened by this account (it says which)

    Example (vigil.config):
      [job.sqlite_check]
      file        = packs/sqlite/check.ps1
      metric_name = sqlite.check
      run_every   = 1d
      max_runtime = 30m
      env         = SQLITE_FILES=C:\ProgramData\app\data.db
      env         = SQLITE_CHECK=quick
#>

$Job = 'check'
. (Join-Path $PSScriptRoot '_sqlite.ps1')
$files = Get-Databases

$how = if ($env:SQLITE_CHECK) { $env:SQLITE_CHECK } else { 'off' }
if ($how -eq 'off') { M 'checked' 0; exit 0 }
if ($how -ne 'quick') { [Console]::Error.WriteLine("${Job}: SQLITE_CHECK is '$how': quick, or off"); exit 1 }
$prog = $env:SQLITE3
if (-not $prog) {
    $c = Get-Command sqlite3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $prog = $c.Source }
}
if (-not $prog -or -not (Test-Path -LiteralPath $prog -PathType Leaf)) {
    [Console]::Error.WriteLine("${Job}: sqlite3 not found: the check runs PRAGMA quick_check with the sqlite3 program (SQLITE3 names it, its full path)")
    exit 1
}

# sqlite3, read-only, on one database: its exit code, output and errors.
# Every argument in double quotes: a Windows path holds none.
function Invoke-Check([string]$path) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $prog
    $si.Arguments = '-readonly -batch -bail -cmd ".timeout 30000" "' + $path + '" "PRAGMA quick_check(100);"'
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardInput = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($si)
    $p.StandardInput.Close()
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Trim(); Err = $err.Result.Trim() }
}

$checked = 0
$bad = 0
$failed = @()
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    $t = "db=$(Safe $f)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Check $f
    $took = $sw.Elapsed.TotalSeconds
    if ($r.Code -ne 0) {
        if ($r.Err -match 'database is locked|busy') { M 'busy' 1 $t; continue }
        if ($r.Err -match 'malformed|not a database|corrupt') { $n = 1 }
        else { $failed += "${f}: $(($r.Err -split "`n")[0].Trim())"; continue }
    } elseif ($r.Out -eq 'ok') { $n = 0 }
    else { $n = @($r.Out -split "`n" | Where-Object { $_.Trim() }).Count }
    $checked++
    if ($n -eq 0) { M 'ok' 1 $t } else { $bad++; M 'ok' 0 $t }
    M 'problems' $n $t
    M 'check_seconds' $took $t
    M 'busy' 0 $t
}
M 'checked' $checked
M 'not_ok' $bad
if ($failed.Count -gt 0) {
    [Console]::Error.WriteLine("${Job}: sqlite3 could not check $($failed -join '; ')")
    exit 1
}
exit 0
