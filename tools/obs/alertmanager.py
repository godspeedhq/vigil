# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The alertmanager pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table

PACK = dict(
    P='Alertmanager', E='ALERTMANAGER', url='http://localhost:9093', version='1.0.0',
    description='Alertmanager: whether it is ready and its configuration loaded, alerts and silences, '
                'notifications sent and failed for each integration, and its cluster (members, failed peers)',
    works='Alertmanager 0.25 and later (tested: 0.35.1, alone and as a cluster of two)',
    head=['alertmanager - an Alertmanager, from its own metrics page: is it ready,',
          'what alerts and silences does it hold, do its notifications get',
          'through, and is its cluster whole.'],
    needs=['its address, where it is not http://localhost:9093: env = ALERTMANAGER_URL=... on each job (one '
           'Alertmanager: for a cluster, the pack on each member\'s machine)',
           'where it asks for a login: ALERTMANAGER_USER and secret = ALERTMANAGER_PASSWORD=secret:ALERTMANAGER_PASSWORD, '
           'or secret = ALERTMANAGER_TOKEN=secret:ALERTMANAGER_TOKEN for a bearer token',
           "for Alertmanager's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Alertmanager's page about itself"

job(pack='alertmanager', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Alertmanager ready, and what it holds',
    what="Reports whether Alertmanager is ready, whether its last configuration reload worked and when, the "
         "alerts it holds (active, suppressed), those it received and those it refused as invalid, its "
         "silences, and what its configuration gives it to work with (receivers, integrations, inhibition rules).",
    reads=READS + ", and /-/ready.",
    steps=[
        page('/metrics'),
        answers('ready', '/-/ready', '1 when Alertmanager says it is ready (/-/ready answers 200), else 0: it is '
                                     'starting, or its cluster has not settled'),
        table(
            ('version|info|alertmanager_build_info||version:version', 'always 1, tagged version=<its version>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('config_reload_ok|min|alertmanager_config_last_reload_successful',
             '1 when the last configuration reload worked, else 0: it is still running the one before'),
            ('config_age_seconds|age|alertmanager_config_last_reload_success_timestamp_seconds',
             'seconds since the configuration it runs was loaded'),
            ('alerts_active|sum|alertmanager_alerts|state=active', 'alerts firing and not silenced or inhibited'),
            ('alerts_suppressed|sum|alertmanager_alerts|state=suppressed', 'alerts silenced or inhibited'),
            ('alerts_unprocessed|sum|alertmanager_alerts|state=unprocessed', 'alerts received and not yet looked at'),
            ('alerts_received_count|sum|alertmanager_alerts_received_total', 'alerts received (a running total)'),
            ('alerts_invalid_count|sum|alertmanager_alerts_invalid_total', 'alerts refused as invalid (a running total)'),
            ('silences_active|sum|alertmanager_silences|state=active', 'silences in force'),
            ('silences_pending|sum|alertmanager_silences|state=pending', 'silences not yet started'),
            ('silences_expired|sum|alertmanager_silences|state=expired', 'silences ended and still kept'),
            ('receivers|sum|alertmanager_receivers', 'receivers configured'),
            ('integrations|sum|alertmanager_integrations', 'integrations in them (a webhook, an email, a pager)'),
            ('inhibition_rules|sum|alertmanager_inhibition_rules', 'inhibition rules configured'),
            ('aggregation_groups|sum|alertmanager_dispatcher_aggregation_groups', 'groups of alerts being held for notification'),
            ('aggregation_limit_reached_count|sum|alertmanager_dispatcher_aggregation_group_limit_reached_total',
             'alerts that could not be grouped: the limit on groups was reached (a running total)'),
            ('_fds|sum|process_open_fds', None),
            ('_maxfds|sum|process_max_fds', None),
            ('fds_pct|pct|_fds|_maxfds', 'open files, as a percentage of its limit'),
        ),
    ],
    healthy='up 1; ready 1; config_reload_ok 1; alerts_invalid_count not moving.',
    watch='alerts_active when you expect none; silences_active that nobody remembers setting; alerts_suppressed '
          'far above alerts_active (a silence or an inhibition hiding a lot).',
    act='up 0 or ready 0: no alert reaches anyone through it; config_reload_ok 0 (an edit it refused: routes and '
        'receivers are the old ones); alerts_received_count not moving while Prometheus has alerts firing: they '
        'are not arriving; aggregation_limit_reached_count moving.')

job(pack='alertmanager', job='notifications', metric='notifications', when='run_every   = 1m', runtime='30s',
    title="Alertmanager's notifications, sent and failed",
    what="Reports the notifications Alertmanager sent and those that failed, for each integration (webhook, "
         "email, PagerDuty, Slack and the rest) and for each reason it gives, the requests made to the "
         "services behind them, and how long a notification takes.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('notifications_count|sum|alertmanager_notifications_total', 'notifications attempted (a running total)'),
            ('notifications_failed_count|sum|alertmanager_notifications_failed_total', 'notifications that failed (a running total)'),
            ('failed_pct|pct|notifications_failed_count|notifications_count', 'of all attempted since it started, the percentage that failed'),
            ('sent|by|alertmanager_notifications_total||integration', 'notifications attempted by each integration, tagged integration=<its kind>'),
            ('failed|by|alertmanager_notifications_failed_total||integration', 'those that failed, for each integration, tagged integration'),
            ('failed_reason|by|alertmanager_notifications_failed_total||reason',
             'those that failed, for each reason Alertmanager gives, tagged reason=<clientError, serverError, '
             'contextDeadlineExceeded, other ...>'),
            ('requests_count|sum|alertmanager_notification_requests_total', 'requests made to the services notified (a running total)'),
            ('requests_failed_count|sum|alertmanager_notification_requests_failed_total', 'requests that failed (a running total)'),
            ('_lsum|sum|alertmanager_notification_latency_seconds_sum', None),
            ('_lcount|sum|alertmanager_notification_latency_seconds_count', None),
            ('latency_avg_seconds|div|_lsum|_lcount', 'how long a notification took, on average since it started'),
        ),
    ],
    healthy='notifications_failed_count not moving while notifications_count does.',
    watch='failed_pct above a few percent; latency_avg_seconds climbing (a slow webhook holds up the group behind it).',
    act='notifications_failed_count moving: failed says which integration and failed_reason why (clientError: a '
        'bad URL, token or payload; serverError: the service is failing; contextDeadlineExceeded: it does not '
        'answer in time). An alert that is not delivered is an outage nobody hears about.')

job(pack='alertmanager', job='cluster', metric='cluster', when='run_every   = 1m', runtime='30s',
    title="Alertmanager's cluster",
    what="Reports this Alertmanager's view of its cluster: whether clustering is on, the members it sees and "
         "the peers it has lost, its health score, its position among the members, the gossip messages "
         "waiting, and reconnections that failed. A single Alertmanager reports members 1.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('cluster_enabled|min|alertmanager_cluster_enabled', '1 when clustering is on, else 0'),
            ('members|sum|alertmanager_cluster_members', 'members this one sees, itself included'),
            ('failed_peers|sum|alertmanager_cluster_failed_peers', 'peers it has lost and is trying to reach'),
            ('health_score|max|alertmanager_cluster_health_score', '0 when its gossip is healthy; higher, the worse'),
            ('peer_position|max|alertmanager_peer_position', 'its position among the members (0 is first to notify)'),
            ('messages_queued|sum|alertmanager_cluster_messages_queued', 'gossip messages waiting to be sent'),
            ('messages_pruned_count|sum|alertmanager_cluster_messages_pruned_total', 'messages dropped from a full queue (a running total)'),
            ('reconnections_count|sum|alertmanager_cluster_reconnections_total', 'reconnections to peers attempted (a running total)'),
            ('reconnections_failed_count|sum|alertmanager_cluster_reconnections_failed_total', 'reconnections that failed (a running total)'),
            ('peers_joined_count|sum|alertmanager_cluster_peers_joined_total', 'peers that joined (a running total)'),
            ('peers_left_count|sum|alertmanager_cluster_peers_left_total', 'peers that left (a running total)'),
        ),
    ],
    healthy='members the number you run, on every member; failed_peers 0; health_score 0.',
    watch='peers_left_count or reconnections_failed_count moving (a member restarting, or a network that drops); '
          'messages_queued growing.',
    act='members below the number you run, or failed_peers above 0: the cluster is split, and each side notifies '
        'on its own: expect duplicate notifications, and silences set on one side missing on the other; '
        'health_score staying above 0.')
