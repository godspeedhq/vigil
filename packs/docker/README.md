# The docker pack

A Docker engine, from its own API. The pack reads whether the engine answers; every container's state (running, paused, restarting, stopped, unhealthy); each container by name: whether it runs, how many times it has been restarted, whether its health check passes, the exit code it ended with, and whether it was killed for memory; what each running container uses (CPU, memory against its limit, processes, network and disk); and the disk the engine itself takes: images, containers, volumes and the build cache.

Docker restarts what falls over, and that is exactly why trouble hides in it. A container in a restart loop is "up" most of the times you look. One killed for memory comes back a second later with a clean log. And the disk under `/var/lib/docker` fills one forgotten image at a time, until every container on the machine stops at once.

**Read-only: every request is a GET.** The pack reads the engine's API and changes nothing: no container is started, stopped or removed, and nothing is pruned. It needs `curl` and `jq` on Linux and macOS, and nothing but PowerShell on Windows.

1. Nothing to turn on in Docker: the engine serves its API on a socket of this machine already (`/var/run/docker.sock`; on Windows the pipe `docker_engine`).
2. **An account that may use the engine.** The account Vigil runs as must be allowed to use that socket:
   - **Linux:** root, or a member of the `docker` group (`sudo usermod -aG docker <account>`, then a new logon).
   - **Windows:** an administrator, or a member of the group the engine names in `C:\ProgramData\docker\config\daemon.json` (`"group": "docker-users"`). Docker Desktop makes `docker-users` for you.
   - **macOS:** the account Docker Desktop (or Colima, or Lima) runs under.

   **That is as good as root on the machine**, as it is for anyone who can run `docker`: the pack only reads, but the socket would let its account do anything. If that is more than you want to give, run the pack's jobs as an account of their own.
3. `vigil pack enable docker`, then in `vigil.config` set `DOCKER_HOST` where the engine is not at the default: `env = DOCKER_HOST=unix:///run/user/1000/docker.sock` for a rootless engine, `unix:///Users/<you>/.colima/default/docker.sock` for Colima.

**An engine that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (the account may not use the socket, or what answers is not a Docker engine), and says why.

The pack reads the engine on its own machine. For a fleet, install it on each machine.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl` 7.40 or later, `jq` | `curl` (built in), `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or later, and .NET |
| Docker | Engine 20.10 and later (API 1.41) | Docker Desktop, Colima or Lima | Docker's engine on Windows Server (Windows containers), or Docker Desktop |
| Its address | `DOCKER_HOST`, default `unix:///var/run/docker.sock` | the same, else `~/.docker/run/docker.sock` | `DOCKER_HOST`, default `npipe:////./pipe/docker_engine` |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `docker_status` | The engine up; its version; containers by state (running, paused, restarting, stopped, created, dead); unhealthy ones; those that ended with an error; images | minute |
| `docker_containers` | Each container by name (the first 100): running or not and its state; restarts; healthy or not; exit code; killed for memory; uptime | minute |
| `docker_resources` | Each running container (the first 100): CPU time, time held back at its CPU limit, memory and its share of the limit, processes, network and disk bytes | minute |
| `docker_disk` | Images (unused, dangling, reclaimable), what containers wrote in their own layers (the 20 largest), volumes (unused, the 20 largest), the build cache | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

**More than 100 containers?** Each job names the first 100 by name and counts the rest in `containers_not_shown`. `env = DOCKER_MOST=300` names more; the totals (`docker_status`) always count every container.

**CPU is a running total**, `cpu_seconds_count`: the CPU time a container has used since it started. Its rate in your backend is the number of processors it uses (a rate of 0.3 is 30% of one processor). A job keeps nothing between runs, so it reads a total and leaves the rate to the backend, which is good at it.

**On Windows containers**, a few readings have nothing behind them and stay 0: `oom_killed`, the CPU throttling ones and `memory_limit_bytes`. Memory is the container's private working set.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `docker.up`.

```text
+--------------------------------------------------------------------------------------------------+
| docker_status   docker.<metric>   every 1m                                                       |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when the engine answers, else 0 (and nothing more is read)                   |
| version         | always 1, tagged version=<the engine's version>, api=<its API's version> and   |
|                 | os=<linux or windows: the containers it runs>                                  |
| containers      | containers it holds, running or not                                            |
| running         | of those, running                                                              |
| paused          | paused                                                                         |
| restarting      | between two starts: the container stopped, and its restart policy is starting  |
|                 | it again. One that stays here is in a loop                                     |
| exited          | stopped: they ran, and ended                                                   |
| created         | created, and never started                                                     |
| dead            | that the engine could not remove                                               |
| unhealthy       | running, with a health check that fails                                        |
| health_starting | running, with a health check that has not passed yet                           |
| exited_nonzero  | stopped with an exit code other than 0                                         |
| images          | images it holds                                                                |
| cpus            | processors the engine sees                                                     |
| memory_bytes    | memory the engine sees                                                         |
| warnings        | what the engine warns about itself (docker info prints them)                   |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  up 1; unhealthy 0; restarting 0; exited_nonzero steady (a job that failed once stays       |
|       counted until its container is removed).                                                   |
| WATCH health_starting above 0 for minutes: a health check that never passes. running lower than  |
|       it was: something stopped and nothing started it again.                                    |
| BAD   up 0: the engine is down, and so is every container without live restore. unhealthy above  |
|       0. restarting above 0 on two runs in a row: a container in a restart loop                  |
|       (docker_containers names it, by restarts_count rising).                                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| docker_containers   docker.containers.<metric>   every 1m                                        |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when the engine answers, else 0 (and nothing more is read)         |
| containers                | containers it holds, running or not                                  |
| containers_restarting     | of those named below, between two starts                             |
| containers_unhealthy      | of those named below, with a health check that fails                 |
| containers_oom_killed     | killed for memory: the kernel ended them at their limit              |
| containers_exited_nonzero | stopped with an exit code other than 0                               |
| restarts_total_count      | times a restart policy started them again (a running total, over     |
|                           | those named below)                                                   |
| running                   | 1 when the container runs, 0 when it does not (stopped, paused,      |
|                           | created, between two starts), tagged name=<the container's name> and |
|                           | state=<its state>                                                    |
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
| docker_resources   docker.resources.<metric>   every 1m                                          |
+-----------------------------+--------------------------------------------------------------------+
| up                          | 1 when the engine answers, else 0 (and nothing more is read)       |
| containers_measured         | running containers measured                                        |
| memory_total_bytes          | memory they use, together                                          |
| memory_fullest_pct          | the fullest of those with a memory limit: its memory, as a share   |
|                             | of its limit                                                       |
| cpu_throttled_containers    | containers held back at their CPU limit at least once since they   |
|                             | started                                                            |
| cpu_seconds_count           | CPU time it has used since it started, in seconds (a running       |
|                             | total: its rate is the processors it uses), tagged name=<the       |
|                             | container's name>                                                  |
| cpu_throttled_seconds_count | time it was held back at its CPU limit (a running total), tagged   |
|                             | name=<the container's name>                                        |
| memory_bytes                | memory it uses, without the file cache that can be given back,     |
|                             | tagged name=<the container's name>                                 |
| memory_limit_bytes          | its memory limit, 0 when it has none, tagged name=<the container's |
|                             | name>                                                              |
| memory_pct                  | for one with a limit: its memory, as a share of it, tagged         |
|                             | name=<the container's name>                                        |
| pids                        | processes and threads in it, tagged name=<the container's name>    |
| network_rx_bytes_count      | bytes it received, over its networks (a running total), tagged     |
|                             | name=<the container's name>                                        |
| network_tx_bytes_count      | bytes it sent (a running total), tagged name=<the container's      |
|                             | name>                                                              |
| block_read_bytes_count      | bytes it read from disk (a running total), tagged name=<the        |
|                             | container's name>                                                  |
| block_write_bytes_count     | bytes it wrote to disk (a running total), tagged name=<the         |
|                             | container's name>                                                  |
| ..._not_shown               | past 100 of a list (containers), how many were left out            |
+-----------------------------+--------------------------------------------------------------------+
| GOOD  memory_pct well under 100; memory_bytes steady for a container doing steady work;          |
|       cpu_throttled_seconds_count flat.                                                          |
| WATCH memory_bytes climbing run after run with no more work to do: a leak, on its way to the     |
|       limit. cpu_throttled_seconds_count rising: its CPU limit holds it back. pids climbing:     |
|       processes or threads that are never reaped.                                                |
| BAD   memory_fullest_pct above 90: a container about to be killed for memory (memory_pct says    |
|       which). pids near the limit of the machine.                                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| docker_disk   docker.disk.<metric>   every 15m                                                   |
+-------------------------------+------------------------------------------------------------------+
| up                            | 1 when the engine answers, else 0 (and nothing more is read)     |
| images                        | images it holds                                                  |
| images_unused                 | of those, used by no container                                   |
| images_dangling               | with no name left: an older build of a tag that moved on         |
| images_bytes                  | disk the images take                                             |
| images_reclaimable_bytes      | of that, what removing the unused ones would give back           |
| containers                    | containers it holds, running or not                              |
| containers_bytes              | disk the containers take: what each wrote in its own layer       |
| containers_stopped_bytes      | of that, held by containers that are not running                 |
| container_bytes               | what one container wrote in its own layer, the 20 largest,       |
|                               | tagged name=<the container's name>                               |
| volumes                       | volumes it holds                                                 |
| volumes_unused                | of those, used by no container                                   |
| volumes_bytes                 | disk the volumes take                                            |
| volumes_unused_bytes          | of that, in volumes no container uses                            |
| volume_bytes                  | the size of one volume, the 20 largest, tagged name=<the         |
|                               | volume's name>                                                   |
| build_cache_bytes             | disk the build cache takes                                       |
| build_cache_reclaimable_bytes | of that, not in use by a build                                   |
| ..._not_shown                 | past 100 of a list (container_bytes, volume_bytes), how many     |
|                               | were left out                                                    |
+-------------------------------+------------------------------------------------------------------+
| GOOD  images_bytes and volumes_bytes steady; images_reclaimable_bytes a small share.             |
| WATCH images_dangling or images_reclaimable_bytes growing: builds and pulls that nothing clears. |
|       container_bytes large and growing: a container writing into its own layer what belongs in  |
|       a volume (or logs nobody rotates).                                                         |
| BAD   any of them growing run after run while the base pack shows the disk filling.              |
|       volumes_unused with volumes_unused_bytes large: data left behind by containers that are    |
|       gone, to keep or to remove on purpose.                                                     |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the containers made on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `docker.up` | 1 |  | 0: the engine is down, and with it every container that has no live restore | `up 0` where nothing listened |
| `docker.containers.running` (by `name`) | 1 for every container meant to run |  | 0 for one meant to run: `state` says what it is instead | 0 with `state=exited` the moment one was stopped, 1 again when it was started |
| `docker.containers.restarts_count` (by `name`) | Flat | Rising now and then: a container that falls over from time to time | Rising on every run: a restart loop | Rising: every second or two at first, then more slowly, since Docker waits twice as long before each new start, up to a minute. So a loop that has gone on for a while rises about once a minute |
| `docker.restarting` | 0 | Above 0 once | Above 0 on two runs in a row | 1 or 0 from one moment to the next: a loop is only *between* starts part of the time, which is why `restarts_count` is the one to alert on |
| `docker.containers.healthy` (by `name`) | 1 |  | 0: its own health check fails | 0 for the container whose check always fails |
| `docker.containers.oom_killed` (by `name`) | 0 |  | 1: the kernel killed it at its memory limit | 1 for the container that grew past its 16 MB, with `exit_code 137` |
| `docker.containers.exit_code` (by `name`) | 0 for a job that ended well |  | Other than 0 on a job that should have succeeded | 7, 0 and 137, as each ended |
| `docker.resources.memory_fullest_pct` | Well under 100 | Above 80 | Above 90: a container about to be killed for memory; `memory_pct` says which | 1.4, for the one container with a limit |
| `docker.resources.cpu_throttled_seconds_count` (by `name`) | Flat | Rising: its CPU limit holds it back |  | Rising for the busy container held at 0.3 of a processor |
| `docker.resources.memory_bytes` (by `name`) | Steady for steady work | Climbing run after run: a leak |  | Not caused |
| `docker.disk.images_reclaimable_bytes` | A small share of `images_bytes` | Growing: builds and pulls nothing clears |  | 2.2 GB of 5.2 GB, on a machine that tests many images |
| `docker.disk.container_bytes` (by `name`) | Small | Large and growing: a container writing into its own layer what belongs in a volume |  | 20 MB for the container that wrote 20 MB |
| `docker.disk.volumes_unused` | 0, or what you keep on purpose | Growing: data left by containers that are gone |  | 1 or more: the volume made and never mounted |

## How it was tested

<!-- tested:start -->
**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-containers.sh docker` and its Windows twin, `run-containers.ps1`, against real engines holding eleven small containers and two volumes made for the run, each in a state the pack reads: one running with a 64 MB memory limit and a volume, one healthy, one unhealthy, one in a restart loop, one that ended with code 7, one that ended well, one killed for memory at 16 MB, one paused, one never started, one busy at a CPU limit of 0.3, and one that wrote 20 MB into its own layer. At the end only those are removed: the engines' other containers were read like any, and none was touched.

- **On Fedora** (Fedora 44, Docker Engine 29.9.3, cgroup v2, bash 5.3): every job and what each must have read; the restart loop watched rising; a container stopped (`running 0`, its exit code, no longer measured) and started again; the number of containers named cut to three, the rest counted; nothing answering (`up 0`, the run succeeding); an address that is not a socket refused: **35 passed, 0 failed**. Then `service-packs.sh` through Vigil (enable, and that the engine's CPU and memory are the base pack's; precheck; every job; an engine that does not answer read as `up 0`; each container's readings reaching the backend): **13 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-docker/console.txt)).
- **On Windows 11**, against Docker Desktop 29.9.2 (Linux containers, through the pipe `docker_engine`), as an account that is not an administrator, under Windows PowerShell 5.1 and under PowerShell 7: the same containers and the same checks, and each job compared with what the Linux script printed reading the same engine from a container (the same readings, by name and tag, for all four jobs): **34 passed, 0 failed** each; through Vigil with `Service-Packs.ps1`, **11 passed, 0 failed** each ([Windows PowerShell 5.1](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-docker-windows/console.txt), [PowerShell 7](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-docker-windows-powershell7/console.txt); the account's and the machine's names are taken out of these two files, and the lines about a container of the tester's own).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, Docker Desktop with Engine 28.0.4), from the account that runs Docker Desktop, with 24 containers of that account's own on the engine beside the test's: the same containers and checks: **34 passed, 0 failed**; through Vigil, **13 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/macos/pack-docker-macos/console.txt); the machine's name and the account's are taken out of it).
- **Not tested yet:** Windows containers on Windows Server. The scripts are written for them (a Windows container's memory is its private working set, and it has no memory-kill or CPU-throttling readings), and this page will say so when they have been run there.

**What the tests found.** Engine 28 leaves a container's name out of its statistics (Engine 29 puts it in): the first run on the Mac read every container's CPU and memory, under no name. The pack now takes each name from the engine's list of containers, which every version gives. And Docker waits twice as long before each new start of a container that keeps failing, up to a minute. A restart loop that has just begun restarts every second or two; one that has gone on for ten minutes restarts once a minute, and is *restarting* for only an instant of it. So alert on `restarts_count` rising over several minutes, not on `restarting` being above 0 at the moment a job runs.
<!-- tested:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
