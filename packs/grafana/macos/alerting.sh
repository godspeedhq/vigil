#!/usr/bin/env bash
#
# alerting.sh - Grafana's alert rules and their notifications
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
# Reports Grafana's own alerting: the rules it schedules, evaluations and
# those that failed, the alerts in each state (alerting, pending, no data,
# error, normal), how far its scheduler is behind, the notifications it sent
# and those that failed (for each integration), and its silences. It only
# reads: every request is a GET, and it changes nothing.
#
# Reads GRAFANA_URL (default http://localhost:3000): /metrics, Grafana's page
# about itself.
# What the scripts share is in _grafana.sh, beside this one.
#
# Metrics:
#   up                              1 when Grafana answered its metrics page,
#                                   else 0 (and nothing more is read)
#   rules                           alert rules it evaluates
#   rule_groups                     rule groups they are in
#   evaluations_count               rule evaluations (a running total)
#   evaluation_failures_count       evaluations that failed: the query could
#                                   not be run (a running total)
#   evaluation_failures_pct         of all since it started, the percentage
#                                   that failed
#   alerts                          alert instances in each state, tagged
#                                   state=<alerting, pending, nodata, error,
#                                   normal, recovering>
#   alerts_not_shown                how many more there were than the 20 shown
#   alerts_alerting                 alert instances firing
#   alerts_error                    alert instances whose rule cannot be
#                                   evaluated
#   alerts_nodata                   alert instances whose query brings nothing
#                                   back
#   scheduler_behind_seconds        how far its scheduler is behind where it
#                                   should be
#   last_tick_seconds               seconds since its scheduler last ticked
#   notifications_count             notifications attempted (a running total)
#   notifications_failed_count      notifications that failed (a running
#                                   total)
#   notifications_failed            the same, for each integration, tagged
#                                   integration=<webhook, email, slack ...>
#   notifications_failed_not_shown  how many more there were than the 20 shown
#   silences_active                 silences in force
#   alerts_received_count           alerts its rules sent to its Alertmanager
#                                   (a running total)
#   alerts_invalid_count            of those, refused as invalid (a running
#                                   total)
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  evaluation_failures_count and notifications_failed_count not
#            moving; alerts_error and alerts_nodata 0; last_tick_seconds under
#            a minute.
#   Watch    alerts_nodata above 0 (a query that stopped bringing data back: a
#            renamed metric, a target gone); scheduler_behind_seconds above 0.
#   Act      evaluation_failures_count moving, or alerts_error above 0: a rule
#            cannot be evaluated, so it cannot fire (its data source is down:
#            the datasources job says which); notifications_failed_count
#            moving: alerts fire and reach nobody, and notifications_failed
#            says through which integration; last_tick_seconds growing:
#            alerting has stopped; alerts_alerting, which is what the rules
#            are for.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Grafana does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or awk is missing

set -u

job=alerting
# shellcheck source=/dev/null
. "$(dirname "$0")/_grafana.sh"
needs curl awk

page '/metrics'
readings <<'T'
rules|sum|grafana_alerting_schedule_alert_rules
rule_groups|sum|grafana_alerting_rule_groups
evaluations_count|sum|grafana_alerting_rule_evaluations_total
evaluation_failures_count|sum|grafana_alerting_rule_evaluation_failures_total
evaluation_failures_pct|pct|evaluation_failures_count|evaluations_count
alerts|by|grafana_alerting_alerts||state
alerts_alerting|sum|grafana_alerting_alerts|state=alerting
alerts_error|sum|grafana_alerting_alerts|state=error
alerts_nodata|sum|grafana_alerting_alerts|state=nodata
scheduler_behind_seconds|max|grafana_alerting_scheduler_behind_seconds
last_tick_seconds|age|grafana_alerting_ticker_last_consumed_tick_timestamp_seconds
notifications_count|sum|grafana_alerting_notifications_total
notifications_failed_count|sum|grafana_alerting_notifications_failed_total
notifications_failed|by|grafana_alerting_notifications_failed_total||integration
silences_active|sum|grafana_alerting_silences|state=active
alerts_received_count|sum|grafana_alerting_alerts_received_total
alerts_invalid_count|sum|grafana_alerting_alerts_invalid_total
T
exit 0
