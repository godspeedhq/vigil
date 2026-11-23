# The rabbitmq pack

RabbitMQ 3.13 and 4.x, a node or a cluster, from the Prometheus pages it serves itself. The pack reads each node's health against its limits (memory against its high watermark, free disk against its limit, file descriptors, Erlang processes) and its three alarms, the messages flowing through it (received, routed, delivered, acknowledged, redelivered, and those lost: unroutable, dead-lettered by reason), every queue with the deepest first, each quorum queue's Raft log and RabbitMQ's own metadata store, what its memory is used for, its disk work, its links to the other nodes, and its virtual hosts, exchanges and bindings. Linux, macOS and Windows.

**`curl` and nothing else.** Every job reads the `rabbitmq_prometheus` plugin's pages (on by default, port 15692) with `curl`, or `Invoke-WebRequest` on Windows. No login, no management API, no Erlang cookie, nothing installed on the node or the Vigil machine.

**The node's Erlang VM: the beam pack.** Its memory by kind, processes, atoms, run queues, the longest mailboxes and its crash dumps are the [beam pack](../beam/README.md)'s, which reads the same page (`BEAM_PROMETHEUS=rabbit1=http://db1:15692/metrics`), and with the node's cookie much more. Name each node the same in both.

1. **The plugin is on by default** in RabbitMQ's packages and images. If it is not: `rabbitmq-plugins enable rabbitmq_prometheus`. Its port, 15692, must be reachable from the Vigil machine; for https, configure the plugin's TLS listener (`prometheus.ssl.*`) and set `RABBITMQ_CACERT` to the CA that signed its certificate (Linux and macOS; on Windows, the certificate must be one Windows trusts).
2. `vigil pack enable rabbitmq`, then in `vigil.config` set the jobs' `RABBITMQ_TARGETS` to each node, a name, then its page's address:

   ```ini
   env = RABBITMQ_TARGETS=rabbit1=http://db1:15692; rabbit2=http://db2:15692; rabbit3=http://db3:15692
   ```

   **Name every node of a cluster.** Each node reports what it holds: its own memory, disk and alarms, the classic queues it hosts and the quorum queues it leads (a quorum queue is counted once, by its leader), its own links. A node that does not answer is a reading, `up 0`, and the run succeeds; a page that is not there, or not RabbitMQ's, fails the run and says so.

**Two figures depend on the version.** RabbitMQ 4.0 stopped counting file I/O (its file handle cache is gone, and the counters read 0): there `rabbitmq_storage` says `counted 0` and reports none of them, rather than zeros that look like an idle disk. RabbitMQ 3.x serves no memory breakdown: there `rabbitmq_memory` says `served 0`.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl` | `curl` | Nothing: `Invoke-WebRequest` |
| The server | RabbitMQ 3.13 or 4.x, with `rabbitmq_prometheus` (on by default), port 15692 reachable | | |
| For https | `RABBITMQ_CACERT`, or a certificate the system trusts | The same | A certificate Windows trusts |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `rabbitmq_status` | Whether each node answers, its RabbitMQ and Erlang versions, node and cluster names; memory against its high watermark, free disk against its limit, file descriptors and Erlang processes against theirs; the memory, disk and file descriptor alarms; unreachable peers; connections, channels, consumers, queues and publishers | minute |
| `rabbitmq_traffic` | Messages received (with confirms), confirmed, routed, unroutable (dropped or returned), delivered (manual and automatic acknowledgement), redelivered, acknowledged, empty gets, dead-lettered by reason (expired, maxlen, rejected, delivery limit); messages unacknowledged and unconfirmed now; the average message size; connections, channels and queues opened and closed; logins and those refused | minute |
| `rabbitmq_queues` | Every queue this node holds (a quorum queue by its leader), the deepest first: messages, ready, unacknowledged, consumers, consumer utilisation, bytes, memory, the oldest message's age, published; queues holding messages with no consumer | 2 minutes |
| `rabbitmq_quorum` | Each quorum queue's copy on this node, leader or follower, and RabbitMQ's metadata store (Khepri): its Raft term (leader elections), commit latency, how far behind it is (to commit, to apply), its segments; the leaders it holds | 5 minutes |
| `rabbitmq_memory` | What the node's memory is used for: connections, channels, classic, quorum and stream queues, binaries, the message index, the metadata store, metrics and management, code, atoms, and what the runtime has allocated and not used (RabbitMQ 4.0 on) | 5 minutes |
| `rabbitmq_storage` | File reads, writes, syncs and seeks, and the time they took; the message store's and queue indexes' reads and writes; metadata transactions (RabbitMQ 3.x; 4.0 on says it no longer counts them) | 5 minutes |
| `rabbitmq_cluster` | Each peer node: its link up, bytes each way, bytes waiting for it; unreachable peers; each virtual host up or down; exchanges and bindings | minute |

Past 100 of anything on a node (queues, quorum members, peers, virtual hosts), the worst first (the deepest, the furthest behind), and the rest counted in a `_not_shown` line. Queues and virtual hosts are tagged by their names, made safe for a tag.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `rabbitmq.nodes`.

```text
+--------------------------------------------------------------------------------------------------+
| rabbitmq_status   rabbitmq.<metric>   every 1m                                                   |
+------------------------+-------------------------------------------------------------------------+
| nodes                  | the nodes named in RABBITMQ_TARGETS                                     |
| up                     | 1 when the node's page answers, else 0, tagged node=<its name>          |
| version                | always 1, tagged node=<the same>, rabbitmq=<its version>,               |
|                        | erlang=<Erlang/OTP's>, rabbitmq_node=<its node name> and cluster=<its   |
|                        | cluster's name>                                                         |
| memory_used_bytes      | memory the node uses (resident)                                         |
| memory_limit_bytes     | its memory high watermark: past it, publishers are blocked              |
| memory_pct             | memory_used_bytes, as a percentage of the limit                         |
| disk_free_bytes        | free disk where it keeps its data                                       |
| disk_free_limit_bytes  | its free disk limit: below it, publishers are blocked                   |
| alarm_memory           | 1 when the memory alarm is on: publishers blocked, cluster-wide         |
| alarm_disk             | 1 when the free disk alarm is on: the same                              |
| alarm_fds              | 1 when it has run out of file descriptors                               |
| fds_used               | file descriptors open: connections, files                               |
| fds_max                | the most it may open                                                    |
| fd_pct                 | fds_used, as a percentage of fds_max                                    |
| erlang_processes       | Erlang processes (a queue, a connection and a channel each take some)   |
| erlang_processes_limit | the most it may have                                                    |
| erlang_process_pct     | erlang_processes, as a percentage of the limit                          |
| run_queue              | Erlang work waiting for a scheduler                                     |
| uptime_seconds         | how long the node has run                                               |
| unreachable_peers      | cluster members it cannot reach                                         |
| connections            | client connections open now                                             |
| channels               | channels open now                                                       |
| consumers              | consumers now                                                           |
| queues                 | queues on this node                                                     |
| publishers             | publishers now                                                          |
+------------------------+-------------------------------------------------------------------------+
| GOOD  up 1; every alarm 0; memory_pct below 60; disk_free_bytes far above disk_free_limit_bytes; |
|       fd_pct below 70; unreachable_peers 0.                                                      |
| WATCH memory_pct above 80: near the watermark; disk_free_bytes under twice its limit; fd_pct     |
|       above 80; connections or channels climbing without falling back: a client leaking them.    |
| BAD   up 0; alarm_memory or alarm_disk 1: every publisher in the cluster is blocked until it     |
|       clears; alarm_fds 1: no new connection is accepted; unreachable_peers above 0: a node is   |
|       down or cut off (a partition).                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_traffic   rabbitmq.traffic.<metric>   every 1m                                          |
+----------------------------+---------------------------------------------------------------------+
| nodes                      | the nodes named in RABBITMQ_TARGETS                                 |
| up                         | 1 when the node's page answers, else 0, tagged node=<its name>      |
| received_count             | messages published to it                                            |
| received_confirm_count     | of those, by publishers asking for confirms                         |
| confirmed_count            | publishes it confirmed                                              |
| routed_count               | messages routed to at least one queue                               |
| unroutable_dropped_count   | messages no queue took, dropped                                     |
| unroutable_returned_count  | messages no queue took, returned to the publisher (mandatory)       |
| delivered_count            | messages delivered to consumers and gets                            |
| delivered_manual_ack_count | of those, to be acknowledged by the client                          |
| delivered_auto_ack_count   | of those, acknowledged on delivery                                  |
| redelivered_count          | deliveries of a message delivered before                            |
| acknowledged_count         | messages acknowledged by clients                                    |
| get_empty_count            | basic.get on an empty queue (polling)                               |
| dead_lettered_count        | messages dead-lettered, tagged reason=<expired, maxlen, rejected or |
|                            | delivery_limit>                                                     |
| unacked                    | messages delivered and not yet acknowledged, on every channel       |
| unconfirmed                | publishes not yet confirmed, on every channel                       |
| message_avg_bytes          | the average size of a message published                             |
| connections_opened_count   | connections opened                                                  |
| connections_closed_count   | connections closed                                                  |
| channels_opened_count      | channels opened                                                     |
| channels_closed_count      | channels closed                                                     |
| queues_declared_count      | queue declarations                                                  |
| queues_created_count       | queues created                                                      |
| queues_deleted_count       | queues deleted                                                      |
| logins_count               | logins tried                                                        |
| logins_failed_count        | logins refused                                                      |
+----------------------------+---------------------------------------------------------------------+
| GOOD  delivered_count and acknowledged_count rising with received_count; unroutable and          |
|       dead_lettered flat; connections opened and closed at a low, steady rate.                   |
| WATCH redelivered_count rising: consumers failing or rejecting; get_empty_count rising fast:     |
|       clients polling, not consuming; unacked climbing: consumers slow to acknowledge;           |
|       connections_opened_count rising as fast as closed, by many a second: clients connecting    |
|       for every message (churn).                                                                 |
| BAD   unroutable_dropped_count rising: messages lost, published where no queue is bound;         |
|       dead_lettered_count reason=maxlen or expired rising: queues full or messages too old, and  |
|       dropped if there is no dead letter queue; logins_failed_count rising: a client with a      |
|       wrong password, or someone trying.                                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_queues   rabbitmq.queues.<metric>   cron 1/2 * * * *                                    |
+-------------------+------------------------------------------------------------------------------+
| nodes             | the nodes named in RABBITMQ_TARGETS                                          |
| up                | 1 when the node's page answers, else 0, tagged node=<its name>               |
| queues            | the queues this node leads                                                   |
| messages_total    | messages in them all                                                         |
| without_consumers | queues holding messages with no consumer                                     |
| messages          | messages in one queue, ready and unacknowledged, tagged node=<its name>,     |
|                   | vhost=<its vhost>, queue=<its name> and type=<classic, quorum or stream>     |
| ready             | of those, waiting for a consumer                                             |
| unacked           | of those, delivered and not yet acknowledged                                 |
| consumers         | its consumers                                                                |
| utilisation_pct   | how much of the time its consumers can take a message at once (100: they     |
|                   | keep up; low: they are slow, or their prefetch too small). Classic queues; a |
|                   | quorum queue says 100 while it has a consumer, slow or not: read its ready   |
|                   | rising instead                                                               |
| bytes             | the size of its messages                                                     |
| memory_bytes      | the memory its process holds                                                 |
| oldest_seconds    | how old its oldest message is (when publishers set the timestamp property)   |
| published_count   | messages published to it (a running total)                                   |
| ..._not_shown     | past 100 of a list (queues), how many were left out                          |
+-------------------+------------------------------------------------------------------------------+
| GOOD  ready near 0, or steady, for queues with consumers; utilisation_pct near 100;              |
|       without_consumers 0.                                                                       |
| WATCH ready growing run after run: consumers fall behind; utilisation_pct low with ready above   |
|       0: consumers are slow, or their prefetch is too small; unacked near consumers times their  |
|       prefetch: every consumer is busy.                                                          |
| BAD   without_consumers above 0 for a queue that should have them: its consumers are gone, and   |
|       messages pile up; oldest_seconds past what your consumers promise; messages_total climbing |
|       with the node's memory_pct (rabbitmq_status): the memory alarm is next, and it blocks      |
|       every publisher.                                                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_quorum   rabbitmq.quorum.<metric>   cron 2/5 * * * *                                    |
+------------------------+-------------------------------------------------------------------------+
| nodes                  | the nodes named in RABBITMQ_TARGETS                                     |
| up                     | 1 when the node's page answers, else 0, tagged node=<its name>          |
| members                | the quorum queues this node holds a copy of, and its metadata store     |
| leaders                | of those, the ones it leads                                             |
| term                   | the queue's Raft term: it rises at each election of a new leader,       |
|                        | tagged node=<its name>, vhost=<its vhost>, queue=<its name> and         |
|                        | role=<leader or follower> (the metadata store: system=rabbit_khepri)    |
| commit_latency_seconds | how long the last command took to commit                                |
| commit_lag             | log entries written here and not yet committed                          |
| apply_lag              | entries committed and not yet applied here                              |
| segments               | the log's segment files on disk                                         |
| ..._not_shown          | past 100 of a list (members), how many were left out                    |
+------------------------+-------------------------------------------------------------------------+
| GOOD  term steady; commit_latency_seconds in milliseconds; commit_lag and apply_lag near 0;      |
|       leaders spread over the nodes.                                                             |
| WATCH term rising: leaders being elected again and again (a node restarting, or the network      |
|       flapping); commit_latency_seconds climbing: the disks or the network are slow; every       |
|       leader on one node: it takes all the work.                                                 |
| BAD   commit_lag or apply_lag growing on one copy: it is falling behind and may need a snapshot; |
|       members lower than the queues you expect here: a copy is gone (a node was removed).        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_memory   rabbitmq.memory.<metric>   cron 3/5 * * * *                                    |
+----------------------------+---------------------------------------------------------------------+
| nodes                      | the nodes named in RABBITMQ_TARGETS                                 |
| up                         | 1 when the node's page answers, else 0, tagged node=<its name>      |
| served                     | 1 when the node serves its memory breakdown (RabbitMQ 4.0 on), 0    |
|                            | when it does not (3.x)                                              |
| connection_readers_bytes   | connections' readers (one per connection)                           |
| connection_writers_bytes   | connections' writers                                                |
| channels_bytes             | channels                                                            |
| connection_other_bytes     | other connection processes                                          |
| classic_queues_bytes       | classic queues' processes                                           |
| quorum_queues_bytes        | quorum queues' processes                                            |
| quorum_queues_dlx_bytes    | quorum queues' dead lettering                                       |
| quorum_ets_bytes           | quorum queues' tables                                               |
| streams_bytes              | streams' processes, readers and coordinator                         |
| binaries_bytes             | binaries: message bodies, mostly                                    |
| message_index_bytes        | the message store's index                                           |
| metadata_store_bytes       | the metadata store (Khepri, or Mnesia)                              |
| metrics_bytes              | RabbitMQ's own metrics                                              |
| management_bytes           | the management plugin's statistics                                  |
| plugins_bytes              | plugins                                                             |
| code_bytes                 | loaded code                                                         |
| atoms_bytes                | the atom table                                                      |
| other_processes_bytes      | other Erlang processes                                              |
| other_tables_bytes         | other ETS tables                                                    |
| other_system_bytes         | other system memory                                                 |
| allocated_unused_bytes     | allocated by the runtime, not in use                                |
| reserved_unallocated_bytes | reserved by the runtime, not allocated                              |
+----------------------------+---------------------------------------------------------------------+
| GOOD  binaries_bytes and the queues' bytes rising and falling with the messages held; the rest   |
|       steady.                                                                                    |
| WATCH binaries_bytes climbing while queues are short: a consumer holding messages                |
|       unacknowledged; connection_readers_bytes and channels_bytes climbing: clients leaking      |
|       connections or channels; management_bytes large: the management plugin's statistics, on a  |
|       busy node.                                                                                 |
| BAD   one part climbing toward rabbitmq_status memory_limit_bytes: that is what will set off the |
|       memory alarm, which blocks every publisher.                                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_storage   rabbitmq.storage.<metric>   cron 4/5 * * * *                                  |
+--------------------------+-----------------------------------------------------------------------+
| nodes                    | the nodes named in RABBITMQ_TARGETS                                   |
| up                       | 1 when the node's page answers, else 0, tagged node=<its name>        |
| counted                  | 1 when the node counts its file I/O (RabbitMQ 3.x), 0 when it does    |
|                          | not (4.0 on)                                                          |
| read_ops_count           | file reads                                                            |
| read_bytes               | bytes read                                                            |
| read_seconds             | time spent reading                                                    |
| write_ops_count          | file writes                                                           |
| write_bytes              | bytes written                                                         |
| write_seconds            | time spent writing                                                    |
| sync_ops_count           | fsyncs: each makes a write durable                                    |
| sync_seconds             | time spent in them                                                    |
| seek_ops_count           | seeks                                                                 |
| seek_seconds             | time spent seeking                                                    |
| reopen_ops_count         | files reopened (too few file handles kept)                            |
| msg_store_reads_count    | reads from the message store (classic queues' message bodies)         |
| msg_store_writes_count   | writes to it                                                          |
| queue_index_reads_count  | reads of classic queues' indexes                                      |
| queue_index_writes_count | writes to them                                                        |
| metadata_disk_tx_count   | metadata store transactions on disk                                   |
| metadata_ram_tx_count    | metadata store transactions in memory                                 |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  sync_seconds and write_seconds rising slowly against their operations: milliseconds each.  |
| WATCH time per sync (sync_seconds over sync_ops_count, as rates) above 10 ms: the disk is slow   |
|       for quorum queues and confirms; reopen_ops_count rising: too few file handles.             |
| BAD   time per sync above 100 ms, or writes stalling while messages arrive: publishers wait for  |
|       confirms, and memory grows (rabbitmq_status memory_pct).                                   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| rabbitmq_cluster   rabbitmq.cluster.<metric>   every 1m                                          |
+---------------------+----------------------------------------------------------------------------+
| nodes               | the nodes named in RABBITMQ_TARGETS                                        |
| up                  | 1 when the node's page answers, else 0, tagged node=<its name>             |
| peers               | the nodes it is linked to                                                  |
| unreachable_peers   | cluster members it cannot reach                                            |
| peer_up             | 1 when the link to a peer is up, 0 while it is still being set up, tagged  |
|                     | node=<its name> and peer=<the peer's node name>                            |
| peer_sent_bytes     | bytes sent to that peer (a running total)                                  |
| peer_received_bytes | bytes received from it (a running total)                                   |
| peer_queue_bytes    | bytes waiting to go to it                                                  |
| vhosts              | the virtual hosts                                                          |
| vhosts_down         | of those, not running on this node                                         |
| vhost_up            | 1 when a virtual host runs on this node, else 0, tagged node=<its name>    |
|                     | and vhost=<its name>                                                       |
| exchanges           | the exchanges, every virtual host                                          |
| bindings            | the bindings from them                                                     |
| ..._not_shown       | past 100 of a list (peers, vhosts), how many were left out                 |
+---------------------+----------------------------------------------------------------------------+
| GOOD  peers one fewer than the cluster's nodes, every peer_up 1; unreachable_peers 0;            |
|       vhosts_down 0; peer_queue_bytes near 0.                                                    |
| WATCH peer_queue_bytes above 0 run after run: the link to that peer is slow or saturated;        |
|       exchanges or bindings climbing without end: an application declaring them per message.     |
| BAD   unreachable_peers above 0, or a peer missing: a node is down or cut off, and quorum queues |
|       there may have lost their majority; vhosts_down above 0: a virtual host failed to start    |
|       here, and its clients are refused.                                                         |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the nodes in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `rabbitmq.up` | 1 | | 0: the node, or its plugin, is down | 0 for the node of the cluster that was stopped |
| `rabbitmq.alarm_memory`, `memory_pct` | 0; below 60 | `memory_pct` above 80 | `alarm_memory` 1: every publisher in the cluster is blocked | 1 on 4.1 given a 50 MB watermark: `memory_pct` 235.90 (118 MB used) |
| `rabbitmq.alarm_disk`, `disk_free_bytes` against `disk_free_limit_bytes` | 0; far above it | Under twice the limit | `alarm_disk` 1: publishers blocked | 1 on 3.13 given a 100 TB limit, with 49 GB free |
| `rabbitmq.alarm_fds`, `fd_pct` | 0; below 70 | Above 80 | `alarm_fds` 1: no new connection accepted | 0; 4.39 (45 of 1,024) |
| `rabbitmq.unreachable_peers`; `rabbitmq.cluster.peer_up` | 0; 1 for each peer | | Above 0, or a peer gone: a node down or cut off | 1 on `a` once `c` was stopped; 2 peers up before |
| `rabbitmq.queues.without_consumers` | 0 | | Above 0 for a queue that should have consumers | 3: the queue nobody read (40 waiting), the dead letter queue (70) and the capped queue (10) |
| `rabbitmq.queues.ready` | Near 0, or steady | Growing run after run | Climbing with `memory_pct`: the memory alarm is next | 14,163 ready on the quorum queue fed 200 a second and read 10 a second |
| `rabbitmq.queues.utilisation_pct` (classic queues) | Near 100 | Low, with `ready` above 0: slow consumers or a small prefetch | | Read on classic queues: a quorum queue says 100 while it has a consumer, slow or not, so its `ready` is what showed it |
| `rabbitmq.traffic.dead_lettered_count` (rate) | Flat | Rising, `reason=expired` or `maxlen` | Rising with no dead letter queue: those messages are gone | 30 for `maxlen` (40 sent to a queue of 10) and 40 for `expired` (a 1 second TTL) |
| `rabbitmq.traffic.unroutable_dropped_count` (rate) | Flat | | Rising: messages published where no queue is bound, lost | 40, sent to an exchange with no queue |
| `rabbitmq.traffic.logins_failed_count` (rate) | Flat | Now and then | Rising: a client with a wrong password, or someone trying | 3, from clients with a wrong password |
| `rabbitmq.quorum.term`, `commit_lag` | Steady; near 0 | `term` rising: leaders elected again and again | `commit_lag` growing on one copy | 1 on each of the three copies of the quorum queue, one leader; commits in 12 to 18 ms |
| `rabbitmq.storage.counted` | | | | 0 on 4.1 and 4.2 (they no longer count file I/O), 1 on 3.13 |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-rabbitmq.sh`, against `compose.rabbitmq.yaml`: **a cluster of three RabbitMQ 4.2 nodes**, **RabbitMQ 4.1** past a 50 MB memory watermark (its memory alarm on), and **RabbitMQ 3.13** below a 100 TB free disk limit (its disk alarm on), each in Docker. Trouble on purpose, with RabbitMQ's own PerfTest and `rabbitmqadmin`: a quorum queue fed 200 messages a second and read 10 a second, a queue nobody reads, a queue of 10 at most and messages with a 1 second TTL, both dead-lettering into a dead letter queue, 40 messages to an exchange no queue is bound to, 3 logins with a wrong password; then a node of the cluster stopped.
- **On Fedora**: every job directly, each reading checked on all five nodes (the alarms, the cluster's links, every queue, the quorum queue once by its leader and its three copies, the metadata store on each node, dead letters by reason, messages lost, logins refused, file I/O counted on 3.13 only), the stopped node read as `up 0` and unreachable from the others; then `service-packs.sh` through Vigil (enable, and that the VM is the beam pack's; every job; each node answering; a node that does not answer read as `up 0`; a page that is not there failing the run): **45 passed, 0 failed**, and through Vigil **19 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-rabbitmq/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2), against **RabbitMQ 4.4.1** (its generic Unix build, on Erlang/OTP 28 from erlef) on the Mac, with queues and messages made through its HTTP API: every job, **18 passed, 0 failed**; through Vigil, **15 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-rabbitmq-macos/console.txt)). This run found that macOS's awk refuses a conditional in `printf`'s arguments unless it is in brackets, and that a failed parse let the run succeed: both fixed, and a parse that fails now fails the run.
- **On Windows**, as an account that is not an administrator, against **RabbitMQ 4.4.1** (its Windows zip, on Erlang/OTP 28.5's) on the machine: every job directly, then `Service-Packs.ps1` through Vigil, on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **28 passed, 0 failed** and **14 passed, 0 failed** on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-rabbitmq-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **14 passed, 0 failed** and **14 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-rabbitmq-windows/console.txt)).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
