#!/usr/bin/env bash
#
# services.sh - Traefik's backend servers, up and down, and the services that fail
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
# Reports the backend servers Traefik health-checks, those up and those down,
# each down server by its URL, and for each service the servers down; the
# requests each service answered, those 5xx, for each service, and how long
# they took; and the retries. It only reads: every request is a GET, and it
# changes nothing.
#
# Reads TRAEFIK_URL (default http://localhost:8080): /metrics, Traefik's
# Prometheus page.
# What the scripts share is in _traefik.sh, beside this one.
#
# Metrics:
#   up                         1 when Traefik answered its metrics page, else
#                              0 (and nothing more is read)
#   servers                    backend servers health-checked
#   servers_down               of them, down: their health check fails
#   server_down                each server: 1 when down, tagged url=<its URL>
#   server_down_not_shown      how many more there were than the 20 shown
#   down_by_service            servers down, for each service, tagged service=
#   down_by_service_not_shown  how many more there were than the 20 shown
#   requests_count             requests the services answered (a running
#                              total)
#   requests_5xx_count         of them, 5xx (a running total)
#   requests_5xx               the 5xx, for each service, tagged service=
#   requests_5xx_not_shown     how many more there were than the 20 shown
#   request_avg_ms             a request to a backend, on average, in
#                              milliseconds
#   retries_count              requests retried on another server (the retry
#                              middleware; a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric servers 3
#   metric servers_down 1
#   metric server_down 1 url=http://nowhere:80
#   metric server_down 0 url=http://w1:80
#   metric server_down 0 url=http://w2:80
#   metric down_by_service 1 service=app@file
#   metric requests_count 42
#   metric requests_5xx_count 20
#   metric requests_5xx 20 service=gone@file
#   metric request_avg_ms 1804.14556
#
# Reading the results (starting points: tune them to your own):
#   Healthy  servers_down 0; requests_5xx_count flat.
#   Watch    servers_down above 0 in a service with others up: it carries on
#            with fewer; retries_count rising.
#   Act      down_by_service equal to a service's servers: that service has
#            none, and answers 503; requests_5xx rising for a service: its
#            backend fails (502 when it cannot be reached, 504 when it is too
#            slow).
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Traefik does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=services
# shellcheck source=/dev/null
. "$(dirname "$0")/_traefik.sh"
needs curl awk

page '/metrics'
readings <<'T'
servers|count?|traefik_service_server_up
servers_down|count?|traefik_service_server_up||=0
server_down|countby?|traefik_service_server_up||url:url =0
down_by_service|countby?|traefik_service_server_up||service:service =0
requests_count|sum?|traefik_service_requests_total
requests_5xx_count|sum?|traefik_service_requests_total|code~^5
requests_5xx|by|traefik_service_requests_total|code~^5|service
_d_s|sum?|traefik_service_request_duration_seconds_sum
_d_n|sum?|traefik_service_request_duration_seconds_count
_d_avg|div|_d_s|_d_n
request_avg_ms|mul|_d_avg|1000
retries_count|sum?|traefik_service_retries_total
T
exit 0
