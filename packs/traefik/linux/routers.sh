#!/usr/bin/env bash
#
# routers.sh - the requests each of Traefik's routers answered, and those that failed
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
# Reports, for each router, the requests it answered and those 4xx and 5xx:
# which application a client's errors belong to. It needs
# --metrics.prometheus.addRoutersLabels=true; without it, nothing. It only
# reads: every request is a GET, and it changes nothing.
#
# Reads TRAEFIK_URL (default http://localhost:8080): /metrics, Traefik's
# Prometheus page.
# What the scripts share is in _traefik.sh, beside this one.
#
# Metrics:
#   up                      1 when Traefik answered its metrics page, else 0
#                           (and nothing more is read)
#   requests_count          requests the routers answered (a running total)
#   requests                the same, for each router, tagged router=
#   requests_not_shown      how many more there were than the 20 shown
#   requests_4xx            the 4xx, for each router
#   requests_4xx_not_shown  how many more there were than the 20 shown
#   requests_5xx            the 5xx, for each router
#   requests_5xx_not_shown  how many more there were than the 20 shown
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  requests_5xx flat for each router.
#   Watch    requests_4xx rising for one router: a client or a link that is
#            wrong.
#   Act      requests_5xx rising for a router: its service fails (the services
#            job).
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Traefik does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=routers
# shellcheck source=/dev/null
. "$(dirname "$0")/_traefik.sh"
needs curl awk

page '/metrics'
readings <<'T'
requests_count|sum?|traefik_router_requests_total
requests|by|traefik_router_requests_total||router
requests_4xx|by|traefik_router_requests_total|code~^4|router
requests_5xx|by|traefik_router_requests_total|code~^5|router
T
exit 0
