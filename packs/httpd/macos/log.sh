#!/usr/bin/env bash
#
# log.sh - Apache httpd's access log, minute by minute
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reads the last whole minute of Apache httpd's access log, in the combined
# format, and reports the requests in it: by status class and status, by
# method, the bytes sent, the clients, and, when the log records it, how long
# the answers took (rtus=%D at the end of the LogFormat). It reads only the
# end of the log, at most HTTPD_LOG_MAX_MB (32 by default), so it costs the
# same on a log of any size, and keeps nothing between runs. It never prints a
# path, a query or an address: only counts. It only reads: it changes nothing.
#
# Reads HTTPD_ACCESS_LOG (default the first of /var/log/httpd/access_log,
# /var/log/apache2/access.log, /usr/local/apache2/logs/access_log,
# /opt/homebrew/var/log/httpd/access_log, /usr/local/var/log/httpd/access_log
# that is there on Linux and macOS, C:\Apache24\logs\access.log on Windows).
# The account Vigil runs as must be allowed to read it (packs/httpd/README.md
# says how); until it is, the job reports log_readable 0 and nothing else.
# What the scripts share is in _httpd.sh, beside this one.
#
# Metrics:
#   log_found        1 when the access log is there, else 0
#   log_readable     1 when this account may read it, else 0 (and nothing more
#                    is read)
#   log_bytes        the log's size
#   window_complete  1 when the whole minute was read; 0 when the log grew
#                    faster than HTTPD_LOG_MAX_MB a minute, and the counts are
#                    of its end only
#   requests         requests logged in the last whole minute
#   status_1xx       of those, answered 1xx
#   status_2xx       answered 2xx
#   status_3xx       answered 3xx
#   status_4xx       answered 4xx: the client asked wrong (not found, refused,
#                    too many)
#   status_5xx       answered 5xx: the server failed
#   errors_4xx_pct   4xx, as a percentage of the requests
#   errors_5xx_pct   5xx, as a percentage of the requests
#   bytes_sent       bytes sent in answers
#   clients          client addresses seen
#   status           requests answered with one status, tagged code=<it> (each
#                    one seen)
#   method           requests by method, tagged method=<GET, POST, HEAD, PUT,
#                    DELETE, PATCH, OPTIONS or other>
#   response_avg_ms  time to answer, on average, when the log records it
#                    (rtus=%D at the end of the LogFormat)
#   response_p50_ms  half the requests were answered within this
#   response_p90_ms  90% were answered within this
#   response_p99_ms  99% were answered within this
#   response_max_ms  the slowest
#
# Example output (the rest are in the same form):
#   metric log_found 1
#   metric log_readable 1
#   metric log_bytes 21563
#   metric window_complete 1
#   metric requests 177
#   metric status_1xx 0
#   metric status_2xx 162
#   metric status_3xx 0
#   metric status_4xx 10
#   metric status_5xx 5
#   metric errors_4xx_pct 5.65
#   metric errors_5xx_pct 2.82
#   metric bytes_sent 33392
#   metric clients 3
#   metric status 162 code=200
#   metric status 10 code=404
#
# Reading the results (starting points: tune them to the server):
#   Healthy  window_complete 1; errors_5xx_pct below 1; response_p99_ms
#            steady.
#   Watch    errors_4xx_pct climbing (a broken link, a client retrying, a
#            scan); response_p99_ms rising while requests do not;
#            window_complete 0 (raise HTTPD_LOG_MAX_MB).
#   Act      errors_5xx_pct above a few percent: the server or its upstream is
#            failing (status says which: 500, 502 bad gateway, 503
#            unavailable, 504 timed out); requests 0 on a busy site: nothing
#            reaches it, or it stopped logging.
#
# Requires: bash
# Exit code: 0, whatever the log holds; 1 never (an unreadable log is a
#   reading)

set -u

job=log
# shellcheck source=/dev/null
. "$(dirname "$0")/_httpd.sh"

f=${HTTPD_ACCESS_LOG-}
if [ -z "$f" ]; then
    for f in /var/log/httpd/access_log /var/log/apache2/access.log /usr/local/apache2/logs/access_log /opt/homebrew/var/log/httpd/access_log /usr/local/var/log/httpd/access_log; do [ -e "$f" ] && break; done
fi
log_minute "$f" "${HTTPD_LOG_MAX_MB:-32}"
exit 0
