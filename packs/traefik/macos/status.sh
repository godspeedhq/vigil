#!/usr/bin/env bash
#
# status.sh - is Traefik up, and what is it answering
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
# Reports whether Traefik answers and its ping, how long since its
# configuration last loaded and how many times it has, the connections open on
# each entrypoint, the requests its entrypoints answered and those 4xx and
# 5xx, how long they took, and when the first of its TLS certificates expires.
# It only reads: every request is a GET, and it changes nothing.
#
# Reads TRAEFIK_URL (default http://localhost:8080): /metrics, Traefik's
# Prometheus page, and /ping.
# What the scripts share is in _traefik.sh, beside this one.
#
# Metrics:
#   up                                   1 when Traefik answered its metrics
#                                        page, else 0 (and nothing more is
#                                        read)
#   ping                                 1 when /ping answers 200
#                                        (--ping=true), else 0
#   last_reload_seconds                  seconds since its configuration last
#                                        loaded
#   reloads_count                        configurations loaded (a running
#                                        total)
#   connections                          connections open, every entrypoint
#   connections_by_entrypoint            the same, for each entrypoint, tagged
#                                        entrypoint=
#   connections_by_entrypoint_not_shown  how many more there were than the 20
#                                        shown
#   requests_count                       requests the entrypoints answered (a
#                                        running total)
#   requests_4xx_count                   of them, 4xx: 404 for a host or path
#                                        no router takes (a running total)
#   requests_5xx_count                   of them, 5xx: a backend down or
#                                        failing (a running total)
#   requests_5xx                         the 5xx, for each entrypoint, tagged
#                                        entrypoint=
#   requests_5xx_not_shown               how many more there were than the 20
#                                        shown
#   request_avg_ms                       a request, on average, in
#                                        milliseconds, since it started
#   tls_requests_count                   requests over TLS (a running total)
#   certs                                TLS certificates it serves
#   cert_expires_at                      when the first of them expires, in
#                                        Unix seconds: compare it with now in
#                                        the backend (the config job says it
#                                        in days)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric ping 1
#   metric last_reload_seconds 165
#   metric reloads_count 1
#   metric connections 1
#   metric connections_by_entrypoint 1 entrypoint=traefik
#   metric connections_by_entrypoint 0 entrypoint=web
#   metric connections_by_entrypoint 0 entrypoint=websecure
#   metric requests_count 102
#   metric requests_4xx_count 60
#   metric requests_5xx_count 20
#   metric requests_5xx 20 entrypoint=web
#   metric request_avg_ms 742.947236
#   metric tls_requests_count 2
#   metric certs 2
#   metric cert_expires_at 1796309450
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; ping 1; requests_5xx_count rising slowly, if at all;
#            cert_expires_at more than 30 days ahead.
#   Watch    requests_4xx_count rising fast: a client calling a host or path
#            no router takes; request_avg_ms rising; cert_expires_at within 30
#            days (Traefik renews ACME certificates 30 days ahead: one still
#            within is not renewing).
#   Act      up 0 or ping 0; requests_5xx_count rising: the services job says
#            which; cert_expires_at within 7 days.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Traefik does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_traefik.sh"
needs curl awk

page '/metrics'
answers ping '/ping'
readings <<'T'
last_reload_seconds|age|traefik_config_last_reload_success
reloads_count|sum|traefik_config_reloads_total
connections|sum|traefik_open_connections
connections_by_entrypoint|by|traefik_open_connections||entrypoint
requests_count|sum|traefik_entrypoint_requests_total
requests_4xx_count|sum|traefik_entrypoint_requests_total|code~^4
requests_5xx_count|sum|traefik_entrypoint_requests_total|code~^5
requests_5xx|by|traefik_entrypoint_requests_total|code~^5|entrypoint
_d_s|sum|traefik_entrypoint_request_duration_seconds_sum
_d_n|sum|traefik_entrypoint_request_duration_seconds_count
_d_avg|div|_d_s|_d_n
request_avg_ms|mul|_d_avg|1000
tls_requests_count|sum|traefik_entrypoint_requests_tls_total
certs|count?|traefik_tls_certs_not_after
cert_expires_at|min?|traefik_tls_certs_not_after
T
exit 0
