#!/usr/bin/env bash
#
# ingestion.sh - what Tempo receives, and what it discards
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
# Reports the spans and bytes Tempo's distributor received, the spans its
# receivers refused, the spans it discarded and why (a trace too large, a rate
# limit, too many live traces), the traces its ingester holds live and has
# created, the blocks it flushed and the flushes that failed. It only reads:
# every request is a GET, and it changes nothing.
#
# Reads TEMPO_URL (default http://localhost:3200): /metrics, Tempo's page
# about itself.
# What the scripts share is in _tempo.sh, beside this one.
#
# Metrics:
#   up                       1 when Tempo answered its metrics page, else 0
#                            (and nothing more is read)
#   spans_received_count     spans received (a running total)
#   bytes_received_count     bytes received (a running total)
#   receiver_accepted_count  spans its receivers (OTLP, Jaeger, Zipkin) took
#                            (a running total)
#   receiver_refused_count   spans its receivers refused (a running total)
#   discarded_count          spans discarded (a running total)
#   discarded                the same, for each reason, tagged
#                            reason=<trace_too_large, rate_limited,
#                            live_traces_exceeded, internal_error ...>
#   discarded_not_shown      how many more there were than the 20 shown
#   live_traces              traces the ingester holds in memory, not yet cut
#                            to a block
#   traces_created_count     traces it started (a running total)
#   blocks_flushed_count     blocks flushed to storage (a running total)
#   flush_failures_count     flushes that failed (a running total)
#   flush_queue              blocks waiting to be flushed
#   append_failures_count    writes an ingester refused or did not answer (a
#                            running total)
#   warnings_count           traces it had to change or cut short (a running
#                            total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric spans_received_count 1503
#   metric bytes_received_count 293623
#   metric receiver_accepted_count 1503
#   metric receiver_refused_count 0
#   metric discarded_count 242
#   metric discarded 242 reason=trace_too_large
#   metric discarded 0 reason=live_traces_exceeded
#   metric discarded 0 reason=unknown_error
#   metric discarded_not_shown 0
#   metric live_traces 21
#   metric traces_created_count 587
#   metric blocks_flushed_count 4
#   metric flush_failures_count 0
#   metric flush_queue 0
#   metric append_failures_count 0
#   metric warnings_count 14
#
# Reading the results (starting points: tune them to your own):
#   Healthy  spans_received_count moving; discarded_count and
#            receiver_refused_count not moving; flush_failures_count at 0.
#   Watch    live_traces climbing towards the tenant's limit; flush_queue
#            growing (storage slower than ingestion).
#   Act      discarded_count moving: discarded says why (trace_too_large: a
#            trace over max_bytes_per_trace, usually a loop; rate_limited:
#            raise the tenant's limits or sample more; live_traces_exceeded);
#            receiver_refused_count moving: senders are being turned away;
#            flush_failures_count moving: blocks are not reaching storage;
#            spans_received_count not moving: nothing arrives.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Tempo does not answer (up 0 is the
#   reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=ingestion
# shellcheck source=/dev/null
. "$(dirname "$0")/_tempo.sh"
needs curl awk

page '/metrics'
readings <<'T'
spans_received_count|sum|tempo_distributor_spans_received_total
bytes_received_count|sum|tempo_distributor_bytes_received_total
receiver_accepted_count|sum|tempo_receiver_accepted_spans
receiver_refused_count|sum|tempo_receiver_refused_spans
discarded_count|sum|tempo_discarded_spans_total
discarded|by|tempo_discarded_spans_total||reason
live_traces|sum|tempo_ingester_live_traces
traces_created_count|sum|tempo_ingester_traces_created_total
blocks_flushed_count|sum|tempo_ingester_blocks_flushed_total
flush_failures_count|sum|tempo_ingester_failed_flushes_total
flush_queue|sum|tempo_ingester_flush_queue_length
append_failures_count|sum|tempo_distributor_ingester_append_failures_total
warnings_count|sum|tempo_warnings_total
T
exit 0
