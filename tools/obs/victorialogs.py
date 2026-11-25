# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The victorialogs pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='VictoriaLogs', E='VICTORIALOGS', url='http://localhost:9428', version='1.0.0',
    description='VictoriaLogs: whether it answers and its storage is writable, disk space, ingestion (rows and '
                'bytes by protocol, rows dropped and why), requests and those that failed, and queries '
                'against the concurrency limit',
    works='VictoriaLogs single-node 1.0 and later (tested: 1.54.0)',
    head=['victorialogs - a VictoriaLogs server, from its own metrics page: is it',
          'up and writable, how much disk is left, what logs it ingests and what',
          'it drops, and how its queries fare.'],
    needs=['its address, where it is not http://localhost:9428: env = VICTORIALOGS_URL=... on each job',
           'where it asks for a login (-httpAuth.username): VICTORIALOGS_USER and secret = '
           'VICTORIALOGS_PASSWORD=secret:VICTORIALOGS_PASSWORD, or secret = VICTORIALOGS_TOKEN=secret:VICTORIALOGS_TOKEN '
           'for a bearer token',
           "for VictoriaLogs' CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, VictoriaLogs' page about itself"

job(pack='victorialogs', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is VictoriaLogs up, writable and answering queries',
    what="Reports whether VictoriaLogs answers, whether its storage has gone read-only for lack of disk, the "
         "disk space left and what its data takes, the requests it answered and those that failed (for each "
         "path), and how close its queries are to the limit on running at once.",
    reads=READS + ", and /health.",
    steps=[
        page('/metrics'),
        answers('healthy', '/health', '1 when /health answers 200, else 0'),
        table(
            ('version|info|vm_app_version||short_version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|max|vm_app_uptime_seconds', 'seconds since it started'),
            ('read_only|max|vl_storage_is_read_only',
             '1 when the storage refuses writes: the disk has less free than -storage.minFreeDiskSpaceBytes; else 0'),
            ('free_disk_bytes|min|vl_free_disk_space_bytes', 'free space on the disk its data is on'),
            ('data_bytes|sum|vl_data_size_bytes', 'what its data and index take on disk'),
            ('http_requests_count|sum|vl_http_requests_total', 'requests answered (a running total)'),
            ('http_errors_count|sum|vl_http_errors_total', 'requests that failed (a running total)'),
            ('http_errors|by|vl_http_errors_total||path', 'the same, for each path, tagged path=<it>'),
            ('selects|sum|vl_concurrent_select_current', 'queries running now'),
            ('selects_capacity|sum|vl_concurrent_select_capacity', 'the most it runs at once (-search.maxConcurrentRequests)'),
            ('selects_pct|pct|selects|selects_capacity', 'queries running, as a percentage of that'),
            ('selects_limit_reached_count|sum|vl_concurrent_select_limit_reached_total', 'times a query had to wait for a place (a running total)'),
            ('selects_limit_timeout_count|sum|vl_concurrent_select_limit_timeout_total',
             'queries turned away after waiting -search.maxQueueDuration (a running total)'),
            ('live_tails|sum|vl_live_tailing_requests', 'live tails open now'),
            ('errors_logged_count|sum|vm_log_messages_total|level=error', 'errors it logged (a running total)'),
            ('panics_logged_count|sum|vm_log_messages_total|level=panic', 'panics it logged (a running total)'),
        ),
    ],
    healthy='up 1; healthy 1; read_only 0; http_errors_count and errors_logged_count not moving.',
    watch='free_disk_bytes falling towards its limit; selects_pct near 100 or selects_limit_reached_count moving; '
          'http_errors_count moving on a query path (a query that does not parse).',
    act='up 0 or healthy 0; read_only 1: it accepts no more logs until space is freed; '
        'selects_limit_timeout_count moving; http_errors_count moving on an insert path (http_errors says '
        'which): a shipper is being refused.')

job(pack='victorialogs', job='ingestion', metric='ingestion', when='run_every   = 1m', runtime='30s',
    title='what VictoriaLogs ingests, and what it drops',
    what="Reports the log entries and bytes VictoriaLogs ingests for each protocol (JSON lines, OTLP, Loki, "
         "Elasticsearch bulk, syslog and the rest), the entries it dropped and why (a timestamp older than "
         "the retention or too far ahead, too many fields), the lines too long to take, the streams created, "
         "and what it holds.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('rows_ingested_count|sum|vl_rows_ingested_total', 'log entries ingested (a running total)'),
            ('rows_ingested|by|vl_rows_ingested_total||type', 'the same, for each protocol, tagged type=<jsonline, opentelemetry_protobuf, loki, ...>'),
            ('bytes_ingested_count|sum|vl_bytes_ingested_total', 'bytes ingested (a running total)'),
            ('rows_dropped_count|sum|vl_rows_dropped_total', 'entries dropped (a running total)'),
            ('rows_dropped|by|vl_rows_dropped_total||reason',
             'the same, for each reason, tagged reason=<too_small_timestamp: older than the retention; '
             'too_big_timestamp: too far ahead; too_many_fields; debug>'),
            ('too_long_lines_count|sum|vl_too_long_lines_skipped_total', 'lines skipped: longer than -insert.maxLineSizeBytes (a running total)'),
            ('ingest_errors_count|sum|vl_errors_total', 'errors reading what a listener was sent, syslog among them (a running total)'),
            ('streams_created_count|sum|vl_streams_created_total', 'log streams created (a running total): its rate is churn'),
            ('rows|sum|vl_storage_rows', 'entries it holds'),
            ('pending_rows|sum|vl_pending_rows', 'entries received and not yet written to a part'),
            ('partitions|sum|vl_partitions', 'daily partitions on disk'),
            ('active_merges|sum|vl_active_merges', 'merges of parts running now'),
            ('_comp|sum|vl_compressed_data_size_bytes', None),
            ('_raw|sum|vl_uncompressed_data_size_bytes', None),
            ('compression_ratio|div|_raw|_comp', 'what its data would take uncompressed, over what it takes'),
        ),
    ],
    healthy='rows_ingested_count moving; rows_dropped_count and too_long_lines_count not moving.',
    watch='streams_created_count climbing fast (a stream field with too many values: memory and disk follow); '
          'pending_rows growing.',
    act='rows_ingested_count not moving: nothing is arriving; rows_dropped_count moving: rows_dropped says why '
        '(too_small_timestamp: a shipper replaying old logs, or a clock far behind; too_big_timestamp: a clock '
        'ahead); too_long_lines_count moving: lines are being thrown away whole.')
