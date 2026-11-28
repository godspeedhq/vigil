# The etcd pack

An etcd member, from what it says about itself on its metrics listener. The pack reads whether it is healthy and, when it is not, whether its cluster has lost its leader or raised an alarm; whether it has a leader, is the leader, or is a learner; how often the leader has changed; the members of its cluster and those it cannot reach; the proposals it committed and applied, those waiting and those that failed. Its database against its quota and the space a defragmentation would give back; its keys, revisions and compaction; watchers and leases. How fast its disk is where etcd needs it: the WAL's fsyncs and the backend's commits. And the gRPC requests it answered and those that failed, by code.

etcd is small, and everything stands on it: Kubernetes keeps its whole state there. Its trouble is quiet until it is total. A slow disk shows first as missed heartbeats and elections; a cluster that loses two members of three has no leader and takes no writes, though the last member still answers; a database that reaches its quota raises NOSPACE and refuses every write until someone compacts, defragments and disarms it. Each of these is on its metrics page, and the pack reads it from each member.

**Read-only: every request is a GET.** The pack reads etcd's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Give etcd a plain metrics listener, if it has none: `--listen-metrics-urls=http://127.0.0.1:2381`. Its client port serves `/metrics` too, but there clients usually need a certificate. kubeadm's etcd has the listener already, on `127.0.0.1:2381`.
2. `vigil pack enable etcd` on each member's machine, and, where the listener is elsewhere, set `ETCD_URL` in the jobs' `env` lines. Each member reports itself, and its view of the cluster.

**Etcd that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| Etcd | etcd 3.5 and 3.6, a member of a cluster or one alone (tested: a 3.6.17 cluster of three, and 3.5.36), from its metrics listener (--listen-metrics-urls) | | |
| Its address | reachable from the Vigil machine: `ETCD_URL` (default `http://localhost:2381`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `etcd_status` | Healthy; version and cluster version; a leader, this member the leader or a learner; leader changes; members, and those it cannot reach; heartbeats and peer messages that failed; proposals committed, applied, waiting and failed; slow applies; reads that failed or were slow; health checks that failed | minute |
| `etcd_database` | The database against its quota; space in use and fragmented; keys; the revision and how far past the last compaction; how long since a compaction; puts, deletes, reads and transactions; watchers and slow watchers; leases granted and expired; a defragmentation running | 5 minutes |
| `etcd_disk` | The WAL's fsyncs and the backend's commits: on average, and those that were slow; bytes written to the WAL; the round trip to its peers | minute |
| `etcd_requests` | gRPC requests handled, and those that failed, for each code; bytes to and from clients | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `etcd.up`.

```text
+--------------------------------------------------------------------------------------------------+
| etcd_status   etcd.<metric>   every 1m                                                           |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when etcd answered its metrics page, else 0 (and nothing more is   |
|                           | read)                                                                |
| healthy                   | 1 when /health answers 200, else 0: no leader, or an alarm (NOSPACE  |
|                           | when the database is at its quota; etcdctl alarm list says which)    |
| version                   | always 1, tagged version=<its version>                               |
| cluster_version           | always 1, tagged version=<the cluster's version>                     |
| has_leader                | 1 when the cluster has a leader, 0 when it has none: quorum is lost, |
|                           | and no write succeeds                                                |
| is_leader                 | 1 when this member is the leader                                     |
| is_learner                | 1 when this member is a learner, not yet voting                      |
| leader_changes_count      | leader changes this member has seen (a running total)                |
| members                   | members of its cluster, itself counted                               |
| peers_active              | other members it is connected to                                     |
| peers_unreachable         | other members it is not connected to                                 |
| heartbeat_failures_count  | heartbeats the leader failed to send (a running total)               |
| peer_send_failures_count  | messages to peers that failed (a running total)                      |
| proposals_committed_count | proposals committed (a running total)                                |
| proposals_applied_count   | proposals applied (a running total)                                  |
| apply_backlog             | committed and not yet applied                                        |
| proposals_pending         | proposals waiting to be committed                                    |
| proposals_failed_count    | proposals that failed: no leader, or a timeout (a running total)     |
| slow_applies_count        | applies that took over 100 ms (a running total)                      |
| read_indexes_failed_count | linearizable reads that failed (a running total)                     |
| slow_read_indexes_count   | linearizable reads that were slow (a running total)                  |
| health_failures_count     | health checks that failed (a running total)                          |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; healthy 1; has_leader 1; peers_unreachable 0; proposals_failed_count and             |
|       leader_changes_count not moving.                                                           |
| WATCH leader_changes_count moving: elections, from a slow disk or network (the disk job), or     |
|       members restarting; apply_backlog or proposals_pending growing; slow_applies_count moving. |
| BAD   has_leader 0: quorum is lost, nothing can be written; healthy 0 with has_leader 1: an      |
|       alarm (NOSPACE: the database job, then compact, defragment and etcdctl alarm disarm);      |
|       peers_unreachable above 0: a member is down or cut off, and one more lost may cost quorum; |
|       proposals_failed_count moving.                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| etcd_database   etcd.database.<metric>   every 5m                                                |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when etcd answered its metrics page, else 0 (and nothing more is     |
|                         | read)                                                                  |
| db_bytes                | the database file's size                                               |
| quota_bytes             | its quota (--quota-backend-bytes; 2 GiB by default)                    |
| db_used_pct             | the file, as a percent of the quota: near 100, the NOSPACE alarm       |
|                         | (raised when a write would pass the quota)                             |
| db_in_use_bytes         | of the file, the space in use                                          |
| fragmented_bytes        | the space a defragmentation would give back                            |
| keys                    | keys                                                                   |
| revision                | the current revision                                                   |
| compacted_revision      | the revision compacted to                                              |
| revisions_kept          | revisions kept since the last compaction: history that fills the       |
|                         | database                                                               |
| last_compaction_seconds | seconds since the last compaction (none since this member started:     |
|                         | nothing)                                                               |
| puts_count              | puts (a running total)                                                 |
| deletes_count           | deletes (a running total)                                              |
| ranges_count            | reads (a running total)                                                |
| txns_count              | transactions (a running total)                                         |
| watchers                | watchers                                                               |
| watch_streams           | watch streams                                                          |
| slow_watchers           | watchers behind the events they watch                                  |
| leases_granted_count    | leases granted (a running total)                                       |
| leases_expired_count    | leases that expired (a running total)                                  |
| defrag_running          | 1 while a defragmentation runs: the member answers nothing meanwhile   |
+-------------------------+------------------------------------------------------------------------+
| GOOD  db_used_pct well below 80; revisions_kept steady (compaction runs); slow_watchers 0.       |
| WATCH db_used_pct above 80; fragmented_bytes a large share of db_bytes: a defragmentation would  |
|       give it back; revisions_kept growing: nothing compacts (Kubernetes compacts every 5        |
|       minutes).                                                                                  |
| BAD   db_used_pct near 100: at the quota, etcd raises NOSPACE and takes no writes until it is    |
|       compacted, defragmented and the alarm disarmed; slow_watchers above 0 for long.            |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| etcd_disk   etcd.disk.<metric>   every 1m                                                        |
+----------------------------+---------------------------------------------------------------------+
| up                         | 1 when etcd answered its metrics page, else 0 (and nothing more is  |
|                            | read)                                                               |
| wal_fsyncs_count           | WAL fsyncs (a running total)                                        |
| wal_fsync_avg_ms           | their average, in milliseconds, since the member started            |
| wal_fsyncs_slow_count      | of them, over 16 ms (a running total): etcd wants most under 10     |
| backend_commits_count      | backend commits (a running total)                                   |
| backend_commit_avg_ms      | their average, in milliseconds                                      |
| backend_commits_slow_count | of them, over 32 ms (a running total): etcd wants most under 25     |
| wal_written_bytes_count    | bytes written to the WAL (a running total)                          |
| peer_rtt_avg_ms            | the round trip to its peers, on average, in milliseconds (none      |
|                            | alone)                                                              |
+----------------------------+---------------------------------------------------------------------+
| GOOD  wal_fsyncs_slow_count and backend_commits_slow_count rising slowly, if at all, against     |
|       their totals.                                                                              |
| WATCH wal_fsync_avg_ms above 10 or backend_commit_avg_ms above 25; the slow counts rising with   |
|       the totals.                                                                                |
| BAD   the slow counts rising fast with leader changes (the status job): the disk is too slow for |
|       etcd. Give it an SSD of its own; peer_rtt_avg_ms above 50: the network between members.    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| etcd_requests   etcd.requests.<metric>   every 1m                                                |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when etcd answered its metrics page, else 0 (and nothing more is |
|                             | read)                                                              |
| requests_count              | requests handled (a running total)                                 |
| failed_count                | of them, failed (a running total)                                  |
| failed                      | the same, for each gRPC code, tagged code=<Unavailable,            |
|                             | DeadlineExceeded, ResourceExhausted, PermissionDenied,             |
|                             | Unauthenticated ...>                                               |
| requests_started_count      | requests started (a running total)                                 |
| client_received_bytes_count | bytes from clients (a running total)                               |
| client_sent_bytes_count     | bytes to clients (a running total)                                 |
| ..._not_shown               | past 100 of a list (failed), how many were left out                |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  failed_count rising slowly, if at all, against requests_count.                             |
| WATCH failed rising with code=DeadlineExceeded: requests that waited too long (a slow disk, or   |
|       no leader).                                                                                |
| BAD   failed rising with code=Unavailable (no leader), ResourceExhausted (NOSPACE: the database  |
|       job), Unauthenticated or PermissionDenied (a client with the wrong credentials).           |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `etcd.up`, `healthy` | 1 |  | `healthy 0`: read `has_leader`; with a leader, an alarm (`etcdctl alarm list`) | `up 0` where nothing listened; `healthy 0` with no quorum, and with the NOSPACE alarm |
| `etcd.has_leader` | 1 |  | 0: quorum is lost, and nothing can be written | 1; 0 on the last member, with two of three stopped |
| `etcd.peers_unreachable` | 0 | Above 0: a member is down or cut off, and one more lost may cost quorum |  | 1 with the leader stopped; 2 with two stopped |
| `etcd.leader_changes_count` | Flat | Rising: elections, from a slow disk or network, or members restarting |  | Up by one when the leader stopped and the others elected another |
| `etcd.proposals_failed_count` | Flat |  | Rising: writes failing (no leader, or timeouts) | Up by one: the write tried with no quorum (`context deadline exceeded`) |
| `etcd.database.db_used_pct` | Below 80 | Past 80 | Near 100: the NOSPACE alarm, and no writes until it is compacted, defragmented and disarmed | 97.07 when the 32 MiB database refused its 24th MiB: etcd raises the alarm when a write would pass the quota; 75.21 once mended |
| `etcd.database.revisions_kept` | Steady | Growing: nothing compacts |  | 2006, for 500 keys written four times and never compacted |
| `etcd.disk.wal_fsync_avg_ms`, `wal_fsyncs_slow_count` | Under 10; slow ones rare | Average past 10, or slow ones rising | Slow ones rising with leader changes: the disk is too slow for etcd | 4.86 ms on average, 18 of 2,013 over 16 ms, on the test machine's disk (a first, scratch run read 21 ms) |
| `etcd.disk.backend_commit_avg_ms` | Under 25 | Past 25 |  | 10.91 |
| `etcd.requests.failed` (by `code`) | Flat | `DeadlineExceeded`, `Canceled` rising: requests waiting too long | `Unavailable`, `ResourceExhausted` (NOSPACE), `Unauthenticated` rising | `code=Canceled` for the write with no quorum (its client gave up first); `code=ResourceExhausted` for the write refused at the quota |

## How it was tested

**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-etcd.sh`, against `compose.etcd.yaml`: **etcd 3.6.17, a cluster of three**, and **etcd 3.5.36, one member alone** with a quota of 32 MiB, each with its metrics on a plain listener (`--listen-metrics-urls`) as the pack reads them. Through etcd's own API: 500 keys, each written four times; a watch held open; two leases of two seconds, left to expire.

- **On Fedora** (Fedora 44, bash 5.3): every job against a member of the cluster and the one alone, and what each read (one leader among the three, as each says of itself; the keys and the history kept; the watch; the leases, expired and counted by the leader; the disk's fsyncs and commits, and the round trip to the peers). Then the leader stopped (the others elected one, the change counted, the old leader unreachable); then two of three stopped (no leader, not healthy, the write that failed counted, by its gRPC code); then the 3.5 member's database filled to its quota (the NOSPACE alarm, healthy 0 with its leader there, the write refused as `ResourceExhausted`), compacted, defragmented and disarmed (healthy again, the space given back); then nothing listening and a page that is not there: **33 passed, 0 failed**. Then `service-packs.sh` through Vigil: **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-etcd/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same cluster through SSH tunnels: every job against the 3.6 member and the 3.5 one, the readings checked, nothing listening: **11 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-etcd-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, against the same cluster: every job under Windows PowerShell 5.1 and PowerShell 7, the same metric names and tags as the Linux scripts read just after; nothing listening and a page that is not there; then through Vigil under each: **22 passed, 0 failed**, the names and tags the same for all 4 jobs against both members under both shells (16 of 16), and through Vigil **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-etcd-windows/console.txt)).

**What the tests found.** etcd publishes no metric for its alarms: a member with NOSPACE says so on `/health` (`ALARM NOSPACE`), and the pack reads it as `healthy 0` with a leader. It raises the alarm when a write would pass the quota, so the database was 97% full, not 100, when writes stopped. A member alone publishes no peer series, so the pack counts members from the active-peer series, one for each other member. Leases are expired, and counted, by the leader alone. A write tried with no quorum fails on the client first: the member counts it as `Canceled`, not `Unavailable`. The container image has no shell: the run makes its keys through etcd's HTTP gateway.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
