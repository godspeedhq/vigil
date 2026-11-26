# The clickhouse pack

ClickHouse, one server or a replicated cluster, from its HTTP interface. On each server, the pack reads whether it answers, its version and uptime, the queries running and its connections, its memory against its limit, and the inserts delayed and refused for too many parts; its tables' parts, partitions, rows and bytes, the worst first; its replicated tables, read-only, behind, their queues and the replicas missing; its mutations, those that fail and those that wait; its merges; the parts it detached, broken ones apart; its disks; and the queries running long, and the errors it has counted, by name. Linux, macOS and Windows.

The trouble ClickHouse is known for is quiet until it is loud. Inserts too small or too frequent leave more parts than merges can join, and past a limit (3,000 parts in a partition by default) ClickHouse refuses every insert into it: `Too many parts`. A replicated table that loses its session with Keeper goes read-only, and its writes fail. A mutation (`ALTER TABLE ... UPDATE`) that fails on one row tries again forever, and those after it wait behind it. Each of these is in the system tables long before it reaches an application: the pack reads them.

**It only reads.** Every statement is a `SELECT` from the system tables, as a user the server itself keeps read-only (`readonly = 1`): ClickHouse refuses anything else from it, whatever the pack sent.

**curl and jq, or PowerShell alone.** On Linux and macOS each job reads ClickHouse's HTTP interface with `curl` and `jq`; on Windows, with PowerShell alone: it speaks HTTP itself, over .NET's own TCP and TLS, so there is nothing to install, on Windows PowerShell 5.1 and PowerShell 7 alike. No ClickHouse client either.

1. **A read-only user**, as an admin, on every server the pack reads (or `ON CLUSTER` once):

   ```sql
   CREATE USER vigil IDENTIFIED WITH sha256_password BY '...' SETTINGS readonly = 1;
   GRANT SELECT ON system.*, SHOW TABLES ON *.* TO vigil;
   ```

   `SELECT ON system.*` lets it read the system tables. **`SHOW TABLES ON *.*` is needed too**: without it, ClickHouse leaves out of `system.parts`, `system.replicas`, `system.mutations` and `system.detached_parts` every table the user may not see, and the pack reads a server with no tables but its own logs, and says nothing wrong. `SHOW TABLES` lets it see that a table is there, never read a row of it.

2. `vigil pack enable clickhouse`, then in `vigil.config` set the jobs' `CLICKHOUSE_URL`, the server's HTTP interface (`http://db1.example.com:8123`, or `https://...:8443`), and over HTTPS with a CA of your own, `CLICKHOUSE_CACERT` (its file). The jobs log in as `CLICKHOUSE_USER` (`vigil` already), with the password as a secret:

   ```sh
   vigil secret set CLICKHOUSE_PASSWORD
   ```

   The user and password reach `curl` on its standard input (its config, `-K -`), as ClickHouse's `X-ClickHouse-User` and `X-ClickHouse-Key` headers, and PowerShell in a request made in memory: never on a command line, never in a URL.

**A server or a cluster.** Every job reads the server at `CLICKHOUSE_URL`, and only it: run the pack on every server, each pointed at its own (`http://localhost:8123`). A replicated table is read by each of its replicas, each from where it stands: one behind is seen by itself.

**A wrong password fails the run, saying so**, and so does a user with no grant, naming the one to give. A server that does not answer is a reading, `up 0`, and the run succeeds.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq` | `curl`, `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or 7 |
| ClickHouse | 25.x or 26.x, one server or replicated (Keeper or ZooKeeper); its HTTP interface reachable from the Vigil machine | | |
| A user | `readonly = 1`; `SELECT ON system.*`, `SHOW TABLES ON *.*` | | |
| A secret | `CLICKHOUSE_PASSWORD` | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `clickhouse_status` | Whether the server answers, its version and uptime, the queries running, its connections by kind, its memory and its limit, the most parts in one partition against the limit that refuses inserts, inserts delayed and refused, queries run and failed (all, SELECTs, inserts), its sessions with Keeper, replicated tables read-only, the furthest behind and their queues | minute |
| `clickhouse_tables` | Its tables: how many, their parts, rows and bytes; each table's parts, partitions, most parts in a partition, rows and bytes, the most parts first | 5 minutes |
| `clickhouse_replication` | Its replicated tables: how many, read-only, replicas missing, queue tasks failing; each table's read-only flag, how far behind, its queue (inserts, merges, failing, the oldest), the shared log not yet read, its replicas and those active, the worst first | minute |
| `clickhouse_merges` | The mutations not done: how many, failing, the oldest; each by table and ID, the failing first; the merges at work, mutations among them, the longest, their memory; the parts detached, by reason | 5 minutes |
| `clickhouse_disks` | Its disks: free, total, how full, the space kept free; the fullest | 5 minutes |
| `clickhouse_queries` | The queries running: how many, those past a minute, the longest, the most memory one holds; the five longest by user, kind and query ID; the errors it has counted since it started, by name | minute |

Past a limit (`CLICKHOUSE_MOST`, 50 tables or replicated tables; 20 mutations; 20 errors), the worst first, and the rest counted in a `_not_shown` line. A query is named by its user, kind and ID, never by its text, which may hold data or a password.

Running totals (`_count`) restart when the server restarts: graph them as a rate.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `clickhouse.up`.

```text
+--------------------------------------------------------------------------------------------------+
| clickhouse_status   clickhouse.<metric>   every 1m                                               |
+------------------------+-------------------------------------------------------------------------+
| up                     | 1 when the server answers, else 0                                       |
| info                   | always 1, tagged version=<25.8.2.29>                                    |
| uptime_seconds         | since it started                                                        |
| queries                | queries running now                                                     |
| connections            | connections open, tagged kind=<tcp, http, mysql, postgresql,            |
|                        | interserver>                                                            |
| memory_bytes           | memory it holds, as it counts it                                        |
| memory_limit_bytes     | the most it may hold (max_server_memory_usage, or its share of the      |
|                        | machine's memory)                                                       |
| memory_pct             | memory_bytes, of memory_limit_bytes                                     |
| max_parts_in_partition | the most active parts any one partition has                             |
| parts_to_throw_insert  | the count where inserts into a partition are refused (Too many parts),  |
|                        | by default                                                              |
| parts_pct              | max_parts_in_partition, of parts_to_throw_insert                        |
| inserts_delayed        | inserts being slowed down now, for too many parts                       |
| inserts_delayed_count  | inserts slowed down (a running total)                                   |
| inserts_rejected_count | inserts refused for too many parts (a running total)                    |
| queries_count          | queries run (a running total)                                           |
| failed_queries_count   | queries that failed (a running total), tagged kind=<all, select,        |
|                        | insert>                                                                 |
| keeper_sessions        | sessions open with Keeper or ZooKeeper (0 without replicated tables).   |
|                        | With Keeper gone it stays 1 while the server retries: readonly_replicas |
|                        | is what says so                                                         |
| readonly_replicas      | replicated tables gone read-only: cut off from Keeper                   |
| replica_delay_seconds  | how far the furthest-behind replicated table is                         |
| replica_queue          | tasks waiting in the replicated tables' queues                          |
+------------------------+-------------------------------------------------------------------------+
| GOOD  up 1; memory_pct below 80; parts_pct below 10 (a few dozen parts a partition);             |
|       inserts_rejected_count flat; readonly_replicas 0; replica_delay_seconds a few seconds.     |
| WATCH memory_pct past 80; parts_pct past 20, or rising run after run (inserts too small or too   |
|       frequent: merges cannot keep up); inserts_delayed above 0; failed_queries_count rising     |
|       faster than usual.                                                                         |
| BAD   up 0; memory_pct past 90 (queries are refused for memory); inserts_rejected_count rising   |
|       (Too many parts: inserts fail); readonly_replicas above 0 (replicated tables take no       |
|       writes); replica_delay_seconds past 300.                                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| clickhouse_tables   clickhouse.tables.<metric>   every 5m                                        |
+------------------+-------------------------------------------------------------------------------+
| up               | 1 when the server answers, else 0                                             |
| tables           | MergeTree tables with data                                                    |
| parts            | active parts, every table's together                                          |
| rows             | rows, every table's together                                                  |
| bytes            | bytes on disk, every table's together                                         |
| table_parts      | a table's active parts, tagged table=<database.table>                         |
| table_partitions | its partitions                                                                |
| table_max_parts  | the most parts one of its partitions has                                      |
| table_rows       | its rows                                                                      |
| table_bytes      | its bytes on disk                                                             |
| ..._not_shown    | past 100 of a list (tables), how many were left out                           |
+------------------+-------------------------------------------------------------------------------+
| GOOD  table_max_parts a few dozen at most; table_parts steady.                                   |
| WATCH table_max_parts past 300, or rising run after run: inserts too small or too frequent for   |
|       merges to keep up (batch them, or use async inserts); a table's bytes growing faster than  |
|       usual.                                                                                     |
| BAD   table_max_parts near parts_to_throw_insert (the status job says the limit, 3000 by         |
|       default): inserts into it are about to be refused.                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| clickhouse_replication   clickhouse.replication.<metric>   every 1m                              |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when the server answers, else 0                                   |
| replicated                 | replicated tables on this server                                    |
| readonly                   | of those, how many are read-only                                    |
| replicas_missing           | replicas that are not active, every table's together                |
| queue_failing              | tasks tried and failed several times, every table's together        |
| table_readonly             | 1 when the table is read-only, else 0, tagged                       |
|                            | table=<database.table>                                              |
| table_delay_seconds        | how far this replica is behind                                      |
| table_queue                | tasks in its queue                                                  |
| table_queue_inserts        | of those, parts to fetch                                            |
| table_queue_merges         | of those, merges to do                                              |
| table_queue_failing        | of those, tasks tried and failed several times                      |
| table_queue_oldest_seconds | the oldest task's age                                               |
| table_log_behind           | entries of the shared log this replica has not read yet             |
| table_replicas_active      | the table's replicas active                                         |
| table_replicas             | the table's replicas                                                |
| ..._not_shown              | past 100 of a list (replicated), how many were left out             |
+----------------------------+---------------------------------------------------------------------+
| GOOD  readonly 0; replicas_missing 0; table_delay_seconds a few seconds; table_queue small and   |
|       falling; queue_failing 0.                                                                  |
| WATCH table_delay_seconds past 60; table_queue rising run after run; table_queue_oldest_seconds  |
|       past 600.                                                                                  |
| BAD   readonly above 0 (writes to the table fail: the session with Keeper is lost);              |
|       replicas_missing above 0 (a replica is down); queue_failing above 0 and not falling (a     |
|       task fails again and again: system.replication_queue's last_exception says why);           |
|       table_delay_seconds past 300.                                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| clickhouse_merges   clickhouse.merges.<metric>   every 5m                                        |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when the server answers, else 0                                     |
| mutations                | mutations not finished                                                |
| mutations_failing        | of those, how many fail                                               |
| mutations_oldest_seconds | the oldest one's age                                                  |
| mutation_seconds         | a mutation's age, tagged table=<database.table> and id=<mutation_id>  |
| mutation_parts_to_do     | the parts it has still to change                                      |
| mutation_failing         | 1 when it fails, else 0                                               |
| merges                   | merges running now                                                    |
| merges_mutating          | of those, mutations at work                                           |
| merge_longest_seconds    | the longest-running one                                               |
| merges_memory_bytes      | memory they hold                                                      |
| detached_parts           | parts detached, tagged reason=<broken, unexpected, ignored, clone,    |
|                          | manual...>; broken counts every broken one (found so at start, from a |
|                          | backup)                                                               |
| ..._not_shown            | past 100 of a list (mutations), how many were left out                |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  mutations 0, or each finishing within minutes; mutations_failing 0; detached_parts 0 but   |
|       reason=manual.                                                                             |
| WATCH mutations_oldest_seconds past an hour on a small table; merge_longest_seconds past an      |
|       hour; merges_memory_bytes a large share of the server's memory.                            |
| BAD   mutations_failing above 0: it will never finish, and those after it wait                   |
|       (system.mutations' latest_fail_reason says why; KILL MUTATION ends it); detached_parts     |
|       reason=broken or unexpected above 0: data the table no longer reads.                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| clickhouse_disks   clickhouse.disks.<metric>   every 5m                                          |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when the server answers, else 0                                              |
| disks           | disks ClickHouse uses                                                          |
| free_bytes      | a disk's free space, tagged disk=<name>                                        |
| total_bytes     | its size                                                                       |
| used_pct        | how much of it is used                                                         |
| keep_free_bytes | the space ClickHouse keeps free on it                                          |
| used_pct_max    | the fullest disk's used_pct                                                    |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  used_pct_max below 70, room for the largest merge.                                         |
| WATCH used_pct_max past 80: merges of large parts may not find room.                             |
| BAD   used_pct_max past 90: merges stop, parts pile up, then inserts fail.                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| clickhouse_queries   clickhouse.queries.<metric>   every 1m                                      |
+------------------+-------------------------------------------------------------------------------+
| up               | 1 when the server answers, else 0                                             |
| running          | queries running now, but this job's own                                       |
| slow             | of those, how many have run longer than a minute                              |
| longest_seconds  | the longest-running one's time                                                |
| memory_max_bytes | the most memory one holds                                                     |
| query_seconds    | one of the five longest, tagged user=<user>, kind=<Select, Insert...> and     |
|                  | id=<query_id>                                                                 |
| errors_count     | an error's count since the server started (a running total), tagged name=<its |
|                  | name>                                                                         |
| ..._not_shown    | past 100 of a list (errors), how many were left out                           |
+------------------+-------------------------------------------------------------------------------+
| GOOD  slow 0 for an interactive server; errors_count flat, but the usual few (UNKNOWN_TABLE from |
|       a typo, and the like).                                                                     |
| WATCH slow above 0 on two runs in a row; longest_seconds past what the workload allows;          |
|       memory_max_bytes a large share of the server's limit.                                      |
| BAD   errors_count rising for TOO_MANY_PARTS, MEMORY_LIMIT_EXCEEDED or KEEPER_EXCEPTION (inserts |
|       refused, queries killed, Keeper lost); a query running for hours that nobody expects (KILL |
|       QUERY WHERE query_id = '...').                                                             |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what a two-replica cluster in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `clickhouse.up` | 1 | | 0 for more than a few minutes: the server is down | 1; `up 0` with 25.8 stopped, from every job, each run succeeding |
| `clickhouse.memory_pct` | Below 80 | Past 80 | Past 90: queries are refused for memory | 22.84 of a 1 GB container (the limit read as 90% of its cgroup, 966,367,641 bytes) |
| `clickhouse.parts_pct`, `max_parts_in_partition` | Below 10: a few dozen parts | Past 20, or rising run after run | Near 100: inserts about to be refused | 19 parts, in `app.tiny`, its merges stopped (0.63% of the server's default 3,000: the table's own limit was 20) |
| `clickhouse.inserts_delayed_count`, `inserts_rejected_count` | Flat | `inserts_delayed_count` rising | `inserts_rejected_count` rising: inserts fail with `Too many parts` | 10 delayed and 5 refused, of 25 one-row inserts: exactly the 5 the server refused |
| `clickhouse.readonly_replicas`, `clickhouse.replication.readonly` | 0 | | Above 0: the table takes no writes, its session with Keeper lost | 1 within seconds of Keeper stopping (`table_readonly 1 table=app.events`), 0 again when it came back. `keeper_sessions` stayed 1 meanwhile: the server keeps its session while it retries |
| `clickhouse.replication.replicas_missing` | 0 | | Above 0: a replica is down | 1 with ch2 stopped (`table_replicas_active 1`, of 2), 0 when it came back |
| `clickhouse.replication.table_delay_seconds`, `table_queue` | A few seconds; small and falling | Past 60; rising run after run | Past 300 | ch2 with its fetches stopped: 62 s behind, 6 tasks waiting (the 5 inserts, and a merge); 0 once fetches started |
| `clickhouse.merges.mutations_failing` | 0 | | Above 0: it never finishes, and those after it wait | 1 (`mutation_failing 1 table=app.m id=mutation_2.txt`, `throwIf` on every row), 58 s old and tried again all along |
| `clickhouse.merges.detached_parts` | 0, but `reason=manual` | | `reason=broken` or `unexpected` above 0: data the table no longer reads | `reason=manual 1`, a part detached by hand; on 25.8, `reason=broken 1` for a part damaged while it was stopped (ClickHouse's own reason: `broken-on-start`) |
| `clickhouse.disks.used_pct_max` | Below 70 | Past 80 | Past 90: merges stop, then inserts fail | 8.77 |
| `clickhouse.queries.slow`, `longest_seconds` | 0 | Above 0 on two runs in a row | A query running for hours nobody expects | `slow 1`, 65.38 s (`query_seconds 65.38 user=default kind=Select id=vigil-it-slow`); the job's own SELECT not counted |
| `clickhouse.queries.errors_count` | Flat, the usual few | | `TOO_MANY_PARTS`, `MEMORY_LIMIT_EXCEEDED`, `KEEPER_EXCEPTION` rising | `FUNCTION_THROW_IF_VALUE_IS_NON_ZERO` 15 (the mutation, again and again), `TOO_MANY_PARTS` 5, `UNKNOWN_TABLE` 3 |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-26 by `tests/integration/backends/scripts/run-clickhouse.sh`, against `compose.clickhouse.yaml`: **ClickHouse 26.8.47.5, two replicas of one shard with ClickHouse Keeper**, and **ClickHouse 25.8.33.6, one server**, each in a container of 1 GB. As the admin, on each: the read-only user the pack asks for (`vigil`); on ch1 a user with no grant, and one with `SELECT ON system.*` alone. In 26.8: a replicated table; a table whose limits were low (10 parts delay an insert, 20 refuse it) with its merges stopped, then 25 inserts of one row each; a part of it detached by hand; a mutation that fails on every row (`throwIf`); three `SELECT`s from a table that is not there; a query running for minutes (`sleepEachRow`); ch2's fetches stopped while ch1 took five inserts. The passwords were made by the run and kept out of the evidence.

- **On Linux** (a Linux test host, Alpine Linux 3.24, bash 5.3, curl 8.23, jq): every job as `vigil` against ch1, ch2 and 25.8, each reading checked; `vigil` refused a write by the server itself; a wrong password and the user with no grant failing, saying why; the user without `SHOW TABLES` seeing no table of the application's; nothing listening read as `up 0`. Then `service-packs.sh` through Vigil. Then ch2 stopped (a replica missing) and came back; Keeper stopped (the replicated table read-only within seconds) and came back; a part of 25.8's truncated while it was stopped (detached as broken when it started); 25.8 stopped, every job `up 0` and succeeding: **60 passed, 0 failed**, and through Vigil **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/linux-it/pack-clickhouse/console.txt)).
- **On Windows**, on Windows 11 as an account that is not an administrator, against the same cluster held up for it: every job under Windows PowerShell 5.1 and PowerShell 7 printed the same metric names and tags as the Linux scripts against ch1 and 25.8, and the same values wherever they hold still between two reads (24 of 24); a wrong password and nothing listening as on Linux; through Vigil, **17 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/windows/pack-clickhouse-windows/console.txt)).
- **On macOS**: not yet. Its scripts are the Linux ones, with `curl` and `jq`.

**What ClickHouse taught the pack:**

- **A user sees only the tables it may see**, in the system tables too. With `SELECT ON system.*` alone, `system.parts`, `system.replicas`, `system.mutations` and `system.detached_parts` left out every table of the application's, and the jobs read a healthy server with nothing in it. `SHOW TABLES ON *.*` shows them, and reads no row.
- **A part damaged at start is `broken-on-start`**, not `broken`: the pack counts every reason that begins with `broken` as `reason=broken`, so one alert covers them.
- **With Keeper gone, the server keeps its session** while it retries: `keeper_sessions` stayed 1. `readonly_replicas` and the replication job's `readonly` said it, within seconds.
- **`log_pointer` is one past the last entry read**: a replica up to date is 0 behind, not -1.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
