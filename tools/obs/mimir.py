# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The mimir pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='Mimir', E='MIMIR', url='http://localhost:9009', version='1.0.0',
    description='Grafana Mimir: whether it is ready and its rings whole (ingesters, distributors, store-gateways, '
                'compactors), ingestion (samples received, discarded and why, series in memory), requests and '
                'those that failed or were refused, and its storage (blocks shipped, compactions, the bucket)',
    works='Grafana Mimir 2.10 and later, and 3.x (tested: 3.2.6, one binary); in microservices mode, each '
          'component reports those of these metrics it has',
    head=['mimir - a Grafana Mimir, from its own metrics page: is it ready and are',
          'its rings whole, what samples does it receive and what does it',
          'discard, are its blocks shipped and compacted, and does its bucket',
          'answer.'],
    needs=['its address, where it is not http://localhost:9009: env = MIMIR_URL=... on each job (in microservices '
           'mode, a component: the ingestion job at a distributor or an ingester, the storage job at an '
           'ingester, a compactor or a store-gateway)',
           'where it asks for a login (a proxy in front of it): MIMIR_USER and secret = MIMIR_PASSWORD=secret:MIMIR_PASSWORD, '
           'or secret = MIMIR_TOKEN=secret:MIMIR_TOKEN for a bearer token',
           "for Mimir's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Mimir's page about itself"

job(pack='mimir', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Mimir ready, its rings whole, its requests answered',
    what="Reports whether Mimir is ready, the members of its rings that are active and those that are not "
         "(ingesters above all: a write needs a quorum of them), the requests it answered and those that "
         "failed, the requests in flight, and those it refused to protect itself.",
    reads=READS + ", and /ready.",
    steps=[
        page('/metrics'),
        answers('ready', '/ready', '1 when Mimir says it is ready (/ready answers 200), else 0: it is starting, '
                                   'or a ring it needs is not whole'),
        table(
            ('version|info|mimir_build_info||version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('ingesters_active|sum|cortex_ring_members|name=ingester,state=ACTIVE', 'ingesters active in the ring'),
            ('ingesters_unhealthy|sum|cortex_ring_members|name=ingester,state=Unhealthy',
             'ingesters in the ring that stopped sending heartbeats'),
            ('store_gateways_active|sum|cortex_ring_members|name=store-gateway,state=ACTIVE', 'store-gateways active in their ring'),
            ('compactors_active|sum|cortex_ring_members|name=compactor,state=ACTIVE', 'compactors active in their ring'),
            ('ring_unhealthy|sum|cortex_ring_members|state=Unhealthy', 'members of any ring that stopped sending heartbeats'),
            ('ring_not_active|sum|cortex_ring_members|state~^[JLP]', 'members of any ring joining, leaving or pending'),
            ('requests_count|sum|cortex_request_duration_seconds_count', 'requests answered (a running total)'),
            ('requests_4xx_count|sum|cortex_request_duration_seconds_count|status_code~^4',
             'of those, answered 4xx: a query that does not parse, samples refused, a limit reached (a running total)'),
            ('requests_5xx_count|sum|cortex_request_duration_seconds_count|status_code~^5', 'answered 5xx: Mimir failed (a running total)'),
            ('inflight_requests|sum|cortex_inflight_requests', 'requests in flight now'),
            ('distributor_rejected_count|sum|cortex_distributor_instance_rejected_requests_total',
             'requests a distributor refused: one of its instance limits was reached (a running total)'),
            ('ingester_rejected_count|sum|cortex_ingester_instance_rejected_requests_total',
             'requests an ingester refused: one of its instance limits was reached (a running total)'),
            ('querier_rejected_count|sum|cortex_querier_queries_rejected_total', 'queries refused (a running total)'),
        ),
    ],
    healthy='up 1; ready 1; ingesters_unhealthy and ring_unhealthy 0; requests_5xx_count not moving.',
    watch='requests_4xx_count climbing (the ingestion job says whether samples are being discarded); '
          'ring_not_active above 0 outside a rollout; inflight_requests climbing.',
    act='up 0 or ready 0; ingesters_unhealthy above 0: with a replication factor of 3, a second one lost stops '
        'writes; requests_5xx_count moving; distributor_rejected_count or ingester_rejected_count moving: Mimir '
        'is turning work away to stay up.')

job(pack='mimir', job='ingestion', metric='ingestion', when='run_every   = 1m', runtime='30s',
    title='what Mimir receives, and what it discards',
    what="Reports the samples Mimir's distributor received, the samples it discarded and why (a tenant's series "
         "limit, its rate limit, samples too old or out of order, labels it does not accept), the series and "
         "tenants its ingester holds in memory, the samples appended and those that failed, and the pushes in "
         "flight.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('samples_in_count|sum|cortex_distributor_samples_in_total', 'samples sent to the distributor, before any check (a running total)'),
            ('samples_received_count|sum|cortex_distributor_received_samples_total', 'samples it accepted (a running total)'),
            ('discarded_count|sum|cortex_discarded_samples_total', 'samples discarded (a running total)'),
            ('discarded|by|cortex_discarded_samples_total||reason',
             'the same, for each reason, tagged reason=<per_user_series_limit, per_metric_series_limit, rate_limited, '
             'sample-out-of-order, sample-too-old, label_invalid, metric_name_invalid ...>'),
            ('series|sum|cortex_ingester_memory_series', 'series the ingester holds in memory'),
            ('tenants|sum|cortex_ingester_memory_users', 'tenants it holds series for'),
            ('active_series|sum|cortex_ingester_active_series', 'series that received a sample lately'),
            ('ingested_samples_count|sum|cortex_ingester_ingested_samples_total', 'samples the ingester appended (a running total)'),
            ('ingested_failures_count|sum|cortex_ingester_ingested_samples_failures_total', 'samples it could not append (a running total)'),
            ('append_failures_count|sum|cortex_distributor_ingester_append_failures_total', 'writes an ingester refused or did not answer (a running total)'),
            ('pushes_in_flight|sum|cortex_distributor_inflight_push_requests', 'pushes the distributor is handling now'),
            ('out_of_order_appended_count|sum|cortex_ingester_tsdb_out_of_order_samples_appended_total',
             'out-of-order samples it took, where that is allowed (a running total)'),
        ),
    ],
    healthy='samples_received_count moving; discarded_count not moving; ingested_failures_count at 0.',
    watch='series climbing towards a tenant\'s limit; ingested_failures_count moving a little (out-of-order or '
          'duplicate samples from a sender).',
    act='discarded_count moving: discarded says why (per_user_series_limit: the tenant is at its limit and new '
        'series are lost; rate_limited: it sends faster than it may; sample-too-old; label_invalid); '
        'append_failures_count moving: ingesters are refusing or missing; samples_received_count not moving: '
        'nothing arrives.')

job(pack='mimir', job='storage', metric='storage', when='run_every   = 5m', runtime='30s',
    title="Mimir's blocks, compactor and bucket",
    what="Reports what happens to Mimir's data after it is ingested: the blocks its ingester ships to the "
         "bucket and the uploads that failed, how old the oldest block not yet shipped is, the head "
         "compactions and truncations that failed, the compactor's runs and when one last succeeded, the "
         "blocks its store-gateway loaded and those it could not, and the bucket operations that failed.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('shipper_uploads_count|sum|cortex_ingester_shipper_uploads_total', 'blocks shipped to the bucket (a running total)'),
            ('shipper_failures_count|sum|cortex_ingester_shipper_upload_failures_total', 'uploads that failed (a running total)'),
            ('oldest_unshipped_seconds|age|cortex_ingester_oldest_unshipped_block_timestamp_seconds',
             'the age of the oldest block not yet shipped (nothing when all are)'),
            ('head_compactions_failed_count|sum|cortex_ingester_tsdb_compactions_failed_total', "the ingester's head compactions that failed (a running total)"),
            ('head_truncations_failed_count|sum|cortex_ingester_tsdb_head_truncations_failed_total', 'head truncations that failed (a running total)'),
            ('wal_corruptions_count|sum|cortex_ingester_tsdb_wal_corruptions_total', 'corruptions found in the WAL (a running total)'),
            ('wal_writes_failed_count|sum|cortex_ingester_tsdb_wal_writes_failed_total', 'WAL writes that failed (a running total)'),
            ('compactor_runs_count|sum|cortex_compactor_runs_completed_total', 'compactor runs completed (a running total)'),
            ('compactor_runs_failed_count|sum|cortex_compactor_runs_failed_total', 'compactor runs that failed (a running total)'),
            ('last_compaction_seconds|age|cortex_compactor_last_successful_run_timestamp_seconds', 'seconds since a compactor run last succeeded'),
            ('cleanup_failures_count|sum|cortex_compactor_block_cleanup_failures_total', 'cleanups of deleted blocks that failed (a running total)'),
            ('blocks_loaded|sum|cortex_bucket_store_blocks_loaded', 'blocks the store-gateway has loaded'),
            ('block_load_failures_count|sum|cortex_bucket_store_block_load_failures_total', 'blocks it could not load (a running total)'),
            ('consistency_failures_count|sum|cortex_querier_blocks_consistency_checks_failed_total',
             'queries that could not find every block they needed in a store-gateway (a running total)'),
            ('bucket_operations_count|sum|thanos_objstore_bucket_operations_total', 'operations on the bucket (a running total)'),
            ('bucket_failures_count|sum|thanos_objstore_bucket_operation_failures_total', 'operations on the bucket that failed (a running total)'),
            ('bucket_failures|by|thanos_objstore_bucket_operation_failures_total||operation',
             'the same, for each operation, tagged operation=<get, upload, iter, exists, delete ...>'),
        ),
    ],
    healthy='every failed count at 0; last_compaction_seconds under a few compaction intervals; '
            'oldest_unshipped_seconds, when printed, under a few hours.',
    watch='bucket_failures_count moving now and then (the object store throttling, or a network that drops); '
          'cleanup_failures_count moving.',
    act='shipper_failures_count moving, or oldest_unshipped_seconds growing: blocks stay on the ingester\'s disk, '
        'which fills, and they are lost if it is; compactor_runs_failed_count moving or last_compaction_seconds '
        'growing: blocks pile up and queries slow; block_load_failures_count or consistency_failures_count '
        'moving: queries are missing data; any WAL count above 0.')
