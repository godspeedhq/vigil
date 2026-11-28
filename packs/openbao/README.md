# The openbao pack

An OpenBao or HashiCorp Vault node, from what it says about itself: the two answer the same paths and publish the same metrics, so one pack reads both, and says which it found. With no token at all, it reads whether the node is initialized and sealed, how far an unseal has got, whether it is active or a standby and knows its leader. With a token that may read its metrics, and nothing else: its Raft cluster as autopilot sees it (healthy or not, how many nodes it may lose, which are unhealthy), followers behind and leadership lost, how long storage takes; its leases and those it could not revoke, the tokens created; and its requests: logins that failed, users locked out after too many, responses refused, audit devices that failed to log.

Everything that has a secret asks it for one, so trouble here is trouble everywhere at once. A node that restarts with a Shamir seal comes back sealed and serves nothing until someone brings the keys; a cluster of three that has lost one may not lose another; a client with a stale password is locked out after a few tries, and an application stops; leases that grow without end make every failover slower; and with every audit device failing, it refuses every request. Each of these is on its health page or its metrics page.

**Read-only: every request is a GET.** The pack reads OpenBao's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on for the status job: `/v1/sys/health`, `/v1/sys/seal-status` and `/v1/sys/leader` answer anyone.
2. For the other three, its metrics: in its configuration, `telemetry { prometheus_retention_time = "24h" }` (it drops a counter not updated in that time: keep it longer than the jobs' interval), and a token that may read `sys/metrics` and nothing else: `bao policy write vigil-metrics - <<< 'path "sys/metrics" { capabilities = ["read"] }'`, then `bao token create -orphan -policy=vigil-metrics -no-default-policy -period=768h` (`vault` for Vault). A periodic token never expires by TTL; renew it within the period, or give a new one. Or let anyone read the metrics: `unauthenticated_metrics_access = true` in the listener's `telemetry` block. **On a Vault standby, that setting is needed**: Vault sends a standby's `sys/metrics` to the active node (HTTP 307) otherwise. OpenBao's standbys answer with the token.
3. `vigil pack enable openbao` on each node's machine, then `vigil secret set OPENBAO_TOKEN`, and where the node is not at `http://localhost:8200`, `OPENBAO_URL` in the jobs' `env` lines (https, with `OPENBAO_CACERT` when its CA is not one the system trusts). Each node reports itself.

**OpenBao that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk` | `curl`, `awk` (built in) | Nothing: PowerShell 5.1 or later, and .NET |
| OpenBao | OpenBao 2.x and HashiCorp Vault 1.15 and later, one node or an HA cluster (tested: OpenBao 2.7.3 and Vault 2.2.2, each a Raft cluster of three) | | |
| Its address | reachable from the Vigil machine: `OPENBAO_URL` (default `http://localhost:8200`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `openbao_status` | Up; OpenBao or Vault, its version, its seal and its storage; initialized, sealed, standby; keys needed, given so far; HA, active, the leader known; Raft entries not yet applied | minute |
| `openbao_storage` | Active; autopilot healthy, failure tolerance, nodes and those unhealthy, named; Raft peers; the follower furthest behind; time since the leader was heard; commit time; leadership lost; storage reads and writes and their time | minute |
| `openbao_leases` | Leases held and those it could not revoke; tokens created, for each auth method; tokens; mounts | 5 minutes |
| `openbao_requests` | Requests and those in flight; logins, those that created a token and those that failed; users locked out; responses refused (4xx, 403) and failed (5xx), on Vault; requests and responses audit devices failed to log | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `openbao.up`.

```text
+--------------------------------------------------------------------------------------------------+
| openbao_status   openbao.<metric>   every 1m                                                     |
+---------------------+----------------------------------------------------------------------------+
| up                  | 1 when the node answered, else 0                                           |
| info                | always 1, tagged product=<openbao or vault>, version=, seal=<shamir,       |
|                     | awskms, transit ...> and storage=<raft, consul, file ...>                  |
| initialized         | 1 when it is initialized                                                   |
| sealed              | 1 when it is sealed: it serves nothing until it is unsealed                |
| standby             | 1 for a standby: it sends requests to the active node                      |
| performance_standby | 1 for a performance standby (Vault Enterprise)                             |
| unseal_threshold    | keys needed to unseal it                                                   |
| unseal_shares       | keys there are                                                             |
| unseal_progress     | keys given so far toward an unseal                                         |
| ha_enabled          | 1 when high availability is on (unsealed only, as the rest)                |
| active              | 1 for the active node                                                      |
| leader_known        | 1 when it knows the active node                                            |
| raft_apply_lag      | Raft entries committed and not yet applied                                 |
+---------------------+----------------------------------------------------------------------------+
| GOOD  up 1; initialized 1; sealed 0; one node of the cluster active 1, the others standby 1;     |
|       leader_known 1.                                                                            |
| WATCH unseal_progress above 0 for long: an unseal started and not finished; raft_apply_lag       |
|       growing.                                                                                   |
| BAD   sealed 1: the node serves nothing (after a restart, a Shamir seal needs its keys again);   |
|       no node active 1: the cluster has no active node; leader_known 0 on an unsealed standby;   |
|       initialized 0 on a node that should have data.                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| openbao_storage   openbao.storage.<metric>   every 1m                                            |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when OpenBao answered its metrics page, else 0 (and nothing    |
|                               | more is read)                                                    |
| active                        | 1 for the active node                                            |
| autopilot_healthy             | 1 when autopilot finds every node healthy (the active node       |
|                               | reports it)                                                      |
| failure_tolerance             | nodes the cluster may lose and keep quorum                       |
| nodes                         | nodes autopilot knows                                            |
| nodes_unhealthy               | of them, unhealthy (sealed, stopped or behind)                   |
| node_unhealthy                | each node: 1 when unhealthy, tagged node=<its node_id>           |
| raft_peers                    | the Raft cluster's peers                                         |
| follower_lag_max              | the follower furthest behind the leader, in log entries (the     |
|                               | active node reports it)                                          |
| leader_contact_avg_ms         | how long since a follower last heard from the leader, on average |
|                               | (on a standby)                                                   |
| commit_avg_ms                 | a Raft commit, on average, in milliseconds (on the active node)  |
| leadership_lost_count         | times this node lost leadership (a running total)                |
| leadership_setup_failed_count | times it failed to take leadership (a running total)             |
| storage_reads_count           | storage reads (a running total)                                  |
| storage_read_avg_ms           | a storage read, on average, in milliseconds                      |
| storage_writes_count          | storage writes (a running total)                                 |
| storage_write_avg_ms          | a storage write, on average, in milliseconds                     |
| ..._not_shown                 | past 100 of a list (node_unhealthy), how many were left out      |
+-------------------------------+------------------------------------------------------------------+
| GOOD  autopilot_healthy 1; nodes_unhealthy 0; failure_tolerance 1 or more (a cluster of three or |
|       five).                                                                                     |
| WATCH failure_tolerance 0: one more node lost and the cluster stops; follower_lag_max growing;   |
|       storage_write_avg_ms or commit_avg_ms rising: slow disks.                                  |
| BAD   autopilot_healthy 0: node_unhealthy names the node (sealed after a restart, stopped, or    |
|       cut off); leadership_lost_count moving with no one stepping it down.                       |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| openbao_leases   openbao.leases.<metric>   every 5m                                              |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when OpenBao answered its metrics page, else 0 (and nothing more is     |
|                      | read)                                                                     |
| leases               | leases held, tokens' included                                             |
| irrevocable_leases   | leases it tried to revoke and could not                                   |
| tokens_created_count | tokens created (a running total)                                          |
| tokens_created       | the same, for each auth method, tagged method=<token, userpass, approle,  |
|                      | kubernetes ...>                                                           |
| tokens               | tokens (Vault, every usage_gauge_period: 10 minutes by default)           |
| mounts               | mounts: secrets engines and auth methods                                  |
| ..._not_shown        | past 100 of a list (tokens_created), how many were left out               |
+----------------------+---------------------------------------------------------------------------+
| GOOD  leases steady with the workload; irrevocable_leases 0.                                     |
| WATCH leases growing day after day: long TTLs, or clients that log in again and again without    |
|       reusing their token (tokens_created says by which method).                                 |
| BAD   irrevocable_leases above 0: credentials it could not revoke, in a database or a cloud      |
|       account, still work: find them (sys/leases) and revoke them where they live; leases in the |
|       hundreds of thousands: restarts and failovers slow down, and storage grows.                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| openbao_requests   openbao.requests.<metric>   every 1m                                          |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when OpenBao answered its metrics page, else 0 (and nothing    |
|                               | more is read)                                                    |
| requests_count                | requests handled (a running total)                               |
| in_flight                     | requests being handled now                                       |
| logins_count                  | login requests (a running total)                                 |
| logins_ok_count               | of them, those that created a token (a running total)            |
| logins_failed_count           | those that did not: a wrong password, a role unknown, a user     |
|                               | locked out (a running total)                                     |
| locked_users                  | users locked out after too many failed logins (updated every few |
|                               | minutes)                                                         |
| responses_4xx_count           | responses refused, 4xx (Vault; a running total)                  |
| permission_denied_count       | of them, 403: a token without the policy, or a user locked out   |
|                               | (Vault)                                                          |
| responses_5xx_count           | responses that failed, 5xx (Vault; a running total)              |
| audit_request_failures_count  | requests an audit device failed to log (a running total)         |
| audit_response_failures_count | responses an audit device failed to log (a running total)        |
+-------------------------------+------------------------------------------------------------------+
| GOOD  logins_failed_count rising slowly, if at all; locked_users 0; the audit failure counts     |
|       flat.                                                                                      |
| WATCH logins_failed_count rising: a client with a stale secret, or someone guessing;             |
|       permission_denied_count rising: a token without the policy it needs.                       |
| BAD   locked_users above 0: a user locked out (an application that cannot log in); the audit     |
|       failure counts moving: with every audit device failing, it refuses every request;          |
|       responses_5xx_count moving.                                                                |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `openbao.up` | 1 |  | 0: the node does not answer | `up 0` where nothing listened |
| `openbao.sealed` | 0 |  | 1: the node serves nothing until its keys are given | 1 on a node restarted (a Shamir seal); `unseal_progress 1` with one key of two given, then `sealed 0` |
| `openbao.active` (over the nodes) | One node 1 |  | None: the cluster has no active node | o1 and v1; then o2 and v2, each taking over within seconds of the active node stopping |
| `openbao.storage.autopilot_healthy`, `node_unhealthy` (by `node`) | 1; 0 |  | 0: `node_unhealthy` names the node | 0, with `node_unhealthy 1 node=o3` (and `v3`): the node restarted and sealed |
| `openbao.storage.failure_tolerance` | 1 or more | 0: one more node lost and the cluster stops |  | 1 for three nodes; 0 with one sealed |
| `openbao.storage.storage_write_avg_ms`, `commit_avg_ms` | Steady | Rising: slow disks |  | 34 and 18 ms (OpenBao), 30 and 15 ms (Vault), on the test machine's disk |
| `openbao.requests.locked_users` | 0 |  | Above 0: a user locked out; an application that cannot log in | 1: the user whose wrong password was tried seven times (400 five times, then 403) |
| `openbao.requests.logins_failed_count` | Flat | Rising: a stale secret, or someone guessing |  | 20 for the 10 wrong passwords: both count a failed login twice |
| `openbao.requests.permission_denied_count`, `responses_4xx_count` | Flat | Rising: tokens without the policy they need, or users locked out |  | 2 and 10 (Vault) |
| `openbao.leases.irrevocable_leases` | 0 |  | Above 0: credentials it could not revoke still work | 0 |
| `openbao.leases.leases` | Steady | Growing day after day | In the hundreds of thousands | 27: 5 from logins, 22 tokens |
| `openbao.requests.audit_request_failures_count` | Flat |  | Rising: with every audit device failing, it refuses every request | Not caused: OpenBao 2.7 enables audit devices only in its configuration file |

## How it was tested

**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-openbao.sh`, against `compose.openbao.yaml`: **OpenBao 2.7.3, a Raft cluster of three**, and **HashiCorp Vault 2.2.2, a Raft cluster of three**, each initialized with three key shares (two needed) and unsealed, and given a token that may read `sys/metrics` and nothing else, as this page says. On each: userpass, five logins that worked and ten with a wrong password (seven of them for one user, locked out after five); twenty tokens with leases. One Vault standby lets anyone read its metrics (`unauthenticated_metrics_access`); the others do not. The keys and tokens were made by the run and kept out of the evidence.

- **On Fedora** (Fedora 44, bash 5.3): every job against each cluster's active node and a standby, and what each read (OpenBao or Vault, Shamir 2 of 3, Raft; autopilot healthy, three nodes, one that may be lost; the leases; tokens by auth method; logins that worked and failed, the user locked out; on Vault, the responses refused and those 403). A Vault standby without unauthenticated metrics (the run fails, saying HTTP 307). Then, on each, a node restarted and sealed (`sealed 1`; autopilot unhealthy, the node named, nothing more may be lost), unsealed a key at a time (`unseal_progress 1`, then unsealed, a standby again); the active node stopped (another active within seconds); a token without the policy, no token, nothing listening.: **45 passed, 0 failed**. Then `service-packs.sh` through Vigil: **14 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-openbao/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same clusters through SSH tunnels: the status job against all six nodes, every job against each active node, a token that is not one, nothing listening: **14 passed, 0 failed**; through Vigil, **14 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-openbao-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator: the same, under Windows PowerShell 5.1 and PowerShell 7, with the Vault standby that sends its metrics away: **26 passed, 0 failed**; the same metric names and tags as the Linux scripts for every job against both active nodes, under both shells (16 of 16); through Vigil, **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-openbao-windows/console.txt)).

**What the tests found.** OpenBao kept Vault's names: its metrics start `vault_`, and its pages are Vault's, so one pack reads both, and tells them apart by the `enterprise` field Vault's health page has. A sealed node answers its health and seal pages, but not its metrics (503) or its leader (503): the status job reads only the pages that answer. A Vault standby sends `sys/metrics` to the active node (307) unless the listener lets anyone read them; an OpenBao standby answers with the token. Both drop a counter not updated within `prometheus_retention_time`, so with a short one the running totals come and go. Both count a failed login twice. A node counts its locked-out users when it becomes active and every 15 minutes or so after, so right after a lockout it may still read 0. Autopilot counts a node that has just joined as a voter only once it has been stable a while: right after a cluster forms, `failure_tolerance` reads 0. OpenBao 2.7 enables audit devices only in its configuration file, not through its API.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
