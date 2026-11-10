# Vigil packs

A pack is a set of scripts and jobs that gives a machine useful metrics straight away. `vigil init` turns on the base pack, and `vigil pack` manages them after that. [SPECIFICATION.md](../SPECIFICATION.md), section 18.10, has the full format.

## What's here

```text
packs/<name>/pack.config    the pack's version, jobs and metrics
packs/<name>/linux/         scripts for Linux
packs/<name>/macos/         scripts for macOS
packs/<name>/windows/       scripts for Windows
```

Each release carries the packs, signed with it, and a machine only ever holds its own platform's scripts.

## The base pack

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `base_cpu` | CPU in use | Yes | Yes | Yes |
| `base_memory` | Memory in use | Yes | Yes | Yes |
| `base_disk` | Space used per file system | Yes | Yes | Yes |
| `base_network` | Bytes moved per interface | Yes | Yes | Yes |
| `base_load` | Load averages | Yes | Yes | No |
| `base_services` | Failed services | Yes | Yes | Yes |

On Windows the scripts read the kernel, .NET and the service manager, not WMI, so they work when Vigil runs as a standard user started over SSH, where WMI refuses. One thing cannot: there, the service manager refuses to list services too, so `base_services` fails and says so. Run Vigil as a service (`--system`), or from a desktop logon, to have it.

## Reading the results

These are starting points, not rules: tune them to what's normal on each machine. Each script's header has the same guide, with an example of its output.

| Metric | Healthy | Watch | Act |
| --- | --- | --- | --- |
| `system.cpu.used_pct` | Below 70 | 70 to 90 for 15 minutes or more | Above 90 for 5 minutes or more |
| `system.memory.used_pct` | Below 80 | 80 to 90, or climbing steadily | Above 90 for 5 minutes or more |
| `system.disk.used_pct` | Below 80 | 80 to 90, or growing fast | Above 90 |
| `system.network.rx_bytes`, `tx_bytes` (as a rate) | Well below the link speed | Above 70 percent of the link speed for 15 minutes or more | Close to the link speed, or no traffic where there should be some |
| `system.load.load1`, `load5`, `load15` | Below the number of cores | 1 to 2 times the cores for 15 minutes or more | Above 2 times the cores for 5 minutes or more |
| `system.services.failed` | 0, or your usual number on macOS and Windows | Higher than usual on macOS | 1 or more on Linux, or still rising elsewhere |

## Service packs

For what a server runs. They are off until you turn one on: `vigil init` never enables them, and nothing touches a database or a web server uninvited.

### postgres

A PostgreSQL server on this machine, through PostgreSQL's own client tools (`psql`, `pg_isready`), which a database server has. It logs in as a read-only role, never a superuser.

1. Create the role once, as a database administrator:

   ```sql
   CREATE ROLE vigil_monitor LOGIN PASSWORD '...' IN ROLE pg_monitor;
   ```

2. Give Vigil its password: `vigil secret set POSTGRES_MONITOR_PASSWORD`. The job reads it with a `secret:` reference when it runs; it is never in the configuration.
3. `vigil pack enable postgres`. It says what is still missing, such as the secret, and the settings the jobs use: they connect to `localhost:5432`, database `postgres`; for anything else, edit their `env` lines in `vigil.config`. `vigil pack list` says the same later.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `postgres_status` | Up, connections and the limit, the longest query and transaction, commits, rollbacks, deadlocks, cache hits | Yes | Yes | Yes |
| `postgres_size` | Each database's size | Yes | Yes | Yes |

A server that does not answer reports `postgres.up` 0, and the run succeeds: that is a reading. A refused login fails the run, and its log says why.

### nginx

An nginx server on this machine, from its `stub_status` page, which you turn on once, reachable from this machine only:

```nginx
location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
```

Then `vigil pack enable nginx`, which reminds you of the page. The job reads `http://127.0.0.1/nginx_status`; for another address, edit its `env` line.

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `nginx_status` | Up, connections (active, reading, writing, waiting), accepted, handled and dropped connections, requests | Yes | Yes | No |

| Metric | Healthy | Watch | Act |
| --- | --- | --- | --- |
| `postgres.up`, `nginx.up` | 1 | | 0 |
| `postgres.connections_pct` | Below 70 | 70 to 90 | Above 90: new connections will soon be refused |
| `postgres.longest_transaction_seconds` | Seconds | Minutes: it holds back vacuum | Growing, on a busy database |
| `postgres.cache_hit_pct` | Above 99, on a busy database | Falling | Well below your usual |
| `postgres.deadlocks_count` (as a rate) | 0 | Any | Rising |
| `nginx.dropped_count` (as a rate) | 0 | Any | Rising: nginx is turning connections away |

## Writing a pack

`tools/new-pack.sh <name>` starts one, and `tools/check-pack.sh --run <name>` says what is left to fix. [CONTRIBUTING.md](../CONTRIBUTING.md#your-first-pack) has the steps. In short:

- Use only what ships with the operating system: bash 3.2 and PowerShell 5.1.
- Print metrics as `metric <name> <value> [key=value ...]`, and use plain ASCII.
- Exit 0 when the script worked. A high reading is not a failure.
- Read data; never change the machine.
- Start with the same header as the other scripts: what it does, its metrics, an example of its output, what healthy and unhealthy look like, what it needs, its exit codes and the disclaimer.

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../LICENSE) gives the full terms, and it takes precedence over this summary.
