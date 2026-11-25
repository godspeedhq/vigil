# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""Each obs pack's page (packs/<pack>/README.md), for tools/obs/gen.py: what
it says before its jobs, what each job reports in a line, and what to alert
on, each row with what the test stack showed (tools/obs/DESIGN.md)."""

PAGES = {}

PAGES['prometheus'] = dict(
    intro="A Prometheus server, from what it says about itself. The pack reads whether it is ready and its last "
          "configuration reload worked; its targets, up and down, for each job; its TSDB (the series in its head, its "
          "WAL, its blocks, and everything that failed); its rules (evaluations that failed, for each group, and the "
          "alerts firing); the alerts it sends to its Alertmanagers and those that do not get there; and its remote "
          "write queues, with how far the slowest remote is behind.",
    why="It is the usual blind spot: Prometheus watches everything, and nothing watches Prometheus. When it stops "
        "scraping, its alerts stop too, and silence looks like health. This pack runs beside it and reports to "
        "wherever Vigil reports, so a Prometheus in trouble is said by something that is not Prometheus.",
    setup=["Nothing to turn on: Prometheus serves `/metrics`, `/-/ready` and `/federate` already.",
           "`vigil pack enable prometheus`, then in `vigil.config` set what differs from the defaults, in the jobs' "
           "`env` lines: `PROMETHEUS_URL` (`http://localhost:9090`; with `--web.route-prefix`, that prefix too), and "
           "where it asks for a login, `PROMETHEUS_USER` with `secret = PROMETHEUS_PASSWORD=secret:PROMETHEUS_PASSWORD` "
           "(then `vigil secret set PROMETHEUS_PASSWORD`), or a bearer token as `PROMETHEUS_TOKEN` the same way."],
    reports={
        'status': 'Up and ready; version; the last configuration reload, and how long ago; queries against the most allowed; requests, 4xx and 5xx; Alertmanagers found, alerts sent, failed (for each Alertmanager) and dropped; open files against the limit',
        'targets': 'Targets up and down, the down ones for each job; the slowest scrape; scrapes rejected whole (sample, body and target limits); samples rejected (out of order, duplicate, out of bounds)',
        'tsdb': 'Series and chunks in the head, churn, samples appended; blocks, WAL and head on disk; retention, and how far back and how fresh its data is; compactions, WAL writes, truncations, checkpoints and reloads that failed; corruptions',
        'rules': 'Rule groups and rules; evaluations, and those that failed for each group; iterations missed; the slowest and the stalest group; alerts firing (for each alert) and pending',
        'remote_write': 'For all remotes and each: samples sent, failed, retried, dropped and waiting; shards against the most allowed; how far the slowest remote is behind; remotes that never took a sample',
    },
    alerts=[
        ('`prometheus.up`, `ready`', '1', '', '0: it is down, starting, or replaying its WAL. Its own alerts are silent meanwhile', '`up 0` where nothing listened; `ready 1` otherwise'),
        ('`prometheus.config_reload_ok`', '1', '', '0: an edit it refused. It runs the old configuration until the file is fixed', '0 after a file with a broken line and a reload; 1 again once mended'),
        ('`prometheus.targets.targets_down`', '0', 'Above 0 for a few scrapes', 'Staying above 0: `down` says which job', '3: two in `job=dead`, one in `job=notmetrics`; 4 with Tempo stopped'),
        ('`prometheus.rules.evaluation_failures_count`', 'Flat', '', 'Rising: `evaluation_failures` names the group. Its alerts cannot fire', 'Rising, all in the group `broken`'),
        ('`prometheus.notifications_errors_count`, `notifications_dropped_count`', 'Flat', '', 'Rising: alerts fire and reach nobody', 'Rising for the Alertmanager that was not there, named in `notifications_errors`'),
        ('`prometheus.remote_write.behind_seconds`', 'Under a minute', 'Rising', 'Minutes and rising: a remote is down or too slow; `pending` says which', 'Seconds, for the two remotes that answered'),
        ('`prometheus.remote_write.samples_failed_count`', 'Flat', '', 'Rising: a remote refuses samples for good (`samples_failed` says which)', 'Rising for `remote=mimir`, which was at its series limit'),
        ('`prometheus.remote_write.remotes_never_sent`', '0', '', 'Above 0 a few minutes after a start: a remote that was never there', '1: the remote nothing listened to'),
        ('`prometheus.tsdb.head_series`', 'Steady', 'Rising fast: a label with too many values', '', 'About 15,600 for the stack\'s twelve targets'),
        ('`prometheus.tsdb.wal_corruptions_count`, `compactions_failed_count`', '0, flat', '', 'Above 0, or rising: the disk is full, read-only or failing', 'Not caused'),
    ])

PAGES['alertmanager'] = dict(
    intro="An Alertmanager, from what it says about itself. The pack reads whether it is ready and its configuration "
          "loaded; the alerts and silences it holds; the notifications it sent and those that failed, for each "
          "integration and each reason; and its view of its cluster: the members it sees and the peers it has lost.",
    why="Alertmanager is the last step before a person. If its webhook has a stale token or its cluster has split, "
        "every alert upstream still fires, and nobody is told. This is the pack whose alerts must not go through the "
        "Alertmanager it watches: Vigil sends its metrics to your backend by a path of its own.",
    setup=["Nothing to turn on: Alertmanager serves `/metrics` and `/-/ready` already.",
           "`vigil pack enable alertmanager`, then in `vigil.config` set what differs from the defaults: "
           "`ALERTMANAGER_URL` (`http://localhost:9093`). For a cluster, install the pack on each member's machine: "
           "each reports its own view, and a split shows as members that disagree.",
           "Where it asks for a login: `ALERTMANAGER_USER` with `secret = ALERTMANAGER_PASSWORD=secret:ALERTMANAGER_PASSWORD`, "
           "or a bearer token as `ALERTMANAGER_TOKEN`."],
    reports={
        'status': 'Up and ready; version; the last configuration reload, and how long ago; alerts active, suppressed and unprocessed; alerts received and refused as invalid; silences; receivers, integrations, inhibition rules; aggregation groups',
        'notifications': 'Notifications attempted and failed, for each integration and each reason; requests to the services notified, and those that failed; how long a notification takes',
        'cluster': 'Clustering on; members seen and peers lost; health score; position among the members; gossip waiting and dropped; reconnections that failed; peers joined and left',
    },
    alerts=[
        ('`alertmanager.up`, `ready`', '1', '', '0: no alert reaches anyone through it', '`up 0` where nothing listened'),
        ('`alertmanager.config_reload_ok`', '1', '', '0: an edit it refused. Routes and receivers are the old ones', '0 after a file with a broken line and a reload; 1 again once mended'),
        ('`alertmanager.notifications.notifications_failed_count`', 'Flat', '', 'Rising: `failed` says which integration, `failed_reason` why', 'Rising: every notification to the webhook nothing listened to'),
        ('`alertmanager.notifications.failed_pct`', '0', 'A few percent', 'Most of them: a receiver is broken', 'About two thirds: one receiver of two failed'),
        ('`alertmanager.cluster.members`', 'The number you run', '', 'Fewer: the cluster is split. Expect duplicate notifications', '2; then 1 when the other member stopped'),
        ('`alertmanager.cluster.failed_peers`', '0', '', 'Above 0: a peer is lost and being retried', '1 when the other member stopped; 0 again when it came back'),
        ('`alertmanager.alerts_invalid_count`', 'Flat', 'Rising: a sender posts alerts it cannot read', '', 'Not caused'),
    ])

PAGES['grafana'] = dict(
    intro="A Grafana, from what it says about itself and, for its data sources, from its API with a read-only token. "
          "The pack reads whether it is healthy (its database too); the requests it answered and those that failed; its "
          "database connections; whether each data source answers; and its own alerting: rules evaluated and failed, "
          "alerts in each state, and the notifications that got through and did not.",
    why="A dashboard that shows nothing looks the same whether the system is quiet or the data source is gone. And "
        "Grafana's alert rules stop evaluating, without a sound, when the data source they read stops answering.",
    setup=["Nothing to turn on for two of its three jobs: Grafana serves `/metrics` (unless `[metrics] enabled = false`) "
           "and `/api/health` already.",
           "**For the datasources job, a token that may only view.** In Grafana: Administration, Users and access, "
           "Service accounts; add one with the role **Viewer**, and a token for it. Then `vigil secret set GRAFANA_TOKEN` "
           "and paste it. A Viewer may list the data sources and ask each for its health; it can change nothing. With no "
           "token to give, turn that one job off: `vigil pack disable grafana_datasources`.",
           "`vigil pack enable grafana`, then in `vigil.config` set what differs from the defaults: `GRAFANA_URL` "
           "(`http://localhost:3000`; with `serve_from_sub_path`, that path too). Where `/metrics` asks for a login "
           "(`[metrics] basic_auth_username`): `GRAFANA_USER` with `secret = GRAFANA_PASSWORD=secret:GRAFANA_PASSWORD` "
           "on the status and alerting jobs."],
    reports={
        'status': 'Up and healthy (its database too); version; dashboards, users, alert rules, data sources by kind; requests, 4xx and 5xx; database connections and waits; plugin requests that failed, for each plugin',
        'alerting': 'Rules scheduled; evaluations, and those that failed; alerts in each state (alerting, pending, no data, error); how far the scheduler is behind; notifications sent and failed, for each integration; silences',
        'datasources': "Each data source (the first 20 by name): whether it answered Grafana's own check; how many are failing",
    },
    alerts=[
        ('`grafana.up`, `healthy`', '1', '', '0: nobody can open a dashboard, and its alert rules are not evaluated', '`up 0` where nothing listened'),
        ('`grafana.datasources.datasources_failing`', '0', '', 'Above 0: `datasource_ok 0` names it. Its dashboards are empty and its alert rules error', '1: `name=Dead`; 2 with Tempo stopped (`name=Tempo`)'),
        ('`grafana.datasources.login_ok`', '1', '', '0: the token is missing, expired or revoked: the job sees nothing', '0 with a token it refused, and with none'),
        ('`grafana.alerting.evaluation_failures_count`, `alerts_error`', 'Flat; 0', '', 'Rising; above 0: a rule cannot be evaluated, so it cannot fire', 'Rising, a third of all evaluations; `alerts_error 1`: the rule reading the dead data source'),
        ('`grafana.alerting.notifications_failed_count`', 'Flat', '', 'Rising: alerts fire and reach nobody; `notifications_failed` says through which integration', 'Rising: every notification, through `integration=webhook`'),
        ('`grafana.alerting.alerts_nodata`', '0', 'Above 0: a query that brings nothing back', '', 'Not caused'),
        ('`grafana.alerting.last_tick_seconds`', 'Under a minute', '', 'Rising: alerting has stopped', '0 to 10'),
        ('`grafana.http_5xx_count`', 'Flat', '', 'Rising: Grafana is failing requests', 'Not caused'),
        ('`grafana.db_waits_count`', 'Flat', 'Rising: requests queue for the database', '', 'Not caused'),
    ])

PAGES['loki'] = dict(
    intro="A Loki, from what it says about itself. The pack reads whether it is ready and its rings whole; the lines "
          "and bytes it received, and the entries it discarded with the reason for each; the streams and chunks its "
          "ingester holds, and whether its chunks reach storage; and its compactor: when it last ran, whether "
          "retention is applied, and the delete requests waiting.",
    why="Loki answers a push with success and then discards entries by policy: too old, too long, over a limit. The "
        "sender sees nothing wrong. The only place that says so is Loki's own counters, one reason at a time.",
    setup=["Nothing to turn on: Loki serves `/metrics` and `/ready` already.",
           "`vigil pack enable loki`, then in `vigil.config` set what differs from the defaults: `LOKI_URL` "
           "(`http://localhost:3100`). In microservices mode each job reads one component: point `loki_ingestion` at a "
           "distributor or an ingester and `loki_compaction` at the compactor, or install the pack beside each. A "
           "component reports the readings it has, and zeros for the rest.",
           "Where a proxy in front of it asks for a login: `LOKI_USER` with `secret = LOKI_PASSWORD=secret:LOKI_PASSWORD`, "
           "or a bearer token as `LOKI_TOKEN`."],
    reports={
        'status': 'Up and ready; version; ingesters active and unhealthy; members of any ring unhealthy or not active; requests, 4xx and 5xx; queries in progress and queued; live tails; panics and errors logged',
        'ingestion': 'Lines and bytes received; entries discarded, for each reason; streams and chunks in memory; chunks flushed, flushes failed and waiting; WAL failures; writes ingesters refused',
        'compaction': 'Compactor active; compactions done and failed, and how long since one succeeded; the same for retention; delete requests waiting, and the oldest',
    },
    alerts=[
        ('`loki.up`, `ready`', '1', '', '0: it takes no logs and answers no query', '`up 0` where nothing listened'),
        ('`loki.ingesters_unhealthy`', '0', '', 'Above 0: writes may fail and queries miss recent logs', '0'),
        ('`loki.ingestion.discarded_count`', 'Flat', '', 'Rising: `discarded` says why, one reason a line', 'Rising: `greater_than_max_sample_age` and `line_too_long`, half each'),
        ('`loki.ingestion.flush_failures_count`', '0, flat', '', 'Rising: chunks are not reaching storage', 'Not caused'),
        ('`loki.ingestion.lines_received_count`', 'Rising', '', 'Flat: nothing is arriving', 'Rising'),
        ('`loki.requests_5xx_count`', 'Flat', '', 'Rising: Loki is failing requests', 'Not caused'),
        ('`loki.requests_4xx_count`', 'Flat', 'Rising: a query that no longer parses, or pushes being refused', '', 'Rising: the bad query and the refused pushes, sent on purpose'),
        ('`loki.compaction.last_compaction_seconds`', 'Under a few compaction intervals', '', 'Rising without end: the index is not compacted and nothing is deleted', 'Under a minute, with a 1-minute interval'),
    ])

PAGES['mimir'] = dict(
    intro="A Grafana Mimir, from what it says about itself. The pack reads whether it is ready and its rings whole; "
          "the samples it received, and those it discarded with the reason for each; the series its ingester holds; "
          "the requests it failed or refused to protect itself; and what happens to its data afterwards: blocks "
          "shipped to the bucket, the compactor, the store-gateway, and the bucket itself.",
    why="Mimir enforces limits by discarding. A tenant at its series limit gets an error its sender may only count, "
        "and the series it was about to create never exist: a new deployment's metrics are simply not there. The "
        "reason is in one counter, with a label saying which limit.",
    setup=["Nothing to turn on: Mimir serves `/metrics` and `/ready` already.",
           "`vigil pack enable mimir`, then in `vigil.config` set what differs from the defaults: `MIMIR_URL` "
           "(`http://localhost:9009`; often 8080 in a deployment). In microservices mode each job reads one component: "
           "point `mimir_ingestion` at a distributor or an ingester and `mimir_storage` at an ingester, a compactor or a "
           "store-gateway, or install the pack beside each. A component reports the readings it has, and zeros for the rest.",
           "Where a proxy in front of it asks for a login: `MIMIR_USER` with `secret = MIMIR_PASSWORD=secret:MIMIR_PASSWORD`, "
           "or a bearer token as `MIMIR_TOKEN`."],
    reports={
        'status': 'Up and ready; version; ingesters, store-gateways and compactors active; members of any ring unhealthy or not active; requests, 4xx and 5xx; requests in flight; requests refused by instance limits',
        'ingestion': 'Samples sent, accepted and discarded, for each reason; series and tenants in memory; active series; samples appended and failed; writes ingesters refused; pushes in flight',
        'storage': 'Blocks shipped and uploads failed; the oldest block not shipped; head compactions, truncations and WAL failures; compactor runs, failures, and how long since one succeeded; blocks loaded and not; bucket operations failed, for each operation',
    },
    alerts=[
        ('`mimir.up`, `ready`', '1', '', '0: it takes no samples and answers no query', '`up 0` where nothing listened'),
        ('`mimir.ingesters_unhealthy`', '0', '', 'Above 0: with a replication factor of 3, a second one lost stops writes', '0'),
        ('`mimir.ingestion.discarded_count`', 'Flat', '', 'Rising: `discarded` says why (which limit, or what is wrong with the samples)', 'Rising: `per_user_series_limit` above all, the tenant held at 200 series'),
        ('`mimir.ingestion.series`', 'Below the tenant\'s limit', 'Nearing it', 'At it: new series are lost', '200, the limit set'),
        ('`mimir.requests_5xx_count`', 'Flat', '', 'Rising: Mimir is failing requests', '1, at its start'),
        ('`mimir.distributor_rejected_count`, `ingester_rejected_count`', 'Flat', '', 'Rising: it is turning work away to stay up', 'Not caused'),
        ('`mimir.storage.shipper_failures_count`', '0, flat', '', 'Rising: blocks stay on the ingester\'s disk, which fills', 'Not caused'),
        ('`mimir.storage.last_compaction_seconds`', 'Under a few compaction intervals', '', 'Rising without end: blocks pile up and queries slow', 'Under a minute, with a 1-minute interval'),
        ('`mimir.storage.bucket_failures_count`', 'Flat', 'Rising now and then', 'Rising steadily: the object store is failing; `bucket_failures` says which operation', 'Not caused'),
    ])

PAGES['tempo'] = dict(
    intro="A Grafana Tempo, from what it says about itself. The pack reads whether it is ready and its ingester ring "
          "whole; the spans it received, those its receivers refused and those it discarded, with the reason for "
          "each; the traces it holds live and the blocks it flushes; and its storage: compaction, retention and the "
          "list of blocks.",
    why="A trace that is too large, or a tenant over its rate, is dropped by Tempo with a success to the sender's "
        "batch as a whole. The trace you go looking for during an incident is the one most likely to have been the "
        "large one.",
    setup=["Nothing to turn on: Tempo serves `/metrics` and `/ready` already.",
           "`vigil pack enable tempo`, then in `vigil.config` set what differs from the defaults: `TEMPO_URL` "
           "(`http://localhost:3200`). In microservices mode each job reads one component: point `tempo_ingestion` at a "
           "distributor or an ingester and `tempo_storage` at the compactor, or install the pack beside each.",
           "Where a proxy in front of it asks for a login: `TEMPO_USER` with `secret = TEMPO_PASSWORD=secret:TEMPO_PASSWORD`, "
           "or a bearer token as `TEMPO_TOKEN`."],
    reports={
        'status': 'Up and ready; version; ingesters active and unhealthy; members of any ring unhealthy or not active; requests, 4xx and 5xx; requests in flight',
        'ingestion': 'Spans and bytes received; spans its receivers took and refused; spans discarded, for each reason; live traces and traces created; blocks flushed, flushes failed and waiting; writes ingesters refused',
        'storage': 'Blocks in the blocklist; compactions and those that failed; blocks retention deleted, and its failures; polls of the blocklist that failed; requests to the backend that failed',
    },
    alerts=[
        ('`tempo.up`, `ready`', '1', '', '0: it takes no spans and answers no query', '`up 0` when it was stopped; then three other packs saw it too'),
        ('`tempo.ingesters_unhealthy`', '0', '', 'Above 0: spans may be refused and recent traces missing', '0'),
        ('`tempo.ingestion.discarded_count`', 'Flat', '', 'Rising: `discarded` says why', 'Rising: `trace_too_large`, the traces of 40 spans against a limit of 2 KB'),
        ('`tempo.ingestion.receiver_refused_count`', 'Flat', '', 'Rising: senders are being turned away', 'Not caused'),
        ('`tempo.ingestion.flush_failures_count`', '0, flat', '', 'Rising: blocks are not reaching storage', 'Not caused'),
        ('`tempo.ingestion.spans_received_count`', 'Rising', '', 'Flat: nothing is arriving', 'Rising'),
        ('`tempo.storage.compaction_errors_count`, `retention_errors_count`', 'Flat', '', 'Rising: blocks pile up, or nothing is deleted', 'Not caused'),
    ])

PAGES['otelcol'] = dict(
    intro="An OpenTelemetry Collector, from what it says about itself. The pack reads what its receivers accepted and "
          "refused, for spans, metric points and log records and for each receiver; what its exporters delivered and "
          "could not, for each exporter; what was dropped because a queue was full; and how full the fullest queue is.",
    why="The Collector sits in the middle of every pipeline and fails in the quietest way there is: a destination "
        "slows, a queue fills, and from then on everything new for that exporter is dropped at the door. Applications "
        "upstream keep sending, and get no error.",
    setup=["**Its own metrics, at the level `detailed`**, in the Collector's configuration, then restart it. It serves "
           "them on `localhost:8888` by default; in a container, name `0.0.0.0` so that the host can read them:\n\n"
           "   ```yaml\n"
           "   service:\n"
           "     telemetry:\n"
           "       metrics:\n"
           "         level: detailed\n"
           "         readers:\n"
           "           - pull:\n"
           "               exporter:\n"
           "                 prometheus:\n"
           "                   host: 0.0.0.0\n"
           "                   port: 8888\n"
           "   ```\n\n"
           "   At the default level, `normal`, some versions leave the queue readings out; the rest of the pack works.",
           "`vigil pack enable otelcol`, then in `vigil.config` set what differs from the defaults: `OTELCOL_URL` "
           "(`http://localhost:8888`). One Collector a pack: for a fleet of them, the pack on each machine.",
           "Where a proxy in front of it asks for a login: `OTELCOL_USER` with `secret = OTELCOL_PASSWORD=secret:OTELCOL_PASSWORD`, "
           "or a bearer token as `OTELCOL_TOKEN`."],
    reports={
        'status': 'Up; its version and distribution; how long it has run; the memory it holds',
        'receivers': 'Spans, metric points and log records accepted, refused and failed; the refusals for each receiver',
        'exporters': 'Spans, metric points and log records delivered, not delivered (for each exporter) and dropped at a full queue; batches waiting, for each exporter; how full the fullest queue is',
    },
    alerts=[
        ('`otelcol.up`', '1', '', '0: nothing it receives goes anywhere', '`up 0` where nothing listened'),
        ('`otelcol.uptime_seconds`', 'Growing', 'Small again and again: it is restarting', '', 'Growing'),
        ('`otelcol.exporters.queue_fullest_pct`', 'Near 0', 'Rising: a destination is slower than what arrives; `queue` says which exporter', '100: everything new for it is dropped', '100, for the exporter nothing listened to'),
        ('`otelcol.exporters.enqueue_failed_*_count`', 'Flat', '', 'Rising: a queue is full, and data is dropped at the door', '`enqueue_failed_spans_count` rising'),
        ('`otelcol.exporters.send_failed_*_count`', 'Flat', '', 'Rising: data is lost; `send_failed_*` names the exporter', 'Rising for spans (two exporters named) and metric points (`prometheusremotewrite/mimir`, refused by Mimir\'s limit)'),
        ('`otelcol.receivers.refused_*_count`', 'Flat', '', 'Rising: senders are told to retry, and lose data when they give up; `refused_*` names the receiver', '`refused_spans` rising for `receiver=otlp/refused`'),
        ('`otelcol.receivers.accepted_*_count`', 'Rising', '', 'Flat while senders run: they cannot reach it', 'Rising, all three'),
    ])

PAGES['victoriametrics'] = dict(
    intro="A VictoriaMetrics server, from what it says about itself. The pack reads whether it answers and whether its "
          "storage has gone read-only for lack of disk; the disk space left; what it ingests for each protocol, and "
          "what it refuses or ignores and why; its queries against the limit on running at once, the slow ones and "
          "those that failed; and the targets it scrapes itself.",
    why="VictoriaMetrics protects itself by going read-only when the disk runs low, and by queueing, then refusing, "
        "inserts and queries past their limits. Each is a counter that moves long before a dashboard goes blank.",
    setup=["Nothing to turn on: VictoriaMetrics serves `/metrics` and `/health` already.",
           "`vigil pack enable victoriametrics`, then in `vigil.config` set what differs from the defaults: "
           "`VICTORIAMETRICS_URL` (`http://localhost:8428`). For a cluster, or vmagent, point each job at the "
           "component that has its metrics (ingestion: vminsert or vmstorage; status: vmselect or vmstorage; targets: "
           "vmagent, on 8429), or install the pack beside each.",
           "Where it asks for a login (`-httpAuth.username`): `VICTORIAMETRICS_USER` with `secret = "
           "VICTORIAMETRICS_PASSWORD=secret:VICTORIAMETRICS_PASSWORD`, or a bearer token as `VICTORIAMETRICS_TOKEN`."],
    reports={
        'status': 'Up and healthy; version; read-only; free disk and what its data takes; requests, and those that failed for each path; slow queries; queries against the most at once, those that waited and those turned away; errors logged',
        'ingestion': 'Rows ingested, for each protocol; rows invalid and ignored, for each reason; new series; slow inserts; inserts against the most at once; rows dropped by a series limit; rows held and pending; merges',
        'targets': 'Targets up and down, the down ones for each job; scrapes made and failed; whether the scrape configuration reloaded',
    },
    alerts=[
        ('`victoriametrics.up`, `healthy`', '1', '', '0: it takes no samples and answers no query', '`up 0` where nothing listened'),
        ('`victoriametrics.read_only`', '0', '', '1: it accepts no more samples until disk is freed', '0'),
        ('`victoriametrics.free_disk_bytes`', 'Steady', 'Falling towards `-storage.minFreeDiskSpaceBytes`', 'Near it: it is about to go read-only', '80 GB'),
        ('`victoriametrics.http_errors_count`', 'Flat', 'Rising on a query path: a query that does not parse', 'Rising on a write path: senders are being refused', 'Rising for `path=/api/v1/query`: the bad query sent on purpose'),
        ('`victoriametrics.selects_limit_timeout_count`', 'Flat', '`selects_limit_reached_count` rising: queries queue', 'Rising: queries are turned away', 'Not caused'),
        ('`victoriametrics.ingestion.rows_inserted_count`', 'Rising', '', 'Flat: nothing is arriving', 'Rising: remote write and its own scraping'),
        ('`victoriametrics.ingestion.slow_inserts_pct`', 'Under 1', 'Above 5: more active series than its memory holds', '', 'Under 1'),
        ('`victoriametrics.ingestion.series_limit_dropped_count`', 'Flat', '', 'Rising: a cardinality limit is discarding data', 'Not caused'),
        ('`victoriametrics.targets.targets_down`', '0', 'Above 0 for a few scrapes', 'Staying above 0: `down` says which job', '1: `job=dead`'),
    ])

PAGES['victorialogs'] = dict(
    intro="A VictoriaLogs server, from what it says about itself. The pack reads whether it answers and whether its "
          "storage has gone read-only for lack of disk; the disk space left; the log entries and bytes it ingests for "
          "each protocol; the entries it dropped and why; and its queries against the limit on running at once.",
    why="A log store drops what it cannot place: an entry stamped older than its retention, or too far ahead, is "
        "counted and gone. A shipper replaying a backlog after an outage can lose exactly the hours you wanted.",
    setup=["Nothing to turn on: VictoriaLogs serves `/metrics` and `/health` already.",
           "`vigil pack enable victorialogs`, then in `vigil.config` set what differs from the defaults: "
           "`VICTORIALOGS_URL` (`http://localhost:9428`).",
           "Where it asks for a login (`-httpAuth.username`): `VICTORIALOGS_USER` with `secret = "
           "VICTORIALOGS_PASSWORD=secret:VICTORIALOGS_PASSWORD`, or a bearer token as `VICTORIALOGS_TOKEN`."],
    reports={
        'status': 'Up and healthy; version; read-only; free disk and what its data takes; requests, and those that failed for each path; queries against the most at once, those that waited and those turned away; live tails; errors logged',
        'ingestion': 'Entries ingested, for each protocol, and bytes; entries dropped, for each reason; lines too long; streams created; entries held and pending; partitions; merges; compression ratio',
    },
    alerts=[
        ('`victorialogs.up`, `healthy`', '1', '', '0: it takes no logs and answers no query', '`up 0` where nothing listened'),
        ('`victorialogs.read_only`', '0', '', '1: it accepts no more logs until disk is freed', '0'),
        ('`victorialogs.free_disk_bytes`', 'Steady', 'Falling towards `-storage.minFreeDiskSpaceBytes`', 'Near it: it is about to go read-only', '80 GB'),
        ('`victorialogs.ingestion.rows_dropped_count`', 'Flat', '', 'Rising: `rows_dropped` says why', 'Rising: `too_small_timestamp`, the entries ten days old against a retention of one'),
        ('`victorialogs.ingestion.rows_ingested_count`', 'Rising', '', 'Flat: nothing is arriving', 'Rising: JSON lines and OTLP'),
        ('`victorialogs.ingestion.too_long_lines_count`', 'Flat', '', 'Rising: lines are thrown away whole', 'Not caused'),
        ('`victorialogs.selects_limit_timeout_count`', 'Flat', '`selects_limit_reached_count` rising: queries queue', 'Rising: queries are turned away', 'Not caused'),
    ])

# How the nine were tested: the same words on every page, filled in from the runs.
TESTED = """
(to be written from the runs)
"""
