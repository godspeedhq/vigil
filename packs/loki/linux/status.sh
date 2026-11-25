#!/usr/bin/env bash
#
# status.sh - is Loki ready, its rings whole, its requests answered
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
# Reports whether Loki is ready, the members of its ingester ring that are
# active and those that are not, the requests it answered and those that
# failed, the queries in progress, and the panics and errors it logged. It
# only reads: every request is a GET, and it changes nothing.
#
# Reads LOKI_URL (default http://localhost:3100): /metrics, Loki's page about
# itself, and /ready.
# What the scripts share is in _loki.sh, beside this one.
#
# Metrics:
#   up                   1 when Loki answered its metrics page, else 0 (and
#                        nothing more is read)
#   ready                1 when Loki says it is ready (/ready answers 200),
#                        else 0: it is starting, or an ingester is not in its
#                        ring
#   version              always 1, tagged version=<its version>
#   uptime_seconds       seconds since it started
#   ingesters_active     ingesters active in the ring
#   ingesters_unhealthy  ingesters in the ring that stopped sending heartbeats
#   ring_unhealthy       members of any ring (ingester, distributor,
#                        compactor, scheduler) that stopped
#   ring_not_active      members of any ring joining, leaving or pending
#   requests_count       requests answered (a running total)
#   requests_4xx_count   of those, answered 4xx: a query that does not parse,
#                        a push refused, a limit reached (a running total)
#   requests_5xx_count   answered 5xx: Loki failed (a running total)
#   queries_in_progress  queries the query frontend has in hand
#   queue_length         queries waiting for a querier
#   tails_active         live tails open now
#   panics_count         panics recovered from (a running total)
#   errors_logged_count  errors it logged (a running total)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0;
#            requests_5xx_count not moving.
#   Watch    requests_4xx_count climbing (a query in a dashboard that no
#            longer parses, or pushes being limited: the ingestion job says
#            which); queue_length staying above 0 (too few queriers);
#            ring_not_active above 0 outside a rollout.
#   Act      up 0 or ready 0; ingesters_unhealthy above 0: writes may fail and
#            queries miss recent logs; requests_5xx_count moving; panics_count
#            moving.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Loki does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_loki.sh"
needs curl awk

page '/metrics'
answers ready '/ready'
readings <<'T'
version|info|loki_build_info||version:version
uptime_seconds|age|process_start_time_seconds
ingesters_active|sum|loki_ring_members|name=ingester,state=ACTIVE
ingesters_unhealthy|sum|loki_ring_members|name=ingester,state=Unhealthy
ring_unhealthy|sum|loki_ring_members|state=Unhealthy
ring_not_active|sum|loki_ring_members|state~^[JLP]
requests_count|sum|loki_request_duration_seconds_count
requests_4xx_count|sum|loki_request_duration_seconds_count|status_code~^4
requests_5xx_count|sum|loki_request_duration_seconds_count|status_code~^5
queries_in_progress|sum|loki_query_frontend_queries_in_progress
queue_length|sum|loki_query_scheduler_queue_length
tails_active|sum|loki_querier_tail_active
panics_count|sum|loki_panic_total
errors_logged_count|sum|loki_internal_log_messages_total|level=error
T
exit 0
