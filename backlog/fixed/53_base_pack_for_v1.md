# 53. A fuller base pack for v1

Decided on 2026-11-16, ahead of v1.

## Why

Someone who installs Vigil and has no scripts yet enables the base pack, and
that is all they see of Vigil. Today it reports one number for CPU, three for
memory and disk, two for network, the load average and failed services:
enough to know a machine is alive, not enough to look into one.

Once v1 ships, the base pack's metric names and tags are a promise, like the
CLI: dashboards and alerts are built on them. So they are settled now.

Vigil still only sends metrics. No dashboards: how they are shown is up to
whoever receives them. A fresh install still sends nothing until its
configuration says so: the pack is enabled on purpose, with `vigil pack
enable base`.

## What it adds

Existing metrics keep their names. On Linux, macOS and Windows unless noted:

| Job | Adds |
| --- | --- |
| `cpu` | `user_pct`, `system_pct`, `iowait_pct` (Linux), `steal_pct` (Linux) |
| `memory` | `available_bytes`, `swap_used_bytes`, `swap_total_bytes` (Windows: the page file) |
| `disk` | `inodes_used_pct` (Linux, macOS) |
| `diskio` (new) | per disk: `read_bytes`, `write_bytes`, `reads`, `writes`, `busy_pct` |
| `network` | per interface: `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors`, `rx_drops`, `tx_drops` |
| `system` (new) | `uptime_seconds`, `processes`, and `info 1` with tags `os`, `os_version`, `cpu_model`, `cores`, `memory_bytes` |
| `processes` (new) | the top 10 by CPU and by memory: `cpu_pct`, `memory_bytes`, tag `name` only (never a PID or a command line, which can hold secrets) |

Windows still has no load average; its pack still leaves `load` out.

Counters (bytes, packets, I/O) are reported as the platform gives them, the
way `network` reports `rx_bytes` now, unless a rate is all a platform offers:
then the script says so in its header.

## Done when

- Each script's header lists its metrics with an example, as now.
- The pack's version goes to 1.2.0; `pack.config` lists the new jobs.
- The base pack's tests cover the new scripts on all three platforms, and
  they pass on the test machines.
- With the whole pack enabled for an hour, `vigil doctor` on a Windows
  machine shows what it costs, and the result is in this file.

## Built (2026-11-16)

Base pack 1.2.0. Existing metric names are unchanged. What changed from the
plan above, and why:

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `cpu` | `used_pct`, `user_pct`, `system_pct`; `iowait_pct`, `steal_pct` | all | no iowait, steal | no iowait, steal |
| `memory` | `used_pct`, `used_bytes`, `total_bytes`, `available_bytes`; swap or commit | swap | swap | `commit_used_bytes`, `commit_limit_bytes` |
| `disk` | `used_pct`, `used_bytes`, `total_bytes`, `inodes_used_pct` | yes | yes (APFS stays near 0) | no inodes |
| `diskio` (new) | `read_bytes`, `write_bytes`, `reads`, `writes`, `busy_ms` | all | no busy | no busy |
| `network` | bytes, packets, errors, drops, in and out | all | no `rx_drops` | all |
| `processes` (new) | the top 10 programs by CPU and by memory: `cpu_pct`, `memory_bytes`, tag `name` | yes | yes | yes |
| `host` (new) | `uptime_seconds`, `process_count`, `cores`, `info 1` tagged `os_name`, `os_version`, `kernel`, `cpu_model` | yes | yes | yes |

- **`host`, not `system`:** a job's own counters go under its
  `metric_name` (`<m>.runs`, `<m>.duration_seconds`, §14.2), so `system`
  would have put them at `system.runs`. It is `system.host`, like the
  other jobs' `system.<area>`. `os` is a reserved tag (§14.6): `os_name`.
- **Windows has no swap figure** of its own: commit (memory plus the page
  file) is what runs out, and is reported instead. `busy_ms` is Linux's
  `io_ticks`; the Windows driver counts idle time only since a disk
  arrived, and macOS keeps none, so neither reports it.
- **A metric a platform cannot report is named in its script's header**,
  which `tools/check-pack.sh` checks.
- **Fewer series:** Linux leaves out Docker's `veth` pairs (the bridge
  carries their traffic), and Windows, like macOS, leaves out interfaces
  that moved nothing (VPNs that are off).
- **Windows reads the kernel, never WMI:** disk counters through
  `IOCTL_DISK_PERFORMANCE`, which a standard user may ask; processes
  through one `NtQuerySystemInformation` call, so a standard user's Vigil
  sees every process, as the service does. Through .NET's `Process` a run
  cost 1.78 CPU s on this laptop; through the kernel, 0.49 s. Every other
  script costs about 0.3 s, a bare PowerShell start 0.22 s.
- **`processes` sends names only,** grouped (20 svchost processes are one),
  never a process id or a command line.

**What it costs.** An hour of the whole pack on the HP (Windows 11,
i7-8565U, 8 threads), as vigil-test with no elevation, every job every
minute but disk and host:

```text
Runs (everything the supervisor started): 3466.14 CPU s = 0.963 cores
What Vigil's runs cost in the last hour
  job                        runs        CPU    CPU/run   time/run
  vigil_sender                358   856.01 s     2.39 s      0.9 s
  base_processes               61   447.07 s     7.33 s      6.1 s
  base_network                 61   399.74 s     6.55 s      4.7 s
  base_diskio                  61   389.51 s     6.39 s      4.7 s
  base_memory                  61   379.46 s     6.22 s      4.7 s
  base_cpu                     61   375.13 s     6.15 s      5.8 s
  base_services                61   365.88 s     6.00 s      4.2 s
  base_host                    12    75.16 s     6.26 s      5.4 s
  base_disk                    12    72.43 s     6.04 s      5.6 s
  WARN  Vigil's runs keep 0.93 of a core busy, above half of one
```

The old pack's hour on the same machine was 0.66 cores. The scripts are
not the cost: about 6 of each run's 6.3 CPU s is Vigil's own Windows
worker, so each job run every minute costs about 0.1 core there. So
`diskio` and `processes` ship every 5 minutes, like `disk` and `host`:
about 0.04 core more than 1.1.2 instead of 0.3. A user who wants them
fresher sets `run_every`. The worker's own cost is the next thing to cut
(backlog 52's "smaller worker").

**Tests.** `tools/check-pack.sh --run` (each script runs, and every metric
is a number listed in `pack.config`) passes on Fedora 44 and macOS 12, and
`tools/Check-Pack.ps1` on Windows 11. `base-pack.sh` 21/21 on Fedora and
the Mac (bash 5.3, 3.2), `Base-Pack.ps1` 20/20 on PowerShell 5.1 and 7:
each new job runs and reaches the backend. `processes.ps1` also runs in a
32-bit PowerShell.
