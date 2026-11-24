# The cockroachdb pack

CockroachDB, one node or a whole cluster, from its HTTP API. On every node, the pack reads the node's own metrics: whether it answers and is ready for SQL, its version, the nodes it sees live, its clock's offset from the others', the days left on its certificates, its CPU, memory and admission control; its ranges (unavailable, under-replicated, decommissioning) and the requests stuck on raft, leases or latches; its stores (how full, the LSM's level 0, write stalls, a slow disk, the write-ahead log's fsyncs); and the SQL it serves (connections, statements by kind, failures, full scans, transactions restarted, latency). For the cluster, from one node: every node's status (live, unavailable, dead, draining, decommissioning), the versions they run and an upgrade left unfinished; and the jobs (backups, schema changes, changefeeds): those failed and paused, the schedules paused or late, and how far behind the furthest changefeed is. Linux, macOS and Windows.

**It only reads.** A node's metrics (`/_status/vars`) and health need no login at all. The cluster's nodes and jobs are read as a user with three read-only system privileges, and the SQL the jobs send through CockroachDB's SQL API is `SELECT` and `SHOW`.

**curl and jq, or PowerShell alone.** On Linux and macOS each job reads the API with `curl` and `jq`; on Windows, with PowerShell alone: it speaks HTTP itself, over .NET's own TCP and TLS, so there is nothing to install, on Windows PowerShell 5.1 and PowerShell 7 alike. No SQL client either.

1. **A user with three read-only system privileges**, as an admin (`cockroach sql`), for the `cluster` and `jobs` jobs:

   ```sql
   CREATE USER vigil WITH PASSWORD '...';
   GRANT SYSTEM VIEWCLUSTERMETADATA, VIEWCLUSTERSETTING, VIEWJOB TO vigil;
   ```

   `VIEWCLUSTERMETADATA` lets it list the nodes, `VIEWCLUSTERSETTING` read the cluster's version, and `VIEWJOB` see every job, not only its own (without it, it sees none). Nothing more: it cannot read a table, or change anything.

2. `vigil pack enable cockroachdb`, then in `vigil.config` set the jobs' `COCKROACH_URL` (the node's HTTP port, the DB Console's: `https://db1.example.com:8080`) and, for a secure cluster, `COCKROACH_CACERT` (its CA file, `ca.crt` in the certs folder; on Windows too). The `cluster` and `jobs` jobs log in as `COCKROACH_USER` (`vigil` already), with the password as a secret:

   ```sh
   vigil secret set COCKROACH_PASSWORD
   ```

   The password reaches `curl` on its standard input (its config, `-K -`), and PowerShell in a request's body made in memory: never on a command line. Each run logs in, reads, and logs out, so no session is left open.

   **An insecure cluster** (`--insecure`) needs no user: `COCKROACH_URL=http://...`, `COCKROACH_USER=` (empty), and take the two `secret` lines out.

**A node or a cluster.** The `status`, `replication`, `storage` and `sql` jobs read the node at `COCKROACH_URL`, and only it: run them on every node, each pointed at its own (`https://localhost:8080`). A range is counted by the node that holds its lease, so each node reports its share, and the cluster's is the sum over every node. The `cluster` and `jobs` jobs read the whole cluster, through any node: on one machine, or on each (they answer the same), but alerting on one is enough.

**A wrong password fails the run, saying so** (HTTP 401), and so does a user without a privilege, naming the one to grant. A node that does not answer is a reading, `up 0`, and the run succeeds. A node that answers but is not ready (starting, draining, or cut off from a quorum) is `ready 0`.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq` | `curl`, `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or 7 |
| CockroachDB | 25.x or 26.x, secure or insecure; its HTTP port reachable from the Vigil machine | | |
| A user (`cluster`, `jobs`) | `VIEWCLUSTERMETADATA`, `VIEWCLUSTERSETTING`, `VIEWJOB` (system privileges) | | |
| A secret | `COCKROACH_PASSWORD`, but on an insecure cluster | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `cockroachdb_status` | Whether the node answers and is ready for SQL, its ID, version and uptime, the nodes it sees live, its liveness heartbeats that failed, its clock's offset from the others', the days left on each certificate, CPU, memory, goroutines and those waiting to run, admission control's CPU queue, file descriptors | minute |
| `cockroachdb_replication` | The node's ranges, replicas, leases and raft leaders; the ranges it leads that are unavailable, under-replicated, over-replicated or on a node being decommissioned; requests stuck on raft, a lease, latches or between nodes; the replicate queue; splits and merges | minute |
| `cockroachdb_storage` | The node's stores: their disks (size, free, used), CockroachDB's own data and the live part of it, the LSM's level 0 (sub-levels, files), read amplification, I/O overload and admission control's write queue, write stalls, a slow disk, the write-ahead log's fsyncs | minute |
| `cockroachdb_sql` | The SQL the node serves as a gateway: connections, statements and transactions open, SQL memory; running totals of connections, SELECTs, INSERTs, UPDATEs, DELETEs, schema changes, failures, full scans, commits, aborts, restarts, and the time statements and transactions took | minute |
| `cockroachdb_cluster` | The cluster's nodes: live, unavailable, dead, draining, decommissioning, decommissioned; the versions they run, the cluster's own version and an upgrade not finished or held back; each node's status, version, address and uptime, the worst first | minute |
| `cockroachdb_jobs` | The cluster's jobs: running, paused, failed, reverting, by type and status; each failed and paused job by ID and type, the worst first; the schedules (scheduled backups), paused and late; the changefeeds, and how far behind the furthest is | 5 minutes |

Past a limit (100 nodes; 20 failed and paused jobs), the worst first, and the rest counted in a `_not_shown` line. A job is named by its ID and type, never by its description, which may hold a statement or a storage URL with its credentials.

Running totals (`_count`, `_seconds`) restart when the node restarts: graph them as a rate. A mean latency is the rate of `statement_seconds` over the rate of `statements_count` (or `wal_fsync_seconds` over `wal_fsyncs_count`).

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `cockroachdb.up`.

```text
+--------------------------------------------------------------------------------------------------+
| cockroachdb_status   cockroachdb.<metric>   every 1m                                             |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when the node answers, else 0                                    |
| ready                       | 1 when it accepts SQL (/health?ready=1), else 0: 0 while it        |
|                             | starts, drains or cannot reach the cluster                         |
| node_id                     | its node ID                                                        |
| info                        | always 1, tagged version=<v26.4.1>                                 |
| uptime_seconds              | since it started                                                   |
| live_nodes                  | nodes this one sees live                                           |
| heartbeat_failures_count    | its liveness heartbeats that failed (a running total)              |
| clock_offset_ms             | its clock's mean offset from the other nodes'                      |
| clock_offset_stddev_ms      | how much that offset varies                                        |
| cpu_pct                     | CPU it uses, of every core                                         |
| rss_bytes                   | its resident memory                                                |
| goroutines                  | its goroutines                                                     |
| runnable_per_cpu            | goroutines waiting to run, a core: past 32 it is CPU bound         |
| cpu_queue                   | requests waiting for admission control's CPU slots                 |
| cpu_slots_exhausted_seconds | time they had to wait, every slot taken (a running total)          |
| fds_open                    | file descriptors it holds                                          |
| fds_pct                     | of those it may hold (the soft limit)                              |
| cert_days                   | days left on a certificate, tagged cert=<ca, node, client, ui...>: |
|                             | those it has                                                       |
| cert_days_min               | the fewest of those                                                |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  up 1 and ready 1 on every node; live_nodes the cluster's size; clock_offset_ms far below   |
|       the maximum (500 by default); cert_days_min above 30.                                      |
| WATCH live_nodes below the cluster's size; clock_offset_ms past 100; cert_days_min below 30;     |
|       runnable_per_cpu past 32; fds_pct past 80.                                                 |
| BAD   up 0 or ready 0 for more than a few minutes; clock_offset_ms near 400 (at 80% of the       |
|       maximum the node stops itself); cert_days_min below 7: a node with an expired certificate  |
|       cannot join; heartbeat_failures_count rising.                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cockroachdb_replication   cockroachdb.replication.<metric>   every 1m                            |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when the node answers, else 0                                       |
| ranges                   | ranges on its stores                                                  |
| replicas                 | replicas on its stores                                                |
| leaseholders             | of those, holding their range's lease                                 |
| raft_leaders             | of those, raft leaders                                                |
| leaders_not_leaseholders | raft leaders whose lease another store holds: more than a few, and    |
|                          | requests take a detour                                                |
| ranges_unavailable       | ranges it leads that lost a quorum                                    |
| ranges_underreplicated   | ranges it leads with too few replicas                                 |
| ranges_overreplicated    | ranges it leads with too many                                         |
| ranges_decommissioning   | ranges it leads with a replica on a node being decommissioned         |
| slow_raft                | requests stuck in raft for a long time                                |
| slow_lease               | requests stuck acquiring a lease                                      |
| slow_latch               | requests stuck acquiring latches                                      |
| slow_distsender          | requests stuck on their way to another node                           |
| replicate_queue_pending  | replicas waiting for the replicate queue                              |
| splits_count             | ranges split (a running total)                                        |
| merges_count             | ranges merged (a running total)                                       |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  ranges_unavailable 0, ranges_underreplicated 0, and every slow_ count 0, on every node.    |
| WATCH ranges_underreplicated above 0 for more than a few minutes after a node left (the cluster  |
|       replaces a dead node's replicas after 5 minutes, server.time_until_store_dead);            |
|       ranges_decommissioning not falling; replicate_queue_pending growing.                       |
| BAD   ranges_unavailable above 0: some data cannot be read or written until the lost nodes       |
|       return; slow_raft, slow_lease or slow_latch above 0 for more than a few minutes.           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cockroachdb_storage   cockroachdb.storage.<metric>   every 1m                                    |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when the node answers, else 0                                    |
| stores                      | its stores                                                         |
| disk_bytes                  | their disks' size                                                  |
| disk_free_bytes             | of those, free for CockroachDB                                     |
| disk_used_pct               | of those, used, by anything: a store stops taking writes when its  |
|                             | disk is nearly full                                                |
| used_bytes                  | CockroachDB's own data, every replica                              |
| live_bytes                  | of that, live keys and values                                      |
| l0_sublevels                | the most level-0 sub-levels a store has                            |
| l0_files                    | level-0 files, every store                                         |
| read_amp                    | the largest read amplification                                     |
| io_overload                 | the most overloaded store, 0 to 1 and past it: at 1 admission      |
|                             | control throttles its writes                                       |
| io_queue                    | writes waiting for admission control, every store                  |
| io_tokens_exhausted_seconds | time writes had to wait, the store out of tokens (a running total) |
| write_stalls_count          | writes stalled, the LSM too far behind (a running total)           |
| write_stall_seconds         | time they stalled (a running total)                                |
| disk_slow_count             | times a disk took too long to answer (a running total)             |
| wal_fsync_seconds           | time the write-ahead log's fsyncs took (a running total)           |
| wal_fsyncs_count            | those fsyncs (a running total): divide the rates for the mean      |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  disk_used_pct below 60; l0_sublevels below 10; io_overload below 0.5; write_stalls_count   |
|       and disk_slow_count flat.                                                                  |
| WATCH disk_used_pct past 70; l0_sublevels past 10 or read_amp past 20 for more than a few        |
|       minutes: compactions are behind; io_overload past 0.5; the mean fsync past 10 ms.          |
| BAD   disk_used_pct past 85; io_overload at 1 and above: writes are throttled;                   |
|       write_stalls_count or disk_slow_count rising: the disk cannot keep up, and a node with a   |
|       stalled disk stops itself.                                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cockroachdb_sql   cockroachdb.sql.<metric>   every 1m                                            |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the node answers, else 0                                            |
| connections         | client connections open                                                    |
| statements_active   | statements running now                                                     |
| transactions_open   | transactions open now                                                      |
| memory_bytes        | memory SQL statements hold now                                             |
| connections_count   | connections made (a running total)                                         |
| selects_count       | SELECTs run (a running total)                                              |
| inserts_count       | INSERTs run (a running total)                                              |
| updates_count       | UPDATEs run (a running total)                                              |
| deletes_count       | DELETEs run (a running total)                                              |
| ddl_count           | schema changes run (a running total)                                       |
| failures_count      | statements that failed (a running total)                                   |
| full_scans_count    | full table or index scans (a running total)                                |
| commits_count       | transactions committed (a running total)                                   |
| aborts_count        | transactions aborted (a running total)                                     |
| restarts_count      | transactions CockroachDB restarted, every reason (a running total)         |
| statement_seconds   | time statements took (a running total)                                     |
| statements_count    | statements timed (a running total): divide the rates for the mean          |
| transaction_seconds | time transactions took (a running total)                                   |
| transactions_count  | transactions timed (a running total)                                       |
+---------------------+----------------------------------------------------------------------------+
| GOOD  failures_count and restarts_count rising slowly, if at all, against the statements; the    |
|       mean statement latency steady.                                                             |
| WATCH restarts_count rising with the load: contention, transactions that touch the same rows;    |
|       full_scans_count rising: a query lacks an index; connections growing without end.          |
| BAD   failures_count rising fast; aborts_count rising with restarts_count; the mean statement    |
|       latency several times its usual.                                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cockroachdb_cluster   cockroachdb.cluster.<metric>   every 1m                                    |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the node answers, else 0                                            |
| nodes               | nodes, decommissioned ones left out                                        |
| live                | of those, live                                                             |
| dead                | dead                                                                       |
| unavailable         | not live, not yet dead                                                     |
| draining            | draining (a restart, or decommissioning)                                   |
| decommissioning     | being decommissioned                                                       |
| decommissioned      | decommissioned                                                             |
| versions            | versions the nodes run                                                     |
| version_info        | always 1, for each version, tagged version=<v26.4.1>                       |
| cluster_version     | always 1, tagged version=<26.4>: the cluster's                             |
| upgrade_pending     | 1 when the cluster's version is behind its oldest node's, else 0           |
| downgrade_preserved | 1 when cluster.preserve_downgrade_option is set, else 0: an upgrade waits  |
|                     | for it to be reset                                                         |
| node_status         | each node's: 3 live, 6 draining, 4 decommissioning, 2 unavailable, 1 dead, |
|                     | 0 unknown; tagged node=<id>, status=<live, dead...>, version=<v26.4.1> and |
|                     | address=<host:port>                                                        |
| node_uptime_seconds | since each node started, tagged node=<id>                                  |
| ..._not_shown       | past 100 of a list (nodes), how many were left out                         |
+---------------------+----------------------------------------------------------------------------+
| GOOD  live equal to nodes; dead and unavailable 0; versions 1; upgrade_pending 0.                |
| WATCH unavailable above 0 (a node restarting, or failing); draining above 0 for long;            |
|       decommissioning stuck; versions 2 for longer than a rolling upgrade takes.                 |
| BAD   dead above 0: its replicas are being moved, and another loss may take ranges with it; live |
|       below a majority of nodes; upgrade_pending 1 with downgrade_preserved 0 for long: the      |
|       upgrade did not finish.                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| cockroachdb_jobs   cockroachdb.jobs.<metric>   every 5m                                          |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when the node answers, else 0                                      |
| running                   | jobs running                                                         |
| paused                    | jobs paused                                                          |
| failed                    | jobs failed in the last 12 hours                                     |
| reverting                 | jobs rolling back a failure, or a cancel                             |
| jobs                      | jobs, by type and status, tagged type=<BACKUP, SCHEMA CHANGE...> and |
|                           | status=<running, paused, failed...>                                  |
| job_failed                | always 1, for each failed job, tagged id=<job ID> and type=<its      |
|                           | type>                                                                |
| job_paused_seconds        | how long each paused job has been paused, tagged id=<job ID> and     |
|                           | type=<its type>                                                      |
| schedules                 | schedules (scheduled backups, and CockroachDB's own)                 |
| schedules_paused          | of those, paused                                                     |
| schedules_late            | of those, active and more than an hour past their next run           |
| changefeeds               | changefeeds running                                                  |
| changefeed_behind_seconds | how far the furthest behind of those is from now: its high-water     |
|                           | mark's age, or, with none yet, its own                               |
| ..._not_shown             | past 100 of a list (jobs), how many were left out                    |
+---------------------------+----------------------------------------------------------------------+
| GOOD  failed 0; paused 0, or only jobs paused on purpose; schedules_late 0;                      |
|       changefeed_behind_seconds near its resolved interval.                                      |
| WATCH paused above 0 for long (a paused schema change blocks the next on its table);             |
|       schedules_paused above 0; reverting above 0.                                               |
| BAD   failed above 0 with type=BACKUP: the last backup did not run; schedules_late above 0;      |
|       changefeed_behind_seconds rising: its sink is down or slow, and the cluster keeps the      |
|       history it still has to send (protected timestamps), which grows.                          |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what a three-node cluster in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `cockroachdb.up`, `ready` | 1; 1 | | 0 for more than a few minutes: the node is down, or cut off | |

## How it was tested

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
