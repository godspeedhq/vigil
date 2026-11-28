# The traefik pack

A Traefik proxy, from its own metrics page and its read-only API. The pack reads whether it is up and answers its ping, when its configuration last loaded, the connections on each entrypoint and the requests they answered, 4xx and 5xx; the backend servers it health-checks, up and down, each down one by its URL; the services and routers answering 5xx, each by name; from its API, the routers, services and middlewares in error, each router in error named with why; and its TLS certificates, those it warns about, and the soonest to expire.

A proxy fails sideways. A router whose service was renamed is put in error, takes no traffic, and every request to its host gets a 404: Traefik itself is fine, and its own health check says so. A backend that dies leaves its service with fewer servers, then none, and every request answers 503. A certificate Traefik should have renewed is still the old one a week before it expires. Each of these is in what Traefik says about itself, and the pack reads it, by name.

**Read-only: every request is a GET.** The pack reads Traefik's own pages and changes nothing, whatever its login would allow. It needs `curl` and `awk` (and `jq` for the data sources) on Linux and macOS, and nothing but PowerShell on Windows.

1. Turn on what the pack reads, in Traefik's static configuration: `--metrics.prometheus=true` (with `--metrics.prometheus.addRoutersLabels=true` and `addServicesLabels=true` for the routers and services jobs), `--api=true` and `--ping=true`. They are served on the `traefik` entrypoint, port 8080. For backends up and down, give the services health checks (`loadBalancer.healthCheck`): without one, Traefik does not know.
2. `vigil pack enable traefik`, and where Traefik is not at `http://localhost:8080`, set `TRAEFIK_URL` in the jobs' `env` lines. Where its API sits behind a login (a router with `basicAuth`), `TRAEFIK_USER` and `secret = TRAEFIK_PASSWORD=secret:TRAEFIK_PASSWORD`. The config job needs `jq` on Linux and macOS.

**Traefik that does not answer is a reading**, `up 0`, and the run succeeds: alert on it in your backend. A run fails only when the answer is wrong (a login refused on a page every job needs, or something that is not HTTP), and says why.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `awk`, `jq` | `curl`, `awk` (built in), `jq` (Homebrew; macOS 15 has it) | Nothing: PowerShell 5.1 or later, and .NET |
| Traefik | Traefik 3.x, as a container, a Kubernetes ingress or a binary (tested: 3.8.0 and 3.7.20), with its Prometheus metrics and its API on the traefik entrypoint | | |
| Its address | reachable from the Vigil machine: `TRAEFIK_URL` (default `http://localhost:8080`) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `traefik_status` | Up and its ping; when its configuration last loaded, and how many times; connections on each entrypoint; requests, 4xx and 5xx (for each entrypoint), and their time; TLS requests; certificates, and when the first expires | minute |
| `traefik_services` | Backend servers health-checked, up and down, each down one by its URL, and for each service; requests to the services, 5xx for each, and their time; retries | minute |
| `traefik_routers` | Requests for each router, and those 4xx and 5xx | minute |
| `traefik_config` | From its API: its version; routers, services and middlewares (HTTP, TCP, UDP) and those in error or warning; each router in error, named, with why; certificates, those it warns about, the soonest to expire and those within 30 days | 5 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `traefik.up`.

```text
+--------------------------------------------------------------------------------------------------+
| traefik_status   traefik.<metric>   every 1m                                                     |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Traefik answered its metrics page, else 0 (and nothing more   |
|                           | is read)                                                             |
| ping                      | 1 when /ping answers 200 (--ping=true), else 0                       |
| last_reload_seconds       | seconds since its configuration last loaded                          |
| reloads_count             | configurations loaded (a running total)                              |
| connections               | connections open, every entrypoint                                   |
| connections_by_entrypoint | the same, for each entrypoint, tagged entrypoint=                    |
| requests_count            | requests the entrypoints answered (a running total)                  |
| requests_4xx_count        | of them, 4xx: 404 for a host or path no router takes (a running      |
|                           | total)                                                               |
| requests_5xx_count        | of them, 5xx: a backend down or failing (a running total)            |
| requests_5xx              | the 5xx, for each entrypoint, tagged entrypoint=                     |
| request_avg_ms            | a request, on average, in milliseconds, since it started             |
| tls_requests_count        | requests over TLS (a running total)                                  |
| certs                     | TLS certificates it serves                                           |
| cert_expires_at           | when the first of them expires, in Unix seconds: compare it with now |
|                           | in the backend (the config job says it in days)                      |
| ..._not_shown             | past 100 of a list (connections_by_entrypoint, requests_5xx), how    |
|                           | many were left out                                                   |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; ping 1; requests_5xx_count rising slowly, if at all; cert_expires_at more than 30    |
|       days ahead.                                                                                |
| WATCH requests_4xx_count rising fast: a client calling a host or path no router takes;           |
|       request_avg_ms rising; cert_expires_at within 30 days (Traefik renews ACME certificates 30 |
|       days ahead: one still within is not renewing).                                             |
| BAD   up 0 or ping 0; requests_5xx_count rising: the services job says which; cert_expires_at    |
|       within 7 days.                                                                             |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| traefik_services   traefik.services.<metric>   every 1m                                          |
+--------------------+-----------------------------------------------------------------------------+
| up                 | 1 when Traefik answered its metrics page, else 0 (and nothing more is read) |
| servers            | backend servers health-checked                                              |
| servers_down       | of them, down: their health check fails                                     |
| server_down        | each server: 1 when down, tagged url=<its URL>                              |
| down_by_service    | servers down, for each service, tagged service=                             |
| requests_count     | requests the services answered (a running total)                            |
| requests_5xx_count | of them, 5xx (a running total)                                              |
| requests_5xx       | the 5xx, for each service, tagged service=                                  |
| request_avg_ms     | a request to a backend, on average, in milliseconds                         |
| retries_count      | requests retried on another server (the retry middleware; a running total)  |
| ..._not_shown      | past 100 of a list (server_down, down_by_service, requests_5xx), how many   |
|                    | were left out                                                               |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  servers_down 0; requests_5xx_count flat.                                                   |
| WATCH servers_down above 0 in a service with others up: it carries on with fewer; retries_count  |
|       rising.                                                                                    |
| BAD   down_by_service equal to a service's servers: that service has none, and answers 503;      |
|       requests_5xx rising for a service: its backend fails (502 when it cannot be reached, 504   |
|       when it is too slow).                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| traefik_routers   traefik.routers.<metric>   every 1m                                            |
+----------------+---------------------------------------------------------------------------------+
| up             | 1 when Traefik answered its metrics page, else 0 (and nothing more is read)     |
| requests_count | requests the routers answered (a running total)                                 |
| requests       | the same, for each router, tagged router=                                       |
| requests_4xx   | the 4xx, for each router                                                        |
| requests_5xx   | the 5xx, for each router                                                        |
| ..._not_shown  | past 100 of a list (requests, requests_4xx, requests_5xx), how many were left   |
|                | out                                                                             |
+----------------+---------------------------------------------------------------------------------+
| GOOD  requests_5xx flat for each router.                                                         |
| WATCH requests_4xx rising for one router: a client or a link that is wrong.                      |
| BAD   requests_5xx rising for a router: its service fails (the services job).                    |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| traefik_config   traefik.config.<metric>   every 5m                                              |
+-----------------------+--------------------------------------------------------------------------+
| up                    | 1 when its API answered, else 0                                          |
| version               | always 1, tagged version=<its version>                                   |
| routers               | routers, tagged protocol=<http, tcp or udp>                              |
| routers_errors        | of them, in error: they take no traffic                                  |
| routers_warnings      | in warning                                                               |
| services              | services, tagged protocol=                                               |
| services_errors       | of them, in error                                                        |
| services_warnings     | in warning                                                               |
| middlewares           | middlewares, tagged protocol=<http or tcp>                               |
| middlewares_errors    | of them, in error                                                        |
| middlewares_warnings  | in warning                                                               |
| certificates          | TLS certificates                                                         |
| certificates_warnings | of them, those Traefik warns about (expiring soon)                       |
| certificates_errors   | of them, in error                                                        |
| router_error          | a router in error: 1, tagged protocol=, router=<its name> and            |
|                       | reason=<the start of its error>                                          |
| cert_expires_days     | days until the soonest certificate expires (below 0: expired)            |
| certs_expiring_30d    | certificates that expire within 30 days                                  |
| ..._not_shown         | past 100 of a list (router_errors), how many were left out               |
+-----------------------+--------------------------------------------------------------------------+
| GOOD  routers_errors, services_errors and middlewares_errors 0; certificates_warnings 0.         |
| WATCH the warnings above 0; certs_expiring_30d above 0.                                          |
| BAD   routers_errors above 0: router_error names it and why (a service that does not exist, a    |
|       middleware missing, a rule that does not parse): it takes no traffic; cert_expires_days    |
|       below 7.                                                                                   |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what the stack in trouble on purpose (below) showed. *Watch* is a warning: someone looks today. *Act* is critical: someone acts now. Graph the `_count` totals as rates: "rising" means its rate is above zero, "flat" that it is zero.

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `traefik.up`, `ping` | 1 |  | 0: the proxy does not answer | `up 0` where nothing listened |
| `traefik.config.routers_errors`, `router_error` (by `router`) | 0 |  | Above 0: `router_error` names the router and why. It takes no traffic: its host answers 404 | 2: `broken@file` (`the service "not-there@file" does not exist`) and `nomiddleware@file` (`middleware "no-such-middleware@file" does not exist`) |
| `traefik.services.servers_down`, `server_down` (by `url`) | 0 | Above 0 in a service with others up | `down_by_service` equal to its servers: the service has none, and answers 503 | 1, the backend whose host does not exist; 2 with a second stopped (`down_by_service 2 service=app@file`) |
| `traefik.requests_5xx_count`, `services.requests_5xx` (by `service`) | Flat |  | Rising: the service named fails (502 unreachable, 504 too slow) | 20, all `service=gone@file`, the service whose only backend does not exist |
| `traefik.requests_4xx_count` | Steady | Rising fast: a host or path no router takes, or a router in error |  | 60: 20 to a host no router takes, and 20 to each router in error |
| `traefik.config.cert_expires_days`, `certs_expiring_30d` | Above 30; 0 | Below 30: Traefik renews ACME certificates 30 days ahead, so one still below is not renewing | Below 7 | 4.99 days and 1, for the certificate made for 5 days; `certificates_warnings 1` |
| `traefik.last_reload_seconds`, `reloads_count` |  | A change that does not show as a reload: Traefik did not take it |  | `reloads_count 2` and `last_reload_seconds 0` a moment after the configuration changed |

## How it was tested

**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-traefik.sh`, against `compose.traefik.yaml`: **Traefik 3.8.0 and 3.7.20**, side by side, reading one dynamic configuration in trouble on purpose: a service of three backends, one a host that does not exist (its health check fails); a service whose only backend is that host; a router to a service that is not there and one with a middleware that is not there; a certificate made for 5 days and one for a year. Twenty requests to each router and to a host no router takes, on each Traefik.

- **On Fedora** (Fedora 44, bash 5.3): every job against each, and what each read (up and ping; the requests, 4xx and 5xx; three backends health-checked, the missing one down and named; the 5xx by service and by router; the two routers in error, each named with why; two certificates, the 5-day one warned of, and when it expires both from the API and the metrics). Then a second backend stopped (two down, both named), the configuration changed (the reload counted, a moment ago), and nothing listening: **30 passed, 0 failed**. Then `service-packs.sh` through Vigil: **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-traefik/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk, jq 1.8.2), against the same two through SSH tunnels: every job, the routers in error and the dead backend named, nothing listening: **11 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-traefik-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator: every job under Windows PowerShell 5.1 and PowerShell 7, against both, the same checks: **22 passed, 0 failed**; the same metric names and tags as the Linux scripts for all 4 jobs against both, under both shells (16 of 16); through Vigil, **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-traefik-windows/console.txt)).

**What the tests found.** A router in error is not an error Traefik's own health shows: it answers its ping, takes the router out, and every request to its host gets a 404, counted with the requests to hosts no router takes. Its API names it, with why. Traefik 3's `traefik_config_last_reload_success` is the time of the last successful load, not a flag. A backend that cannot be reached keeps a request waiting: the service's average time rose past a second with every request to the missing host. Without a health check on a service, Traefik reports no server up or down for it.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
