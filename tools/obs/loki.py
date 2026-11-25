# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The loki pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='Loki', E='LOKI', url='http://localhost:3100', version='1.0.0',
    description='Loki: whether it is ready and its rings whole, ingestion (lines and bytes received, entries '
                'discarded and why, streams, chunks flushed and flushes failed), requests and those that '
                'failed, and its compactor (last compaction, retention, delete requests)',
    works='Loki 2.9 and later, and 3.x (tested: 3.7.9, one binary); in microservices mode, each component '
          'reports those of these metrics it has',
    head=['loki - a Loki, from its own metrics page: is it ready and are its rings',
          'whole, what logs does it receive and what does it discard, do its',
          'chunks get flushed, and does its compactor run.'],
    needs=['its address, where it is not http://localhost:3100: env = LOKI_URL=... on each job (in microservices '
           'mode, a component: the ingestion job at a distributor or an ingester, the compaction job at the '
           'compactor)',
           'where it asks for a login (a proxy in front of it): LOKI_USER and secret = LOKI_PASSWORD=secret:LOKI_PASSWORD, '
           'or secret = LOKI_TOKEN=secret:LOKI_TOKEN for a bearer token',
           "for Loki's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Loki's page about itself"

job(pack='loki', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Loki ready, its rings whole, its requests answered',
    what="Reports whether Loki is ready, the members of its ingester ring that are active and those that are "
         "not, the requests it answered and those that failed, the queries in progress, and the panics and "
         "errors it logged.",
    reads=READS + ", and /ready.",
    steps=[
        page('/metrics'),
        answers('ready', '/ready', '1 when Loki says it is ready (/ready answers 200), else 0: it is starting, '
                                   'or an ingester is not in its ring'),
        table(
            ('version|info|loki_build_info||version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('ingesters_active|sum|loki_ring_members|name=ingester,state=ACTIVE', 'ingesters active in the ring'),
            ('ingesters_unhealthy|sum|loki_ring_members|name=ingester,state=Unhealthy',
             'ingesters in the ring that stopped sending heartbeats'),
            ('ring_unhealthy|sum|loki_ring_members|state=Unhealthy', 'members of any ring (ingester, distributor, compactor, scheduler) that stopped'),
            ('ring_not_active|sum|loki_ring_members|state~^[JLP]', 'members of any ring joining, leaving or pending'),
            ('requests_count|sum|loki_request_duration_seconds_count', 'requests answered (a running total)'),
            ('requests_4xx_count|sum|loki_request_duration_seconds_count|status_code~^4',
             'of those, answered 4xx: a query that does not parse, a push refused, a limit reached (a running total)'),
            ('requests_5xx_count|sum|loki_request_duration_seconds_count|status_code~^5', 'answered 5xx: Loki failed (a running total)'),
            ('queries_in_progress|sum|loki_query_frontend_queries_in_progress', 'queries the query frontend has in hand'),
            ('queue_length|sum|loki_query_scheduler_queue_length', 'queries waiting for a querier'),
            ('tails_active|sum|loki_querier_tail_active', 'live tails open now'),
            ('panics_count|sum|loki_panic_total', 'panics recovered from (a running total)'),
            ('errors_logged_count|sum|loki_internal_log_messages_total|level=error', 'errors it logged (a running total)'),
        ),
    ],
    healthy='up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.',
    watch='requests_4xx_count climbing (a query in a dashboard that no longer parses, or pushes being limited: '
          'the ingestion job says which); queue_length staying above 0 (too few queriers); ring_not_active '
          'above 0 outside a rollout.',
    act='up 0 or ready 0; ingesters_unhealthy above 0: writes may fail and queries miss recent logs; '
        'requests_5xx_count moving; panics_count moving.')

job(pack='loki', job='ingestion', metric='ingestion', when='run_every   = 1m', runtime='30s',
    title='what Loki receives, and what it discards',
    what="Reports the log lines and bytes Loki's distributor received, the entries it discarded and why "
         "(too old, a line too long, a rate limit, too many streams), the streams and chunks its ingester "
         "holds in memory, the chunks flushed to storage and the flushes that failed, and the WAL's failures.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('lines_received_count|sum|loki_distributor_lines_received_total', 'log lines received (a running total)'),
            ('bytes_received_count|sum|loki_distributor_bytes_received_total', 'bytes received (a running total)'),
            ('discarded_count|sum|loki_discarded_samples_total', 'entries discarded (a running total)'),
            ('discarded|by|loki_discarded_samples_total||reason',
             'the same, for each reason, tagged reason=<greater_than_max_sample_age, line_too_long, rate_limited, '
             'per_stream_rate_limit, stream_limit, too_far_behind ...>'),
            ('discarded_bytes_count|sum|loki_discarded_bytes_total', 'bytes discarded (a running total)'),
            ('streams|sum|loki_ingester_memory_streams', 'streams the ingester holds in memory'),
            ('chunks|sum|loki_ingester_memory_chunks', 'chunks it holds in memory'),
            ('streams_created_count|sum|loki_ingester_streams_created_total', 'streams created (a running total): its rate is churn'),
            ('chunks_flushed_count|sum|loki_ingester_chunks_flushed_total', 'chunks flushed to storage (a running total)'),
            ('flush_failures_count|sum|loki_ingester_chunks_flush_failures_total', 'flushes that failed (a running total)'),
            ('flush_queue|sum|loki_ingester_flush_queue_length', 'chunks waiting to be flushed'),
            ('wal_disk_full_count|sum|loki_ingester_wal_disk_full_failures_total', "WAL writes refused: the WAL's disk is full (a running total)"),
            ('wal_corruptions_count|sum|loki_ingester_wal_corruptions_total', 'corruptions found replaying the WAL (a running total)'),
            ('checkpoints_failed_count|sum|loki_ingester_checkpoint_creations_failed_total', 'WAL checkpoints that failed (a running total)'),
            ('append_failures_count|sum|loki_distributor_ingester_append_failures_total', 'writes an ingester refused or did not answer (a running total)'),
        ),
    ],
    healthy='lines_received_count moving; discarded_count not moving; flush_failures_count and the WAL counts at 0.',
    watch='streams or streams_created_count climbing fast (a label with too many values); flush_queue growing '
          '(storage slower than ingestion).',
    act='discarded_count moving: discarded says why (rate_limited and stream_limit: raise the tenant\'s limits or '
        'cut what is sent; greater_than_max_sample_age: a shipper replaying, or a clock behind; line_too_long); '
        'flush_failures_count moving: chunks are not reaching storage, and an ingester restart would lose them; '
        'wal_disk_full_count or append_failures_count moving; lines_received_count not moving: nothing arrives.')

job(pack='loki', job='compaction', metric='compaction', when='run_every   = 5m', runtime='30s',
    title="Loki's compactor and retention",
    what="Reports Loki's compactor: its compactions done and failed and how long ago the last one succeeded, "
         "the same for retention, and the delete requests waiting with the age of the oldest. It reports "
         "little where no compactor runs at @E@_URL.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('compactor_active|sum|loki_ring_members|name=compactor,state=ACTIVE', 'compactors active in their ring'),
            ('compactions_count|sum|loki_boltdb_shipper_compact_tables_operation_total|status=success', 'compactions that succeeded (a running total)'),
            ('compactions_failed_count|sum|loki_boltdb_shipper_compact_tables_operation_total|status=failure', 'compactions that failed (a running total)'),
            ('last_compaction_seconds|age|loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds',
             'seconds since a compaction last succeeded'),
            ('retention_runs_count|sum|loki_compactor_apply_retention_operation_total|status=success', 'retention runs that succeeded (a running total)'),
            ('retention_failed_count|sum|loki_compactor_apply_retention_operation_total|status=failure', 'retention runs that failed (a running total)'),
            ('last_retention_seconds|age|loki_compactor_apply_retention_last_successful_run_timestamp_seconds',
             'seconds since retention was last applied'),
            ('delete_requests_pending|sum|loki_compactor_pending_delete_requests_count', 'delete requests waiting to be processed'),
            ('oldest_delete_request_seconds|max|loki_compactor_oldest_pending_delete_request_age_seconds', 'the age of the oldest of them'),
            ('tables_skipped|sum|loki_compactor_locked_table_successive_compaction_skips', 'compactions skipped in a row because a table was locked'),
        ),
    ],
    healthy='last_compaction_seconds under a few compaction intervals (10 minutes by default); the failed counts not moving.',
    watch='delete_requests_pending or oldest_delete_request_seconds growing; tables_skipped above 0.',
    act='last_compaction_seconds growing, or compactions_failed_count moving: the index is not compacted (queries '
        'slow down) and, with retention on, nothing is deleted (storage grows without end); '
        'retention_failed_count moving; compactor_active 0 where one should run.')
