# The sqlite pack

SQLite databases, from the files an application keeps them in. For each database you name, the pack reads whether it is there and is a SQLite database; its size, page size and pages; its free pages, which hold no data and which a `VACUUM` would give back; its write-ahead log; a rollback journal in use, and for how long; and when it was last written. Only when you ask, once a day, it checks each database for damage with `PRAGMA quick_check`.

SQLite has no server to ask, and that is exactly why trouble hides in it. Grafana, Gitea, Home Assistant, a phone app's backend, half the tools on a machine keep their data in one, and nothing reports on it until something goes wrong: a reader that holds an old snapshot keeps every checkpoint from finishing, and the WAL grows to gigabytes while reads slow down; a writer that dies in the middle of a transaction leaves its journal behind, and every other writer fails with "database is locked"; a disk that lies about its writes leaves a page damaged that nobody reads until the day someone does.

**It takes no lock, and needs no SQLite.** The `status` job reads each database's first 100 bytes, its header, and the sizes and times of it and its `-wal` and `-journal` files, as files like any other. No SQLite library opens the database, so there is nothing the application can notice: no lock taken, no checkpoint started, no file created. It needs `od` and `awk` on Linux and macOS, which every one has, and nothing but PowerShell on Windows.

**The check is off until you turn it on.** `PRAGMA quick_check` reads every page, so it takes seconds a gigabyte. And in rollback mode (not WAL) it holds a shared lock while it runs, so the application's writes wait for it, and fail with "database is locked" if they wait longer than the application allows. The `check` job does nothing (`checked 0`) until `SQLITE_CHECK=quick`. Then it opens each database read-only with the `sqlite3` program, changes nothing and repairs nothing. Run it once a day, at a quiet hour.

1. `vigil pack enable sqlite`, then in `vigil.config` set both jobs' `SQLITE_FILES`: the databases, their full paths separated by `;`:

   ```ini
   env = SQLITE_FILES=/var/lib/grafana/grafana.db; /var/lib/gitea/data/gitea.db
   ```

   On Windows, `env = SQLITE_FILES=C:\ProgramData\app\data.db; D:\srv\other.db`. Each database is tagged `db=<its path>`, with `/` for `\`, and its last 120 characters when it is longer.

2. **Read access for the account Vigil runs as.** A database is usually its application's own, readable by nobody else. Give Vigil's account read access, and nothing more:

   - **Linux:** `sudo setfacl -m u:vigil:r /var/lib/grafana/grafana.db` and `sudo setfacl -m u:vigil:x /var/lib/grafana` (to reach the file in its folder), or add the account to the application's group when the file is group-readable (`sudo usermod -aG grafana vigil`, then restart Vigil).
   - **Windows:** `icacls C:\ProgramData\app\data.db /grant "vigil:(R)"`, for the account the Vigil service runs as.
   - **macOS:** `chmod +a "vigil allow read" <file>`, or run the job as the application's account.

   For the check in WAL mode, `sqlite3` also reads the `-wal` and `-shm` files beside the database, so give the account read access to the folder they are in (Linux: `sudo setfacl -m u:vigil:rx <folder>` and `sudo setfacl -d -m u:vigil:r <folder>`, so the new ones SQLite makes are readable too).

3. **For the check**, `sqlite3` on the Vigil machine (`apt install sqlite3`, `dnf install sqlite`; macOS has it; on Windows the `sqlite-tools` zip from sqlite.org, and `env = SQLITE3=C:\Tools\sqlite\sqlite3.exe`), then on the `sqlite_check` job:

   ```ini
   env = SQLITE_CHECK=quick
   ```

   It runs once a day already (`run_every = 1d`); `max_runtime = 30m` covers a database of several gigabytes on an ordinary disk.

**A database that is not there is a reading**, `found 0`, and the run succeeds: alert on `missing` in your backend. So is one that is not a SQLite database, `valid 0`. A run fails only when it cannot do its work: a database this account may not read, a folder named instead of a file, `sqlite3` missing for the check. It says which.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `bash`, `od`, `awk` (every Linux has them); `sqlite3` for the check | the same (macOS has `sqlite3`) | Nothing: PowerShell 5.1 or later; `sqlite3.exe` for the check |
| The databases | SQLite 3, WAL or rollback journal | | |
| Access | read access to each database for Vigil's account; for the check in WAL mode, to its folder too | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `sqlite_status` | Each database: there or not, a SQLite database or not, its journal mode, the SQLite that last wrote it, auto-vacuum; its size, page size, pages, free pages and the space they hold; its WAL's size; a rollback journal in use and for how long; since it was last written | 5 minutes |
| `sqlite_check` | Off until `SQLITE_CHECK=quick`. Then each database's `PRAGMA quick_check`: whether it found anything wrong and how much, how long it took, or that the database stayed locked | day |

**The header is as of the last checkpoint.** In WAL mode, a change reaches the database file, and its header, only when a checkpoint copies it there. Until then `pages` and `free_pages` may lag what the application sees by a few pages: a few minutes' work, on an ordinary database.

**The WAL's size is the most it has needed.** SQLite reuses its WAL from the start after each checkpoint, without making the file smaller, until the last connection closes (then it deletes it) or the application sets `journal_size_limit`. So a WAL of 40 MB that stays at 40 MB is one that once needed 40 MB. One that is larger at every run is one whose checkpoints cannot finish.

**A journal in use** is one whose header is there. SQLite writes it as a transaction starts changing pages, and deletes it (or zeroes it, or truncates it) as the transaction ends. So a journal for a second is ordinary; a journal there for minutes is a transaction left open, or one whose writer died. `journal_seconds` is since the journal was last written.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `sqlite.databases`.

```text
+--------------------------------------------------------------------------------------------------+
| sqlite_status   sqlite.<metric>   every 5m                                                       |
+--------------------+-----------------------------------------------------------------------------+
| databases          | the databases in SQLITE_FILES                                               |
| missing            | of those, how many are not there                                            |
| found              | 1 when the file is there, else 0, tagged db=<path>; the rest only for one   |
|                    | found                                                                       |
| valid              | 1 when it starts as a SQLite database does (or is empty), else 0: not a     |
|                    | database, damaged, or encrypted (SQLCipher)                                 |
| info               | always 1, tagged mode=<wal, rollback>, version=<the SQLite that last wrote  |
|                    | it, 3.45.1> and vacuum=<none, full, incremental>                            |
| size_bytes         | the file's size                                                             |
| page_size          | its page size, in bytes                                                     |
| pages              | its pages                                                                   |
| free_pages         | pages on its free list: kept by the file, holding no data                   |
| free_pct           | free_pages, of pages                                                        |
| free_bytes         | the space a VACUUM would give back                                          |
| wal_bytes          | its write-ahead log's size (0 when it has none): the largest it has been    |
|                    | since the last connection closed, as SQLite reuses it                       |
| journal_bytes      | a rollback journal in use (0 when none)                                     |
| journal_seconds    | how long that journal has been in use, by when it was last written          |
| last_write_seconds | since the database or its WAL was last written                              |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  missing 0; valid 1; wal_bytes a few MB (SQLite checkpoints at about 4 MB); journal_bytes 0 |
|       most of the time; free_pct low, or steady.                                                 |
| WATCH wal_bytes past 64 MB, or higher every day; free_pct past 25 on a large database (a VACUUM  |
|       would give space back); last_write_seconds far longer than the application's habit.        |
| BAD   missing above 0 or valid 0; wal_bytes past 1 GB and growing (a reader holds an old         |
|       snapshot: checkpoints cannot finish, reads slow down); journal_seconds past 10 minutes (a  |
|       writer died in a transaction, or holds one open: other writers wait or fail with "database |
|       is locked").                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| sqlite_check   sqlite.check.<metric>   every 1d                                                  |
+---------------+----------------------------------------------------------------------------------+
| checked       | databases checked; 0 while SQLITE_CHECK is not quick                             |
| ok            | 1 when the check found nothing wrong, else 0, tagged db=<path>                   |
| problems      | what it found wrong (at most 100): 0 when ok                                     |
| check_seconds | how long the check took                                                          |
| busy          | 1 when the database stayed locked and could not be checked                       |
| not_ok        | databases whose check found something wrong                                      |
+---------------+----------------------------------------------------------------------------------+
| GOOD  not_ok 0; check_seconds steady.                                                            |
| WATCH busy 1 on two days running (a writer holds the database most of the time: pick another     |
|       hour); check_seconds near max_runtime.                                                     |
| BAD   not_ok above 0: copy the database aside (with its -wal), and run sqlite3 <file> "PRAGMA    |
|       integrity_check" on the copy to see what is wrong; restore from a backup, or .recover what |
|       can be.                                                                                    |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the databases made on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `sqlite.missing` | 0 |  | Above 0: a database is gone, or its path is wrong; `found` says which | 1, for the path named that was never made |
| `sqlite.valid` (by `db`) | 1 |  | 0: the file is not a SQLite database: damaged at the start, replaced, or encrypted (SQLCipher, whose header is encrypted too) | 0 for the file of random bytes |
| `sqlite.wal_bytes` (by `db`) | A few MB: SQLite checkpoints at about 4 MB | Past 64 MB, or larger every day | Past 1 GB and growing: a reader holds an old snapshot, so no checkpoint can finish, and reads slow down as they search the WAL | 21 MB in seconds, while a reader held one transaction open and a writer went on; 0 for the same writes with no reader (each writer's last close checkpointed it into the database); Gitea's own, 4 MB, while it ran |
| `sqlite.journal_seconds` (by `db`) | Absent, or a few seconds |  | Past 10 minutes: a transaction left open, or a writer that died in one; other writers wait or fail with "database is locked" | 15 s, a 66 KB journal, while a writer held its transaction open; gone when it ended |
| `sqlite.free_pct` (by `db`) | Low, or steady | Past 25 on a large database: a `VACUUM` would give `free_bytes` back |  | 88.52 after nine rows in ten were deleted |
| `sqlite.last_write_seconds` (by `db`) | Within the application's habit | Far longer than its habit: the application has stopped writing |  | The seconds since each was made |
| `sqlite.check.not_ok` | 0 |  | Above 0: a damaged database. Copy it aside, with its `-wal`, and run `sqlite3 <copy> "PRAGMA integrity_check"` to see what; restore from a backup, or `.recover` what can be | 2: the copy with its table's root page overwritten (`problems 100`, the most the check lists), and the file of random bytes |
| `sqlite.check.busy` (by `db`) | 0 | 1 on two days running: a writer holds the database most of the time; pick another hour |  | 1 while a writer held the database locked past the 30 seconds the check waits |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-26 by `tests/integration/backends/scripts/run-sqlite.sh`, with `sqlite3` 3.53.4, on a Linux test host (Alpine Linux 3.24, bash 5.3, as an account that is not root, so a file it may not read is one it cannot read). The run made, with `sqlite3`, a database in every state the pack reads: rollback mode and WAL; nine rows in ten deleted (free pages); 64 KB pages; auto-vacuum full and incremental; a WAL held by an old reader while a writer went on, beside the same writes with no reader; a transaction held open (its journal); a database locked for writing (`BEGIN EXCLUSIVE`); a file of random bytes, an empty file, a copy with its table's root page overwritten, and a path that was never made. And two applications that keep their data in SQLite, running in containers while they were read and checked: **Grafana 12.2.1** (rollback mode, as it ships, written by its SQLite 3.45.1) and **Gitea 1.24** (set to WAL, its SQLite 3.49.1).

- **On Linux**: every job, each reading checked against what `sqlite3` itself says (pages, free pages, page size, mode, version); the check off, then on: sound databases `ok 1`, the damaged copy and the random bytes found, the locked one `busy` after its 30 seconds, the database in rollback mode with a transaction open checked all the same; then released: the journal and the WAL gone. A file this account may not read, a folder named and `SQLITE_FILES` empty, each as the header says. **37 passed, 0 failed**; then `service-packs.sh` through Vigil (enable, precheck, both jobs, the check turned on and finding the damaged copy, metrics in the backend, each database by its path): **11 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/linux-it/pack-sqlite/console.txt)).
- **On Windows** (Windows 11, an account that is not an administrator, Windows PowerShell 5.1 and PowerShell 7), the `status` job through Vigil against databases made the same way: **9 passed, 0 failed**. The `check` job, which runs `sqlite3.exe`, and `run-sqlite.ps1` (the Windows twin of the run above) are still to run on a Windows test machine.
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, BSD `od`, `awk` and `stat`, its own `sqlite3` 3.37.0): the same run, every state made the same way, without the two applications (no Docker for the test account there): **34 passed, 0 failed**; through Vigil, **11 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/macos/pack-sqlite/console.txt)).

**What the run taught the pack:**

- **SQLite heads its list of problems with a line of its own**, `*** in database main ***`. Counted, a database with 100 problems read 101; it is left out now.
- **A rollback journal is in use when its first bytes are not all zero**, not when its magic number is there: SQLite writes the magic number only when it syncs the journal, so a transaction open and not yet synced has none.
- **With no reader holding it, a WAL does not stay**: each connection that closes last checkpoints it into the database and deletes it. A WAL that is there and large, with the application idle, is the sign of a reader that never let go.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
