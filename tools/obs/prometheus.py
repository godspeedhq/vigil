# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The prometheus pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table, extra

PACK = dict(
    P='Prometheus', E='PROMETHEUS', url='http://localhost:9090', version='1.0.0',
    description='Prometheus: whether it is ready and its configuration loaded, targets up and down, the TSDB '
                '(head, WAL, compactions), rule evaluation and alerts firing, notifications to Alertmanager, '
                'remote write queues and how far they are behind',
    works='Prometheus 2.40 and later, and 3.x (tested: 3.15.1)',
    head=['prometheus - a Prometheus server, from its own metrics page and its',
          'federation page: is it ready, are its targets up, is its TSDB sound,',
          'are its rules evaluated, do its alerts reach an Alertmanager, and does',
          'its remote write keep up.'],
    needs=['its address, where it is not http://localhost:9090: env = PROMETHEUS_URL=... on each job',
           'where it asks for a login: PROMETHEUS_USER and secret = PROMETHEUS_PASSWORD=secret:PROMETHEUS_PASSWORD, '
           'or secret = PROMETHEUS_TOKEN=secret:PROMETHEUS_TOKEN for a bearer token',
           "for Prometheus' CPU and memory: the base pack's processes job"])

READS = ("Reads @E@_URL (default @URL@): /metrics, Prometheus' page about itself")

job(pack='prometheus', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Prometheus ready, loaded and answering',
    what="Reports whether Prometheus is ready, whether its last configuration reload worked and when, the "
         "queries it is running against the most it allows, the requests it answered and those that failed, "
         "and the alerts it sent to its Alertmanagers, with those that failed or were dropped.",
    reads=READS + ", and /-/ready.",
    steps=[
        page('/metrics'),
        answers('ready', '/-/ready', '1 when Prometheus says it is ready to serve (/-/ready answers 200), else 0: '
                                     'it is starting, replaying its WAL, or shutting down'),
        table(
            ('version|info|prometheus_build_info||version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('config_reload_ok|min|prometheus_config_last_reload_successful',
             '1 when the last configuration reload worked, else 0: it is still running the one before'),
            ('config_age_seconds|age|prometheus_config_last_reload_success_timestamp_seconds',
             'seconds since the configuration it runs was loaded'),
            ('queries|sum|prometheus_engine_queries', 'queries running or waiting now'),
            ('queries_max|sum|prometheus_engine_queries_concurrent_max', 'the most it runs at once (--query.max-concurrency)'),
            ('queries_pct|pct|queries|queries_max', 'queries, as a percentage of that'),
            ('http_requests_count|sum|prometheus_http_requests_total', 'requests answered (a running total)'),
            ('http_4xx_count|sum|prometheus_http_requests_total|code~^4', 'of those, answered 4xx: a query it could not parse, or refused (a running total)'),
            ('http_5xx_count|sum|prometheus_http_requests_total|code~^5', 'answered 5xx: it failed, or a query timed out (a running total)'),
            ('alertmanagers|sum|prometheus_notifications_alertmanagers_discovered', 'Alertmanagers it found to send alerts to'),
            ('notifications_sent_count|sum|prometheus_notifications_sent_total', 'alerts sent to them (a running total)'),
            ('notifications_errors_count|sum|prometheus_notifications_errors_total', 'alerts an Alertmanager did not take (a running total)'),
            ('notifications_errors|by|prometheus_notifications_errors_total||alertmanager',
             'the same, for each Alertmanager, tagged alertmanager=<its address>'),
            ('notifications_dropped_count|sum|prometheus_notifications_dropped_total',
             'alerts dropped: the queue was full, or no Alertmanager took them (a running total)'),
            ('notification_queue|sum|prometheus_notifications_queue_length', 'alerts waiting to be sent'),
            ('notification_queue_capacity|sum|prometheus_notifications_queue_capacity', 'how many may wait'),
            ('_fds|sum|process_open_fds', None),
            ('_maxfds|sum|process_max_fds', None),
            ('fds_pct|pct|_fds|_maxfds', 'open files, as a percentage of its limit'),
        ),
    ],
    healthy='up 1; ready 1; config_reload_ok 1; http_5xx_count and notifications_errors_count not moving.',
    watch='queries_pct near 100 (queries queue behind --query.max-concurrency); notification_queue growing; '
          'http_4xx_count climbing (a dashboard or a rule with a query that no longer parses).',
    act='up 0 or ready 0; config_reload_ok 0 (an edit it refused: it runs the old configuration until the file is '
        'fixed); notifications_errors_count or notifications_dropped_count climbing: alerts are not reaching '
        'anyone; fds_pct above 80.')

job(pack='prometheus', job='targets', metric='targets', when='run_every   = 1m', runtime='30s',
    title="Prometheus' targets, up and down",
    what="Reports the targets Prometheus scrapes: how many are up and how many down, the down ones for each "
         "job, the slowest scrape, and the scrapes it had to cut short or reject (too many samples, samples "
         "out of order, duplicate timestamps).",
    reads=READS + ", and /federate for the up, scrape_duration_seconds and scrape_samples_scraped series (one "
          "line a target).",
    steps=[
        page('/metrics'),
        table(
            ('scrape_pools|count|prometheus_target_scrape_pool_targets', 'scrape jobs configured'),
            ('targets|sum|prometheus_target_scrape_pool_targets', 'targets in them'),
            ('discovered_targets|sum|prometheus_sd_discovered_targets|name=scrape', 'targets service discovery found, before relabelling'),
            ('sd_failed_configs|sum|prometheus_sd_failed_configs', 'service discovery configurations that could not be loaded'),
            ('pool_reloads_failed_count|sum|prometheus_target_scrape_pool_reloads_failed_total', 'scrape jobs that could not be reloaded (a running total)'),
            ('exceeded_sample_limit_count|sum|prometheus_target_scrapes_exceeded_sample_limit_total',
             'scrapes rejected whole: more samples than sample_limit (a running total)'),
            ('exceeded_body_size_count|sum|prometheus_target_scrapes_exceeded_body_size_limit_total',
             'scrapes rejected whole: a page larger than body_size_limit (a running total)'),
            ('exceeded_target_limit_count|sum|prometheus_target_scrape_pool_exceeded_target_limit_total',
             'times a scrape job had more targets than target_limit: none of them is scraped (a running total)'),
            ('out_of_order_count|sum|prometheus_target_scrapes_sample_out_of_order_total', 'samples rejected: out of order (a running total)'),
            ('duplicate_timestamp_count|sum|prometheus_target_scrapes_sample_duplicate_timestamp_total',
             'samples rejected: the same series twice in one scrape (a running total)'),
            ('out_of_bounds_count|sum|prometheus_target_scrapes_sample_out_of_bounds_total', 'samples rejected: too old or too far ahead (a running total)'),
        ),
        extra('/federate?match[]=up&match[]=scrape_duration_seconds&match[]=scrape_samples_scraped',
              ('targets_up|count|up||=1', 'targets whose last scrape worked'),
              ('targets_down|count|up||=0', 'targets whose last scrape failed: nothing answered, or not with metrics'),
              ('down|countby|up||job:job =0', 'the targets down in each job, tagged job=<it> (0 for a job with none down)'),
              ('scrape_slowest_seconds|max|scrape_duration_seconds', 'the slowest target\'s last scrape'),
              ('samples_scraped|sum|scrape_samples_scraped', 'samples the last scrape of every target brought'),
              ),
    ],
    healthy='targets_down 0; the rejected counts not moving; scrape_slowest_seconds well under the scrape interval.',
    watch='scrape_slowest_seconds near the scrape timeout (a target about to fail); out_of_order_count or '
          'duplicate_timestamp_count climbing (an exporter printing a series twice, or two Prometheus scraping '
          'into one).',
    act='targets_down above 0 for more than a few scrapes: down says which job; exceeded_sample_limit_count or '
        'exceeded_target_limit_count moving: whole scrapes are being thrown away; sd_failed_configs above 0.')

job(pack='prometheus', job='tsdb', metric='tsdb', when='run_every   = 1m', runtime='30s',
    title="Prometheus' time series database",
    what="Reports Prometheus' TSDB: the series and chunks in its head, the samples appended, what its blocks "
         "and its WAL take on disk, how far back its data goes, and everything that failed: compactions, WAL "
         "writes, truncations and checkpoints, reloads of its blocks, and corruptions found.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('head_series|sum|prometheus_tsdb_head_series', 'series in memory: the cardinality it carries now'),
            ('head_chunks|sum|prometheus_tsdb_head_chunks', 'chunks in memory'),
            ('series_created_count|sum|prometheus_tsdb_head_series_created_total', 'series created (a running total): its rate is churn'),
            ('samples_appended_count|sum|prometheus_tsdb_head_samples_appended_total', 'samples appended (a running total)'),
            ('out_of_order_samples_count|sum|prometheus_tsdb_out_of_order_samples_total', 'samples refused: out of order (a running total)'),
            ('blocks|sum|prometheus_tsdb_blocks_loaded', 'blocks on disk it has loaded'),
            ('blocks_bytes|sum|prometheus_tsdb_storage_blocks_bytes', 'what they take'),
            ('wal_bytes|sum|prometheus_tsdb_wal_storage_size_bytes', 'what the WAL takes'),
            ('head_chunks_bytes|sum|prometheus_tsdb_head_chunks_storage_size_bytes', "what the head's chunks on disk take"),
            ('retention_seconds|sum|prometheus_tsdb_retention_limit_seconds', 'how long it keeps data (0: no limit by time)'),
            ('oldest_sample_seconds|age|prometheus_tsdb_lowest_timestamp_seconds', 'how far back its data goes, in seconds'),
            ('newest_sample_seconds|age|prometheus_tsdb_head_max_time_seconds', 'seconds since the newest sample it holds: it is ingesting when this stays small'),
            ('compactions_count|sum|prometheus_tsdb_compactions_total', 'compactions run (a running total)'),
            ('compactions_failed_count|sum|prometheus_tsdb_compactions_failed_total', 'compactions that failed (a running total)'),
            ('wal_corruptions_count|sum|prometheus_tsdb_wal_corruptions_total', 'corruptions found in the WAL (a running total)'),
            ('wal_writes_failed_count|sum|prometheus_tsdb_wal_writes_failed_total', 'WAL writes that failed (a running total)'),
            ('wal_truncations_failed_count|sum|prometheus_tsdb_wal_truncations_failed_total', 'WAL truncations that failed (a running total)'),
            ('checkpoints_failed_count|sum|prometheus_tsdb_checkpoint_creations_failed_total', 'checkpoints that failed (a running total)'),
            ('head_truncations_failed_count|sum|prometheus_tsdb_head_truncations_failed_total', 'head truncations that failed (a running total)'),
            ('reloads_failed_count|sum|prometheus_tsdb_reloads_failures_total', 'reloads of its blocks from disk that failed (a running total)'),
            ('mmap_corruptions_count|sum|prometheus_tsdb_mmap_chunk_corruptions_total', "corruptions found in the head's chunks on disk (a running total)"),
            ('clean_start|min|prometheus_tsdb_clean_start', '1 when it started from a clean shutdown; 0 when it had to recover; -1 when it cannot tell'),
        ),
    ],
    healthy='head_series steady or growing slowly; newest_sample_seconds under a minute; every failed count at 0.',
    watch='head_series or series_created_count climbing fast (a label with too many values: memory follows); '
          'wal_bytes growing without end (checkpoints or truncations failing); clean_start 0 after a restart.',
    act='any of compactions_failed_count, wal_writes_failed_count, checkpoints_failed_count, reloads_failed_count '
        'moving: the disk is full, read-only or failing; wal_corruptions_count or mmap_corruptions_count above 0; '
        'newest_sample_seconds growing: it has stopped ingesting.')

job(pack='prometheus', job='rules', metric='rules', when='run_every   = 1m', runtime='30s',
    title="Prometheus' rules and alerts",
    what="Reports Prometheus' recording and alerting rules: the groups and rules loaded, evaluations and those "
         "that failed (for each group), iterations a group missed because the one before was still running, "
         "the slowest group, how stale the stalest one is, and the alerts firing and pending.",
    reads=READS + ", and /federate for the ALERTS series (one line an alert).",
    steps=[
        page('/metrics'),
        table(
            ('groups|count|prometheus_rule_group_rules', 'rule groups loaded'),
            ('rules|sum|prometheus_rule_group_rules', 'rules in them'),
            ('evaluations_count|sum|prometheus_rule_evaluations_total', 'rule evaluations (a running total)'),
            ('evaluation_failures_count|sum|prometheus_rule_evaluation_failures_total', 'evaluations that failed (a running total)'),
            ('evaluation_failures|by|prometheus_rule_evaluation_failures_total||rule_group:group',
             'the same, for each group, tagged group=<file;name>'),
            ('iterations_missed_count|sum|prometheus_rule_group_iterations_missed_total',
             'times a group was skipped: its last run had not ended (a running total)'),
            ('slowest_group_seconds|max|prometheus_rule_group_last_duration_seconds', 'how long the slowest group took, last time'),
            ('stalest_group_seconds|oldest|prometheus_rule_group_last_evaluation_timestamp_seconds',
             'seconds since the group evaluated longest ago was evaluated'),
        ),
        extra('/federate?match[]=ALERTS',
              ('alerts_firing|count|ALERTS|alertstate=firing', 'alerts firing now'),
              ('alerts_pending|count|ALERTS|alertstate=pending', 'alerts whose condition holds, waiting out their "for"'),
              ('firing|countby|ALERTS|alertstate=firing|alertname:alert', 'the alerts firing, for each alert rule, tagged alert=<its name>'),
              ),
    ],
    healthy='evaluation_failures_count and iterations_missed_count not moving; stalest_group_seconds under twice '
            'the longest group interval.',
    watch='slowest_group_seconds near its group interval (it will start missing iterations); alerts_pending '
          'staying high.',
    act='evaluation_failures_count moving: evaluation_failures says which group (its alerts cannot fire, and its '
        'recorded series go stale); iterations_missed_count moving; stalest_group_seconds growing: rules have '
        'stopped being evaluated; alerts_firing, which is what the rules are for.')

job(pack='prometheus', job='remote_write', metric='remote_write', when='run_every   = 1m', runtime='30s',
    title="Prometheus' remote write",
    what="Reports Prometheus' remote write queues: the samples sent, failed, retried and dropped, those waiting "
         "(for each remote), the shards in use against the most allowed, and how far the slowest remote is "
         "behind what Prometheus has ingested. It reports zeros where no remote write is configured.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('remotes|count|prometheus_remote_storage_samples_pending', 'remote write destinations configured'),
            ('samples_sent_count|sum|prometheus_remote_storage_samples_total', 'samples sent (a running total)'),
            ('samples_failed_count|sum|prometheus_remote_storage_samples_failed_total',
             'samples a remote refused for good: they are lost to it (a running total)'),
            ('samples_failed|by|prometheus_remote_storage_samples_failed_total||remote_name:remote', 'the same, for each remote, tagged remote=<its name>'),
            ('samples_retried_count|sum|prometheus_remote_storage_samples_retried_total',
             'samples sent again after a failure that may pass: the remote was down or slow (a running total)'),
            ('samples_dropped_count|sum|prometheus_remote_storage_samples_dropped_total',
             'samples dropped before sending: relabelled away, or too old (a running total)'),
            ('samples_pending|sum|prometheus_remote_storage_samples_pending', 'samples waiting in the queues'),
            ('pending|by|prometheus_remote_storage_samples_pending||remote_name:remote', 'the same, for each remote, tagged remote'),
            ('shards|sum|prometheus_remote_storage_shards', 'shards sending now'),
            ('shards_max|sum|prometheus_remote_storage_shards_max', 'the most it may use'),
            ('shards_desired|sum|prometheus_remote_storage_shards_desired', 'how many it works out it needs: above shards_max, it cannot keep up'),
            ('_in|max|prometheus_remote_storage_highest_timestamp_in_seconds', None),
            ('_sent|minpos|prometheus_remote_storage_queue_highest_sent_timestamp_seconds', None),
            ('behind_seconds|sub|_in|_sent', 'how far the slowest remote that has sent anything is behind the newest sample ingested, in seconds'),
            ('remotes_never_sent|count|prometheus_remote_storage_queue_highest_sent_timestamp_seconds||=0',
             'remotes that have not taken a single sample since Prometheus started'),
        ),
    ],
    healthy='samples_failed_count not moving; behind_seconds under a minute; samples_pending small and steady.',
    watch='samples_retried_count climbing (a remote that is slow or flapping); shards near shards_max.',
    act='behind_seconds growing: a remote is down or too slow, and pending says which; remotes_never_sent above 0 '
        'once Prometheus has run a few minutes: a remote that was never there; '
        'samples_failed_count '
        'moving: samples_failed says which remote refuses them (a limit reached there, or samples it rejects); '
        'shards_desired above shards_max.')
