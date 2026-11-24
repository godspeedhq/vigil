# The httpd pack

An Apache httpd server on this machine. The pack reads its `server-status` page (its version and MPM, uptime since the last restart and how many graceful restarts, requests, bytes and time served, CPU, workers busy, idle and finishing against those running, every worker's state from the scoreboard, connections writing, kept alive and closing with the event MPM, and with `mod_ssl` its TLS session cache: entries, how full, hits, misses and sessions thrown out for lack of room), whether a file of its configuration changed since the last restart (an edit not loaded yet), its access log minute by minute (requests by status and method, the 4xx and 5xx share, bytes, clients, and, when the log records them, response times with percentiles), and the certificates it serves (days left, within their dates, trusted, the TLS version). Linux, macOS and Windows.

**A status page, the log's group, and `curl` and `openssl`.** Every job only reads: a page from this machine, the configuration's files and the log, and, for certificates, a TLS handshake.

1. **The status page**, from this machine only, with its totals, then reload httpd (`apachectl -k graceful`):

   ```apache
   ExtendedStatus On
   <Location "/server-status">
       SetHandler server-status
       Require local
   </Location>
   ```

   `mod_status` is loaded by default on most systems (`a2enmod status` on Debian and Ubuntu).
2. **For the log job, response times in the log** (optional, and worth it): end the `LogFormat` with `rtus=%D`, and use it.

   ```apache
   LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" rtus=%D" vigil
   CustomLog "logs/access_log" vigil
   ```

   Without it, the log job reads the same counts from the standard `combined` format, with no times.
3. **For the log job, read access to the log.** On Debian and Ubuntu the logs belong to the `adm` group: `sudo usermod -aG adm vigil`, then restart Vigil. On Fedora and RHEL, `/var/log/httpd` is root's alone: `sudo setfacl -m u:vigil:rx /var/log/httpd` and `sudo setfacl -m u:vigil:r /var/log/httpd/access_log`. Until then the job reports `log_readable 0` and nothing more, and the run succeeds.
4. `vigil pack enable httpd`, then in `vigil.config` set what differs from the defaults, in the jobs' `env` lines: `HTTPD_STATUS_URL` (`http://127.0.0.1/server-status`), `HTTPD_CONF` (by default the first of `/etc/httpd/conf/httpd.conf`, `/etc/apache2/apache2.conf`, `/usr/local/apache2/conf/httpd.conf` and Homebrew's that is there; `C:\Apache24\conf\httpd.conf` on Windows), `HTTPD_ACCESS_LOG` (by default the first of `/var/log/httpd/access_log`, `/var/log/apache2/access.log` and the others that is there), `HTTPD_TLS` (the https endpoints, `localhost:443`) and, for a private CA, `HTTPD_CACERT`.

**httpd that does not answer is a reading**, `up 0`, and the run succeeds. A page that answers but is not `server-status` fails the run.

**What server-status cannot say.** It does not say `MaxRequestWorkers`: its scoreboard has a slot for every worker `ServerLimit` and `ThreadLimit` allow. So `busy_pct` is of the workers running, busy and idle: near 100 with `idle_workers` 0, every worker is busy and httpd may start no more.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `openssl` | `curl`, `openssl` (built in) | Nothing: `Invoke-WebRequest` and .NET |
| httpd | 2.4, any MPM | | Apache Lounge's build |
| A page | `server-status`, from this machine only (step 1) | | |
| The log | read access (step 3) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `httpd_status` | Up, version and MPM, ExtendedStatus, uptime since the last restart, graceful restarts, requests, bytes and time served, CPU, workers busy, idle and finishing, scoreboard slots, busy %, processes and those stopping, connections (writing, keep-alive, closing), every scoreboard state, the TLS session cache, a configuration changed since the last restart | minute |
| `httpd_log` | The access log's last whole minute: requests, by status class and by status, the 4xx and 5xx share, by method, bytes, clients; with `rtus=`, response times (average, p50, p90, p99, the slowest); whether the whole minute was read | minute |
| `httpd_tls` | Each https endpoint: answering TLS, days until its certificate expires, within its dates, trusted (and why not), its issuer and the TLS version | 15 minutes |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.

