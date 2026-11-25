# The podman pack

Podman, asked with its own command. The pack reads whether Podman can be asked; every container's state (running, paused, stopped, unhealthy); each container by name: whether it runs, how many times it has been restarted, whether its health check passes, the exit code it ended with, and whether it was killed for memory; what each running container uses (CPU, memory against its limit, processes, network and disk); and the disk Podman takes: images, containers and volumes.

Podman has no daemon, so nothing is "down" when a container falls over: there is no one to notice. A container under `--restart=always` that fails at start is, to `podman ps`, simply *running*, and only its restart count says otherwise. One killed for memory leaves an exit code and nothing else. And a rootless account's images fill its home directory, quietly, one build at a time.

**Read-only.** The pack asks Podman to read (`info`, `ps`, `inspect`, `stats`, `system df`, `images`) and changes nothing: no container is started, stopped or removed, and nothing is pruned. It needs `podman` and `jq`.

1. Nothing to turn on: there is no service to start, and the pack does not need `podman.socket`.
2. **Decide whose containers.** Podman keeps containers by account, and Vigil reads those of the account it runs as:
   - **Vigil running as root** reads root's containers (the ones `sudo podman` makes, and quadlets installed for the system).
   - **Vigil running as another account** reads that account's own containers (rootless), and no one else's.

   For rootless containers that should outlive a logon, the account needs lingering: `sudo loginctl enable-linger <account>`. Without it, systemd stops the account's containers, and the timers that run their health checks, when its last session ends.
3. `vigil pack enable podman`. There is nothing to set for the account's own Podman. For another one (a remote Podman, a `podman machine` that is not the default), `env = CONTAINER_HOST=...` on each job, as for the `podman` command.

**A Podman that cannot be reached is a reading**, `up 0`, and the run succeeds: on a Mac that is a `podman machine` that is stopped. A run fails only when Podman answers with an error, and says which.

## What it needs

| | Linux | macOS |
| --- | --- | --- |
| On the Vigil machine | `podman`, `jq` | `podman` and a `podman machine` that runs, `jq` (Homebrew; macOS 15 has it) |
| Podman | 4.0 and later, rootless or as root | the same, in its machine |
| For each container's CPU and memory | cgroup v2 (every current distribution); rootless on cgroup v1, Podman cannot measure them and `podman_resources` says so | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `podman_status` | Podman answering; its version; rootless or not; containers by state (running, paused, stopped, created); unhealthy ones; those that ended with an error; restarts over all of them; pods; images | minute |
| `podman_containers` | Each container by name (the first 100): running or not and its state; restarts; healthy or not; exit code; killed for memory; uptime | minute |
| `podman_resources` | Each running container (the first 100): CPU time, memory and its share of the limit, processes, network and disk bytes | minute |
| `podman_disk` | Images (unused, dangling, reclaimable), what containers wrote in their own layers (the 20 largest), volumes (unused, reclaimable) | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

**A restart loop reads as running.** Docker shows a container between two starts as *restarting*; Podman starts it again at once and shows it as *running*, with an uptime of a second or two. So the reading to alert on is `restarts_count`, rising, and `uptime_seconds` that never grows.

**More than 100 containers?** Each job names the first 100 by name and counts the rest in `containers_not_shown`. `env = PODMAN_MOST=300` names more; the totals (`podman_status`) always count every container.

**CPU is a running total**, `cpu_seconds_count`: the CPU time a container has used since it started. Its rate in your backend is the number of processors it uses (a rate of 0.3 is 30% of one processor).

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `podman.up`.

```text
+--------------------------------------------------------------------------------------------------+
| podman_status   podman.<metric>   every 1m                                                       |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when Podman answers, else 0 (and nothing more is read)                  |
| version              | always 1, tagged version=<Podman's version>, os=<linux> and               |
|                      | rootless=<true or false>                                                  |
| rootless             | 1 when these are an account's own containers (rootless), 0 when they are  |
|                      | root's                                                                    |
| containers           | containers it holds, running or not                                       |
| running              | of those, running                                                         |
| paused               | paused                                                                    |
| exited               | stopped: they ran, and ended                                              |
| created              | created, and never started                                                |
| unhealthy            | running, with a health check that fails                                   |
| health_starting      | running, with a health check that has not passed yet                      |
| exited_nonzero       | stopped with an exit code other than 0                                    |
| restarts_total_count | times a restart policy started a container again, over all of them (a     |
|                      | running total): under Podman a container in a loop reads as running, and  |
|                      | this is what rises                                                        |
| pods                 | pods these containers are in                                              |
| images               | images it holds                                                           |
| cpus                 | processors Podman sees                                                    |
| memory_bytes         | memory Podman sees                                                        |
+----------------------+---------------------------------------------------------------------------+
| GOOD  up 1; unhealthy 0; restarts_total_count flat; exited_nonzero steady (a job that failed     |
|       once stays counted until its container is removed).                                        |
| WATCH health_starting above 0 for minutes: a health check that never passes. running lower than  |
|       it was: something stopped and nothing started it again.                                    |
| BAD   up 0: Podman cannot be asked (on a Mac, its machine is stopped). unhealthy above 0.        |
|       restarts_total_count rising: a container in a restart loop, which Podman shows as running  |
|       (podman_containers names it).                                                              |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| podman_containers   podman.containers.<metric>   every 1m                                        |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Podman answers, else 0 (and nothing more is read)             |
| containers                | containers it holds, running or not                                  |
| containers_unhealthy      | of those named below, with a health check that fails                 |
| containers_oom_killed     | killed for memory: the kernel ended them at their limit              |
| containers_exited_nonzero | stopped with an exit code other than 0                               |
| restarts_total_count      | times a restart policy started them again (a running total, over     |
|                           | those named below)                                                   |
| running                   | 1 when the container runs, 0 when it does not (stopped, paused,      |
|                           | created), tagged name=<the container's name> and state=<its state>   |
| restarts_count            | times its restart policy started it again (a running total), tagged  |
|                           | name=<the container's name>                                          |
| oom_killed                | 1 when it was killed for memory, tagged name=<the container's name>  |
| uptime_seconds            | for one that runs: seconds since it last started, tagged name=<the   |
|                           | container's name>                                                    |
| healthy                   | for one with a health check that has run: 1 healthy, 0 unhealthy,    |
|                           | tagged name=<the container's name>                                   |
| exit_code                 | for one that stopped: its exit code, tagged name=<the container's    |
|                           | name>                                                                |
| ..._not_shown             | past 100 of a list (containers), how many were left out              |
+---------------------------+----------------------------------------------------------------------+
| GOOD  running 1 for every container meant to run; restarts_count flat; healthy 1; oom_killed 0.  |
| WATCH restarts_count rising slowly: a container that falls over now and then. uptime_seconds     |
|       small on a container nobody restarted.                                                     |
| BAD   running 0 on a container meant to run. restarts_count rising on every run: a restart loop. |
|       healthy 0. oom_killed 1: it needs more memory, or leaks it. exit_code other than 0 on a    |
|       job that should have succeeded (137: killed; 139: it crashed; 143: stopped by a signal).   |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| podman_resources   podman.resources.<metric>   every 1m                                          |
+-------------------------+------------------------------------------------------------------------+
| up                      | 1 when Podman answers, else 0 (and nothing more is read)               |
| containers_measured     | running containers measured                                            |
| memory_total_bytes      | memory they use, together                                              |
| memory_fullest_pct      | the fullest of those with a memory limit: its memory, as a share of    |
|                         | its limit                                                              |
| cpu_seconds_count       | CPU time it has used since it started, in seconds (a running total:    |
|                         | its rate is the processors it uses), tagged name=<the container's      |
|                         | name>                                                                  |
| memory_bytes            | memory it uses, without the file cache that can be given back, tagged  |
|                         | name=<the container's name>                                            |
| memory_limit_bytes      | its memory limit, 0 when it has none, tagged name=<the container's     |
|                         | name>                                                                  |
| memory_pct              | for one with a limit: its memory, as a share of it, tagged name=<the   |
|                         | container's name>                                                      |
| pids                    | processes and threads in it, tagged name=<the container's name>        |
| network_rx_bytes_count  | bytes it received, over its networks (a running total), tagged         |
|                         | name=<the container's name>                                            |
| network_tx_bytes_count  | bytes it sent (a running total), tagged name=<the container's name>    |
| block_read_bytes_count  | bytes it read from disk (a running total), tagged name=<the            |
|                         | container's name>                                                      |
| block_write_bytes_count | bytes it wrote to disk (a running total), tagged name=<the container's |
|                         | name>                                                                  |
| ..._not_shown           | past 100 of a list (containers), how many were left out                |
+-------------------------+------------------------------------------------------------------------+
| GOOD  memory_pct well under 100; memory_bytes steady for a container doing steady work.          |
| WATCH memory_bytes climbing run after run with no more work to do: a leak, on its way to the     |
|       limit. pids climbing: processes or threads that are never reaped.                          |
| BAD   memory_fullest_pct above 90: a container about to be killed for memory (memory_pct says    |
|       which). pids near the limit of the machine.                                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| podman_disk   podman.disk.<metric>   every 15m                                                   |
+------------------------------+-------------------------------------------------------------------+
| up                           | 1 when Podman answers, else 0 (and nothing more is read)          |
| images                       | images it holds                                                   |
| images_unused                | of those, used by no container                                    |
| images_dangling              | with no name left: an older build of a tag that moved on          |
| images_bytes                 | disk the images take                                              |
| images_reclaimable_bytes     | of that, what removing the unused ones would give back            |
| containers                   | containers it holds, running or not                               |
| containers_bytes             | disk the containers take: what each wrote in its own layer        |
| containers_reclaimable_bytes | of that, held by containers that are not running                  |
| container_bytes              | what one container wrote in its own layer, the 20 largest, tagged |
|                              | name=<the container's name>                                       |
| volumes                      | volumes it holds                                                  |
| volumes_unused               | of those, used by no container                                    |
| volumes_bytes                | disk the volumes take                                             |
| volumes_reclaimable_bytes    | of that, in volumes no container uses                             |
| ..._not_shown                | past 100 of a list (container_bytes), how many were left out      |
+------------------------------+-------------------------------------------------------------------+
| GOOD  images_bytes and volumes_bytes steady; images_reclaimable_bytes a small share.             |
| WATCH images_dangling or images_reclaimable_bytes growing: builds and pulls that nothing clears. |
|       container_bytes large and growing: a container writing into its own layer what belongs in  |
|       a volume (or logs nobody rotates).                                                         |
| BAD   any of them growing run after run while the base pack shows the disk filling.              |
|       volumes_unused with volumes_reclaimable_bytes large: data left behind by containers that   |
|       are gone, to keep or to remove on purpose.                                                 |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the containers made on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `podman.up` | 1 |  | 0: Podman cannot be asked (on a Mac, its machine is stopped) | `up 0` where nothing listened |
| `podman.containers.running` (by `name`) | 1 for every container meant to run |  | 0 for one meant to run: `state` says what it is instead | 0 with `state=exited` the moment one was stopped, 1 again when it was started |
| `podman.containers.restarts_count` (by `name`) | Flat | Rising now and then | Rising on every run: a restart loop, which Podman shows as running | Rising by about one every two seconds for the container in a loop, `running 1` all the while |
| `podman.restarts_total_count` | Flat |  | Rising: some container is in a loop; `podman_containers` names it | Rising |
| `podman.containers.healthy` (by `name`) | 1 |  | 0: its own health check fails | 0 for the container whose check always fails |
| `podman.containers.oom_killed` (by `name`) | 0 |  | 1: the kernel killed it at its memory limit | 1 for the container that grew past its 16 MB, with `exit_code 137` |
| `podman.containers.exit_code` (by `name`) | 0 for a job that ended well |  | Other than 0 on a job that should have succeeded | 7, 0 and 137, as each ended |
| `podman.resources.memory_fullest_pct` | Well under 100 | Above 80 | Above 90: a container about to be killed for memory; `memory_pct` says which | Under 1, for the one container with a limit |
| `podman.resources.memory_bytes` (by `name`) | Steady for steady work | Climbing run after run: a leak |  | Not caused |
| `podman.disk.images_reclaimable_bytes` | A small share of `images_bytes` | Growing: builds and pulls nothing clears |  | Not caused: one image, in use |
| `podman.disk.container_bytes` (by `name`) | Small | Large and growing: a container writing into its own layer what belongs in a volume |  | 20 MB for the container that wrote 20 MB |
| `podman.disk.volumes_unused` | 0, or what you keep on purpose | Growing: data left by containers that are gone |  | 1: the volume made and never mounted |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-containers.sh podman`, against a real Podman holding eleven small containers and two volumes made for the run, each in a state the pack reads: one running with a 64 MB memory limit and a volume, one healthy, one unhealthy, one in a restart loop, one that ended with code 7, one that ended well, one killed for memory at 16 MB, one paused, one never started, one busy at a CPU limit of 0.3, and one that wrote 20 MB into its own layer. At the end only those are removed.

- **On Fedora, rootless** (Fedora 44, Podman 5.8.9, cgroup v2, crun, bash 5.3), as an ordinary account with containers of its own: every job and what each must have read; the restart loop watched rising; a container stopped (`running 0`, its exit code, no longer measured) and started again; the number of containers named cut to three, the rest counted; nothing answering (`up 0`, the run succeeding): **32 passed, 0 failed**. Then `service-packs.sh` through Vigil (enable, and that the machine's CPU and memory are the base pack's; precheck; every job; a Podman that cannot be reached read as `up 0`; each container's readings reaching the backend): **13 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-podman/console.txt)).
- **On Fedora, as root** (the same machine and Podman, `rootless=false`): the same containers, made as root, and the same checks: **32 passed, 0 failed**; through Vigil, **13 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-podman-root/console.txt)). Root's containers and the account's own were on the machine at different times, and each run read only its own.
- **Not tested yet: macOS.** On the Intel Mac test machine (macOS 12.7.6, Podman 5.1.2 from MacPorts), `podman machine init` worked but `podman machine start` could not: it needs `vfkit`, the helper that starts the machine with Apple's Virtualization framework, and none was installed. The pack's macOS scripts are the Linux ones, and only ask the `podman` command, but until they have run against a machine that starts, this page does not claim them.

**What the tests found.** Under `--restart=always`, Podman starts a failing container again at once, with no growing wait, and shows it as *running* the whole time: in a probe before these runs, ours restarted 387 times in eight minutes while `podman ps` showed it as up. `restarts_count` is the only reading that tells.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
