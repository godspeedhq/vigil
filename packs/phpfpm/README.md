# The phpfpm pack

PHP-FPM's pools, from their status pages. When a PHP site slows down or answers 502 while nginx or httpd look fine, the cause is usually here: every worker busy, requests waiting in the pool's listen queue, `pm.max_children` reached. The pack reads, for each pool, its process manager and uptime, the requests it accepted, its listen queue against its length and its peak, its workers (idle, active, all, the most active at once), how often it hit `pm.max_children`, its slow requests and its memory peak; then its workers one by one, summed up: how many are in each state, the longest request running now, and the most memory, CPU, requests and age of any. It never prints a request's URI or script, only counts. Linux and macOS: PHP-FPM does not run on Windows.

**A status page for each pool, through the web server, and `curl`.** PHP-FPM serves its status page over FastCGI, so the web server in front of it passes the page on, from this machine only.

1. **Turn the page on** in each pool's configuration (`www.conf`), then reload PHP-FPM:

   ```ini
   pm.status_path = /fpm-status
   ```

2. **Pass it on, from this machine only.** With nginx:

   ```nginx
   location = /fpm-status {
       allow 127.0.0.1;
       deny all;
       include fastcgi_params;
       fastcgi_param SCRIPT_NAME /fpm-status;
       fastcgi_param SCRIPT_FILENAME /fpm-status;
       fastcgi_pass unix:/run/php-fpm/www.sock;
   }
   ```

   With httpd:

   ```apache
   <Location "/fpm-status">
       Require local
       SetHandler "proxy:unix:/run/php-fpm/www.sock|fcgi://localhost"
   </Location>
   ```

   A second pool has its own socket and its own path (`/fpm-status-api`, say).
3. `vigil pack enable phpfpm`, then in `vigil.config` set the job's `PHPFPM_STATUS_URLS`: one URL for each pool, separated by spaces (`http://127.0.0.1/fpm-status http://127.0.0.1/fpm-status-api`).

**A pool that does not answer is a reading**, `up 0` tagged with its URL, and the run succeeds. A URL that answers but is not a PHP-FPM status page fails the run.

## What it needs

| | Linux | macOS |
| --- | --- | --- |
| On the Vigil machine | `curl` | `curl` |
| PHP-FPM | 7.4 and later (`memory_peak_bytes`: 8.4 and later) | |
| A page | each pool's `pm.status_path`, passed on by the web server (steps 1 and 2) | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `phpfpm_pools` | Each pool: up, its process manager, uptime, requests accepted, listen queue against its length and its peak, workers idle, active, all and the most active at once, times `pm.max_children` was reached, slow requests, memory peak; its workers by state, the longest request running, and the most memory, CPU, requests and age of any worker | minute |

The job's script says, in its header, what every metric means and what healthy, watch and bad look like.
