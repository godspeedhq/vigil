# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The tempo pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='Tempo', E='TEMPO', url='http://localhost:3200', version='1.0.0',
    description='Grafana Tempo: whether it is ready and its ingester ring whole, ingestion (spans received, '
                'refused and discarded, and why; live traces; blocks flushed), requests and those that '
                'failed, and its storage (compaction, retention, the blocklist)',
    works='Grafana Tempo 2.x (tested: 2.10.10, one binary); in microservices mode, each component reports '
          'those of these metrics it has',
    head=['tempo - a Grafana Tempo, from its own metrics page: is it ready and is',
          'its ingester ring whole, what spans does it receive and what does it',
          'discard, are its blocks flushed, and are they compacted.'],
    needs=['its address, where it is not http://localhost:3200: env = TEMPO_URL=... on each job (in microservices '
           'mode, a component: the ingestion job at a distributor or an ingester, the storage job at the '
           'compactor)',
           'where it asks for a login (a proxy in front of it): TEMPO_USER and secret = TEMPO_PASSWORD=secret:TEMPO_PASSWORD, '
           'or secret = TEMPO_TOKEN=secret:TEMPO_TOKEN for a bearer token',
           "for Tempo's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Tempo's page about itself"

job(pack='tempo', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Tempo ready, its ring whole, its requests answered',
    what="Reports whether Tempo is ready, the members of its ingester ring that are active and those that are "
         "not, the requests it answered and those that failed, and the requests in flight.",
    reads=READS + ", and /ready.",
    steps=[
        page('/metrics'),
        answers('ready', '/ready', '1 when Tempo says it is ready (/ready answers 200), else 0: it is starting, '
                                   'or an ingester is not in its ring'),
        table(
            ('version|info|tempo_build_info||version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('ingesters_active|sum|tempo_ring_members|name=ingester,state=ACTIVE', 'ingesters active in the ring'),
            ('ingesters_unhealthy|sum|tempo_ring_members|name=ingester,state=Unhealthy',
             'ingesters in the ring that stopped sending heartbeats'),
            ('ring_unhealthy|sum|tempo_ring_members|state=Unhealthy', 'members of any ring that stopped sending heartbeats'),
            ('ring_not_active|sum|tempo_ring_members|state~^[JLP]', 'members of any ring joining, leaving or pending'),
            ('requests_count|sum|tempo_request_duration_seconds_count', 'requests answered (a running total)'),
            ('requests_4xx_count|sum|tempo_request_duration_seconds_count|status_code~^4',
             'of those, answered 4xx: a search that does not parse, a trace that is not there, a limit reached (a running total)'),
            ('requests_5xx_count|sum|tempo_request_duration_seconds_count|status_code~^5', 'answered 5xx: Tempo failed (a running total)'),
            ('inflight_requests|sum|tempo_inflight_requests', 'requests in flight now'),
        ),
    ],
    healthy='up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.',
    watch='requests_4xx_count climbing; ring_not_active above 0 outside a rollout.',
    act='up 0 or ready 0; ingesters_unhealthy above 0: spans may be refused and recent traces missing; '
        'requests_5xx_count moving.')

job(pack='tempo', job='ingestion', metric='ingestion', when='run_every   = 1m', runtime='30s',
    title='what Tempo receives, and what it discards',
    what="Reports the spans and bytes Tempo's distributor received, the spans its receivers refused, the spans "
         "it discarded and why (a trace too large, a rate limit, too many live traces), the traces its "
         "ingester holds live and has created, the blocks it flushed and the flushes that failed.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('spans_received_count|sum|tempo_distributor_spans_received_total', 'spans received (a running total)'),
            ('bytes_received_count|sum|tempo_distributor_bytes_received_total', 'bytes received (a running total)'),
            ('receiver_accepted_count|sum|tempo_receiver_accepted_spans', 'spans its receivers (OTLP, Jaeger, Zipkin) took (a running total)'),
            ('receiver_refused_count|sum|tempo_receiver_refused_spans', 'spans its receivers refused (a running total)'),
            ('discarded_count|sum|tempo_discarded_spans_total', 'spans discarded (a running total)'),
            ('discarded|by|tempo_discarded_spans_total||reason',
             'the same, for each reason, tagged reason=<trace_too_large, rate_limited, live_traces_exceeded, internal_error ...>'),
            ('live_traces|sum|tempo_ingester_live_traces', 'traces the ingester holds in memory, not yet cut to a block'),
            ('traces_created_count|sum|tempo_ingester_traces_created_total', 'traces it started (a running total)'),
            ('blocks_flushed_count|sum|tempo_ingester_blocks_flushed_total', 'blocks flushed to storage (a running total)'),
            ('flush_failures_count|sum|tempo_ingester_failed_flushes_total', 'flushes that failed (a running total)'),
            ('flush_queue|sum|tempo_ingester_flush_queue_length', 'blocks waiting to be flushed'),
            ('append_failures_count|sum|tempo_distributor_ingester_append_failures_total', 'writes an ingester refused or did not answer (a running total)'),
            ('warnings_count|sum|tempo_warnings_total', 'traces it had to change or cut short (a running total)'),
        ),
    ],
    healthy='spans_received_count moving; discarded_count and receiver_refused_count not moving; '
            'flush_failures_count at 0.',
    watch='live_traces climbing towards the tenant\'s limit; flush_queue growing (storage slower than ingestion).',
    act='discarded_count moving: discarded says why (trace_too_large: a trace over max_bytes_per_trace, usually '
        'a loop; rate_limited: raise the tenant\'s limits or sample more; live_traces_exceeded); '
        'receiver_refused_count moving: senders are being turned away; flush_failures_count moving: blocks are '
        'not reaching storage; spans_received_count not moving: nothing arrives.')

job(pack='tempo', job='storage', metric='storage', when='run_every   = 5m', runtime='30s',
    title="Tempo's blocks, compaction and retention",
    what="Reports Tempo's storage: the blocks in each tenant's blocklist, the compactions run and those that "
         "failed, the blocks retention deleted and its failures, the polls of the blocklist that failed, "
         "and the requests to the backend (the bucket, or the disk) that failed.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('blocks|sum|tempodb_blocklist_length', 'blocks in the blocklist, every tenant'),
            ('compactions_count|sum|tempodb_compaction_blocks_total', 'blocks compacted (a running total)'),
            ('compaction_errors_count|sum|tempodb_compaction_errors_total', 'compactions that failed (a running total)'),
            ('retention_deleted_count|sum|tempodb_retention_deleted_total', 'blocks retention deleted (a running total)'),
            ('retention_errors_count|sum|tempodb_retention_errors_total', 'retention runs that failed (a running total)'),
            ('blocklist_poll_errors_count|sum|tempodb_blocklist_poll_errors_total', 'polls of the blocklist that failed (a running total)'),
            ('backend_requests_count|sum|tempodb_backend_request_duration_seconds_count', 'requests to the backend (a running total)'),
            ('backend_errors_count|sum|tempodb_backend_request_duration_seconds_count|status_code~^5',
             'of those, the ones the backend failed (a running total)'),
            ('work_queue|sum|tempodb_work_queue_length', 'jobs waiting in its read queue'),
        ),
    ],
    healthy='compaction_errors_count, retention_errors_count and blocklist_poll_errors_count not moving.',
    watch='blocks growing without end (compaction or retention not keeping up); work_queue staying above 0.',
    act='compaction_errors_count moving: blocks pile up and searches slow; retention_errors_count moving: '
        'nothing is deleted and storage grows; blocklist_poll_errors_count or backend_errors_count moving: Tempo '
        'cannot read its storage, and queries miss traces.')
