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

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
