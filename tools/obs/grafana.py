# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The grafana pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table, code

PACK = dict(
    P='Grafana', E='GRAFANA', url='http://localhost:3000', version='1.0.0',
    description='Grafana: whether it is healthy (its database too), requests and those that failed, its '
                'database connections, whether each data source answers, and its alerting (rules evaluated '
                'and failed, alerts by state, notifications sent and failed)',
    works='Grafana 10 and later (tested: 13.2.5)',
    head=['grafana - a Grafana, from its own metrics page and, for the data',
          'sources, its API with a read-only token: is it healthy, does every',
          'data source answer, are its alert rules evaluated, and do their',
          'notifications get through.'],
    needs=['its address, where it is not http://localhost:3000: env = GRAFANA_URL=... on each job',
           'its metrics page, which is on by default ([metrics] enabled); where it asks for a login ([metrics] '
           'basic_auth_username): GRAFANA_USER and secret = GRAFANA_PASSWORD=secret:GRAFANA_PASSWORD',
           'for the datasources job, a service account with the Viewer role and a token for it (Administration, '
           'Users and access, Service accounts): secret = GRAFANA_TOKEN=secret:GRAFANA_TOKEN on that job, then '
           'vigil secret set GRAFANA_TOKEN. A Viewer may list the data sources and ask each for its health, and '
           'change nothing',
           "for Grafana's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Grafana's page about itself"

job(pack='grafana', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Grafana healthy, and answering',
    what="Reports whether Grafana is healthy (its own check, which includes its database), what it holds "
         "(dashboards, users, data sources by kind, alert rules), the requests it answered and those that "
         "failed, its database connections, and the requests its data source plugins failed.",
    reads=READS + ", and /api/health.",
    steps=[
        page('/metrics'),
        answers('healthy', '/api/health', '1 when /api/health answers 200 (Grafana and its database are up), else 0'),
        table(
            ('version|info|grafana_build_info||version:version,edition:edition', 'always 1, tagged version=<its version> and edition=<oss or enterprise>'),
            ('uptime_seconds|age|process_start_time_seconds', 'seconds since it started'),
            ('dashboards|sum|grafana_stat_totals_dashboard', 'dashboards it holds'),
            ('users|sum|grafana_stat_total_users', 'users it has'),
            ('active_users|sum|grafana_stat_active_users', 'of those, seen in the last 30 days'),
            ('alert_rules|sum|grafana_stat_totals_alert_rules', 'alert rules it holds'),
            ('datasources|sum|grafana_stat_totals_datasource', 'data sources configured'),
            ('datasources_by_type|by|grafana_stat_totals_datasource||plugin_id:type', 'the same, for each kind, tagged type=<prometheus, loki, ...>'),
            ('http_requests_count|sum|grafana_http_request_duration_seconds_count', 'requests answered (a running total)'),
            ('http_4xx_count|sum|grafana_http_request_duration_seconds_count|status_code~^4',
             'of those, answered 4xx: not logged in, not allowed, not found (a running total)'),
            ('http_5xx_count|sum|grafana_http_request_duration_seconds_count|status_code~^5', 'answered 5xx: Grafana failed (a running total)'),
            ('requests_in_flight|sum|grafana_http_request_in_flight', 'requests in hand now'),
            ('db_connections|sum|grafana_database_conn_open', 'connections to its database open'),
            ('db_connections_in_use|sum|grafana_database_conn_in_use', 'of those, in use'),
            ('db_connections_max|sum|grafana_database_conn_max_open', 'the most it may open (0: no limit)'),
            ('db_waits_count|sum|grafana_database_conn_wait_count_total', 'times a request had to wait for a connection (a running total)'),
            ('plugin_requests_count|sum|grafana_plugin_request_total', 'requests to its plugins, data sources above all (a running total)'),
            ('plugin_errors_count|sum|grafana_plugin_request_total|status=error', 'of those, the ones that failed (a running total)'),
            ('plugin_errors|by|grafana_plugin_request_total|status=error|plugin_id:plugin', 'the same, for each plugin, tagged plugin=<its id>'),
            ('live_clients|sum|grafana_live_node_num_clients', 'browsers connected to Grafana Live'),
        ),
    ],
    healthy='up 1; healthy 1; http_5xx_count and plugin_errors_count not moving.',
    watch='db_waits_count moving (requests queue for the database: raise max_open_conn, or the database is '
          'slow); http_4xx_count climbing (logins failing, or a dashboard asking for what is gone).',
    act='up 0 or healthy 0: nobody can open a dashboard, and its alert rules are not evaluated; http_5xx_count '
        'moving; plugin_errors_count moving: a data source is failing, plugin_errors says which kind, and the '
        'datasources job which one.')

job(pack='grafana', job='alerting', metric='alerting', when='run_every   = 1m', runtime='30s',
    title="Grafana's alert rules and their notifications",
    what="Reports Grafana's own alerting: the rules it schedules, evaluations and those that failed, the alerts "
         "in each state (alerting, pending, no data, error, normal), how far its scheduler is behind, the "
         "notifications it sent and those that failed (for each integration), and its silences.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('rules|sum|grafana_alerting_schedule_alert_rules', 'alert rules it evaluates'),
            ('rule_groups|sum|grafana_alerting_rule_groups', 'rule groups they are in'),
            ('evaluations_count|sum|grafana_alerting_rule_evaluations_total', 'rule evaluations (a running total)'),
            ('evaluation_failures_count|sum|grafana_alerting_rule_evaluation_failures_total',
             'evaluations that failed: the query could not be run (a running total)'),
            ('evaluation_failures_pct|pct|evaluation_failures_count|evaluations_count', 'of all since it started, the percentage that failed'),
            ('alerts|by|grafana_alerting_alerts||state', 'alert instances in each state, tagged state=<alerting, pending, nodata, error, normal, recovering>'),
            ('alerts_alerting|sum|grafana_alerting_alerts|state=alerting', 'alert instances firing'),
            ('alerts_error|sum|grafana_alerting_alerts|state=error', 'alert instances whose rule cannot be evaluated'),
            ('alerts_nodata|sum|grafana_alerting_alerts|state=nodata', 'alert instances whose query brings nothing back'),
            ('scheduler_behind_seconds|max|grafana_alerting_scheduler_behind_seconds', 'how far its scheduler is behind where it should be'),
            ('last_tick_seconds|age|grafana_alerting_ticker_last_consumed_tick_timestamp_seconds', 'seconds since its scheduler last ticked'),
            ('notifications_count|sum|grafana_alerting_notifications_total', 'notifications attempted (a running total)'),
            ('notifications_failed_count|sum|grafana_alerting_notifications_failed_total', 'notifications that failed (a running total)'),
            ('notifications_failed|by|grafana_alerting_notifications_failed_total||integration',
             'the same, for each integration, tagged integration=<webhook, email, slack ...>'),
            ('silences_active|sum|grafana_alerting_silences|state=active', 'silences in force'),
            ('alerts_received_count|sum|grafana_alerting_alerts_received_total', 'alerts its rules sent to its Alertmanager (a running total)'),
            ('alerts_invalid_count|sum|grafana_alerting_alerts_invalid_total', 'of those, refused as invalid (a running total)'),
        ),
    ],
    healthy='evaluation_failures_count and notifications_failed_count not moving; alerts_error and alerts_nodata 0; '
            'last_tick_seconds under a minute.',
    watch='alerts_nodata above 0 (a query that stopped bringing data back: a renamed metric, a target gone); '
          'scheduler_behind_seconds above 0.',
    act='evaluation_failures_count moving, or alerts_error above 0: a rule cannot be evaluated, so it cannot '
        'fire (its data source is down: the datasources job says which); notifications_failed_count moving: '
        'alerts fire and reach nobody, and notifications_failed says through which integration; '
        'last_tick_seconds growing: alerting has stopped; alerts_alerting, which is what the rules are for.')

DS_SH = r'''# The data sources, and what each answers when asked for its health: only
# with a login (@E@_TOKEN, or @E@_USER and @E@_PASSWORD).
if [ -z "${@E@_TOKEN-}" ] && [ -z "${@E@_USER-}" ]; then
    echo "metric login_ok 0"
    echo "$job: no login: this job needs a Viewer's token (secret = @E@_TOKEN=secret:@E@_TOKEN; packs/@p@/README.md)" >&2
    exit 0
fi
get '/api/datasources' list
case $? in
    0) echo "metric up 1"; echo "metric login_ok 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    4) echo "metric up 1"; echo "metric login_ok 0"; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
jq -r 'sort_by(.name) | .[] | [.uid, .type, .name] | @tsv' "$work/list" > "$work/ds" || { echo "$job: /api/datasources did not answer with a list" >&2; exit 1; }
total=$(grep -c . "$work/ds")
shown=0 failing=0
while IFS=$'\t' read -r uid type name; do
    [ "$shown" -lt 20 ] || break
    shown=$((shown + 1))
    code=$(login | curl -sS -g -m 20 -K - -o "$work/health" -w '%{http_code}' "$url/api/datasources/uid/$(printf '%s' "$uid" | jq -sRr @uri)/health" 2> /dev/null)
    ok=0
    [ "$code" = 200 ] && [ "$(jq -r '.status // empty' "$work/health" 2> /dev/null)" = OK ] && ok=1
    [ "$ok" = 1 ] || failing=$((failing + 1))
    echo "metric datasource_ok $ok name=$(tag "$name") type=$(tag "$type")"
done < "$work/ds"
echo "metric datasources $total"
echo "metric datasources_failing $failing"
echo "metric datasources_not_shown $((total - shown))"
'''

DS_PS = r'''# The data sources, and what each answers when asked for its health: only
# with a login (@E@_TOKEN, or @E@_USER and @E@_PASSWORD).
if (-not $script:Auth) {
    Write-Output 'metric login_ok 0'
    [Console]::Error.WriteLine("${Job}: no login: this job needs a Viewer's token (secret = @E@_TOKEN=secret:@E@_TOKEN; packs/@p@/README.md)")
    exit 0
}
$r = Get-Answer '/api/datasources'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1'; Write-Output 'metric login_ok 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'forbidden' { Write-Output 'metric up 1'; Write-Output 'metric login_ok 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
# Kept in a variable first: Windows PowerShell 5.1 hands a JSON array back
# as one object, and @() makes it the list.
$parsed = $r.Body | ConvertFrom-Json
$list = @($parsed | ForEach-Object { $_ } | Sort-Object -Property name -CaseSensitive)
$shown = 0; $failing = 0
foreach ($d in $list) {
    if ($shown -ge 20) { break }
    $shown++
    $h = Get-Answer ('/api/datasources/uid/' + [Uri]::EscapeDataString([string]$d.uid) + '/health')
    $ok = 0
    if ($h.State -eq 'ok') { try { if (($h.Body | ConvertFrom-Json).status -ceq 'OK') { $ok = 1 } } catch { } }
    if (-not $ok) { $failing++ }
    Write-Output "metric datasource_ok $ok name=$(Safe $d.name) type=$(Safe $d.type)"
}
Write-Output "metric datasources $($list.Count)"
Write-Output "metric datasources_failing $failing"
Write-Output "metric datasources_not_shown $($list.Count - $shown)"
'''

job(pack='grafana', job='datasources', metric='datasources', when='run_every   = 5m', runtime='2m',
    needs_sh=['curl', 'jq'],
    title='does every Grafana data source answer',
    what="Lists Grafana's data sources and asks Grafana to check each one, as the Test button on its settings "
         "page does: Grafana makes one small query to it and says whether it answered. A data source that "
         "does not answer is a dashboard that shows nothing and an alert rule that cannot fire. It needs a "
         "token: a Viewer's is enough, and can change nothing.",
    reads="Reads @E@_URL (default @URL@): /api/datasources and, for each of the first 20 by name, "
          "/api/datasources/uid/<uid>/health, with @E@_TOKEN (or @E@_USER and @E@_PASSWORD).",
    steps=[code(DS_SH, DS_PS, [
        ('up', '1 when Grafana answered, else 0'),
        ('login_ok', '1 when the token (or the user) may list the data sources; 0 when there is none, or it is refused (and nothing more is read)'),
        ('datasource_ok', "1 when the data source answered Grafana's check, else 0; tagged name=<its name> and type=<its kind>"),
        ('datasources', 'data sources configured'),
        ('datasources_failing', 'of those checked, the ones that did not answer'),
        ('datasources_not_shown', 'data sources past the first 20, not checked'),
    ])],
    healthy='login_ok 1; datasources_failing 0.',
    watch='datasources_not_shown above 0: only the first 20 by name are checked.',
    act='datasources_failing above 0: datasource_ok 0 names it. Its dashboards are empty and the alert rules '
        'that read it error (the alerting job) until it answers again; login_ok 0: the token is missing, '
        'expired or revoked, and this job sees nothing.',
    exit_sh="0, whatever it reads, when Grafana does not answer (up 0), and when there is no login or it is "
            "refused (login_ok 0); 1 when it answers wrong, or curl or jq is missing",
    exit_ps="0, whatever it reads, when Grafana does not answer (up 0), and when there is no login or it is "
            "refused (login_ok 0); 1 when it answers wrong")
