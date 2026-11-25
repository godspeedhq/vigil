# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The victoriametrics pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='VictoriaMetrics', E='VICTORIAMETRICS', url='http://localhost:8428', version='1.0.0',
    description='VictoriaMetrics: whether it answers and its storage is writable, disk space, ingestion (rows '
                'by protocol, rows refused, new series, limits reached), queries (errors, slow ones, the '
                'concurrency limit), and the targets it scrapes',
    works='VictoriaMetrics single-node 1.90 and later (tested: 1.157.0); each component of a cluster (vminsert, '
          'vmselect, vmstorage) and vmagent report those of these metrics they have',
    head=['victoriametrics - a VictoriaMetrics server, from its own metrics page: is',
          'it up and writable, how much disk is left, what it ingests and what',
          'it turns away, how its queries fare, and are its scrape targets up.'],
    needs=['its address, where it is not http://localhost:8428: env = VICTORIAMETRICS_URL=... on each job',
           'where it asks for a login (-httpAuth.username, or -metricsAuthKey behind a proxy): VICTORIAMETRICS_USER '
           'and secret = VICTORIAMETRICS_PASSWORD=secret:VICTORIAMETRICS_PASSWORD, or secret = '
           'VICTORIAMETRICS_TOKEN=secret:VICTORIAMETRICS_TOKEN for a bearer token',
           "for VictoriaMetrics' CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, VictoriaMetrics' page about itself"

job(pack='victoriametrics', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is VictoriaMetrics up, writable and answering queries',
    what="Reports whether VictoriaMetrics answers, whether its storage has gone read-only for lack of disk, the "
         "disk space left and what its data takes, the requests it answered and those that failed (for each "
         "path), slow queries, and how close its queries are to the limit on running at once.",
    reads=READS + ", and /health.",
    steps=[
        page('/metrics'),
        answers('healthy', '/health', '1 when /health answers 200, else 0'),
        table(
            ('version|info|vm_app_version||short_version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|max|vm_app_uptime_seconds', 'seconds since it started'),
            ('read_only|max|vm_storage_is_read_only',
             '1 when the storage refuses writes: the disk has less free than -storage.minFreeDiskSpaceBytes; else 0'),
            ('free_disk_bytes|min|vm_free_disk_space_bytes', 'free space on the disk its data is on'),
            ('data_bytes|sum|vm_data_size_bytes', 'what its data and index take on disk'),
            ('http_requests_count|sum|vm_http_requests_total', 'requests answered (a running total)'),
            ('http_errors_count|sum|vm_http_request_errors_total', 'requests that failed (a running total)'),
            ('http_errors|by|vm_http_request_errors_total||path', 'the same, for each path, tagged path=<it>'),
            ('slow_queries_count|sum|vm_slow_queries_total', 'queries slower than -search.logSlowQueryDuration (a running total)'),
            ('selects|sum|vm_concurrent_select_current', 'queries running now'),
            ('selects_capacity|sum|vm_concurrent_select_capacity', 'the most it runs at once (-search.maxConcurrentRequests)'),
            ('selects_pct|pct|selects|selects_capacity', 'queries running, as a percentage of that'),
            ('selects_limit_reached_count|sum|vm_concurrent_select_limit_reached_total',
             'times a query had to wait for a place (a running total)'),
            ('selects_limit_timeout_count|sum|vm_concurrent_select_limit_timeout_total',
             'queries turned away after waiting -search.maxQueueDuration (a running total)'),
            ('errors_logged_count|sum|vm_log_messages_total|level=error', 'errors it logged (a running total)'),
            ('panics_logged_count|sum|vm_log_messages_total|level=panic', 'panics it logged (a running total)'),
        ),
    ],
    healthy='up 1; healthy 1; read_only 0; http_errors_count and errors_logged_count not moving.',
    watch='free_disk_bytes falling towards its limit; selects_pct near 100 or selects_limit_reached_count moving '
          '(queries queue); slow_queries_count climbing.',
    act='up 0 or healthy 0; read_only 1: it accepts no more samples until space is freed, and everything sent is '
        'lost or queued at the sender; selects_limit_timeout_count moving: dashboards and rules get errors; '
        'http_errors_count moving on a write path (http_errors says which).')

job(pack='victoriametrics', job='ingestion', metric='ingestion', when='run_every   = 1m', runtime='30s',
    title='what VictoriaMetrics ingests, and what it turns away',
    what="Reports the rows VictoriaMetrics ingests for each protocol (remote write, scraping, InfluxDB, OTLP and "
         "the rest), the rows it refused or ignored and why, the new series created, the slow inserts that "
         "say memory is short for the series it holds, its insert concurrency against its limit, the rows "
         "dropped by a cardinality limit, and what it holds.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('rows_inserted_count|sum|vm_rows_inserted_total', 'rows (samples) ingested (a running total)'),
            ('rows_inserted|by|vm_rows_inserted_total||type', 'the same, for each protocol, tagged type=<promremotewrite, promscrape, influx, ...>'),
            ('rows_invalid_count|sum|vm_rows_invalid_total', 'rows that could not be parsed (a running total)'),
            ('rows_ignored_count|sum|vm_rows_ignored_total',
             'rows ignored: a timestamp outside the retention, a value that is not a number, a label too long (a running total)'),
            ('rows_ignored|by|vm_rows_ignored_total||reason', 'the same, for each reason, tagged reason'),
            ('new_series_count|sum|vm_new_timeseries_created_total', 'series created (a running total): its rate is churn'),
            ('slow_row_inserts_count|sum|vm_slow_row_inserts_total',
             'rows inserted the slow way, their series not in the cache (a running total): a rising share means too little memory for the active series'),
            ('slow_inserts_pct|pct|slow_row_inserts_count|rows_inserted_count', 'slow inserts, as a percentage of all rows since it started'),
            ('inserts|sum|vm_concurrent_insert_current', 'inserts running now'),
            ('inserts_capacity|sum|vm_concurrent_insert_capacity', 'the most it runs at once (-maxConcurrentInserts)'),
            ('inserts_limit_reached_count|sum|vm_concurrent_insert_limit_reached_total', 'times an insert had to wait (a running total)'),
            ('inserts_limit_timeout_count|sum|vm_concurrent_insert_limit_timeout_total',
             'inserts turned away after waiting -insert.maxQueueDuration (a running total)'),
            ('series_limit_dropped_count|sum|vm_hourly_series_limit_rows_dropped_total',
             'rows dropped by -storage.maxHourlySeries (a running total)'),
            ('daily_limit_dropped_count|sum|vm_daily_series_limit_rows_dropped_total', 'rows dropped by -storage.maxDailySeries (a running total)'),
            ('rows|sum|vm_rows|type~^storage', 'rows it holds'),
            ('pending_rows|sum|vm_pending_rows', 'rows received and not yet written to a part'),
            ('active_merges|sum|vm_active_merges', 'merges of parts running now'),
        ),
    ],
    healthy='rows_inserted_count moving; rows_invalid_count, rows_ignored_count and the limit counts not moving.',
    watch='slow_inserts_pct above a few percent (more active series than the memory holds: raise memory or cut '
          'churn); new_series_count climbing fast; inserts_limit_reached_count moving.',
    act='rows_inserted_count not moving: nothing is arriving; rows_ignored_count or rows_invalid_count moving '
        '(rows_ignored says why); series_limit_dropped_count or daily_limit_dropped_count moving: a cardinality '
        'limit is discarding data; inserts_limit_timeout_count moving: senders are being turned away.')

job(pack='victoriametrics', job='targets', metric='targets', when='run_every   = 1m', runtime='30s',
    title="the targets VictoriaMetrics scrapes",
    what="Reports the targets VictoriaMetrics (or vmagent) scrapes itself: how many are up and down, the down "
         "ones for each job, the scrapes made and failed, and whether its scrape configuration reloaded. It "
         "reports zeros where it scrapes nothing (-promscrape.config not set).",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('targets_up|sum|vm_promscrape_targets|status=up', 'targets whose last scrape worked'),
            ('targets_down|sum|vm_promscrape_targets|status=down', 'targets whose last scrape failed'),
            ('scrapes_count|sum|vm_promscrape_scrapes_total', 'scrapes made (a running total)'),
            ('scrapes_failed_count|sum|vm_promscrape_scrapes_failed_total', 'scrapes that failed (a running total)'),
            ('config_reload_ok|min?|vm_promscrape_config_last_reload_successful', '1 when the last reload of the scrape configuration worked, else 0'),
            ('config_reload_errors_count|sum|vm_promscrape_config_reloads_errors_total', 'reloads of it that failed (a running total)'),
            ('down|by|vm_promscrape_scrape_pool_targets|status=down|scrape_job:job', 'the targets down in each job, tagged job=<it>'),
        ),
    ],
    healthy='targets_down 0; scrapes_failed_count not moving; config_reload_ok 1.',
    watch='scrapes_failed_count moving now and then (a target that restarts, or answers slowly).',
    act='targets_down above 0 for more than a few scrapes: down says which job; config_reload_ok 0: an edit it '
        'refused, and it scrapes what it scraped before.')
