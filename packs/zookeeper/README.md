# The zookeeper pack

Apache ZooKeeper, one server or a whole ensemble, from its four-letter words. For each server you name, the pack reads whether it answers and whether it serves (a server cut off from its quorum answers, and serves nothing); its version and role (leader, follower, observer, standalone, read-only); latency, connections and the requests waiting; its znodes, watches and ephemeral znodes, and the data they hold; its file descriptors; the longest fsync and the longest JVM pause; and elections, failed logins, requests throttled and errors. On the leader, its followers and how many are in sync. And for the ensemble as this machine sees it: servers up, serving, and how many lead: one, and only one, when all is well. Linux, macOS and Windows.

ZooKeeper sits under Kafka (before 4.0), HBase, Solr, Hadoop, ClickHouse clusters of old, and a great many systems of its own age, and it is quiet about its trouble. A server that loses its quorum keeps answering `ruok` with `imok`, and serves no one. A slow disk makes an fsync take a second, and every session on the server times out at once. A garbage collection that stops the JVM does the same. An ensemble that keeps electing leaders is an ensemble whose clients keep reconnecting. Each of these is in `mntr`, and in no ping.

**No login, no client, nothing to install.** The pack sends `ruok`, `mntr` and `isro` to each server's client port, each over a connection of its own, and reads the answer: with bash alone on Linux and macOS (`/dev/tcp`), PowerShell alone on Windows. It changes nothing: those three words only read.

1. **Allow the words on each server.** ZooKeeper answers only the four-letter words in its whitelist, and since 3.5.3 that is `srvr` alone. In `zoo.cfg`:

   ```properties
   4lw.commands.whitelist=mntr,ruok,isro
   ```

   then restart the server (one at a time, in an ensemble). In the official Docker image, `ZOO_4LW_COMMANDS_WHITELIST=mntr,ruok,isro`. `mntr`, `ruok` and `isro` only read; you need not allow the ones that do more (`srst` resets statistics, `wchp` and `cons` can be heavy on a large server).

2. `vigil pack enable zookeeper`, then in `vigil.config` set the job's `ZOOKEEPER_SERVERS`, the servers to read, `host:port`, separated by `;`:

   ```ini
   env = ZOOKEEPER_SERVERS=zk1:2181; zk2:2181; zk3:2181
   ```

   Each is tagged `server=<host:port>`. The default is `localhost:2181`. An IPv6 address is written `[::1]:2181`.

**An ensemble from one machine, or each server on its own.** Name every server of the ensemble on one machine, and the `leaders`, `servers_serving` and `servers_up` lines tell you about the ensemble as a whole: alert on `leaders` not being 1. Or run the pack on each server, pointed at its own: each reports itself, and the ensemble is the sum in your backend.

**The words are plain text on the client port.** A server that takes TLS alone (`secureClientPort`, no `clientPort`) cannot be read this way; most keep a plain port, often on localhost or a private network, and that is the one to name.

**A server that does not answer is a reading**, `up 0`, and the run succeeds. A server that answers but refuses the words (not in its whitelist) fails the run, after every other server is read, saying which server, which words, and the line to add.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `bash` | `bash` (3.2 is enough) | Nothing: PowerShell 5.1 or 7 |
| ZooKeeper | 3.8 or 3.9, a server or an ensemble; the client port reachable, in plain text | | |
| On each server | `4lw.commands.whitelist=mntr,ruok,isro` in `zoo.cfg` | | |

## Its job

| Job | Reports | Every |
| --- | --- | --- |
| `zookeeper_status` | Each server: up, serving, version and role, read-only, uptime, latency, connections, requests waiting, znodes, watches, ephemerals, data size, file descriptors, the longest fsync and JVM pause, packets, elections, failed logins, requests throttled, errors; on the leader, followers and those in sync. The ensemble: servers, up, serving, leaders | minute |

Running totals (`_count`) restart when the server restarts: graph them as a rate. The longest fsync, JVM pause and latency are since the server started (or since someone sent it `srst`).

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `zookeeper.servers`.

```text
+--------------------------------------------------------------------------------------------------+
| zookeeper_status   zookeeper.<metric>   every 1m                                                 |
+------------------------+-------------------------------------------------------------------------+
| servers                | servers named in ZOOKEEPER_SERVERS                                      |
| servers_up             | of those, answering                                                     |
| servers_serving        | of those, serving requests                                              |
| leaders                | of those, leader: 1 for an ensemble (standalone servers are not         |
|                        | counted)                                                                |
| up                     | 1 when the server answers ruok, else 0                                  |
| serving                | 1 when it serves requests (it answered mntr), else 0: it has no quorum  |
| info                   | always 1, tagged version=<3.9.7> role=<leader, follower, observer,      |
|                        | standalone, readonly>                                                   |
| readonly               | 1 in read-only mode (cut off from its quorum, with                      |
|                        | readonlymode.enabled): it serves reads, and refuses writes              |
| uptime_seconds         | since it started                                                        |
| latency_avg_ms         | time to answer a request, on average                                    |
| latency_max_ms         | the longest (since it started, or since srst)                           |
| connections            | clients connected                                                       |
| outstanding_requests   | requests waiting to be processed                                        |
| znodes                 | znodes in its tree                                                      |
| watches                | watches set by clients                                                  |
| ephemerals             | ephemeral znodes (each held by a session)                               |
| data_bytes             | the data its znodes hold, approximately                                 |
| fds_open               | file descriptors open                                                   |
| fds_pct                | fds_open, of the most it may open                                       |
| fsync_max_ms           | the longest write to its transaction log took (since it started)        |
| jvm_pause_max_ms       | the longest the JVM stopped it (garbage collection, since it started)   |
| packets_received_count | packets received (a running total)                                      |
| packets_sent_count     | packets sent (a running total)                                          |
| elections_count        | times it looked for a leader (a running total)                          |
| auth_failed_count      | logins refused (a running total)                                        |
| throttled_count        | requests throttled (a running total)                                    |
| errors_count           | errors it could not recover from (a running total)                      |
| quorum_size            | servers of the ensemble that vote                                       |
| followers              | on the leader: followers and observers connected                        |
| followers_synced       | on the leader: followers in sync                                        |
| pending_syncs          | on the leader: followers still syncing                                  |
+------------------------+-------------------------------------------------------------------------+
| GOOD  servers_serving equal to servers; leaders 1; on the leader, followers_synced the quorum    |
|       less one; latency_avg_ms below 10; outstanding_requests near 0; fds_pct below 50.          |
| WATCH latency_avg_ms past 50; outstanding_requests above 10 for several runs; fsync_max_ms past  |
|       1000 (a slow disk: sessions time out); jvm_pause_max_ms past 1000; elections_count rising; |
|       watches or znodes growing without end; fds_pct past 70.                                    |
| BAD   up 0; serving 0 (no quorum: clients of this server get nothing); leaders 0 or above 1;     |
|       readonly 1 (writes refused); followers_synced below a majority; auth_failed_count rising.  |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures the script's header explains; "In our tests" is what a three-server ensemble in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `zookeeper.leaders` | 1 (an ensemble) | | 0, or above 1: no leader, no writes | 1; 1 again after the leader stopped (zk2 elected); 0 with two of three stopped |
| `zookeeper.servers_serving`, `serving` (by `server`) | Equal to `servers` | | `serving 0` while `up 1`: the server has no quorum, and its clients get nothing | 4 of 4; `serving 0`, `up 1` for the server left alone with read-only mode off |
| `zookeeper.readonly` (by `server`) | 0 | | 1: cut off from its quorum, it serves reads and refuses writes | 1, `role=readonly`, for the server left alone with `readonlymode.enabled` |
| `zookeeper.followers_synced` (on the leader) | The ensemble's size less one | Below it | Below a majority | 2; 1 with a follower stopped |
| `zookeeper.latency_avg_ms`, `outstanding_requests` | Below 10; near 0 | Past 50; above 10 for several runs | Rising together: the server cannot keep up | 17.52 on the server that took 200 creates in a burst, 0 on the others; 0 waiting |
| `zookeeper.fsync_max_ms` | Tens of ms | Past 1,000: a slow disk | Past the session timeout: sessions expire | 88, 73 and 50 on a shared disk |
| `zookeeper.jvm_pause_max_ms` | Tens of ms | Past 1,000 | Past the session timeout | 0 |
| `zookeeper.elections_count` | Flat | Rising | Rising run after run: the ensemble cannot keep a leader | 1 each at start; 2 on both servers left after the leader stopped |
| `zookeeper.znodes`, `watches`, `ephemerals`, `data_bytes` | Steady, or growing with the application | Growing without end (a client leaking znodes or watches) | `data_bytes` near the heap | 208 znodes and 102,610 bytes on every server; 2 watches and 2 connections on the server the client used; 1 ephemeral |
| `zookeeper.fds_pct` | Below 50 | Past 70 | Past 90: new connections refused | 0.01 |
| `zookeeper.up` (by `server`) | 1 | | 0: the server is down, or its port unreachable | 0 for each stopped server and for a port nothing listened on, each run succeeding |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-26 by `tests/integration/backends/scripts/run-zookeeper.sh`, against `compose.zookeeper.yaml`: **ZooKeeper 3.9.7, an ensemble of three** (two with read-only mode enabled, one without), **ZooKeeper 3.8.8, one server**, and a 3.9.7 server left with the default whitelist. With `zkCli`, in the ensemble: 200 znodes and one of 100 KB, and a client session held open with an ephemeral znode and two watches.

- **On Fedora 44** (bash 5.3): the job against the ensemble and 3.8.8, each reading checked (roles, versions, the leader's followers in sync, the znodes and their data on every server, the ephemeral, the watches where the session was); the server with the default whitelist failing the run, naming the words, with the other server read all the same; nothing listening read as `up 0`; a server that is not `host:port`. Then `service-packs.sh` through Vigil. Then the ensemble fell apart: a follower stopped (one in sync); the leader stopped (another elected, `elections_count` rising on both left); two stopped leaving the server with read-only mode off (`up 1`, `serving 0`, no leader); two stopped leaving one with it on (`readonly 1`, `role=readonly`): **26 passed, 0 failed**, and through Vigil **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/fedora/pack-zookeeper/console.txt)).
- **On Windows**, on Windows 11 as an account that is not an administrator, against the same ensemble held up for it, through SSH tunnels: under Windows PowerShell 5.1 and PowerShell 7, the same 102 lines as the Linux script read at the same moment, names and tags alike, and the same 42 values where they hold still; the refusing server and nothing listening as on Linux; through Vigil, **12 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/windows/pack-zookeeper-windows/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2), the same way: **9 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-26/macos/pack-zookeeper-macos/console.txt)).

**What ZooKeeper taught the pack:**

- **`ruok` says `imok` without a quorum.** A server cut off from its ensemble answers it, and answers `mntr` with "This ZooKeeper instance is not currently serving requests". So the pack reads `up` from `ruok` and `serving` from `mntr`, and they part exactly when it matters.
- **Read-only mode is a role of its own**: `mntr` says `zk_server_state read-only`, and `isro` says `ro`. Without read-only mode enabled, `isro` answers `null`.
- **Since 3.5.3, only `srvr` is allowed** out of the box: `mntr` and `ruok` answer "is not executed because it is not in the whitelist", which the pack turns into the line to add.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
