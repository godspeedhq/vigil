# The base pack

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `base_cpu` | CPU in use, split into programs and the kernel; on Linux, I/O wait and steal too | Yes | Yes | Yes |
| `base_memory` | Memory in use and available; swap on Linux and macOS, commit on Windows | Yes | Yes | Yes |
| `base_disk` | Space used per file system; inodes on Linux and macOS | Yes | Yes | Yes |
| `base_diskio` | Bytes and operations read and written per disk; busy time on Linux | Yes | Yes | Yes |
| `base_network` | Bytes, packets, errors and drops per interface | Yes | Yes | Yes |
| `base_load` | Load averages | Yes | Yes | No |
| `base_services` | Failed services | Yes | Yes | Yes |
| `base_processes` | The 10 programs using the most CPU and the 10 using the most memory, by name | Yes | Yes | Yes |
| `base_host` | Uptime, process count, cores, and an `info` metric tagged with the OS, its version, the kernel and the CPU model | Yes | Yes | Yes |

Every metric is listed, with an example, in its script's header, and a metric a platform cannot report is named there too. Counters (bytes, packets, operations) are running totals since boot: graph them as a rate. `base_processes` sends program names only, never a process id or a command line.
On Windows the scripts read the kernel, .NET and the service manager, not WMI, so they work when Vigil runs as a standard user started over SSH, where WMI refuses. One thing cannot: there, the service manager refuses to list services too, so `base_services` fails and says so. Run Vigil as a service (`--system`), or from a desktop logon, to have it.

## Reading the results

These are starting points, not rules: tune them to what's normal on each machine. Each script's header has the same guide, with an example of its output.

| Metric | Healthy | Watch | Act |
| --- | --- | --- | --- |
| `system.cpu.used_pct` | Below 70 | 70 to 90 for 15 minutes or more | Above 90 for 5 minutes or more |
| `system.memory.used_pct` | Below 80 | 80 to 90, or climbing steadily | Above 90 for 5 minutes or more |
| `system.disk.used_pct` | Below 80 | 80 to 90, or growing fast | Above 90 |
| `system.network.rx_bytes`, `tx_bytes` (as a rate) | Well below the link speed | Above 70 percent of the link speed for 15 minutes or more | Close to the link speed, or no traffic where there should be some |
| `system.network.rx_errors`, `tx_errors` (as a rate) | 0 | Rising | Rising steadily: a cable, a port or a driver |
| `system.diskio.busy_ms` (as a rate, Linux) | Below 500 a second (50 percent busy) | Above 800 a second for 15 minutes or more | Near 1000 a second with work waiting |
| `system.memory.commit_used_bytes` (Windows) | Well below `commit_limit_bytes` | Within 10 percent of it | At it: programs fail to get memory |
| `system.load.load1`, `load5`, `load15` | Below the number of cores | 1 to 2 times the cores for 15 minutes or more | Above 2 times the cores for 5 minutes or more |
| `system.services.failed` | 0, or your usual number on macOS and Windows | Higher than usual on macOS | 1 or more on Linux, or still rising elsewhere |


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `system.cpu.used_pct`.

```text
+--------------------------------------------------------------------------------------------------+
| base_cpu   system.cpu.<metric>   every 1m                                                        |
+------------+-------------------------------------------------------------------------------------+
| used_pct   | percent of CPU time in use, across all cores                                        |
| user_pct   | of which running programs (user and nice)                                           |
| system_pct | of which the kernel (system, irq and softirq)                                       |
| iowait_pct | idle while waiting for a disk; not part of used_pct                                 |
| steal_pct  | taken by the hypervisor for other virtual machines; part of used_pct                |
+------------+-------------------------------------------------------------------------------------+
| GOOD  used_pct below 70: normal work, and short spikes to 100 are fine.                          |
| WATCH used_pct 70 to 90 for 15 minutes or more: little room left for a peak. iowait_pct above    |
|       10: the disks are holding work back.                                                       |
| BAD   used_pct above 90 for 5 minutes or more: find what is using the CPU (system.processes).    |
|       steal_pct above 10 on a virtual machine: its host is overcommitted.                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_memory   system.memory.<metric>   every 1m                                                  |
+-------------------+------------------------------------------------------------------------------+
| used_pct          | percent of memory in use                                                     |
| used_bytes        | memory in use, in bytes                                                      |
| total_bytes       | installed memory, in bytes                                                   |
| available_bytes   | memory available to programs without swapping, in bytes                      |
| swap_used_bytes   | swap in use, in bytes                                                        |
| swap_total_bytes  | swap configured, in bytes (0 with no swap)                                   |
| commit_used_bytes | and commit_limit_bytes are Windows only                                      |
+-------------------+------------------------------------------------------------------------------+
| GOOD  below 80: room for peaks.                                                                  |
| WATCH 80 to 90, or used_bytes climbing steadily, which can mean a leak. swap_used_bytes growing  |
|       while used_pct is high.                                                                    |
| BAD   above 90 for 5 minutes or more: the machine may start to swap, or the system may stop      |
|       processes to free memory.                                                                  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_disk   system.disk.<metric>   cron 1/5 * * * *                                              |
+-----------------+--------------------------------------------------------------------------------+
| used_pct        | percent of usable space in use (tag: mount)                                    |
| used_bytes      | space in use, in bytes (tag: mount)                                            |
| total_bytes     | size of the file system, in bytes (tag: mount)                                 |
| inodes_used_pct | percent of inodes (file entries) in use (tag: mount); left out for file        |
|                 | systems with no fixed number, such as btrfs                                    |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  below 80.                                                                                  |
| WATCH 80 to 90, or used_bytes growing fast: work out when it fills up.                           |
| BAD   above 90: free some space. At 100, writes fail, and databases and logs usually go with     |
|       them. The same goes for inodes_used_pct: many small files can fill a disk that still has   |
|       space.                                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_diskio   system.diskio.<metric>   cron 2/5 * * * *                                          |
+-------------+------------------------------------------------------------------------------------+
| read_bytes  | bytes read (tag: disk)                                                             |
| write_bytes | bytes written (tag: disk)                                                          |
| reads       | reads completed (tag: disk)                                                        |
| writes      | writes completed (tag: disk)                                                       |
| busy_ms     | milliseconds the disk was busy (tag: disk); as a rate, busy_ms / 10 per second is  |
|             | the percent of time it was busy                                                    |
+-------------+------------------------------------------------------------------------------------+
| GOOD  busy below 50 percent of the time.                                                         |
| WATCH busy above 80 percent for 15 minutes or more: the disk is the bottleneck, and              |
|       system.cpu.iowait_pct usually rises with it.                                               |
| BAD   busy near 100 percent with work waiting: find what is reading or writing, or move it to a  |
|       faster disk. Totals restart after a reboot.                                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_network   system.network.<metric>   every 1m                                                |
+------------+-------------------------------------------------------------------------------------+
| rx_bytes   | bytes received (tag: iface)                                                         |
| tx_bytes   | bytes sent (tag: iface)                                                             |
| rx_packets | packets received (tag: iface)                                                       |
| tx_packets | packets sent (tag: iface)                                                           |
| rx_errors  | received packets with errors (tag: iface)                                           |
| tx_errors  | packets that failed to send (tag: iface)                                            |
| rx_drops   | received packets dropped, for lack of room or of a taker (tag: iface)               |
| tx_drops   | packets dropped before sending (tag: iface)                                         |
+------------+-------------------------------------------------------------------------------------+
| GOOD  steady, and well below the speed of the link; errors at 0.                                 |
| WATCH above 70 percent of the link speed for 15 minutes or more, or errors or drops rising.      |
| BAD   close to the link speed, no traffic where there should be some, or errors rising steadily: |
|       a cable, a port or a driver. Totals restart after a reboot.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_load   system.load.<metric>   every 1m                                                      |
+--------+-----------------------------------------------------------------------------------------+
| load1  | average over 1 minute                                                                   |
| load5  | average over 5 minutes                                                                  |
| load15 | average over 15 minutes                                                                 |
+--------+-----------------------------------------------------------------------------------------+
| GOOD  below 4: every core can keep up.                                                           |
| WATCH 4 to 8 for 15 minutes or more: work is queueing.                                           |
| BAD   above 8 for 5 minutes or more: the machine is overloaded. load1 above load15 means load is |
|       rising; below it, falling.                                                                 |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_services   system.services.<metric>   every 1m                                              |
+--------+-----------------------------------------------------------------------------------------+
| failed | number of failed units                                                                  |
+--------+-----------------------------------------------------------------------------------------+
| GOOD  0.                                                                                         |
| BAD   1 or more: something that should be running is not. To see what: systemctl --failed        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_processes   system.processes.<metric>   cron 3/5 * * * *                                    |
+--------------+-----------------------------------------------------------------------------------+
| cpu_pct      | percent of the whole machine's CPU, all cores together, so it adds up with        |
|              | system.cpu.used_pct (tag: name)                                                   |
| memory_bytes | resident memory, in bytes (tag: name)                                             |
+--------------+-----------------------------------------------------------------------------------+
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| base_host   system.host.<metric>   cron 4/5 * * * *                                              |
+----------------+---------------------------------------------------------------------------------+
| uptime_seconds | seconds since the machine started                                               |
| process_count  | processes running now                                                           |
| cores          | logical cores (hardware threads)                                                |
| info           | always 1 (tags: os_name, os_version, kernel, cpu_model)                         |
+----------------+---------------------------------------------------------------------------------+
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
