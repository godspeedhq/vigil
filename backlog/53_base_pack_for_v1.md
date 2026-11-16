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
