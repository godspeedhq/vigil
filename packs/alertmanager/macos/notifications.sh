#!/usr/bin/env bash
#
# notifications.sh - Alertmanager's notifications, sent and failed
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
# Reports the notifications Alertmanager sent and those that failed, for each
# integration (webhook, email, PagerDuty, Slack and the rest) and for each
# reason it gives, the requests made to the services behind them, and how long
# a notification takes. It only reads: every request is a GET, and it changes
# nothing.
#
# Reads ALERTMANAGER_URL (default http://localhost:9093): /metrics,
# Alertmanager's page about itself.
# What the scripts share is in _alertmanager.sh, beside this one.
#
# Metrics:
#   up                          1 when Alertmanager answered its metrics page,
#                               else 0 (and nothing more is read)
#   notifications_count         notifications attempted (a running total)
#   notifications_failed_count  notifications that failed (a running total)
#   failed_pct                  of all attempted since it started, the
#                               percentage that failed
#   sent                        notifications attempted by each integration,
#                               tagged integration=<its kind>
#   sent_not_shown              how many more there were than the 20 shown
#   failed                      those that failed, for each integration,
#                               tagged integration
#   failed_not_shown            how many more there were than the 20 shown
#   failed_reason               those that failed, for each reason
#                               Alertmanager gives, tagged
#                               reason=<clientError, serverError,
#                               contextDeadlineExceeded, other ...>
#   failed_reason_not_shown     how many more there were than the 20 shown
#   requests_count              requests made to the services notified (a
#                               running total)
#   requests_failed_count       requests that failed (a running total)
#   latency_avg_seconds         how long a notification took, on average since
#                               it started
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  notifications_failed_count not moving while notifications_count
#            does.
#   Watch    failed_pct above a few percent; latency_avg_seconds climbing (a
#            slow webhook holds up the group behind it).
#   Act      notifications_failed_count moving: failed says which integration
#            and failed_reason why (clientError: a bad URL, token or payload;
#            serverError: the service is failing; contextDeadlineExceeded: it
#            does not answer in time). An alert that is not delivered is an
#            outage nobody hears about.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Alertmanager does not answer (up 0
#   is the reading); 1 when it answers wrong (a login refused, not HTTP), said
#   on stderr, or curl or awk is missing

set -u

job=notifications
# shellcheck source=/dev/null
. "$(dirname "$0")/_alertmanager.sh"
needs curl awk

page '/metrics'
readings <<'T'
notifications_count|sum|alertmanager_notifications_total
notifications_failed_count|sum|alertmanager_notifications_failed_total
failed_pct|pct|notifications_failed_count|notifications_count
sent|by|alertmanager_notifications_total||integration
failed|by|alertmanager_notifications_failed_total||integration
failed_reason|by|alertmanager_notifications_failed_total||reason
requests_count|sum|alertmanager_notification_requests_total
requests_failed_count|sum|alertmanager_notification_requests_failed_total
_lsum|sum|alertmanager_notification_latency_seconds_sum
_lcount|sum|alertmanager_notification_latency_seconds_count
latency_avg_seconds|div|_lsum|_lcount
T
exit 0
