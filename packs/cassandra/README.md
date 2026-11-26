# The cassandra pack

Apache Cassandra, every node of a cluster, over JMX. For each node, the pack reads whether it answers, its version and mode (normal, or joining, leaving, draining, drained, decommissioned), whether gossip and the native protocol (CQL) are running, the nodes it sees up and down, the data it holds, exceptions, hints kept for nodes that were away, clients and the commit log; the requests it coordinates by kind, their latency, and those that timed out, found too few replicas (unavailable) or failed; its thread pools, tasks blocked and messages dropped; and its compactions, key cache, and for each of the application's tables, its SSTables, how many a read looks in, the tombstones a read scans, its space on disk and its largest partition. Linux, macOS and Windows.

Cassandra's trouble shows in its reads and writes long before it shows in an outage. A node down is not an outage: writes go on at QUORUM, and the node's share is kept as hints, until the hints outlive their window and repair is the only way back. Writes at a consistency level the live replicas cannot meet are refused at once. Tombstones from deletes and expired data pile up until a read has to scan thousands of them, and Cassandra fails it at 100,000. SSTables that compaction cannot keep up with make every read look in more of them. The pack reads each of these from the node's own MBeans.

**It only reads**, and needs nothing of Cassandra's on the Vigil machine: the pack reads JMX with the probe (`_probe.jar`, shared by every JMX pack, built by the release and checked against its digest before each run), on Java 11 or later, a JDK or a JRE. It reads attributes, and calls no operation.

1. **JMX the Vigil machine can reach.** Out of the box Cassandra listens for JMX on localhost only (`LOCAL_JMX=yes` in `cassandra-env.sh`), with no password. Either:

   - **run the pack on each node**, pointed at its own JMX, `localhost:7199`: nothing to change on the node; or
   - **open JMX with a password** to read the nodes from elsewhere: `LOCAL_JMX=no` in `cassandra-env.sh` (it turns authentication on, from `/etc/cassandra/jmxremote.password`), and a read-only user in that file. The JDK's own access file already makes `monitorRole` read-only:

     ```text
     monitorRole <a password>
     ```

     (the file readable by Cassandra's account alone: `chmod 400`). Then the pack logs in as `monitorRole`.

2. `vigil pack enable cassandra`, then in `vigil.config` set the jobs' `CASSANDRA_JMX`, the nodes, each with a name if you like:

   ```ini
   env = CASSANDRA_JMX=db1: jmx=localhost:7199
   ```

   (`jmxs=` for JMX over TLS, with `CASSANDRA_CACERT` when its CA is not one Java trusts). With a password: `CASSANDRA_JMX_USER=monitorRole`, a `secret` line on each job (`secret = CASSANDRA_JMX_PASSWORD=secret:CASSANDRA_JMX_PASSWORD`), then `vigil secret set CASSANDRA_JMX_PASSWORD`.

**A node that does not answer is a reading**, `jmx_up 0`, and the run succeeds. A wrong password fails the run, saying JMX refused the login. A jar that is not the one the scripts carry the digest of is not run.

Cassandra's JVM (heap, garbage collection, threads) is the **jvm** pack's, not this one's: install it beside, with each node named the same way.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | Java 11 or later (JDK or JRE) | Java 11 or later | Java 11 or later; PowerShell 5.1 or 7 |
| Cassandra | 4.1 or 5.0; its JMX reachable (localhost, or `LOCAL_JMX=no` with a password) | | |
| A user | none on localhost; `monitorRole` (read-only) with a password | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `cassandra_status` | Each node: JMX up, version, mode and normal or not, gossip and CQL running, nodes up and down, load, exceptions, hints written and in progress, clients, the commit log | minute |
| `cassandra_requests` | The requests each node coordinates, by kind (Read, Write, RangeSlice, CAS): how many, latency (99th percentile, mean), timeouts, unavailables, failures | minute |
| `cassandra_threads` | Each thread pool: tasks pending, active, blocked now and blocked so far; messages dropped, in all and by kind | minute |
| `cassandra_tables` | Compactions pending and done, bytes compacted, the key cache's hit rate; each application table (Cassandra's own keyspaces left out), the worst first: SSTables, compactions pending, SSTables per read and tombstones per read (99th percentile), space on disk, the largest partition | 5 minutes |

The 99th percentiles and means are Cassandra's own, over recent requests (its histograms decay): a figure with no request lately reads 0, and a mean with none is left out. Running totals (`_count`) restart when the node restarts: graph them as a rate.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `cassandra.version`.

```text
+--------------------------------------------------------------------------------------------------+
| cassandra_status   cassandra.<metric>   every 1m                                                 |
+-------------------+------------------------------------------------------------------------------+
| jmx_up            | 1 when JMX answers, else 0, tagged node=<its name> and jmx=<its address>     |
| version           | always 1, tagged version=<Cassandra's version, 5.0.9>                        |
| mode              | always 1, tagged mode=<NORMAL, JOINING, LEAVING, DRAINING, DRAINED,          |
|                   | DECOMMISSIONED>                                                              |
| normal            | 1 when the node is in normal operation, else 0                               |
| gossip_up         | 1 when gossip is running, else 0 (the node is cut off from the ring)         |
| native_up         | 1 when the native protocol (CQL) takes clients, else 0                       |
| nodes_up          | nodes this one sees up, itself included                                      |
| nodes_down        | nodes this one sees down                                                     |
| load_bytes        | the data this node holds on disk                                             |
| exceptions_count  | errors Cassandra caught (a running total)                                    |
| hints_count       | hints written for nodes that were down (a running total)                     |
| hints_in_progress | hints being sent now                                                         |
| clients           | CQL clients connected                                                        |
| commitlog_pending | commit log writes waiting                                                    |
| commitlog_bytes   | the commit log on disk                                                       |
+-------------------+------------------------------------------------------------------------------+
| GOOD  normal 1, gossip_up and native_up 1; nodes_down 0; hints_in_progress 0; exceptions_count   |
|       flat.                                                                                      |
| WATCH hints_count rising (a node was away: it is catching up); commitlog_pending above 0 for     |
|       several runs.                                                                              |
| BAD   the node down over JMX; normal 0 (draining, leaving, decommissioned); gossip_up or         |
|       native_up 0; nodes_down above 0: a node is down, and with it, requests at QUORUM may fail. |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cassandra_requests   cassandra.requests.<metric>   every 1m                                      |
+--------------------+-----------------------------------------------------------------------------+
| jmx_up             | 1 when JMX answers, else 0, tagged node=<its name> and jmx=<its address>    |
| requests_count     | requests coordinated (a running total), tagged scope=<Read, Write,          |
|                    | RangeSlice, ...> (the counts Cassandra keeps per consistency level,         |
|                    | Write-ALL and the like, left out)                                           |
| latency_p99_ms     | the 99th percentile of their latency, tagged the same                       |
| latency_mean_ms    | their mean latency, tagged the same                                         |
| timeouts_count     | requests that timed out waiting for replicas (a running total), tagged the  |
|                    | same                                                                        |
| unavailables_count | requests refused at once: too few replicas up for their consistency level   |
|                    | (a running total), tagged the same                                          |
| failures_count     | requests a replica failed (a running total), tagged the same                |
| ..._not_shown      | past 100 of a list (requests_count, latency_p99_ms, latency_mean_ms,        |
|                    | timeouts_count, unavailables_count, failures_count), how many were left out |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  latency_p99_ms steady; timeouts_count, unavailables_count and failures_count flat.         |
| WATCH latency_p99_ms rising run after run; timeouts_count rising now and then.                   |
| BAD   unavailables_count rising: replicas are down for the consistency level asked;              |
|       timeouts_count or failures_count rising fast.                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cassandra_threads   cassandra.threads.<metric>   every 1m                                        |
+---------------------+----------------------------------------------------------------------------+
| jmx_up              | 1 when JMX answers, else 0, tagged node=<its name> and jmx=<its address>   |
| pending             | tasks waiting in a pool, tagged scope=<ReadStage, MutationStage,           |
|                     | CompactionExecutor, ...>                                                   |
| active              | tasks at work, tagged the same                                             |
| blocked             | tasks blocked now (the pool is full), tagged the same                      |
| blocked_count       | tasks that were blocked (a running total), tagged the same                 |
| dropped_total_count | messages dropped, past their timeout, of every kind (a running total)      |
| dropped_count       | of those, each kind that dropped any, tagged scope=<MUTATION, READ, ...>   |
|                     | (some 90 kinds: those at 0 are left out)                                   |
| ..._not_shown       | past 100 of a list (pending, active, blocked, blocked_count,               |
|                     | dropped_total_count, dropped_count), how many were left out                |
+---------------------+----------------------------------------------------------------------------+
| GOOD  pending near 0; blocked 0; dropped_total_count flat.                                       |
| WATCH pending rising in ReadStage or MutationStage; CompactionExecutor pending growing.          |
| BAD   blocked above 0; dropped_total_count rising, dropped_count for MUTATION or READ above all: |
|       the node is overloaded, and writes are being lost to hints or reads to timeouts.           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cassandra_tables   cassandra.tables.<metric>   cron 3/5 * * * *                                  |
+---------------------------+----------------------------------------------------------------------+
| jmx_up                    | 1 when JMX answers, else 0, tagged node=<its name> and jmx=<its      |
|                           | address>                                                             |
| compactions_pending       | compactions waiting                                                  |
| compactions_done_count    | compactions done (a running total)                                   |
| compacted_bytes_count     | bytes compacted (a running total)                                    |
| key_cache_hit_pct         | reads that found their key in the key cache, of all                  |
| sstables                  | a table's SSTables, tagged keyspace=<its keyspace> and scope=<the    |
|                           | table>                                                               |
| table_compactions_pending | its compactions waiting, tagged the same                             |
| sstables_per_read_p99     | SSTables a read had to look in, the 99th percentile, tagged the same |
| tombstones_per_read_p99   | tombstones a read scanned, the 99th percentile, tagged the same      |
| disk_bytes                | its live data on disk, tagged the same                               |
| partition_max_bytes       | its largest partition, tagged the same                               |
| ..._not_shown             | past 100 of a list (sstables, table_compactions_pending,             |
|                           | sstables_per_read_p99, tombstones_per_read_p99, disk_bytes,          |
|                           | partition_max_bytes), how many were left out                         |
+---------------------------+----------------------------------------------------------------------+
| GOOD  compactions_pending near 0; sstables_per_read_p99 a few; tombstones_per_read_p99 low.      |
| WATCH compactions_pending rising run after run; sstables in the dozens for a table;              |
|       tombstones_per_read_p99 past 1,000 (Cassandra warns); partition_max_bytes past 100 MB.     |
| BAD   compactions_pending in the hundreds and growing; tombstones_per_read_p99 near 100,000      |
|       (Cassandra fails the read); partition_max_bytes past 1 GB.                                 |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what a three-node cluster in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `cassandra.jmx_up`, `normal` | 1; 1 | | 0: the node is down, or not in normal operation | 1 on every node; `normal 0`, `mode=DRAINED` for the node drained, its gossip and CQL stopped |
| `cassandra.nodes_down` | 0 | | Above 0: a node is down; QUORUM still works with one of three, ALL does not | 1 on c1 with c3 stopped (`nodes_up 2`) |
| `cassandra.hints_count` | Flat | Rising: a node was away | Rising for longer than `max_hint_window` (3 h): repair will be needed | 3 for the writes that timed out on a paused replica; 23 with c3 stopped |
| `cassandra.requests.unavailables_count` | Flat | | Rising: too few replicas up for the consistency level asked | 3: writes at ALL with c3 stopped, refused at once |
| `cassandra.requests.timeouts_count` | Flat | Rising now and then | Rising fast: replicas too slow or gone | 3: writes at ALL with c2 paused (`WriteTimeout`) |
| `cassandra.requests.latency_p99_ms` | Steady | Rising run after run | | 11.86 ms for reads; past 2,000 ms for writes while a replica was paused |
| `cassandra.threads.blocked`, `dropped_total_count` | 0; flat | | `blocked` above 0, or drops rising: the node is overloaded | 0; 0 |
| `cassandra.tables.sstables_per_read_p99` | A few | Past 10 | Rising, with `compactions_pending` | 8: a partition written in 8 rounds, each flushed to its own SSTable, autocompaction off |
| `cassandra.tables.tombstones_per_read_p99` | Low | Past 1,000 (Cassandra warns) | Near 100,000 (Cassandra fails the read) | 3,311: a partition of 3,000 cells, expired |
| `cassandra.tables.compactions_pending` | Near 0 | Rising run after run | In the hundreds | 0 |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-26 by `tests/integration/backends/scripts/run-cassandra.sh`, against `compose.cassandra.yaml`: **Cassandra 5.0.9, a cluster of three**, and **Cassandra 4.1.12, one node**, each with JMX open to other hosts and a password (`LOCAL_JMX=no`), read as `monitorRole`. With `cqlsh` and `nodetool`: a keyspace of three replicas; 400 partitions, a row added to each in 8 rounds, each flushed, autocompaction off on every node; a partition of 3,000 cells that expired a second after they were written, read five times; writes at `CONSISTENCY ALL` with a replica paused. The passwords were made by the run and kept out of the evidence.

- **On Fedora 44** (bash 5.3, Java 25; the jar built with JDK 21): every job against c1 and 4.1, each reading checked; a wrong password (refused, the run failing), nothing listening (`jmx_up 0`), a jar that does not match its digest (not run). Then `service-packs.sh` through Vigil. Then c3 stopped (a node down, writes at ALL unavailable, hints written for it), and c2 drained: **24 passed, 0 failed**, and through Vigil **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/fedora/pack-cassandra/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, with Java 21, the pack's Windows archive as the release builds it, against the same nodes held up for it, through SSH tunnels: every job under Windows PowerShell 5.1 and PowerShell 7, the same metric names and tags as the Linux scripts against the same nodes, and the same values where they hold still; a wrong password refused; through Vigil, **18 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/windows/pack-cassandra-windows/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, Java 21), the macOS archive, the same way: **10 passed, 0 failed**; through Vigil, **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/macos/pack-cassandra-macos/console.txt)).

**What Cassandra taught the pack, and the probe:**

- **Cassandra refuses a wrong JMX password as a `FailedLoginException`**, not the `SecurityException` the JDK's own agent throws. The probe took it for a node that does not answer, and the run succeeded. It now knows both, and fails the run, saying the login was refused: a new version of every pack that carries the probe.
- **Cassandra reads the newest SSTable first, and stops once it has the whole row.** A row rewritten in eight SSTables is read from one: SSTables per read rises when a partition's rows are spread over many, as a partition written to over time is.
- **Its histograms decay.** A 99th percentile reads 0, and a mean is left out, when there were no such requests in the last minutes: a quiet node is not a fast one.
- **Since 4.1, every request kind is counted again per consistency level** (`Write-ALL`, `Read-QUORUM`, ...): some 80 lines a node, left out; the totals per kind are kept.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
