# The redis pack

A Redis or Valkey server, on this machine or any it can reach (a container, another server, a managed service), from its `INFO`, as a user that may run `INFO` and `PING` and nothing else. On Linux and macOS through `redis-cli` or `valkey-cli`, whichever is there; on Windows the scripts speak the server's protocol themselves, with what ships with Windows, so there is nothing to install. Linux, macOS and Windows.

1. Create the user once, as an administrator (Redis 6 or later, or Valkey):

   ```text
   ACL SETUSER vigil_monitor on >... -@all +info +ping
   ```

   Then `ACL SAVE` if the server keeps its users in an ACL file, or `CONFIG REWRITE` if it keeps them in its configuration, so the user outlives a restart. It can read no key and change nothing.
2. Give Vigil its password: `vigil secret set REDIS_MONITOR_PASSWORD`, as the account Vigil runs as. The jobs pass it in `REDISCLI_AUTH`, which `redis-cli` and `valkey-cli` read for themselves: never on a command line.
3. `vigil pack enable redis`. The jobs connect to `127.0.0.1:6379` as `vigil_monitor`; for anything else, edit their `env` lines (`REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`) in `vigil.config`.

A server with a password but no users of its own (`requirepass` only): set `REDIS_USER=default`. A server with no password at all: delete the jobs' `secret` lines, and they read it as its default user.

**TLS:** give each job `env = REDIS_TLS=1`, and `env = REDIS_CACERT=<a CA file>` unless the server's certificate is from a CA the machine already trusts. On Linux and macOS, `REDIS_CERT` and `REDIS_KEY` give a client certificate, for a server that asks for one. A certificate that cannot be trusted fails the run and says so. Know this: `redis-cli` and `valkey-cli` check that the certificate is from a trusted CA, but not that it names the server (we tried Redis 6.2 to 8.10 and Valkey 7.2 to 9.2), so give `REDIS_CACERT` a CA that signs only your own servers. On Windows, .NET checks the name too.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| A client on the Vigil machine | `redis-cli` or `valkey-cli`: Debian and Ubuntu `redis-tools` or `valkey-tools`, Fedora `valkey`, RHEL 9 and its rebuilds `redis` or `valkey` | Homebrew's `redis` or `valkey` | None |
| The server | Redis 6.2 or later, or Valkey; tested with Redis 6.2, 7.4 and 8.10 and Valkey 7.2, 8.1 and 9.2 | | |
| A user | `vigil_monitor`, allowed `INFO` and `PING` only (step 1) | | |
| A secret | `REDIS_MONITOR_PASSWORD`, set with `vigil secret set` as the account Vigil runs as (step 2) | | |
| Where to connect | Each job's `env` lines: `REDIS_HOST`, `REDIS_PORT`, `REDIS_USER`; for TLS `REDIS_TLS`, `REDIS_CACERT` | | |

The client must be on the `PATH` the Vigil service runs with. Only `redis-cli` from Redis 7.4 and `valkey-cli` from Valkey 8.1 have a connect timeout: with an older client (Ubuntu 24.04's is 7.0), a server that drops packets rather than refusing the connection keeps the run waiting until the job's `max_runtime`, and the run times out instead of reading `up 0`.

## Its jobs

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `redis_status` | Up, what it is (Redis or Valkey, its version, standalone, cluster or Sentinel), clients and the limit, blocked clients, refused connections, commands, lookups that hit and missed, evicted and expired keys, error replies | Yes | Yes | Yes |
| `redis_memory` | Memory used against `maxmemory` and the policy at the limit, memory from the system, the peak, fragmentation | Yes | Yes | Yes |
| `redis_replication` | On a primary: replicas connected, and each one's state and lag in bytes and seconds. On a replica: whether its link is up, when it last heard from the primary, and whether a full copy is under way | Yes | Yes | Yes |
| `redis_persistence` | Whether the last snapshot and append-only file writes worked, the snapshot's age and the changes since, how long the last fork stopped the server | Yes | Yes | Yes |
| `redis_keyspace` | Keys in each database, and those with a time to live, from the server's own counts: it never reads a key | Yes | Yes | Yes |

Each script's header says what its metrics mean and how to read them. Worth knowing:

- `hit_pct` is since the server started, so it moves slowly: graph `hits_count` and `misses_count` as rates to see the hit rate now.
- `fragmentation_ratio` is high on a server with little data, with no harm: judge it once there is data. Below 1, the system is swapping the server out.
- A cluster node is read as a server of its own. On a Sentinel, `redis_status` reports it (`mode=sentinel`) and the other jobs print nothing.

A server that does not answer reports `redis.up` 0, and the run succeeds: that is a reading. The other jobs then print nothing and succeed. A refused login, a user that may not run `INFO`, and a TLS handshake that fails, fail the run, and its log says why. A wrong password fails even where the server's default user is open and would answer. For several servers, copy a job's section under a new name, as for postgres.

## What to alert on

Starting points, not rules: Vigil runs the jobs and delivers what they print, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give most alerts a few minutes, since a server that restarts reads `loading 1` while it loads its data, and a replica that restarts is missing from its primary for a moment, and that is healthy. The last column is what the test servers showed, in [the Valkey 9.2 run's console output](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-9-replication/console.txt): some of it caused on purpose (twice its `maxmemory` written to the primary, a client left waiting, the replica stopped), and where we caused nothing, it says so. Everything not here (commands, the hit rate, keys expired, uptime) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `redis.up` | 1 | | 0: the server does not answer | 0 for the replica while it was stopped |
| `redis.loading` | 0 | | 1 for longer than a start usually takes: the server answers little else | Not caused: 0 |
| `redis.clients_pct` | Below 70 | 70 to 90 | Above 90: new clients will soon be refused | Not caused: 0, with 2 clients against a limit of 10000 |
| `redis.rejected_connections_count` (as a rate) | 0 | | Any: clients are turned away at `maxclients` | Not caused: 0 |
| `redis.blocked_clients` | Steady, or 0 where nothing should wait | Growing where nothing should wait | | 1: a client the test left waiting on a list no one writes |
| `redis.memory.used_pct`, with the `policy` tag of `redis.memory.max_bytes` | Below 80, or steady at the limit on a cache meant to evict | 80 to 95 with policy `noeviction` | Above 95 with policy `noeviction`: at 100, writes fail | 100 with policy `allkeys-lru`, after twice its limit was written: healthy for a cache, it evicted |
| `redis.memory.max_bytes` | Your limit, above 0 | 0: no limit, and the server grows until the machine runs out of memory | | Not caused: 33554432 (32 MB), policy `allkeys-lru` |
| `redis.evicted_keys_count` (as a rate) | 0, or steady on a cache meant to evict | Rising faster than usual, on a cache | Any, where keys must not be lost | 15,825 after twice its `maxmemory` was written |
| `redis.memory.fragmentation_ratio` | 1 to 1.5, on a server holding real data | Above 1.5: memory held but not used. A server with little data reads high, with no harm | Below 1: the system is swapping the server out, and it slows down | 1.72 on the 32 MB primary after the fill; below 1 not caused |
| `redis.replication.replicas` (a primary) | As many as you run | | Fewer: a replica is down or cut off | 0 with the replica stopped, 1 again once it started |
| `redis.replication.link_up`, `link_down_seconds` (a replica) | 1 | | 0 for a minute or more: it serves older and older data. `link_down_seconds` says for how long | Not caused: 1, as the primary was never stopped |
| `redis.replication.lag_bytes` (a primary) | Near 0 | Rising, and not falling after heavy writes | Still rising after 15 minutes: the replica cannot keep up | Not caused: 0 |
| `redis.replication.lag_seconds` (a primary) | 0 or 1 | Above 10 | Above 60: past the default `repl-timeout`, the primary drops the replica | Not caused: 0 and 1 |
| `redis.replication.online` (a primary), `sync_in_progress` (a replica) | `online 1`, `sync_in_progress 0` | A full copy (`online 0`, `sync_in_progress 1`) for long, or again and again: each costs the primary a fork and the replica a reload | | Not caused: `online 1` and `sync_in_progress 0` |
| `redis.persistence.last_save_ok`, `aof_last_write_ok` | 1 | | 0: the disk is full or not writable, and by default the server refuses writes | Not caused: 1 and 1 |
| `redis.persistence.aof_last_rewrite_ok` | 1 | 0: the append-only file is not rewritten, and keeps growing | | Not caused: 1 |
| `redis.persistence.last_save_age_seconds` | Within your snapshot schedule (the `save` setting) | Well past it while `changes_since_save` grows. With snapshots off it only grows: leave it out | | 10, just after a snapshot the test asked for |
| `redis.keyspace.keys` | Steady, or rising and falling with the work | Growing without end, with `expires` flat: keys with no time to live | Falling to 0 when they should not: a `FLUSHALL`, or a restart that loaded nothing | Not caused: 4180 in `db0` |

## How it was tested

**Tested** on 2026-11-20 on the Fedora 44 test machine, against **Redis 6.2.24, 7.4.12 and 8.10.3 and Valkey 7.2.16, 8.1.12 and 9.2.0**, each a primary with a replica and a TLS server beside it (`compose.redis.yaml`), each with its own client, by `tests/integration/backends/scripts/run-replication.sh redis <image>`: `service-packs.sh` through Vigil, **71 passed, 0 failed** on each, then the replica stopped and started. The full console output: [Redis 6.2](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-6-replication/console.txt), [Redis 7.4](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-7-replication/console.txt), [Redis 8.10](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-redis-8-replication/console.txt), [Valkey 7.2](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-7-replication/console.txt), [Valkey 8.1](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-8-replication/console.txt), [Valkey 9.2](../../tests/integration/backends/reports/runs/2026-11-20/fedora/pack-valkey-9-replication/console.txt). **On Windows**, every job on Windows PowerShell 5.1 and PowerShell 7 against the same servers on the Fedora machine, then `Service-Packs.ps1` through Vigil itself on each: [Valkey 9.2](../../tests/integration/backends/reports/runs/2026-11-20/windows/pack-valkey-windows/console.txt), [Redis 8.10](../../tests/integration/backends/reports/runs/2026-11-20/windows/pack-redis-windows/console.txt). In CI, the same test runs against Valkey 9.2 and Redis 8.10, with the runner's own `redis-cli` (8.0.5 on 2026-11-20), on every change to Vigil itself. From Valkey 9.2, on Linux:

Twice its `maxmemory` written to a primary that evicts (`allkeys-lru`), with a client blocked on a list no one writes:

```text
  PASS  redis: status runs
        metric up 1
        metric info 1 server=valkey version=9.2.0 mode=standalone
        metric clients 2
        metric blocked_clients 1
        metric evicted_keys_count 15825
  PASS  redis: memory runs
        metric used_bytes 33560408
        metric max_bytes 33554432 policy=allkeys-lru
        metric used_pct 100
        metric fragmentation_ratio 1.72
```

Replication, from both sides, as the replica stops and starts again:

```text
# Both sides, streaming.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 1
metric online 1 replica=172.20.0.4_6379
metric lag_bytes 0 replica=172.20.0.4_6379
metric lag_seconds 1 replica=172.20.0.4_6379
$ REDIS_PORT=16380 bash packs/redis/replication.sh
metric is_replica 1
metric replicas 0
metric link_up 1
metric last_io_seconds 7
metric sync_in_progress 0

# The replica stops.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 0
$ REDIS_PORT=16380 bash packs/redis/status.sh
metric up 0

# The replica starts again, and catches up.
$ REDIS_PORT=16379 bash packs/redis/replication.sh
metric is_replica 0
metric replicas 1
metric online 1 replica=172.20.0.4_6379
metric lag_bytes 0 replica=172.20.0.4_6379
metric lag_seconds 1 replica=172.20.0.4_6379
```

**On macOS**, on the Intel Mac test machine under its bash 3.2 and awk, with clients built from their source: every job directly, then `service-packs.sh` through Vigil, **61 passed, 0 failed** on each, against a primary and a replica on the Fedora machine: `valkey-cli` 9.2.0 against [Valkey 9.2](../../tests/integration/backends/reports/runs/2026-11-20/macos/pack-valkey-macos/console.txt), and `redis-cli` 7.2.17, which has no connect timeout, against [Redis 8.10](../../tests/integration/backends/reports/runs/2026-11-20/macos/pack-redis-macos/console.txt). Those clients were built without TLS, so TLS was tested on Linux and Windows. Before that, the macOS scripts ran against replies captured from real servers and replayed by a stand-in client, and gave the same output, line for line, as the Linux scripts: [that run](../../tests/integration/backends/reports/runs/2026-11-20/macos/pack-redis-macos-replay/console.txt).

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
