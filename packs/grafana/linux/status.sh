#!/usr/bin/env bash
#
# status.sh - is Grafana healthy, and answering
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports whether Grafana is healthy (its own check, which includes its
# database), what it holds (dashboards, users, data sources by kind, alert
# rules), the requests it answered and those that failed, its database
# connections, and the requests its data source plugins failed. It only reads:
# every request is a GET, and it changes nothing.
#
# Reads GRAFANA_URL (default http://localhost:3000): /metrics, Grafana's page
# about itself, and /api/health.
# What the scripts share is in _grafana.sh, beside this one.
#
# Metrics:
#   up                             1 when Grafana answered its metrics page,
#                                  else 0 (and nothing more is read)
#   healthy                        1 when /api/health answers 200 (Grafana and
#                                  its database are up), else 0
#   version                        always 1, tagged version=<its version> and
#                                  edition=<oss or enterprise>
#   uptime_seconds                 seconds since it started
#   dashboards                     dashboards it holds
#   users                          users it has
#   active_users                   of those, seen in the last 30 days
#   alert_rules                    alert rules it holds
#   datasources                    data sources configured
#   datasources_by_type            the same, for each kind, tagged
#                                  type=<prometheus, loki, ...>
#   datasources_by_type_not_shown  how many more there were than the 20 shown
#   http_requests_count            requests answered (a running total)
#   http_4xx_count                 of those, answered 4xx: not logged in, not
#                                  allowed, not found (a running total)
#   http_5xx_count                 answered 5xx: Grafana failed (a running
#                                  total)
#   requests_in_flight             requests in hand now
#   db_connections                 connections to its database open
#   db_connections_in_use          of those, in use
#   db_connections_max             the most it may open (0: no limit)
#   db_waits_count                 times a request had to wait for a
#                                  connection (a running total)
#   plugin_requests_count          requests to its plugins, data sources above
#                                  all (a running total)
#   plugin_errors_count            of those, the ones that failed (a running
#                                  total)
#   plugin_errors                  the same, for each plugin, tagged
#                                  plugin=<its id>
#   plugin_errors_not_shown        how many more there were than the 20 shown
#   live_clients                   browsers connected to Grafana Live
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; healthy 1; http_5xx_count and plugin_errors_count not
#            moving.
#   Watch    db_waits_count moving (requests queue for the database: raise
#            max_open_conn, or the database is slow); http_4xx_count climbing
#            (logins failing, or a dashboard asking for what is gone).
#   Act      up 0 or healthy 0: nobody can open a dashboard, and its alert
#            rules are not evaluated; http_5xx_count moving;
#            plugin_errors_count moving: a data source is failing,
#            plugin_errors says which kind, and the datasources job which one.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Grafana does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_grafana.sh"
needs curl awk

page '/metrics'
answers healthy '/api/health'
readings <<'T'
version|info|grafana_build_info||version:version,edition:edition
uptime_seconds|age|process_start_time_seconds
dashboards|sum|grafana_stat_totals_dashboard
users|sum|grafana_stat_total_users
active_users|sum|grafana_stat_active_users
alert_rules|sum|grafana_stat_totals_alert_rules
datasources|sum|grafana_stat_totals_datasource
datasources_by_type|by|grafana_stat_totals_datasource||plugin_id:type
http_requests_count|sum|grafana_http_request_duration_seconds_count
http_4xx_count|sum|grafana_http_request_duration_seconds_count|status_code~^4
http_5xx_count|sum|grafana_http_request_duration_seconds_count|status_code~^5
requests_in_flight|sum|grafana_http_request_in_flight
db_connections|sum|grafana_database_conn_open
db_connections_in_use|sum|grafana_database_conn_in_use
db_connections_max|sum|grafana_database_conn_max_open
db_waits_count|sum|grafana_database_conn_wait_count_total
plugin_requests_count|sum|grafana_plugin_request_total
plugin_errors_count|sum|grafana_plugin_request_total|status=error
plugin_errors|by|grafana_plugin_request_total|status=error|plugin_id:plugin
live_clients|sum|grafana_live_node_num_clients
T
exit 0
