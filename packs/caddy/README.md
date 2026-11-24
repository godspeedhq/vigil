# The caddy pack

A Caddy server, from its admin API. The pack reads what its configuration serves (HTTP servers, their addresses, routes, site names, reverse proxies, file servers, certificate policies), whether the last configuration change loaded and how long ago, its goroutines and its open files against its limit; the traffic each server handles (requests, those in flight, handler errors, answers by status class, the average time to answer); every upstream of its reverse proxies (the requests it handles now, its recent failures, and, where Caddy checks them, healthy or not); and the certificate of every site it serves, found in its configuration (days left, within their dates, trusted, the TLS version). Certificates Caddy's own local CA issued check against that CA. Linux, macOS and Windows.

**The admin API, GET only, and `curl`, `jq` and `openssl`.** Caddy's admin API could change its configuration: the pack only ever reads it. A certificate is read from a TLS handshake: nothing else is sent.

1. **The admin API**, which Caddy serves on `localhost:2019` unless told otherwise. Leave it there, reachable from this machine only; if you moved it, the jobs' `CADDY_ADMIN` says where.
2. **For the traffic job, Caddy's HTTP metrics**, in the Caddyfile's global options, then reload Caddy:

   ```caddyfile
   {
       metrics
   }
   ```

   Without them, `caddy_traffic` says `metrics_enabled 0` and nothing else, and no run fails.
3. `vigil pack enable caddy`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `CADDY_ADMIN` (`http://localhost:2019`), `CADDY_TLS_ADDRESS` (where its sites answer https, `127.0.0.1:443`), or `CADDY_TLS` to name the endpoints yourself instead (`127.0.0.1:443/shop.example.com`), and for a CA of your own, `CADDY_CACERT`.

**Caddy that does not answer is a reading**, `up 0`, and the run succeeds. An address that answers but is not Caddy's admin API fails the run.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq`, `openssl` | `curl`, `jq` (Homebrew; macOS 15 has it), `openssl` (built in) | Nothing: `Invoke-WebRequest`, `ConvertFrom-Json` and .NET |
| Caddy | 2.6 and later | | |
| The admin API | on, from this machine (step 1) | | |
| For traffic | `metrics` in the global options (step 2) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `caddy_status` | Up; servers, listeners, routes, sites, reverse proxies, file servers, certificate policies; HTTP metrics on; the last configuration change loaded, and how long ago; goroutines; open files against the limit | minute |
| `caddy_traffic` | Each server: requests, in flight, handler errors, answers 2xx to 5xx, average time to answer | minute |
| `caddy_upstreams` | Each upstream, the failing first: requests it handles now, recent failures, healthy (where Caddy checks); upstreams failing and unhealthy | minute |
| `caddy_tls` | Every site name in its configuration (or `CADDY_TLS`): answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

