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
        ('`alertmanager.notifications.failed_pct`', '0', 'A few percent', 'Most of them: a receiver is broken', '100 on the member second in line, which sends only what the first could not; lower on the first'),
        ('`alertmanager.cluster.members`', 'The number you run', '', 'Fewer: the cluster is split. Expect duplicate notifications', '2; then 1 when the other member stopped'),
        ('`alertmanager.cluster.failed_peers`', '0', '', 'Above 0: a peer is lost and being retried', '1 when the other member stopped; 0 again when it came back'),
        ('`alertmanager.alerts_invalid_count`', 'Flat', 'Rising: a sender posts alerts it cannot read', '', 'Not caused'),
    ],
    found="In a cluster, one member sends each notification and tells the others, who then do not. So a notification that gets through is counted on one member only, and the member second in line may show every attempt of its own as failed: read `notifications_count` and `notifications_failed_count` summed over the members.")

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

PAGES['etcd'] = dict(
    intro="An etcd member, from what it says about itself on its metrics listener. The pack reads whether it is "
          "healthy and, when it is not, whether its cluster has lost its leader or raised an alarm; whether it has "
          "a leader, is the leader, or is a learner; how often the leader has changed; the members of its cluster "
          "and those it cannot reach; the proposals it committed and applied, those waiting and those that failed. "
          "Its database against its quota and the space a defragmentation would give back; its keys, revisions "
          "and compaction; watchers and leases. How fast its disk is where etcd needs it: the WAL's fsyncs and the "
          "backend's commits. And the gRPC requests it answered and those that failed, by code.",
    why="etcd is small, and everything stands on it: Kubernetes keeps its whole state there. Its trouble is quiet "
        "until it is total. A slow disk shows first as missed heartbeats and elections; a cluster that loses two "
        "members of three has no leader and takes no writes, though the last member still answers; a database "
        "that reaches its quota raises NOSPACE and refuses every write until someone compacts, defragments and "
        "disarms it. Each of these is on its metrics page, and the pack reads it from each member.",
    setup=["Give etcd a plain metrics listener, if it has none: `--listen-metrics-urls=http://127.0.0.1:2381`. Its "
           "client port serves `/metrics` too, but there clients usually need a certificate. kubeadm's etcd has "
           "the listener already, on `127.0.0.1:2381`.",
           "`vigil pack enable etcd` on each member's machine, and, where the listener is elsewhere, set "
           "`ETCD_URL` in the jobs' `env` lines. Each member reports itself, and its view of the cluster."],
    reports={
        'status': 'Healthy; version and cluster version; a leader, this member the leader or a learner; leader changes; members, and those it cannot reach; heartbeats and peer messages that failed; proposals committed, applied, waiting and failed; slow applies; reads that failed or were slow; health checks that failed',
        'database': 'The database against its quota; space in use and fragmented; keys; the revision and how far past the last compaction; how long since a compaction; puts, deletes, reads and transactions; watchers and slow watchers; leases granted and expired; a defragmentation running',
        'disk': "The WAL's fsyncs and the backend's commits: on average, and those that were slow; bytes written to the WAL; the round trip to its peers",
        'requests': 'gRPC requests handled, and those that failed, for each code; bytes to and from clients',
    },
    alerts=[
        ('`etcd.up`, `healthy`', '1', '', '`healthy 0`: read `has_leader`; with a leader, an alarm (`etcdctl alarm list`)', '`up 0` where nothing listened; `healthy 0` with no quorum, and with the NOSPACE alarm'),
        ('`etcd.has_leader`', '1', '', '0: quorum is lost, and nothing can be written', '1; 0 on the last member, with two of three stopped'),
        ('`etcd.peers_unreachable`', '0', 'Above 0: a member is down or cut off, and one more lost may cost quorum', '', '1 with the leader stopped; 2 with two stopped'),
        ('`etcd.leader_changes_count`', 'Flat', 'Rising: elections, from a slow disk or network, or members restarting', '', 'Up by one when the leader stopped and the others elected another'),
        ('`etcd.proposals_failed_count`', 'Flat', '', 'Rising: writes failing (no leader, or timeouts)', 'Up by one: the write tried with no quorum (`context deadline exceeded`)'),
        ('`etcd.database.db_used_pct`', 'Below 80', 'Past 80', 'Near 100: the NOSPACE alarm, and no writes until it is compacted, defragmented and disarmed', '97.07 when the 32 MiB database refused its 24th MiB: etcd raises the alarm when a write would pass the quota; 75.21 once mended'),
        ('`etcd.database.revisions_kept`', 'Steady', 'Growing: nothing compacts', '', '2006, for 500 keys written four times and never compacted'),
        ('`etcd.disk.wal_fsync_avg_ms`, `wal_fsyncs_slow_count`', 'Under 10; slow ones rare', 'Average past 10, or slow ones rising', 'Slow ones rising with leader changes: the disk is too slow for etcd', '4.86 ms on average, 18 of 2,013 over 16 ms, on the test machine\'s disk (a first, scratch run read 21 ms)'),
        ('`etcd.disk.backend_commit_avg_ms`', 'Under 25', 'Past 25', '', '10.91'),
        ('`etcd.requests.failed` (by `code`)', 'Flat', '`DeadlineExceeded`, `Canceled` rising: requests waiting too long', '`Unavailable`, `ResourceExhausted` (NOSPACE), `Unauthenticated` rising', '`code=Canceled` for the write with no quorum (its client gave up first); `code=ResourceExhausted` for the write refused at the quota'),
    ],
    tested="""
**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-etcd.sh`, against `compose.etcd.yaml`: **etcd 3.6.17, a cluster of three**, and **etcd 3.5.36, one member alone** with a quota of 32 MiB, each with its metrics on a plain listener (`--listen-metrics-urls`) as the pack reads them. Through etcd's own API: 500 keys, each written four times; a watch held open; two leases of two seconds, left to expire.

- **On Fedora** (Fedora 44, bash 5.3): every job against a member of the cluster and the one alone, and what each read (one leader among the three, as each says of itself; the keys and the history kept; the watch; the leases, expired and counted by the leader; the disk's fsyncs and commits, and the round trip to the peers). Then the leader stopped (the others elected one, the change counted, the old leader unreachable); then two of three stopped (no leader, not healthy, the write that failed counted, by its gRPC code); then the 3.5 member's database filled to its quota (the NOSPACE alarm, healthy 0 with its leader there, the write refused as `ResourceExhausted`), compacted, defragmented and disarmed (healthy again, the space given back); then nothing listening and a page that is not there: **33 passed, 0 failed**. Then `service-packs.sh` through Vigil: **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-etcd/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same cluster through SSH tunnels: every job against the 3.6 member and the 3.5 one, the readings checked, nothing listening: **11 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-etcd-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator, against the same cluster: every job under Windows PowerShell 5.1 and PowerShell 7, the same metric names and tags as the Linux scripts read just after; nothing listening and a page that is not there; then through Vigil under each: **22 passed, 0 failed**, the names and tags the same for all 4 jobs against both members under both shells (16 of 16), and through Vigil **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-etcd-windows/console.txt)).
""",
    found="etcd publishes no metric for its alarms: a member with NOSPACE says so on `/health` (`ALARM NOSPACE`), and the pack reads it as `healthy 0` with a leader. It raises the alarm when a write would pass the quota, so the database was 97% full, not 100, when writes stopped. A member alone publishes no peer series, so the pack counts members from the active-peer series, one for each other member. Leases are expired, and counted, by the leader alone. A write tried with no quorum fails on the client first: the member counts it as `Canceled`, not `Unavailable`. The container image has no shell: the run makes its keys through etcd's HTTP gateway.")

PAGES['openbao'] = dict(
    intro="An OpenBao or HashiCorp Vault node, from what it says about itself: the two answer the same paths and "
          "publish the same metrics, so one pack reads both, and says which it found. With no token at all, it "
          "reads whether the node is initialized and sealed, how far an unseal has got, whether it is active or a "
          "standby and knows its leader. With a token that may read its metrics, and nothing else: its Raft cluster "
          "as autopilot sees it (healthy or not, how many nodes it may lose, which are unhealthy), followers behind "
          "and leadership lost, how long storage takes; its leases and those it could not revoke, the tokens created; "
          "and its requests: logins that failed, users locked out after too many, responses refused, audit devices "
          "that failed to log.",
    why="Everything that has a secret asks it for one, so trouble here is trouble everywhere at once. A node that "
        "restarts with a Shamir seal comes back sealed and serves nothing until someone brings the keys; a cluster of "
        "three that has lost one may not lose another; a client with a stale password is locked out after a few "
        "tries, and an application stops; leases that grow without end make every failover slower; and with every "
        "audit device failing, it refuses every request. Each of these is on its health page or its metrics page.",
    setup=["Nothing to turn on for the status job: `/v1/sys/health`, `/v1/sys/seal-status` and `/v1/sys/leader` "
           "answer anyone.",
           "For the other three, its metrics: in its configuration, `telemetry { prometheus_retention_time = \"24h\" }` "
           "(it drops a counter not updated in that time: keep it longer than the jobs' interval), and a token that may "
           "read `sys/metrics` and nothing else: `bao policy write vigil-metrics - <<< 'path \"sys/metrics\" "
           "{ capabilities = [\"read\"] }'`, then `bao token create -orphan -policy=vigil-metrics -no-default-policy "
           "-period=768h` (`vault` for Vault). A periodic token never expires by TTL; renew it within the period, or "
           "give a new one. Or let anyone read the metrics: `unauthenticated_metrics_access = true` in the listener's "
           "`telemetry` block. **On a Vault standby, that setting is needed**: Vault sends a standby's `sys/metrics` "
           "to the active node (HTTP 307) otherwise. OpenBao's standbys answer with the token.",
           "`vigil pack enable openbao` on each node's machine, then `vigil secret set OPENBAO_TOKEN`, and where the "
           "node is not at `http://localhost:8200`, `OPENBAO_URL` in the jobs' `env` lines (https, with "
           "`OPENBAO_CACERT` when its CA is not one the system trusts). Each node reports itself."],
    reports={
        'status': 'Up; OpenBao or Vault, its version, its seal and its storage; initialized, sealed, standby; keys needed, given so far; HA, active, the leader known; Raft entries not yet applied',
        'storage': 'Active; autopilot healthy, failure tolerance, nodes and those unhealthy, named; Raft peers; the follower furthest behind; time since the leader was heard; commit time; leadership lost; storage reads and writes and their time',
        'leases': 'Leases held and those it could not revoke; tokens created, for each auth method; tokens; mounts',
        'requests': 'Requests and those in flight; logins, those that created a token and those that failed; users locked out; responses refused (4xx, 403) and failed (5xx), on Vault; requests and responses audit devices failed to log',
    },
    alerts=[
        ('`openbao.up`', '1', '', '0: the node does not answer', '`up 0` where nothing listened'),
        ('`openbao.sealed`', '0', '', '1: the node serves nothing until its keys are given', '1 on a node restarted (a Shamir seal); `unseal_progress 1` with one key of two given, then `sealed 0`'),
        ('`openbao.active` (over the nodes)', 'One node 1', '', 'None: the cluster has no active node', 'o1 and v1; then o2 and v2, each taking over within seconds of the active node stopping'),
        ('`openbao.storage.autopilot_healthy`, `node_unhealthy` (by `node`)', '1; 0', '', '0: `node_unhealthy` names the node', '0, with `node_unhealthy 1 node=o3` (and `v3`): the node restarted and sealed'),
        ('`openbao.storage.failure_tolerance`', '1 or more', '0: one more node lost and the cluster stops', '', '1 for three nodes; 0 with one sealed'),
        ('`openbao.storage.storage_write_avg_ms`, `commit_avg_ms`', 'Steady', 'Rising: slow disks', '', '34 and 18 ms (OpenBao), 30 and 15 ms (Vault), on the test machine\'s disk'),
        ('`openbao.requests.locked_users`', '0', '', 'Above 0: a user locked out; an application that cannot log in', '1: the user whose wrong password was tried seven times (400 five times, then 403)'),
        ('`openbao.requests.logins_failed_count`', 'Flat', 'Rising: a stale secret, or someone guessing', '', '20 for the 10 wrong passwords: both count a failed login twice'),
        ('`openbao.requests.permission_denied_count`, `responses_4xx_count`', 'Flat', 'Rising: tokens without the policy they need, or users locked out', '', '2 and 10 (Vault)'),
        ('`openbao.leases.irrevocable_leases`', '0', '', 'Above 0: credentials it could not revoke still work', '0'),
        ('`openbao.leases.leases`', 'Steady', 'Growing day after day', 'In the hundreds of thousands', '27: 5 from logins, 22 tokens'),
        ('`openbao.requests.audit_request_failures_count`', 'Flat', '', 'Rising: with every audit device failing, it refuses every request', 'Not caused: OpenBao 2.7 enables audit devices only in its configuration file'),
    ],
    tested="""
**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-openbao.sh`, against `compose.openbao.yaml`: **OpenBao 2.7.3, a Raft cluster of three**, and **HashiCorp Vault 2.2.2, a Raft cluster of three**, each initialized with three key shares (two needed) and unsealed, and given a token that may read `sys/metrics` and nothing else, as this page says. On each: userpass, five logins that worked and ten with a wrong password (seven of them for one user, locked out after five); twenty tokens with leases. One Vault standby lets anyone read its metrics (`unauthenticated_metrics_access`); the others do not. The keys and tokens were made by the run and kept out of the evidence.

- **On Fedora** (Fedora 44, bash 5.3): every job against each cluster's active node and a standby, and what each read (OpenBao or Vault, Shamir 2 of 3, Raft; autopilot healthy, three nodes, one that may be lost; the leases; tokens by auth method; logins that worked and failed, the user locked out; on Vault, the responses refused and those 403). A Vault standby without unauthenticated metrics (the run fails, saying HTTP 307). Then, on each, a node restarted and sealed (`sealed 1`; autopilot unhealthy, the node named, nothing more may be lost), unsealed a key at a time (`unseal_progress 1`, then unsealed, a standby again); the active node stopped (another active within seconds); a token without the policy, no token, nothing listening.: **45 passed, 0 failed**. Then `service-packs.sh` through Vigil: **14 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-openbao/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same clusters through SSH tunnels: the status job against all six nodes, every job against each active node, a token that is not one, nothing listening: **14 passed, 0 failed**; through Vigil, **14 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-openbao-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator: the same, under Windows PowerShell 5.1 and PowerShell 7, with the Vault standby that sends its metrics away: **26 passed, 0 failed**; the same metric names and tags as the Linux scripts for every job against both active nodes, under both shells (16 of 16); through Vigil, **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-openbao-windows/console.txt)).
""",
    found="OpenBao kept Vault's names: its metrics start `vault_`, and its pages are Vault's, so one pack reads both, and tells them apart by the `enterprise` field Vault's health page has. A sealed node answers its health and seal pages, but not its metrics (503) or its leader (503): the status job reads only the pages that answer. A Vault standby sends `sys/metrics` to the active node (307) unless the listener lets anyone read them; an OpenBao standby answers with the token. Both drop a counter not updated within `prometheus_retention_time`, so with a short one the running totals come and go. Both count a failed login twice. A node counts its locked-out users when it becomes active and every 15 minutes or so after, so right after a lockout it may still read 0. Autopilot counts a node that has just joined as a voter only once it has been stable a while: right after a cluster forms, `failure_tolerance` reads 0. OpenBao 2.7 enables audit devices only in its configuration file, not through its API.")

PAGES['traefik'] = dict(
    intro="A Traefik proxy, from its own metrics page and its read-only API. The pack reads whether it is up and "
          "answers its ping, when its configuration last loaded, the connections on each entrypoint and the requests "
          "they answered, 4xx and 5xx; the backend servers it health-checks, up and down, each down one by its URL; "
          "the services and routers answering 5xx, each by name; from its API, the routers, services and "
          "middlewares in error, each router in error named with why; and its TLS certificates, those it warns "
          "about, and the soonest to expire.",
    why="A proxy fails sideways. A router whose service was renamed is put in error, takes no traffic, and every "
        "request to its host gets a 404: Traefik itself is fine, and its own health check says so. A backend that "
        "dies leaves its service with fewer servers, then none, and every request answers 503. A certificate Traefik "
        "should have renewed is still the old one a week before it expires. Each of these is in what Traefik says "
        "about itself, and the pack reads it, by name.",
    setup=["Turn on what the pack reads, in Traefik's static configuration: `--metrics.prometheus=true` (with "
           "`--metrics.prometheus.addRoutersLabels=true` and `addServicesLabels=true` for the routers and services "
           "jobs), `--api=true` and `--ping=true`. They are served on the `traefik` entrypoint, port 8080. For "
           "backends up and down, give the services health checks (`loadBalancer.healthCheck`): without one, Traefik "
           "does not know.",
           "`vigil pack enable traefik`, and where Traefik is not at `http://localhost:8080`, set `TRAEFIK_URL` in the "
           "jobs' `env` lines. Where its API sits behind a login (a router with `basicAuth`), `TRAEFIK_USER` and "
           "`secret = TRAEFIK_PASSWORD=secret:TRAEFIK_PASSWORD`. The config job needs `jq` on Linux and macOS."],
    reports={
        'status': 'Up and its ping; when its configuration last loaded, and how many times; connections on each entrypoint; requests, 4xx and 5xx (for each entrypoint), and their time; TLS requests; certificates, and when the first expires',
        'services': 'Backend servers health-checked, up and down, each down one by its URL, and for each service; requests to the services, 5xx for each, and their time; retries',
        'routers': 'Requests for each router, and those 4xx and 5xx',
        'config': 'From its API: its version; routers, services and middlewares (HTTP, TCP, UDP) and those in error or warning; each router in error, named, with why; certificates, those it warns about, the soonest to expire and those within 30 days',
    },
    alerts=[
        ('`traefik.up`, `ping`', '1', '', '0: the proxy does not answer', '`up 0` where nothing listened'),
        ('`traefik.config.routers_errors`, `router_error` (by `router`)', '0', '', 'Above 0: `router_error` names the router and why. It takes no traffic: its host answers 404', '2: `broken@file` (`the service "not-there@file" does not exist`) and `nomiddleware@file` (`middleware "no-such-middleware@file" does not exist`)'),
        ('`traefik.services.servers_down`, `server_down` (by `url`)', '0', 'Above 0 in a service with others up', '`down_by_service` equal to its servers: the service has none, and answers 503', '1, the backend whose host does not exist; 2 with a second stopped (`down_by_service 2 service=app@file`)'),
        ('`traefik.requests_5xx_count`, `services.requests_5xx` (by `service`)', 'Flat', '', 'Rising: the service named fails (502 unreachable, 504 too slow)', '20, all `service=gone@file`, the service whose only backend does not exist'),
        ('`traefik.requests_4xx_count`', 'Steady', 'Rising fast: a host or path no router takes, or a router in error', '', '60: 20 to a host no router takes, and 20 to each router in error'),
        ('`traefik.config.cert_expires_days`, `certs_expiring_30d`', 'Above 30; 0', 'Below 30: Traefik renews ACME certificates 30 days ahead, so one still below is not renewing', 'Below 7', '4.99 days and 1, for the certificate made for 5 days; `certificates_warnings 1`'),
        ('`traefik.last_reload_seconds`, `reloads_count`', '', 'A change that does not show as a reload: Traefik did not take it', '', '`reloads_count 2` and `last_reload_seconds 0` a moment after the configuration changed'),
    ],
    tested="""
**Tested** on 2026-11-28 by `tests/integration/backends/scripts/run-traefik.sh`, against `compose.traefik.yaml`: **Traefik 3.8.0 and 3.7.20**, side by side, reading one dynamic configuration in trouble on purpose: a service of three backends, one a host that does not exist (its health check fails); a service whose only backend is that host; a router to a service that is not there and one with a middleware that is not there; a certificate made for 5 days and one for a year. Twenty requests to each router and to a host no router takes, on each Traefik.

- **On Fedora** (Fedora 44, bash 5.3): every job against each, and what each read (up and ping; the requests, 4xx and 5xx; three backends health-checked, the missing one down and named; the 5xx by service and by router; the two routers in error, each named with why; two certificates, the 5-day one warned of, and when it expires both from the API and the metrics). Then a second backend stopped (two down, both named), the configuration changed (the reload counted, a moment ago), and nothing listening: **30 passed, 0 failed**. Then `service-packs.sh` through Vigil: **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/fedora/pack-traefik/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk, jq 1.8.2), against the same two through SSH tunnels: every job, the routers in error and the dead backend named, nothing listening: **11 passed, 0 failed**; through Vigil, **12 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/macos/pack-traefik-macos/console.txt)).
- **On Windows**, on the HP test machine (Windows 11) as an account that is not an administrator: every job under Windows PowerShell 5.1 and PowerShell 7, against both, the same checks: **22 passed, 0 failed**; the same metric names and tags as the Linux scripts for all 4 jobs against both, under both shells (16 of 16); through Vigil, **10 passed, 0 failed** under each ([the console output](../../tests/integration/backends/reports/runs/2026-11-28/windows/pack-traefik-windows/console.txt)).
""",
    found="A router in error is not an error Traefik's own health shows: it answers its ping, takes the router out, and every request to its host gets a 404, counted with the requests to hosts no router takes. Its API names it, with why. Traefik 3's `traefik_config_last_reload_success` is the time of the last successful load, not a flag. A backend that cannot be reached keeps a request waiting: the service's average time rose past a second with every request to the missing host. Without a health check on a service, Traefik reports no server up or down for it.")

# How the nine were tested: the same words on every page, filled in from the runs.
TESTED = """
**Tested** on 2026-11-25 by `tests/integration/backends/scripts/run-obs.sh`, against `compose.obs.yaml`: one stack of all nine services wired together as they are in use, each in trouble on purpose. **Prometheus 3.15.1** (two targets down and one that answers without metrics, a rule group that cannot be evaluated, an Alertmanager that is not there, a remote write nothing answers and one that is refused), **Alertmanager 0.35.1** (two in a cluster; a receiver nothing listens to), **Grafana 13.2.5** (a data source nothing answers, an alert rule that reads it, a contact point nothing listens to), **Loki 3.7.9** (entries too old, lines too long), **Mimir 3.2.6** (a tenant held at 200 series), **Tempo 2.10.10** (traces larger than its limit), **the OpenTelemetry Collector 0.166.0** (an exporter nothing answers, whose queue fills; a receiver that must refuse), **VictoriaMetrics 1.157.0** (a scrape target down, queries that fail) and **VictoriaLogs 1.54.0** (entries older than its retention), in Docker, with traces, metrics and logs flowing through all of it.

- **On Fedora** (Fedora 44, bash 5.3): every job of every pack and what each must have read; a token Grafana refuses, a page that is not there, and nothing answering; then the stack broken further, live (Tempo stopped, and seen by its own pack and by Prometheus', the Collector's and Grafana's; an Alertmanager leaving its cluster; a configuration Prometheus refuses, then Alertmanager): **84 passed, 0 failed**. Then `service-packs.sh` through Vigil, for all nine packs (enable, and that CPU and memory are the base pack's; precheck; every job; a service that does not answer read as `up 0`; Grafana's token kept as a secret and written nowhere; the metrics reaching the backend): **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/fedora/pack-obs/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, its own awk), against the same stack through SSH tunnels: every job and the same checks, **69 passed, 0 failed**; through Vigil, **95 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-25/macos/pack-obs-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against the same stack through SSH tunnels: every job, each compared with what the Linux script printed a moment before (the same readings, by name and tag, for all 28 jobs), the faults read again, then `Service-Packs.ps1` through Vigil. On Windows 11 under Windows PowerShell 5.1 and under PowerShell 7, and on Windows Server 2025 under Windows PowerShell 5.1: **79 passed, 0 failed** and **76 passed, 0 failed** on each ([Windows 11](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console.txt), [under PowerShell 7](../../tests/integration/backends/reports/runs/2026-11-25/windows/pack-obs-windows/console-powershell7.txt), [Server 2025](../../tests/integration/backends/reports/runs/2026-11-25/windows-server-2025/pack-obs-windows/console.txt)). Over SSH, Windows refuses its data protection to a logon with no password, so there the suite gives Grafana's token by an `env:` reference; at a console, `vigil secret set` keeps it.
- **The two engines**, bash with awk and PowerShell, were compared line for line over all nine services' pages with a table that uses every operation on every metric: 12,873 readings, none differing, between gawk, mawk, macOS' awk, busybox's, Windows PowerShell 5.1 and PowerShell 7 (`tools/obs/DESIGN.md`).
"""
