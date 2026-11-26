#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - SQLite databases: found, their size, free pages, the WAL and the rollback journal, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each database in SQLITE_FILES: whether it is there, how big it
    is, how much of it is free pages (space a VACUUM would give back), its
    write-ahead log (a WAL that keeps growing is a reader that never lets a
    checkpoint finish), and a rollback journal still there long after a
    transaction should have ended (a writer that died in the middle of one,
    or a transaction left open).

    Reads only each database's first 100 bytes (its header) and the sizes
    and times of it and its -wal and -journal files, as files like any
    other, opened so the application may go on using them: no SQLite
    library, no lock taken, nothing the application can notice. In WAL mode
    the header is as of the last checkpoint, so pages and free_pages may lag
    the WAL by a few. Needs read access to each database file. What the
    scripts share is in _sqlite.ps1, beside this one.

    Metrics:
      databases            the databases in SQLITE_FILES
      missing              of those, how many are not there
      found                1 when the file is there, else 0, tagged
                           db=<path, with / for \>; the rest only for one
                           found
      valid                1 when it starts as a SQLite database does (or is
                           empty), else 0: not a database, damaged, or
                           encrypted (SQLCipher)
      info                 always 1, tagged mode=<wal, rollback>,
                           version=<the SQLite that last wrote it, 3.45.1>
                           and vacuum=<none, full, incremental>
      size_bytes           the file's size
      page_size            its page size, in bytes
      pages                its pages
      free_pages           pages on its free list: kept by the file, holding
                           no data
      free_pct             free_pages, of pages
      free_bytes           the space a VACUUM would give back
      wal_bytes            its write-ahead log's size (0 when it has none):
                           the largest it has been since the last connection
                           closed, as SQLite reuses it
      journal_bytes        a rollback journal in use (0 when none)
      journal_seconds      how long that journal has been in use, by when it
                           was last written
      last_write_seconds   since the database or its WAL was last written

    Example output (the rest are in the same form):
      metric databases 2
      metric missing 0
      metric found 1 db=C:/ProgramData/app/data.db
      metric valid 1 db=C:/ProgramData/app/data.db
      metric info 1 db=C:/ProgramData/app/data.db mode=wal version=3.45.1 vacuum=none
      metric size_bytes 1658880 db=C:/ProgramData/app/data.db
      metric free_pct 3.21 db=C:/ProgramData/app/data.db
      metric wal_bytes 4144752 db=C:/ProgramData/app/data.db

    Reading the results (starting points: tune them to the application):
      Healthy  missing 0; valid 1; wal_bytes a few MB (SQLite checkpoints at
               about 4 MB); journal_bytes 0 most of the time; free_pct low,
               or steady.
      Watch    wal_bytes past 64 MB, or higher every day; free_pct past 25
               on a large database (a VACUUM would give space back);
               last_write_seconds far longer than the application's habit.
      Act      missing above 0 or valid 0; wal_bytes past 1 GB and growing
               (a reader holds an old snapshot: checkpoints cannot finish,
               reads slow down); journal_seconds past 10 minutes (a writer
               died in a transaction, or holds one open: other writers wait
               or fail with "database is locked").

    Requires: PowerShell 5.1 or later
    Exit code: 0 on success, databases there or not; 1 if a database cannot
      be read by this account, or a folder is named (it says which)

    Example (vigil.config):
      [job.sqlite_status]
      file        = packs/sqlite/status.ps1
      metric_name = sqlite
      run_every   = 5m
      env         = SQLITE_FILES=C:\ProgramData\app\data.db; D:\srv\other.db
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_sqlite.ps1')
$files = Get-Databases

$magic = [Text.Encoding]::ASCII.GetBytes("SQLite format 3`0")
$missing = 0
$denied = @()
$folders = @()
foreach ($f in $files) {
    $t = "db=$(Safe $f)"
    if (Test-Path -LiteralPath $f -PathType Container) { $folders += $f; continue }
    $st = Get-Stat $f
    if ($null -eq $st) { $missing++; M 'found' 0 $t; continue }
    try { $h = Read-Head $f 100 } catch { $denied += $f; continue }
    M 'found' 1 $t
    $last = $st.Time
    $wal = 0
    $w = Get-Stat "$f-wal"
    if ($null -ne $w) {
        $wal = $w.Size
        if ($w.Time -gt $last) { $last = $w.Time }
    }
    # A rollback journal in use, or left by a writer that died: its header
    # is there. One kept after its transaction (journal_mode=PERSIST) has
    # its first 28 bytes zeroed; one truncated (TRUNCATE) is empty.
    $jbytes = 0
    $jage = $null
    $j = Get-Stat "$f-journal"
    if ($null -ne $j -and $j.Size -gt 0) {
        $jh = $null
        try { $jh = Read-Head "$f-journal" 28 } catch { }
        if ($null -ne $jh -and @($jh | Where-Object { $_ -ne 0 }).Count -gt 0) {
            $jbytes = $j.Size
            $jage = [Math]::Max(0, $script:Now - $j.Time)
        }
    }
    M 'size_bytes' $st.Size $t
    $ok = $h.Length -ge 100
    for ($i = 0; $ok -and $i -lt 16; $i++) { if ($h[$i] -ne $magic[$i]) { $ok = $false } }
    if ($st.Size -eq 0) {
        # An empty file is an empty database: SQLite writes the header with
        # the first table.
        M 'valid' 1 $t
    } elseif (-not $ok) {
        M 'valid' 0 $t
    } else {
        M 'valid' 1 $t
        $ps = U16 $h 16
        if ($ps -eq 1) { $ps = 65536 }
        $mode = if ($h[18] -eq 2) { 'wal' } else { 'rollback' }
        $v = U32 $h 96
        $version = '{0}.{1}.{2}' -f [Math]::Floor($v / 1000000), ([Math]::Floor($v / 1000) % 1000), ($v % 1000)
        $vacuum = if ((U32 $h 52) -eq 0) { 'none' } elseif ((U32 $h 64) -eq 0) { 'full' } else { 'incremental' }
        M 'info' 1 "$t mode=$mode version=$version vacuum=$vacuum"
        # The page count in the header when it is current (its
        # version-valid-for is its change counter); else by size.
        $pages = if ((U32 $h 92) -eq (U32 $h 24) -and (U32 $h 28) -gt 0) { U32 $h 28 } else { [Math]::Floor($st.Size / $ps) }
        $free = U32 $h 36
        M 'page_size' $ps $t
        M 'pages' $pages $t
        M 'free_pages' $free $t
        if ($pages -gt 0) { M 'free_pct' (100 * $free / $pages) $t }
        M 'free_bytes' ($free * $ps) $t
    }
    M 'wal_bytes' $wal $t
    M 'journal_bytes' $jbytes $t
    if ($null -ne $jage) { M 'journal_seconds' $jage $t }
    M 'last_write_seconds' ([Math]::Max(0, $script:Now - $last)) $t
}
M 'databases' $files.Count
M 'missing' $missing
if ($folders.Count -gt 0) { [Console]::Error.WriteLine("${Job}: SQLITE_FILES names a folder, not a database file: $($folders -join ', ')") }
if ($denied.Count -gt 0) {
    [Console]::Error.WriteLine("${Job}: this account ($([Environment]::UserName)) cannot read $($denied -join ', '): give it read access (packs/sqlite/README.md shows how)")
}
if ($denied.Count -gt 0 -or $folders.Count -gt 0) { exit 1 }
exit 0
