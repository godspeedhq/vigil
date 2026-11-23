# The beam pack

Erlang and Elixir virtual machines, the BEAM, and any application that runs on one: RabbitMQ, CouchDB, ejabberd, EMQX, a Phoenix app, your own release. The pack reads the VM as the OS sees it, the nodes epmd knows, the VM's own figures (memory by kind, processes, ports, atoms and ETS tables against their limits, run queues, garbage collection), what runs inside it (the longest mailboxes, the largest processes and ETS tables), its peers in a cluster, its applications, and the crash dumps a VM leaves when it dies. It reports the VM's, never the application's: a RabbitMQ queue's depth is for a pack of its own. Linux, macOS and Windows.

**No Java, no agent, nothing to install in the VM.** The pack is shell and PowerShell, and one Erlang script (`_beam.escript`) for the tier that needs the cookie. Each tier is used where it reaches, and each works without the others:

| Tier | What it reads | What it needs |
| --- | --- | --- |
| **The process** (`beam_process`, `beam_crashdumps`) | Every VM on this machine: memory, CPU, threads, open files, uptime, named by its node name; the crash dumps VMs left, and why each died | Nothing |
| **epmd** (`beam_epmd`) | The nodes epmd knows, on this machine or another, and their ports: epmd's own protocol, spoken by the script | Nothing (no cookie) |
| **Prometheus** (`beam_vm`) | The VM's own figures, from a node's `/metrics` page as RabbitMQ and `prometheus.erl` give it (`erlang_vm_*`) | The page; `curl` (Linux, macOS) |
| **The cookie** (`beam_vm`, `beam_processes`, `beam_tables`, `beam_dist`, `beam_apps`) | All of the VM's figures, and what runs inside it, from the node itself | The node's cookie, and Erlang/OTP 25 or later on the Vigil machine |

`beam_vm` reads a node either way, Prometheus or the cookie, and gives the same metrics, tagged `source=prometheus` or `source=dist`: a RabbitMQ node needs no cookie for them.

> [!WARNING]
> **The cookie lets whoever holds it run anything on the node.** Erlang has no read-only login: a node trusts any node with its cookie completely. This pack never changes anything: it only reads. `_beam.escript` joins as a hidden node that never listens (`-dist_listen false`: the nodes never list it, nothing can connect to it, and it needs no epmd here), and every call it makes is one of these, listed at its top: `erlang:memory/0`, `erlang:system_info/1`, `erlang:statistics/1`, `erlang:processes/0`, `erlang:process_info/2`, `erlang:port_info/2`, `erlang:nodes/1`, `ets:all/0`, `ets:info/1`, `proc_lib:translate_initial_call/1` and `application:which_applications/0`. It never calls `erlang:system_flag/2`, so figures that need a switch turned on first (scheduler utilisation, for one) are not read. Read the script before you give Vigil the cookie, and give it only if you accept what the cookie allows. Without the cookie, the process, epmd and Prometheus tiers still work.

1. `vigil pack enable beam`. The process, epmd and crash dump jobs work at once, on this machine.
2. **For Prometheus**, in `vigil.config` set `beam_vm`'s `BEAM_PROMETHEUS` to each node's page, a name, then its address: `rabbit1=http://127.0.0.1:15692/metrics; rabbit2=http://db2:15692/metrics`. RabbitMQ serves it with its `rabbitmq_prometheus` plugin, on by default; an Elixir or Erlang app with `prometheus.erl` (or `prometheus_ex`) and its default collectors serves the same names.
3. **For the cookie**, set `BEAM_DIST` on the jobs that read it (`beam_vm`, `beam_processes`, `beam_tables`, `beam_dist`, `beam_apps`) to each node, a name, then its node name, exactly as the node has it (names are case-sensitive; `beam_process` shows each VM's): `rabbit1=rabbit@db1; shop=shop@app1.example.com`. Erlang must be on the Vigil machine: `BEAM_ERLANG` where it is (`/usr/lib/erlang`, `C:\Program Files\Erlang OTP`), or `escript` on the PATH. Then add a secret line to each of those jobs, under its `env` lines, and the cookie:

   ```ini
   secret = BEAM_COOKIE=secret:BEAM_COOKIE
   ```

   ```sh
   vigil secret set BEAM_COOKIE
   ```

   The cookie reaches `_beam.escript` from Vigil's secrets, in its environment: never on a command line, never in a file. Erlang writes a cookie file into its home when it has none, so each run gives it a home of its own, deleted when the run ends: nothing is written into Vigil's. The nodes must be reachable from the Vigil machine on epmd's port (4369) and their distribution ports.
4. **For epmd on other machines**, set `beam_epmd`'s `BEAM_EPMD` to them, `host` or `host:port`, separated by spaces: `db1 db2 db3`.
5. **For crash dumps elsewhere**, set `beam_crashdumps`'s `BEAM_CRASH_DUMPS` to the folders or files, separated by `;`. Without it the pack looks where VMs write them: the folder each running VM was started in, and where its `ERL_CRASH_DUMP` points (Linux, as root or the VM's account; macOS, its folder only), and RabbitMQ's log folders.

**A wrong cookie fails the run, saying so**: the node is listed by epmd but refused the connection, because the cookie is not its cookie, or the node name is not exactly its own. A node that does not answer is a reading, `up 0`, and the run succeeds.

**`cookie_on_command_line` is a finding of its own.** A VM started with `-setcookie` shows its cookie to every account on the machine (`ps` shows it). The pack reads only whether it is there, never its value: give the VM a `.erlang.cookie` file readable by its own account only, or an `-args_file` that is.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| The process tier | Nothing (another account's open files: root) | `lsof`, for open files | Nothing (another account's command lines: an administrator; without them, each VM is named by its process id) |
| epmd | Nothing: bash's `/dev/tcp` | The same | Nothing: .NET's `TcpClient` |
| Prometheus | `curl` | `curl` | Nothing: `Invoke-WebRequest` |
| The cookie | Erlang/OTP 25 or later (`escript`), the secret `BEAM_COOKIE` | The same | The same (`escript.exe`; the Windows zip of Erlang/OTP needs no installer) |
| The VMs | Erlang/OTP 25 or later; the cookie tier reads older ones as far as their calls allow | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `beam_process` | Every VM on this machine, as the OS sees it: memory, CPU, threads, open files against the limit, uptime, the runtime's version, and whether its cookie is on its command line | minute |
| `beam_epmd` | Whether epmd answers on each machine, and the nodes it knows with their ports | minute |
| `beam_vm` | Each node's memory by kind (processes, binaries, code, ETS, atoms), processes, ports, atoms and ETS tables against their limits, run queues (dirty ones too), reductions, garbage collection, context switches, bytes in and out; its version and uptime with the cookie | minute |
| `beam_processes` | Inside each node (the cookie): messages waiting in all mailboxes, those over 1,000, and the ten longest mailboxes, the ten largest and the ten busiest processes, each by name | 5 minutes |
| `beam_tables` | Inside each node (the cookie): its ETS tables, their objects and memory, and the ten largest and fullest, with the process that owns each | 5 minutes |
| `beam_dist` | Each node's peers (the cluster) and hidden peers (tools, remote shells), the bytes waiting for each, and the limit at which senders wait | minute |
| `beam_apps` | The applications each node runs, and their versions | hour |
| `beam_crashdumps` | The crash dumps VMs left, newest first: when, which node, and why it died (its slogan) | 15 minutes |

A process is named by its registered name, else by what it runs: a gen_server by its module (not `proc_lib`), a fun by the first function of its stack in its own code (`trouble:cache/1`, not `timer:sleep/1`). Past 20,000 processes on a node, `beam_processes` reads the first 20,000 and counts the rest; past 100 of anything else (VMs, nodes, peers, applications), the rest are counted in a `_not_shown` line.


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `beam.process.beams`.

```text
+--------------------------------------------------------------------------------------------------+
| beam_process   beam.process.<metric>   every 1m                                                  |
+------------------------+-------------------------------------------------------------------------+
| beams                  | the Erlang VMs running on this machine                                  |
| running                | always 1, tagged node=<its node name, else its -s module, else pid<n>>  |
|                        | and erts=<the runtime's version, 16.1.2>                                |
| rss_bytes              | memory it holds (resident), tagged node=<the same>                      |
| cpu_seconds            | CPU time it has used, user and system                                   |
| threads                | its threads (schedulers, dirty schedulers, async and others)            |
| open_files             | files and sockets it has open (root, or its own account)                |
| open_files_max         | the most it may have open (its soft limit)                              |
| uptime_seconds         | how long it has run                                                     |
| cookie_on_command_line | 1 when -setcookie is on its command line, which every account here can  |
|                        | read, else 0                                                            |
| ..._not_shown          | past 100 of a list (beams), how many were left out                      |
+------------------------+-------------------------------------------------------------------------+
| GOOD  beams as many as you run; rss_bytes steady over days; open_files well below                |
|       open_files_max; uptime_seconds rising.                                                     |
| WATCH rss_bytes climbing for hours without falling back; open_files past 70% of open_files_max;  |
|       cookie_on_command_line 1: any account here can read the cookie (use ~/.erlang.cookie, or   |
|       -args_file with a file only its account reads).                                            |
| BAD   beams lower than you run: a VM is gone (beam.crashdumps says why); uptime_seconds back     |
|       near 0: it restarted; open_files past 90% of open_files_max: it is about to refuse         |
|       connections.                                                                               |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_epmd   beam.epmd.<metric>   every 1m                                                        |
+---------------+----------------------------------------------------------------------------------+
| epmd_up       | 1 when epmd answers, else 0, tagged host=<host:port>                             |
| nodes         | the nodes it has, tagged host=<the same>                                         |
| node          | always 1, tagged host=<the same>, name=<the node's name> and port=<its           |
|               | distribution port>                                                               |
| ..._not_shown | past 100 of a list (nodes), how many were left out                               |
+---------------+----------------------------------------------------------------------------------+
| GOOD  epmd_up 1; nodes as many as you run, each with its usual name.                             |
| WATCH a node with a name you do not know: something else on the machine runs Erlang distribution |
|       (rabbitmqcli-... and vigil_... nodes come and go: tools connecting).                       |
| BAD   epmd_up 0 where nodes run: no node can find another, so a cluster cannot form again; a     |
|       node you run missing from it: it stopped, or cannot register.                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_vm   beam.vm.<metric>   every 1m                                                            |
+------------------------+-------------------------------------------------------------------------+
| nodes                  | the nodes named in BEAM_PROMETHEUS and BEAM_DIST                        |
| up                     | 1 when the node answers, else 0, tagged node=<its name> and             |
|                        | source=<prometheus or dist>                                             |
| version                | always 1, tagged the same, otp=<its release> and erts=<its runtime's    |
|                        | version> (dist only)                                                    |
| memory_bytes           | memory it has allocated, tagged the same and kind=<total, processes,    |
|                        | system, atom, binary, code or ets>                                      |
| processes              | its processes (Erlang's, not the OS's)                                  |
| process_limit          | the most it may have (+P)                                               |
| process_pct            | processes, as a percentage of process_limit                             |
| ports                  | its ports: sockets, files and drivers open                              |
| port_limit             | the most it may have (+Q)                                               |
| port_pct               | ports, as a percentage of port_limit                                    |
| atoms                  | its atoms, which are never freed                                        |
| atom_limit             | the most it may have (+t): past it, the VM dies                         |
| atom_pct               | atoms, as a percentage of atom_limit                                    |
| ets_tables             | its ETS tables                                                          |
| ets_limit              | the most it may have                                                    |
| ets_pct                | ets_tables, as a percentage of ets_limit                                |
| schedulers_online      | schedulers running Erlang code                                          |
| run_queue              | processes and ports ready to run, waiting for a scheduler               |
| dirty_cpu_run_queue    | work waiting for a dirty CPU scheduler (NIFs)                           |
| dirty_io_run_queue     | work waiting for a dirty I/O scheduler (files)                          |
| reductions_count       | reductions, its unit of work (a running total)                          |
| gcs_count              | garbage collections (a running total)                                   |
| gc_reclaimed_bytes     | memory they reclaimed (a running total)                                 |
| context_switches_count | process switches (a running total)                                      |
| received_bytes         | bytes its ports received (a running total)                              |
| sent_bytes             | bytes its ports sent (a running total)                                  |
| uptime_seconds         | how long it has run (dist only)                                         |
+------------------------+-------------------------------------------------------------------------+
| GOOD  up 1; process_pct, port_pct, atom_pct and ets_pct low and flat; run_queue near 0 most of   |
|       the time; memory_bytes of kind total steady once warmed up.                                |
| WATCH atom_pct rising and never falling: something makes atoms from input (list_to_atom), and    |
|       atoms are never freed; process_pct or ets_pct climbing: a leak; run_queue above            |
|       schedulers_online for minutes: the VM is short of CPU; kind=binary climbing: large         |
|       binaries held on to (a process keeps a reference).                                         |
| BAD   up 0; atom_pct past 80: at 100 the VM dies; process_pct or port_pct past 80: at 100        |
|       nothing new can start, connections are refused; memory_bytes total near the machine's      |
|       memory.                                                                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_processes   beam.processes.<metric>   cron 2/5 * * * *                                      |
+--------------------------+-----------------------------------------------------------------------+
| nodes                    | the nodes named in BEAM_DIST                                          |
| up                       | 1 when the node answers, else 0, tagged node=<its name> and           |
|                          | source=dist                                                           |
| processes_read           | the processes read                                                    |
| processes_not_read       | past 20,000, the processes left out                                   |
| mailbox_messages         | messages waiting, in every mailbox read                               |
| mailboxes_over_1000      | processes with more than 1,000 waiting                                |
| mailbox                  | messages waiting for one of the ten longest mailboxes, tagged         |
|                          | node=<its name>, source=dist and process=<its name>                   |
| process_memory_bytes     | memory of one of the ten largest processes (its heap, stack and       |
|                          | mailbox), tagged the same                                             |
| process_reductions_count | work done by one of the ten busiest, since it started (a running      |
|                          | total), tagged the same                                               |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  mailbox_messages near 0; mailboxes_over_1000 0; the largest processes the same ones, at    |
|       about the same size, run to run.                                                           |
| WATCH a mailbox growing run after run: that process takes messages in faster than it handles     |
|       them; one process_memory_bytes climbing: it holds on to state, or to large binaries.       |
| BAD   mailboxes_over_1000 above 0 and rising: a process is falling behind, and its memory grows  |
|       with its mailbox until the VM runs out; the busiest is the same process every run, far     |
|       ahead of the rest: a hot spot.                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_tables   beam.tables.<metric>   cron 3/5 * * * *                                            |
+--------------------+-----------------------------------------------------------------------------+
| nodes              | the nodes named in BEAM_DIST                                                |
| up                 | 1 when the node answers, else 0, tagged node=<its name> and source=dist     |
| tables             | its ETS tables                                                              |
| objects            | the objects in them all                                                     |
| memory_bytes       | the memory they all hold                                                    |
| table_memory_bytes | memory one of the ten largest holds, tagged node=<its name>, source=dist,   |
|                    | table=<its name, with (unnamed) when it is not a named table> and           |
|                    | owner=<the process that owns it>                                            |
| table_objects      | objects one of the ten fullest holds, tagged the same                       |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  tables steady; the largest tables the same ones, at a size your data explains.             |
| WATCH one table_objects rising and never falling: a cache with no eviction, or entries never     |
|       deleted.                                                                                   |
| BAD   memory_bytes a large share of beam.vm memory_bytes total and climbing: a table will take   |
|       the VM's memory; tables rising run after run: tables made and never deleted (beam.vm       |
|       ets_pct shows how near the limit).                                                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_dist   beam.dist.<metric>   every 1m                                                        |
+------------------+-------------------------------------------------------------------------------+
| nodes            | the nodes named in BEAM_DIST                                                  |
| up               | 1 when the node answers, else 0, tagged node=<its name> and source=dist       |
| peers            | the nodes it is connected to, as a cluster                                    |
| hidden_peers     | hidden nodes connected to it (remote shells, tools)                           |
| peer             | always 1, tagged node=<its name>, source=dist, peer=<the peer's node> and     |
|                  | hidden=<true or false>                                                        |
| peer_queue_bytes | bytes waiting to be sent to that peer, tagged the same (TCP distribution; not |
|                  | over TLS)                                                                     |
| busy_limit_bytes | the queue at which a peer's sender is made to wait (+zdbbl)                   |
| ..._not_shown    | past 100 of a list (peers), how many were left out                            |
+------------------+-------------------------------------------------------------------------------+
| GOOD  peers as many as the cluster's other nodes; peer_queue_bytes near 0.                       |
| WATCH hidden_peers you do not expect: someone has a remote shell on the node, or a tool holds    |
|       the cookie.                                                                                |
| BAD   peers lower than the cluster's other nodes: a node is down or cut off (a partition);       |
|       peer_queue_bytes near busy_limit_bytes: the link to that peer is the bottleneck, and its   |
|       senders wait.                                                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_apps   beam.apps.<metric>   cron 11 * * * *                                                 |
+---------------+----------------------------------------------------------------------------------+
| nodes         | the nodes named in BEAM_DIST                                                     |
| up            | 1 when the node answers, else 0, tagged node=<its name> and source=dist          |
| apps          | the applications it runs                                                         |
| app           | always 1, tagged node=<its name>, source=dist, app=<the application> and         |
|               | version=<its version>                                                            |
| ..._not_shown | past 100 of a list (apps), how many were left out                                |
+---------------+----------------------------------------------------------------------------------+
| GOOD  apps the same, run to run, with the versions you deployed.                                 |
| WATCH a version you did not deploy: something was upgraded in place, or a node runs an older     |
|       release than the others.                                                                   |
| BAD   apps lower than usual: an application stopped (one that is not permanent stops alone, and  |
|       the node carries on without it).                                                           |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| beam_crashdumps   beam.crashdumps.<metric>   cron 4/15 * * * *                                   |
+--------------------+-----------------------------------------------------------------------------+
| dumps              | the crash dumps found                                                       |
| dump               | always 1, tagged file=<its path>, node=<the node that died, when the dump   |
|                    | names it> and slogan=<why it died>                                          |
| age_seconds        | how long ago it was written, tagged file=<the same>                         |
| newest_age_seconds | how long ago the newest was written                                         |
| ..._not_shown      | past 100 of a list (dumps), how many were left out                          |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  dumps 0, or only old ones you have read and kept.                                          |
| WATCH newest_age_seconds under a day: a VM died since yesterday; read its slogan, then move or   |
|       delete the dump (one dump file, erl_crash.dump, is overwritten by the next).               |
| BAD   newest_age_seconds under an hour: a VM died just now. Its slogan says why: "Cannot         |
|       allocate": out of memory (beam.vm memory_bytes); "no more index entries in atom_tab": the  |
|       atom limit (beam.vm atom_pct); "Kernel pid terminated": an application it could not run    |
|       without stopped.                                                                           |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what four nodes in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `beam.vm.up`, `beam.epmd.epmd_up` | 1 | | 0: the node, or epmd, is down; a wrong cookie fails the run instead, saying so | 0 for a node that was not there, and for an epmd port where nothing listened |
| `beam.process.beams` | As many as you run | | Fewer: a VM is gone (`beam.crashdumps` says why) | 5 on Fedora: the four nodes and RabbitMQ, RabbitMQ named `rabbit` by its `-s` module |
| `beam.vm.atom_pct` | Low and flat | Rising and never falling: atoms made from input, never freed | Past 80: at 100 the VM dies | 1.2 on Erlang/OTP 28, rising 20 a second; a VM given 20,000 atoms died of it (below) |
| `beam.vm.process_pct`, `port_pct`, `ets_pct` | Low and flat | Climbing: a leak | Past 80: at 100 nothing new starts | 591 processes and climbing, 5 more a second, far below the limit of 1,048,576 |
| `beam.processes.mailboxes_over_1000`; `mailbox` | 0; near 0 | A mailbox growing run after run | Above 0 and rising: a process falling behind, its memory growing with its mailbox | 1, `slow_consumer`, with 5,316 messages after two minutes, the longest mailbox on every node |
| `beam.tables.table_objects`, `table_memory_bytes` | Steady, the same tables | One rising and never falling: a cache that never evicts | A large share of `beam.vm.memory_bytes` total, climbing | `leaky_cache`, 10,480 objects in 2.3 MB, owned by `trouble:cache/1`, the largest table on every node |
| `beam.vm.memory_bytes` `kind=binary` | Steady | Climbing: binaries held on to | Near the machine's memory | 14.2 MB of a 49.5 MB VM, held by `hoarder` |
| `beam.vm.run_queue` against `schedulers_online` | Near 0 | Above `schedulers_online` for minutes: short of CPU | | 1 of 4: the busy loop, `spinner`, the busiest process by far (15 billion reductions) |
| `beam.process.cookie_on_command_line` | 0 | 1: every account here can read the cookie | | 1 for the two nodes started with `-setcookie`, 0 for the two reading `.erlang.cookie` and for RabbitMQ |
| `beam.crashdumps.newest_age_seconds` | No dumps, or old ones you have read | Under a day | Under an hour: a VM died just now; its `slogan` says why | 2 dumps, 129 seconds old: `no more index entries in atom_tab (max=20000)` and `eheap_alloc: Cannot allocate 41262936 bytes of memory (of type "heap")` |
| `beam.dist.peers` | As many as the cluster's other nodes | Hidden peers you do not expect | Fewer: a node down or cut off | 0: the nodes ran alone (a cluster is for RabbitMQ's own pack to test) |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-beam.sh`, against **Erlang/OTP 25, 26, 27 and 28**, each a node in Docker on the machine's own network (one epmd for them all) running `workloads/beam/trouble.erl`: a mailbox nobody reads, a cache that never evicts, atoms and processes leaking, a process holding binaries, a busy loop. Two take their cookie on their command lines, two from `.erlang.cookie`. Beside them, **RabbitMQ 4.2** for its Prometheus page, and two VMs that died on purpose first for their crash dumps: one of atoms (`+t 20000`), one of memory (`ulimit -v`). The cookie tier ran with each image's own `escript`, 28's then 25's, in a container on the machine's network, the cookie passed in by name.
- **On Fedora**: every job directly, each reading checked on all four nodes, the escript of Erlang/OTP 25 reading them all too, a wrong cookie failing the run and saying so, a node and an epmd that are not there read as 0; then `service-packs.sh` through Vigil (enable and its warning, the secret line on the five jobs that read the cookie, every job, a wrong cookie failing the run, a node that is down read as `up 0`, the cookie written nowhere, no cookie file written into the home, no run's home left behind): **74 passed, 0 failed**, and through Vigil **37 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-beam/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2), with Erlang/OTP 28 from [erlef/otp_builds](https://github.com/erlef/otp_builds) and RabbitMQ 4.4.1's generic Unix build, a node in trouble, RabbitMQ and a dump, all on the Mac: every job, **26 passed, 0 failed**; through Vigil, **31 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-beam-macos/console.txt)).
- **On Windows**, on Windows 11 as an account that is not an administrator, with Erlang/OTP 28.5's Windows zip and RabbitMQ 4.4.1's, a node in trouble, RabbitMQ and a dump, all on the machine: `Service-Packs.ps1` through Vigil, **29 passed, 0 failed** on Windows PowerShell 5.1 and on PowerShell 7 ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-beam-windows/console.txt)). The cookie came from an `env:` reference: Windows refuses its data protection to a logon by SSH key, as the test machine's was. Windows refused the command lines to that logon too (CIM), so `beam_process` named each VM by its process id, as it says it will. And on Windows Server 2025, on Windows PowerShell 5.1, the same: **29 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-beam-windows/console.txt)).

Erlang's Windows zip needs the Visual C++ runtime, which its installer brings and the zip does not: without it, `erl.exe` and `escript.exe` do not start (`0xC0000135`, a DLL not found). Install it as an administrator (`vc_redist.exe`, in the zip), or, without one, put its three files (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`) beside `erl.exe`, in Erlang's `bin` and `erts-<version>\bin`, as Microsoft allows: the Server 2025 test machine ran so.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
