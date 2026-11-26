# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# run-sqlite.ps1 - the sqlite pack on Windows, against databases in every
# state it reads, with its evidence kept like the other runs'. The twin of
# run-sqlite.sh.
#
#   scripts\run-sqlite.ps1 [-Shell <a PowerShell>] [-Sqlite3 <sqlite3.exe>]
#
# With sqlite3.exe (-Sqlite3, else the one on the PATH) it makes, in a
# folder of its own, the same databases as run-sqlite.sh: rollback and WAL,
# free pages, 64 KB pages, auto-vacuum full and incremental, a WAL held by
# an old reader beside one that is not, a transaction held open, a database
# locked for writing, random bytes, an empty file and a damaged copy. Every
# job runs under -Shell (default: the PowerShell this runs in) and what each
# read is checked. Then tests\integration\Service-Packs.ps1 runs the pack
# through Vigil. Nothing outside its folder is touched.
param([string]$Shell = (Get-Process -Id $PID).Path, [string]$Sqlite3 = '')
$ErrorActionPreference = 'Continue'
$bk = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
. (Join-Path $PSScriptRoot 'evidence.ps1')
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-sqlite-it.$PID"
$root = Join-Path $work 'none'
$d = Join-Path $work 'db'
[void](New-Item -ItemType Directory -Force -Path $d)
# Windows PowerShell 5.1 started from PowerShell 7 must not load 7's modules.
if ($Shell -like '*\powershell.exe') {
    $env:PSModulePath = (@($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -notlike '*\PowerShell\7*' -and $_ -notlike '*\Documents\PowerShell\*' -and $_ -notlike '*\Program Files\PowerShell\Modules*' }) -join ';')
}
if (-not $Sqlite3) { $g = Get-Command sqlite3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g) { $Sqlite3 = $g.Source } }
if (-not $Sqlite3 -or -not (Test-Path -LiteralPath $Sqlite3 -PathType Leaf)) { Write-Output 'sqlite3.exe not found: -Sqlite3 <its path>'; exit 1 }
$sqv = (& $Sqlite3 --version).Split(' ')[0]
$psv = & $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
$name = 'pack-sqlite-windows' + $(if ($psv -like '5.*') { '' } else { '-powershell7' })
Start-Evidence $name $bk '' "$($MyInvocation.MyCommand.Path) -Shell $Shell"
Write-Output "here     sqlite3 $sqv, jobs run under PowerShell $psv, as an account that $(if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'is an administrator' } else { 'is not an administrator' })"

$script:pass = 0; $script:fail = 0
function Check([string]$what, [string]$want, [string]$got) {
    if ($want -ceq $got) { $script:pass++; Write-Output "  PASS  $what" } else { $script:fail++; Write-Output "  FAIL  ${what}: expected [$want] actual [$got]" }
}
function Say([string]$t) { Write-Output ''; Write-Output "# $t" }
$out = @{}
function Quiet([string]$j) {
    $lines = @(& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "packs\sqlite\windows\$j.ps1") 2>&1 | ForEach-Object { "$_" })
    $script:code = $LASTEXITCODE
    $out[$j] = $lines
    [System.IO.File]::WriteAllLines((Join-Path $work "$j.out"), $lines)
}
# Run-Job <job> [<label>]: its output shown, the run's folder taken out of
# the paths.
$tagWork = ($work -replace '\\', '/') -replace '[^A-Za-z0-9@._:/+-]', '_'
function Run-Job([string]$j, [string]$label = '') {
    Write-Output ''
    Write-Output "PS> powershell -File packs\sqlite\windows\$j.ps1$(if ($label) { "   ($label)" })"
    Quiet $j
    $out[$j] | ForEach-Object { $_.Replace("$tagWork/", '.../').Replace("$work\", '...\') } | Write-Output
    if ($script:code -ne 0) { Write-Output "exit $($script:code)" }
}
# Val <job> <reading> [<db file name>] [<more tags>]
function Val([string]$j, [string]$metric, [string]$db = '', [string]$tags = '') {
    foreach ($l in $out[$j]) {
        if ($l -cmatch "^metric $metric (\S+)( .*)?$") {
            $v = $Matches[1]; $rest = "$([string]$Matches[2]) "
            if ($db -and $rest -notmatch " db=\S*/$([regex]::Escape($db)) ") { continue }
            if ($tags -and $rest -notmatch " $([regex]::Escape($tags)) ") { continue }
            return $v
        }
    }
    return ''
}
function Has([string]$j, [string]$metric, [string]$db = '', [string]$tags = '') { if ((Val $j $metric $db $tags) -ne '') { 'yes' } else { 'no' } }
function Least([string]$j, [string]$metric, [string]$db, [double]$n) {
    $v = Val $j $metric $db
    $x = [double]0
    if ($v -and [double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x) -and $x -ge $n) { return 'yes' }
    return "no [$v]"
}
# Statements for sqlite3.exe, on its standard input: no quoting to get wrong.
function Q([string]$db, [string]$sql) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $Sqlite3
    $si.Arguments = '"' + $db + '"'
    $si.UseShellExecute = $false
    $si.RedirectStandardInput = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($si)
    $p.StandardInput.WriteLine($sql)
    $p.StandardInput.Close()
    $e = $p.StandardError.ReadToEndAsync()
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "sqlite3 failed on ${db}: $($e.Result)" }
    return $o.Trim()
}
function Rows([int]$n, [int]$size) { "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < $n) INSERT INTO t (v) SELECT randomblob($size) FROM c;" }
# A database held: sqlite3.exe reading its statements from a pipe this
# script keeps open; it ends when the pipe is closed.
$script:holders = @()
function Hold([string]$db, [string]$sql) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $Sqlite3
    $si.Arguments = '"' + $db + '"'
    $si.UseShellExecute = $false
    $si.RedirectStandardInput = $true
    $si.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($si)
    [void]$p.StandardOutput.ReadToEndAsync()
    $p.StandardInput.WriteLine($sql)
    $p.StandardInput.Flush()
    $script:holders += $p
}
function Release {
    foreach ($p in $script:holders) {
        try { $p.StandardInput.Close() } catch { }
        if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    $script:holders = @()
}

try {
    Say 'Databases in every state the pack reads, made with sqlite3.'
    $t = 'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB);'
    [void](Q "$d\plain.db" "$t $(Rows 200 500)")
    [void](Q "$d\frag.db" "$t $(Rows 20000 500) DELETE FROM t WHERE id % 10 != 0;")
    [void](Q "$d\wal.db" "PRAGMA journal_mode = WAL; $t $(Rows 100 500)")
    [void](Q "$d\big-pages.db" "PRAGMA page_size = 65536; $t $(Rows 100 500)")
    [void](Q "$d\autovac.db" "PRAGMA auto_vacuum = FULL; $t $(Rows 100 500)")
    [void](Q "$d\incremental.db" "PRAGMA auto_vacuum = INCREMENTAL; $t $(Rows 100 500)")
    [void](Q "$d\held.db" "$t $(Rows 200 500)")
    [void](Q "$d\locked.db" "$t $(Rows 200 500)")
    foreach ($w in 'grow', 'calm') { [void](Q "$d\$w.db" "PRAGMA journal_mode = WAL; $t $(Rows 10 100)") }
    $rnd = New-Object byte[] 8192
    (New-Object System.Random 7).NextBytes($rnd)
    [IO.File]::WriteAllBytes("$d\notdb.db", $rnd)
    [IO.File]::WriteAllBytes("$d\empty.db", (New-Object byte[] 0))
    Copy-Item -LiteralPath "$d\frag.db" -Destination "$d\damaged.db"
    # Page 6 overwritten: inside the table, past the header.
    $ps = [int](Q "$d\damaged.db" 'PRAGMA page_size;')
    $fs = [IO.File]::Open("$d\damaged.db", 'Open', 'Write')
    $fs.Position = 5 * $ps
    $z = New-Object byte[] $ps
    for ($i = 0; $i -lt $ps; $i++) { $z[$i] = 0x5A }
    $fs.Write($z, 0, $ps)
    $fs.Dispose()
    # An old reader holds grow.db's WAL; calm.db has the same writes and no
    # reader.
    Hold "$d\grow.db" 'BEGIN; SELECT count(*) FROM t;'
    Start-Sleep -Seconds 1
    foreach ($w in 'grow', 'calm') { foreach ($i in 1..40) { [void](Q "$d\$w.db" (Rows 500 1000)) } }
    Hold "$d\held.db" 'BEGIN IMMEDIATE; UPDATE t SET v = randomblob(600) WHERE id < 100;'
    Hold "$d\locked.db" 'BEGIN EXCLUSIVE;'
    Start-Sleep -Seconds 2
    Get-ChildItem -LiteralPath $d | ForEach-Object { '  {0,10}  {1}' -f $_.Length, $_.Name } | Write-Output

    $names = 'plain', 'frag', 'wal', 'big-pages', 'autovac', 'incremental', 'grow', 'calm', 'held', 'locked', 'notdb', 'empty', 'damaged', 'nope'
    $env:SQLITE_FILES = (@($names | ForEach-Object { "$d\$_.db" }) -join '; ')
    $n = $names.Count

    Say 'Every job, as the Windows scripts print it.'
    Run-Job status
    Check 'status: runs' '0' ([string]$script:code)
    Remove-Item env:SQLITE_CHECK -ErrorAction SilentlyContinue
    Run-Job check 'SQLITE_CHECK not set: off'
    Check 'check: off until asked: checked 0, and nothing else' '0 1 0' "$($script:code) $(@($out['check']).Count) $(Val check checked)"
    $env:SQLITE_CHECK = 'quick'
    $env:SQLITE3 = $Sqlite3
    Run-Job check 'SQLITE_CHECK=quick'
    Check 'check: runs' '0' ([string]$script:code)

    Say 'What each job must have read.'
    Check 'status: every database named is counted, and the one not there' "$n 1 0" "$(Val status databases) $(Val status missing) $(Val status found nope.db)"
    Check 'status: the database files are valid; random bytes are not; an empty file is' '1 1 0 1' "$(Val status valid plain.db) $(Val status valid wal.db) $(Val status valid notdb.db) $(Val status valid empty.db)"
    Check 'status: the journal mode, as written in each header' 'yes yes' "$(Has status info plain.db mode=rollback) $(Has status info wal.db mode=wal)"
    Check 'status: the SQLite that last wrote it' 'yes' (Has status info plain.db "version=$sqv")
    Check 'status: auto-vacuum: none, full and incremental' 'yes yes yes' "$(Has status info plain.db vacuum=none) $(Has status info autovac.db vacuum=full) $(Has status info incremental.db vacuum=incremental)"
    Check 'status: the page size, 64 KB too (written as 1 in the header)' '4096 65536' "$(Val status page_size plain.db) $(Val status page_size big-pages.db)"
    foreach ($f in 'plain', 'frag', 'big-pages') {
        Check "status: ${f}.db: pages and free pages, as sqlite3 counts them" "$(Q "$d\$f.db" 'PRAGMA page_count;') $(Q "$d\$f.db" 'PRAGMA freelist_count;')" "$(Val status pages "$f.db") $(Val status free_pages "$f.db")"
    }
    Check 'status: nine rows in ten deleted: most pages free, and the space they hold' 'yes True' "$(Least status free_pct frag.db 80) $([double](Val status free_bytes frag.db) -eq [double](Val status free_pages frag.db) * 4096)"
    Check 'status: the size, as the file is' ([string](Get-Item -LiteralPath "$d\frag.db").Length) (Val status size_bytes frag.db)
    $calm = [double](Val status wal_bytes calm.db)
    Check 'status: the WAL held by an old reader has grown; the same writes without one have not' 'yes True' "$(Least status wal_bytes grow.db 15000000) $($calm -gt 0 -and $calm -lt 6000000)"
    Check 'status: a database closed cleanly has no WAL' '0' (Val status wal_bytes wal.db)
    Check 'status: the transaction held open: its journal, and how long since it was written' 'yes yes' "$(Least status journal_bytes held.db 1) $(Has status journal_seconds held.db)"
    Check 'status: no journal where no transaction is open' '0 no' "$(Val status journal_bytes plain.db) $(Has status journal_seconds plain.db)"
    Check 'status: last written: seconds ago, for each' 'yes yes' "$(Has status last_write_seconds plain.db) $(Least status last_write_seconds frag.db 0)"
    Check 'check: every database there is checked, but those locked' ([string]($n - 2)) (Val check checked)
    Check 'check: a sound database is ok; its check timed' '1 0 yes' "$(Val check ok frag.db) $(Val check problems frag.db) $(Has check check_seconds frag.db)"
    Check 'check: the page overwritten is found' 'yes 0' "$(Least check problems damaged.db 1) $(Val check ok damaged.db)"
    Check 'check: random bytes: not a database' '0' (Val check ok notdb.db)
    Check 'check: a WAL held by a reader is checked, read-only' '1' (Val check ok grow.db)
    Check 'check: in rollback mode, a transaction still open does not stop the check' '1' (Val check ok held.db)
    Check 'check: the database locked for writing could not be checked: busy, after 30 seconds' '1' (Val check busy locked.db)
    Check 'check: the damaged ones are counted' '2' (Val check not_ok)

    Say 'Released: the reader, the writer and the lock end, and the WAL and the journal go.'
    Release
    Start-Sleep -Seconds 1
    Quiet status
    $out['status'] | Where-Object { $_ -match '(wal_bytes|journal_bytes|journal_seconds) .*(grow|held)\.db' } | ForEach-Object { $_.Replace("$tagWork/", '.../') } | Write-Output
    Check 'released: the journal is gone' '0 no' "$(Val status journal_bytes held.db) $(Has status journal_seconds held.db)"
    Check 'released: the WAL is deleted as its last connection closes' '0' (Val status wal_bytes grow.db)

    Say 'A database this account may not read: the others are read, and the run fails, naming it.'
    Copy-Item -LiteralPath "$d\plain.db" -Destination "$d\secret.db"
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls "$d\secret.db" /deny "${me}:(R)" > $null
    $env:SQLITE_FILES = "$d\plain.db; $d\secret.db"
    Quiet status
    $out['status'] | Where-Object { $_ -match 'found|cannot' } | ForEach-Object { $_.Replace("$tagWork/", '.../').Replace("$work\", '...\') } | Write-Output
    Check 'unreadable: exit 1, the others read, and the file named' '1 1 True' "$($script:code) $(Val status found plain.db) $([string](@($out['status'] | Where-Object { $_ -match 'cannot read .*secret\.db' }).Count -gt 0))"
    & icacls "$d\secret.db" /remove:d $me > $null
    $env:SQLITE_FILES = $d
    Quiet status
    Check 'a folder named: exit 1, said' '1 True' "$($script:code) $([string](@($out['status'] | Where-Object { $_ -match 'names a folder' }).Count -gt 0))"
    $env:SQLITE_FILES = ''
    Quiet status
    Check 'SQLITE_FILES not set: databases 0, and the run succeeds' '0 metric databases 0' "$($script:code) $($out['status'][0])"

    Write-Output ''
    Write-Output "$($script:pass) passed, $($script:fail) failed"
    $direct = $script:fail

    Say 'The pack through Vigil.'
    $env:VIGIL_IT_SQLITE = "$d\plain.db; $d\frag.db; $d\damaged.db; $d\nope.db"
    $env:VIGIL_IT_SQLITE3 = $Sqlite3
    Remove-Item env:SQLITE_FILES, env:SQLITE_CHECK, env:SQLITE3 -ErrorAction SilentlyContinue
    & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\integration\Service-Packs.ps1') 2>&1 | ForEach-Object { "$_".Replace("$tagWork/", '.../').Replace("$work\", '...\') } | Write-Output
    $rc = $LASTEXITCODE
}
finally {
    Release
    Save-Evidence $work $root @()
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
if ($direct -eq 0 -and $rc -eq 0) { exit 0 }
exit 1
