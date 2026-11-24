# The web packs

Five packs from one source: `nginx`, `httpd`, `caddy`, `haproxy` and `phpfpm`. They watch the servers in front of most sites, and each stands on its own (packs never depend on each other). They are written together because two of them read the same access log format, three of them check the same kind of certificate, and every one of them reads a status page the same way.

`py tools/web/gen.py .` writes them all; `py tools/web/gen.py . nginx` writes one.

| File | What |
| --- | --- |
| `lib.sh`, `lib.ps1` | What every script shares, as `_<pack>.sh` (Linux, macOS) and `_<pack>.ps1` (Windows), beside the scripts: one request, the tags and numbers, the access log's last minute, and the certificates' handshake. |
| `jobs.py` | How a job is written, and the two jobs nginx and httpd share (`log`) and three share (`tls`), made per pack. |
| `nginx.py`, `httpd.py`, `caddy.py`, `haproxy.py`, `phpfpm.py` | Each pack's own jobs: what each reports, its metrics, how to read them, its settings, and its code for bash and, where there is one, PowerShell. `haproxy.py` adds its runtime API to `_haproxy.sh`; `caddy.py` adds its helpers to `_caddy.ps1`. |
| `gen.py` | Each pack's words (its name, its settings' prefix, its version, what it needs), the scripts' headers, and `pack.config`. |
| `examples-<pack>.txt` | Each job's example output, from the test runs, for its script's header. |

## Choices

- **Read-only.** Every request is a GET, or (HAProxy) `show info` and `show stat`, which a socket at `level user` allows and nothing more. Caddy's admin API could change its configuration: the caddy pack only ever reads it. A TLS check sends nothing but the handshake.
- **The access log, without keeping anything.** The `log` job reads the last whole minute of the log (the minute before the one it runs in), from the log's last `*_LOG_MAX_MB` only, so it costs the same on a log of any size and needs no state between runs. When the log grew faster than that, it says so (`window_complete 0`) rather than undercount in silence. It reads the combined format, and response times when the format ends with them (`rt=$request_time urt=$upstream_response_time` for nginx, `rtus=%D` for httpd). It never prints a path, a query or an address: only counts.
- **Opt-in where it needs access.** Reading a log needs the account Vigil runs as in the log's group. Until it is, the job reports `log_readable 0` and nothing else, and the run succeeds: turning the job on costs nothing until the access is given.
- **What clients see.** The `tls` job reads the certificate a handshake gets, not the file on disk: it catches a certificate renewed and not loaded. Caddy's finds its site names in Caddy's configuration, and checks the certificates of Caddy's own CA against that CA.
- **A configuration edited and not loaded.** nginx and httpd report files in their configuration folder changed since the last reload: nginx's last reload is when its youngest worker started; httpd's is its last restart, from server-status.
- **No CPU or memory of the processes.** That is the base pack's `processes` job; the packs say so in their `needs` lines.
- **Windows where the server runs there.** nginx, httpd and Caddy have Windows scripts. HAProxy and PHP-FPM do not run on Windows, and the nginx `server` job reads Unix processes: they have none.
- **Bounded output.** Every list (status codes, servers, backends, upstreams, endpoints) stops at a limit, the worst first, and says how many it left out (`*_not_shown`).

## Lessons from the test servers

- httpd's scoreboard has a slot for ServerLimit times ThreadLimit workers, not MaxRequestWorkers, and server-status does not say MaxRequestWorkers: `busy_pct` is of the workers running.
- Windows PowerShell 5.1 hands back a JSON array as one object: kept in a variable first, `@()` makes it the list.
- On macOS's bash 3.2, an empty array is unset under `set -u`: `${list[@]+"${list[@]}"}`.
- httpd's graceful restart does not reset `ServerUptimeSeconds`, and an old worker holding a kept-alive connection (a load balancer's, or Caddy's health checks in our tests) outlives it: an edit not loaded is one made after the *youngest* worker started.
- PHP-FPM serves its status page with a worker of the pool: when every worker is busy, the page waits too (`timed_out 1`). Its slow-request count needs ptrace (Docker: `cap_add: SYS_PTRACE`).
- Caddy 2.11.9 stopped reporting its HTTP metrics and its upstreams' health after any configuration reload through its admin API (refused or not), until it restarted: `servers_reporting 0` says so.
- awk: `>` in `printf`'s arguments is a redirection (parenthesise a `?:`); mawk prints integers past 2^31 as `3e+09`, so counters are printed as the server wrote them, and sums with `%.0f` (`%.15g` for Prometheus values).
- IIS (`iis.py`, Windows only): an account that is not an administrator may not read `applicationHost.config` or use the WebAdministration module, nor, over SSH, the service manager; it may read the performance counters (in Performance Monitor Users), the event logs (in Event Log Readers), the W3C and HTTPERR logs (given access) and `netsh http show sslcert`. `Get-Counter` lowercases instance names: the names come back from `-ListSet`'s paths. IIS writes its logs out once a minute: the log job reads the minute before last. HTTP.sys's error log holds what never reached a site (a stopped pool: `Disabled`; a crashed one: `AppOffline`).
