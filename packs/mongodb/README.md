# The mongodb pack

MongoDB, one server or a member of a replica set, from the server itself. On each server, the pack reads whether it answers, its version and storage engine; connections and their share of the most it takes; operations by kind and how long they took; operations queued for a lock; its memory; the WiredTiger cache, how full and how dirty, and pages the request threads had to evict themselves; cursors, asserts, network and transactions. The replica set as that member sees it: a primary or not, members healthy and down, how far each is behind, and the oplog's window. Its databases and their size. And the operations running now: those past a minute, the longest, those waiting for a lock. Linux, macOS and Windows.

MongoDB's trouble is mostly about time. A secondary that falls behind is fine until it falls off the end of the oplog, and then it needs a full resync. A replica set that loses its primary takes no writes, though every member still answers. A query left running for an hour holds its resources the whole time. The cache that cannot keep its dirty pages down makes every write wait. Each of these is in what the server says about itself, and the pack reads it.

**It only reads, and sees no data.** It logs in as a user with MongoDB's own `clusterMonitor` role, which may read the server's state (`serverStatus`, `replSetGetStatus`, `listDatabases`, `dbStats`, `currentOp`, the oplog's first and last entries) and none of the application's documents. In our tests MongoDB refused it a `find` and an `insert`.

**mongosh, and the password never on a command line.** Each job is a small script that MongoDB's shell, `mongosh`, runs with no connection of its own (`--nodb`): the script makes the connection, from the job's environment, so the password is never on mongosh's command line, where any account on the machine could see it. The same scripts run on Linux, macOS and Windows.

1. **A user with the clusterMonitor role**, as an admin, on the replica set's primary (it reaches every member) or on each server:

   ```javascript
   db.getSiblingDB('admin').createUser({ user: 'vigil', pwd: passwordPrompt(), roles: ['clusterMonitor'] })
   ```

2. **mongosh** on the Vigil machine, from [MongoDB's download page](https://www.mongodb.com/try/download/shell) (or `brew install mongosh`, `winget install MongoDB.Shell`). If it is not on the PATH of the account Vigil runs as, set the jobs' `MONGOSH` to its full path. **On macOS 12**, mongosh 2.14 does not start (it needs a newer system C++ library); mongosh 2.5.10 does, and reads MongoDB 9.0 as well.

3. `vigil pack enable mongodb`, then in `vigil.config` set the jobs' `MONGODB_URL`, without a password (the pack refuses one there):

   ```ini
   env = MONGODB_URL=mongodb://db1.example.com:27017
   ```

   and the password as a secret:

   ```sh
   vigil secret set MONGODB_PASSWORD
   ```

   Over TLS, `MONGODB_URL=mongodb://db1.example.com:27017/?tls=true`, and `MONGODB_CACERT` when the server's CA is not one the system trusts.

**One server, as it is.** The pack reads the server at `MONGODB_URL` and never moves to another (it connects directly, not to "the primary"), so a secondary reports as a secondary. Run it on every member, each pointed at its own (`mongodb://localhost:27017`): each reports itself and the set as it sees it. A URL that names a replica set (`?replicaSet=rs0`, or several hosts) is read as the driver chooses, which is the primary.

**A wrong password fails the run, saying so**, and so does a user without `clusterMonitor`, naming the role. A server that does not answer is a reading, `up 0`, and the run succeeds. A server that is not in a replica set reports `replicated 0`: a reading too.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `bash`, `mongosh` | `bash`, `mongosh` (2.5.10 on macOS 12) | PowerShell 5.1 or 7, `mongosh.exe` |
| MongoDB | 8.0 or 9.0, a server or a replica set member, reachable from the Vigil machine | | |
| A user | `clusterMonitor` (on `admin`) | | |
| A secret | `MONGODB_PASSWORD` | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `mongodb_status` | Whether the server answers, its version, engine and uptime; connections, available, their share, active; operations by kind and their average latency; operations queued for a lock; memory; the WiredTiger cache, how full and dirty, and pages evicted by the request threads; cursors; asserts; network; transactions | minute |
| `mongodb_replication` | The replica set as this member sees it: its name and this member's role; a primary or not; members healthy and down; how far each is behind, the furthest, and this member's own lag; the oplog's window, size and limit | minute |
| `mongodb_databases` | The databases, the largest first: how many and their size on disk; each one's size, data, indexes, collections and documents | 15 minutes |
| `mongodb_operations` | The operations running for clients: how many, those past a minute, the longest, those waiting for a lock, those in a transaction; the five longest by namespace, kind and ID (never their text) | minute |

Past a limit (`MONGODB_MOST`, 50 databases or members), the largest first, and the rest counted in a `_not_shown` line.

Running totals (`_count`) restart when the server restarts: graph them as a rate. `latency_avg_ms` is the average since the server started.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `mongodb.up`.

```text
+--------------------------------------------------------------------------------------------------+
| mongodb_status   mongodb.<metric>   every 1m                                                     |
+--------------------------------+-----------------------------------------------------------------+
| up                             | 1 when the server answers, else 0                               |
| info                           | always 1, tagged version=<9.0.8> engine=<wiredTiger>            |
| uptime_seconds                 | since it started                                                |
| connections                    | connections open                                                |
| connections_available          | connections it still takes                                      |
| connections_pct                | connections, of the most it takes                               |
| connections_active             | of those, running an operation                                  |
| connections_created_count      | connections opened (a running total)                            |
| operations_count               | operations (a running total), tagged op=<insert, query, update, |
|                                | delete, getmore, command>                                       |
| latency_avg_ms                 | time an operation took on average, since it started, tagged     |
|                                | op=<reads, writes, commands>                                    |
| queued                         | operations waiting for a lock, tagged for=<read, write>         |
| memory_resident_bytes          | memory it holds                                                 |
| cache_bytes                    | WiredTiger's cache, in use                                      |
| cache_max_bytes                | the most it may hold                                            |
| cache_pct                      | cache_bytes, of cache_max_bytes                                 |
| cache_dirty_pct                | changes not yet written, of cache_max_bytes                     |
| cache_evicted_by_threads_count | pages the threads serving requests had to evict themselves (a   |
|                                | running total)                                                  |
| cursors_open                   | cursors open                                                    |
| cursors_timed_out_count        | cursors closed for idling (a running total)                     |
| asserts_count                  | asserts (a running total), tagged kind=<regular, warning, msg,  |
|                                | user>                                                           |
| page_faults_count              | page faults (a running total)                                   |
| network_in_bytes_count         | bytes received (a running total)                                |
| network_out_bytes_count        | bytes sent (a running total)                                    |
| transactions_open              | multi-document transactions open                                |
| transactions_aborted_count     | transactions aborted (a running total)                          |
+--------------------------------+-----------------------------------------------------------------+
| GOOD  up 1; connections_pct below 50; cache_pct near 80 (WiredTiger keeps it there) and          |
|       cache_dirty_pct below 5; queued near 0; cache_evicted_by_threads_count flat.               |
| WATCH connections_pct past 70; cache_dirty_pct past 10; queued above 0 on several runs;          |
|       latency_avg_ms rising; asserts_count kind=regular or warning rising.                       |
| BAD   up 0; connections_pct past 90 (new clients refused); cache_dirty_pct past 20 or            |
|       cache_evicted_by_threads_count rising fast (writes stall); queued rising run after run.    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mongodb_replication   mongodb.replication.<metric>   every 1m                                    |
+--------------------+-----------------------------------------------------------------------------+
| up                 | 1 when the server answers, else 0                                           |
| info               | always 1, tagged set=<rs0> role=<primary, secondary, arbiter, standalone,   |
|                    | ...>                                                                        |
| replicated         | 1 in a replica set, else 0                                                  |
| members            | the set's members                                                           |
| members_healthy    | of those, answering                                                         |
| members_down       | of those, not answering                                                     |
| primary            | 1 when the set has a primary, else 0 (no writes)                            |
| secondaries        | members that are secondaries                                                |
| lag_seconds_max    | the furthest a secondary is behind                                          |
| lag_seconds        | this member's own lag, when a secondary                                     |
| member_health      | 1 when a member answers, else 0, tagged member=<host:port> state=<primary,  |
|                    | ...>                                                                        |
| member_lag_seconds | how far a member is behind, same tags                                       |
| oplog_window_hours | the oplog's history, as time                                                |
| oplog_bytes        | the oplog's size                                                            |
| oplog_max_bytes    | the most it may hold                                                        |
| ..._not_shown      | past 100 of a list (members), how many were left out                        |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  primary 1; members_down 0; lag_seconds_max a few seconds; oplog_window_hours a day or      |
|       more.                                                                                      |
| WATCH lag_seconds_max past 60; oplog_window_hours below 24 (a member away for a day would need a |
|       full resync).                                                                              |
| BAD   primary 0 (no writes); members_down above 0; lag_seconds_max past 600, or near             |
|       oplog_window_hours (the member will fall off the oplog).                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mongodb_databases   mongodb.databases.<metric>   every 15m                                       |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when the server answers, else 0                                               |
| databases      | databases                                                                       |
| size_bytes     | their size on disk                                                              |
| db_size_bytes  | a database's size on disk, tagged db=<name>                                     |
| db_data_bytes  | its data, uncompressed                                                          |
| db_index_bytes | its indexes                                                                     |
| db_collections | its collections                                                                 |
| db_indexes     | its indexes                                                                     |
| db_documents   | its documents                                                                   |
| ..._not_shown  | past 100 of a list (databases), how many were left out                          |
+----------------+---------------------------------------------------------------------------------+
| GOOD  db_size_bytes growing as the application does.                                             |
| WATCH a database growing faster than usual; db_index_bytes past its data (indexes nobody uses).  |
| BAD   size_bytes near the disk's free space (the base pack has it).                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| mongodb_operations   mongodb.operations.<metric>   every 1m                                      |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when the server answers, else 0                                            |
| running           | operations running                                                           |
| slow              | of those, running past 60 seconds                                            |
| longest_seconds   | the longest running                                                          |
| waiting_for_lock  | of those, waiting for a lock                                                 |
| transactions_open | operations in a transaction                                                  |
| op_seconds        | the five longest, tagged ns=<db.collection> op=<query, command, ...>         |
|                   | id=<opid>                                                                    |
+-------------------+------------------------------------------------------------------------------+
| GOOD  slow 0; waiting_for_lock 0.                                                                |
| WATCH slow above 0 on two runs in a row; waiting_for_lock above 0.                               |
| BAD   an operation running for hours that nobody expects: db.killOp(<id>), as an admin.          |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what a three-member replica set in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `mongodb.up` | 1 | | 0 for more than a few minutes: the server is down | 1; `up 0` for a port nothing listened on, the run succeeding |
| `mongodb.replication.primary` | 1 | | 0: the set takes no writes | 1; 0 with two of three stopped, the member left `role=secondary`, `up 1` |
| `mongodb.replication.members_down`, `member_health` (by `member`) | 0; 1 | | `members_down` above 0 | 1 with a member stopped (`member_health 0 ... state=not_reachable_healthy`); 1 again when the primary stopped and m2 was elected |
| `mongodb.replication.lag_seconds_max`, `member_lag_seconds` | Up to some 10 s at rest (the primary writes a no-op every 10 s) | Past 60 | Past 600, or near `oplog_window_hours`: the member will fall off the oplog | 66 for the member whose fetching was stopped (a fail point), the others 0 |
| `mongodb.replication.oplog_window_hours` | A day or more | Below 24 | Below the longest a member may be away | 0.02 on a set an hour old: the window grows until the oplog is full |
| `mongodb.connections_pct` | Below 50 | Past 70 | Past 90: new clients refused | 4.16 |
| `mongodb.cache_dirty_pct`, `cache_evicted_by_threads_count` | Below 5; flat | Past 10 | Past 20, or evictions by threads rising fast: writes stall | 0.21 dirty of a 256 MB cache (3.14 full) |
| `mongodb.latency_avg_ms` (by `op`) | Steady | Rising | | 0.22 reads, 18.61 writes, 3.96 commands, on the primary after it took 10,000 inserts |
| `mongodb.operations.slow`, `longest_seconds` | 0 | Above 0 on two runs | An operation running for hours nobody expects: `db.killOp(<id>)` | `slow 1`, 67.89 s (`op_seconds 67.89 ns=app.slow op=query`), a `$where` sleeping a second a document |
| `mongodb.operations.waiting_for_lock` | 0 | Above 0 | Rising run after run | 1, an insert behind `fsyncLock` on 8.0 |
| `mongodb.transactions_open` | Short-lived | One open for minutes | | 1, held open on purpose (MongoDB aborts one after 60 s unless `transactionLifetimeLimitSeconds` says otherwise; the test set it to an hour) |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-26 by `tests/integration/backends/scripts/run-mongodb.sh`, against `compose.mongodb.yaml`: **MongoDB 9.0.8, a replica set of three** with authentication (a keyfile) and chaining off, and **MongoDB 8.0.38, one server** with authentication. As root, on each: the user the pack asks for (`vigil`, `clusterMonitor`), and on the set one with a role to read `app` and nothing else. In the set: 10,000 documents; a query that runs for minutes (`$where` with `sleep`); a transaction held open; a secondary stopped from fetching (the `stopReplProducer` fail point) while the primary took writes. On 8.0: an insert held behind `fsyncLock`. The passwords and the keyfile were made by the run and kept out of the evidence.

- **On Fedora 44** (bash 5.3, mongosh 2.14.3): every job against the primary, a secondary and 8.0, each reading checked; a wrong password, the user without `clusterMonitor` (naming the role), no password set, a password left in `MONGODB_URL` (refused), nothing listening (`up 0`); and the password on no process's command line while a job ran, every process's read again and again until mongosh was among them. Then `service-packs.sh` through Vigil. Then the set fell apart: a member stopped (down, the set still with a primary); the primary stopped (another elected); two stopped (no primary, the last one `role=secondary`, still `up 1`): **38 passed, 0 failed**, and through Vigil **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/fedora/pack-mongodb/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, with mongosh 2.14.3, against the same servers held up for it, through SSH tunnels: every job against the primary, a secondary and 8.0, under Windows PowerShell 5.1 and PowerShell 7, the same metric names and tags as the Linux scripts read just after, and the same values where they hold still (24 of 24); a wrong password and nothing listening as on Linux; through Vigil, **17 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/windows/pack-mongodb-windows/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2) with **mongosh 2.5.10** (2.14.3 does not start on macOS 12: `Symbol not found` in the system's `libc++`), against the same servers through SSH tunnels: every job against the primary, a secondary and 8.0, each reading checked, a wrong password and nothing listening: **14 passed, 0 failed**; through Vigil, **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/macos/pack-mongodb-macos/console.txt)). So an older mongosh reads MongoDB 9.0 as well.

**What MongoDB taught the pack:**

- **mongosh makes promises of the database calls, and awaits them where it can.** A call returned from inside `try` was awaited only after the function had returned, so a refusal slipped past the `catch`: the scripts assign each answer first, then return it.
- **`run` and `connect` are mongosh's own** (it has functions by those names): the pack's are `vigilRun` and `vigilConnect`.
- **A secondary at rest reads up to some 10 seconds behind**: the primary writes a no-op every 10 seconds, and the secondaries report it a moment later. Under load, with chaining on (the default), a secondary can also fetch from another secondary, and wait with it.
- **MongoDB aborts a transaction open longer than 60 seconds** by default, so `transactions_open` above 0 for long means a server set otherwise.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
