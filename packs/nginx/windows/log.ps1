#Requires -Version 5.1

<#
.SYNOPSIS
    log.ps1 - nginx's access log, minute by minute, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reads the last whole minute of nginx's access log, in the combined format,
    and reports the requests in it: by status class and status, by method, the
    bytes sent, the clients, and, when the log records it, how long the answers
    took (rt=$request_time at the end of the log_format) and how long the
    upstream took (urt=$upstream_response_time). It reads only the end of the
    log, at most NGINX_LOG_MAX_MB (32 by default), so it costs the same on a log
    of any size, and keeps nothing between runs. It never prints a path, a query
    or an address: only counts. It only reads: it changes nothing.

    Reads NGINX_ACCESS_LOG (default /var/log/nginx/access.log on Linux and
    macOS, C:\nginx\logs\access.log on Windows). The account Vigil runs as must
    be allowed to read it (packs/nginx/README.md says how); until it is, the job
    reports log_readable 0 and nothing else.
    What the scripts share is in _nginx.ps1, beside this one.

    Metrics:
      log_found        1 when the access log is there, else 0
      log_readable     1 when this account may read it, else 0 (and nothing more
                       is read)
      log_bytes        the log's size
      window_complete  1 when the whole minute was read; 0 when the log grew
                       faster than NGINX_LOG_MAX_MB a minute, and the counts are
                       of its end only
      requests         requests logged in the last whole minute
      status_1xx       of those, answered 1xx
      status_2xx       answered 2xx
      status_3xx       answered 3xx
      status_4xx       answered 4xx: the client asked wrong (not found, refused,
                       too many)
      status_5xx       answered 5xx: the server failed
      errors_4xx_pct   4xx, as a percentage of the requests
      errors_5xx_pct   5xx, as a percentage of the requests
      bytes_sent       bytes sent in answers
      clients          client addresses seen
      status           requests answered with one status, tagged code=<it> (each
                       one seen)
      method           requests by method, tagged method=<GET, POST, HEAD, PUT,
                       DELETE, PATCH, OPTIONS or other>
      response_avg_ms  time to answer, on average, when the log records it
                       (rt=$request_time at the end of the log_format)
      response_p50_ms  half the requests were answered within this
      response_p90_ms  90% were answered within this
      response_p99_ms  99% were answered within this
      response_max_ms  the slowest
      upstream_avg_ms  the upstream's time to answer, on average, when the log
                       records it (urt=$upstream_response_time)
      upstream_p50_ms  half the upstream's answers came within this
      upstream_p90_ms  90% came within this
      upstream_p99_ms  99% came within this
      upstream_max_ms  the slowest

    Example output (the rest are in the same form):
      metric log_found 1
      metric log_readable 1
      metric log_bytes 30151
      metric window_complete 1
      metric requests 221
      metric status_1xx 0
      metric status_2xx 168
      metric status_3xx 0
      metric status_4xx 41
      metric status_5xx 12
      metric errors_4xx_pct 18.55
      metric errors_5xx_pct 5.43
      metric bytes_sent 8086
      metric clients 4
      metric status 168 code=200
      metric status 41 code=404

    Reading the results (starting points: tune them to the server):
      Healthy  window_complete 1; errors_5xx_pct below 1; response_p99_ms
               steady.
      Watch    errors_4xx_pct climbing (a broken link, a client retrying, a
               scan); response_p99_ms rising while requests do not;
               window_complete 0 (raise NGINX_LOG_MAX_MB).
      Act      errors_5xx_pct above a few percent: the server or its upstream is
               failing (status says which: 500, 502 bad gateway, 503
               unavailable, 504 timed out); requests 0 on a busy site: nothing
               reaches it, or it stopped logging.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever the log holds; 1 never (an unreadable log is a
      reading)
#>

$Job = 'log'
. (Join-Path $PSScriptRoot '_nginx.ps1')

$f = $env:NGINX_ACCESS_LOG; if (-not $f) { $f = 'C:\nginx\logs\access.log' }
$cap = 32; if ($env:NGINX_LOG_MAX_MB) { $cap = [int]$env:NGINX_LOG_MAX_MB }
Read-LogMinute $f $cap
exit 0
