# The nginx pack

An nginx server on this machine, from its `stub_status` page, which you turn on once, reachable from this machine only:

```nginx
location = /nginx_status { stub_status; allow 127.0.0.1; deny all; }
```

Then `vigil pack enable nginx`, which reminds you of the page. The job reads `http://127.0.0.1/nginx_status`; for another address, edit its `env` line.

## Its jobs

| Job | Reports | Linux | macOS | Windows |
| --- | --- | --- | --- | --- |
| `nginx_status` | Up, connections (active, reading, writing, waiting), accepted, handled and dropped connections, requests | Yes | Yes | No |

## What to alert on

Starting points, not rules: Vigil runs the job and delivers what it prints, and the alerts are yours, in the backend you already use. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Give `up` a minute or two, since a restart leaves nginx not answering for a moment, and that is healthy. The totals start again from 0 when nginx restarts: graph them as rates. The last column is what the test server, nginx 1.30.5 in Docker, showed, in [the run's console output](../../tests/integration/backends/reports/runs/2026-11-04/fedora/pack-nginx/console.txt): where we caused nothing, it says so. Everything not here (reading, writing, waiting, accepted and handled connections) is for dashboards.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `nginx.up` | 1 | | 0: nginx does not answer | 0, with the job pointed at a port where nothing listens |
| `nginx.dropped_count` (as a rate) | 0 | Any | Rising: nginx is turning connections away, usually at a resource limit | Not caused: 0 |
| `nginx.active_connections` | Well below `worker_connections` times the worker processes | Near it: past it, nginx turns connections away | | Not caused: 1 |
| `nginx.requests_count` (as a rate) | Your usual rate | Well below your usual | 0 where there should be traffic: nothing reaches nginx | Not caused: the total read 130 |

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
