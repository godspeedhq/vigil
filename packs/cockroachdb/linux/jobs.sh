#!/usr/bin/env bash
#
# jobs.sh - a CockroachDB cluster's jobs: backups, schema changes, changefeeds
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
# Reports the cluster's jobs (backups, restores, imports, schema changes,
# changefeeds...): how many run, are paused, or failed in the time SHOW JOBS
# keeps finished jobs (12 hours), by type; the failed and paused ones, worst
# first, by ID and type (never their description, which may hold a
# statement or a storage URL); the schedules (scheduled backups), and those
# paused or late to run; and the changefeeds, and how far the furthest
# behind is from now. Run it on one node: the answer is the cluster's. It
# only reads.
#
# Reads CockroachDB at COCKROACH_URL (default https://localhost:8080), the
# node's HTTP port, as COCKROACH_USER with the password in
# COCKROACH_PASSWORD (a secret), with curl and jq: SHOW JOBS, SHOW
# SCHEDULES and SHOW CHANGEFEED JOBS through /api/v2/sql/. The user needs the
# system privilege VIEWJOB (without it, it sees only its own jobs: none); an
# insecure cluster needs no login. Over https, the certificate is checked
# against COCKROACH_CACERT, the cluster's CA file (ca.crt), when it is set,
# else the system's CAs. What the scripts share is in _cockroachdb.sh,
# beside this one.
#
# Metrics:
#   up                          1 when the node answers, else 0
#   running                     jobs running
#   paused                      jobs paused
#   failed                      jobs failed in the last 12 hours
#   reverting                   jobs rolling back a failure, or a cancel
#   jobs                        jobs, by type and status, tagged
#                               type=<BACKUP, SCHEMA CHANGE...> and
#                               status=<running, paused, failed...>
#   job_failed                  always 1, for each failed job, tagged
#                               id=<job ID> and type=<its type>
#   job_paused_seconds          how long each paused job has been paused,
#                               tagged id=<job ID> and type=<its type>
#   jobs_not_shown              failed and paused jobs past the first 20, left
#                               out
#   schedules                   schedules (scheduled backups, and
#                               CockroachDB's own)
#   schedules_paused            of those, paused
#   schedules_late              of those, active and more than an hour past
#                               their next run
#   changefeeds                 changefeeds running
#   changefeed_behind_seconds   how far the furthest behind of those is from
#                               now: its high-water mark's age, or, with
#                               none yet, its own
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric running 2
#   metric paused 1
#   metric failed 1
#   metric jobs 1 type=BACKUP status=failed
#   metric job_failed 1 id=1230347512866324481 type=BACKUP
#   metric schedules 3
#   metric changefeeds 0
#
# Reading the results (starting points: tune them to the cluster):
#   Healthy  failed 0; paused 0, or only jobs paused on purpose;
#            schedules_late 0; changefeed_behind_seconds near its
#            resolved interval.
#   Watch    paused above 0 for long (a paused schema change blocks the next
#            on its table); schedules_paused above 0; reverting above 0.
#   Act      failed above 0 with type=BACKUP: the last backup did not run;
#            schedules_late above 0; changefeed_behind_seconds rising: its
#            sink is down or slow, and the cluster keeps the history it
#            still has to send (protected timestamps), which grows.
#
# Requires: bash, curl and jq; a user with VIEWJOB
# Exit code: 0 on success, node up or down; 1 if curl or jq is missing, the
#   login is refused, or the user lacks a privilege
#
# Example (vigil.config):
#   [job.cockroachdb_jobs]
#   file        = packs/cockroachdb/jobs.sh
#   metric_name = cockroachdb.jobs
#   run_every   = 5m
#   env         = COCKROACH_URL=https://localhost:8080
#   env         = COCKROACH_CACERT=/var/lib/cockroach/certs/ca.crt
#   env         = COCKROACH_USER=vigil
#   secret      = COCKROACH_PASSWORD=secret:COCKROACH_PASSWORD

set -u

job=jobs
# shellcheck source=/dev/null
. "$(dirname "$0")/_cockroachdb.sh"

login
# Up: the node answers its health (no login needed for that).
get /health
case $? in
    0 | 3) ;;
    2) echo "metric up 0"; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
echo "metric up 1"
# IDs as strings: they are past what a JSON number holds exactly.
sql "SELECT job_id::STRING AS id, job_type AS type, status, extract(epoch FROM modified)::INT8 AS modified FROM [SHOW JOBS]"
cp "$work/rows" "$work/jobs"
sql "SELECT schedule_status AS status, extract(epoch FROM next_run)::INT8 AS next FROM [SHOW SCHEDULES]"
cp "$work/rows" "$work/schedules"
sql "SELECT status, (extract(epoch FROM now())::DECIMAL - COALESCE(high_water_timestamp / 1e9, extract(epoch FROM created)::DECIMAL))::FLOAT8 AS behind FROM [SHOW CHANGEFEED JOBS] WHERE status = 'running'"
jq -r --argjson now "$now" --slurpfile s "$work/schedules" --slurpfile c "$work/rows" "$jqlib"'
    # Worst first: failed, then paused, each newest first.
    def rank: {"failed": 0, "paused": 1}[.status] // 9;
    . as $j |
    "metric running \([$j[] | select(.status == "running")] | length)",
    "metric paused \([$j[] | select(.status == "paused")] | length)",
    "metric failed \([$j[] | select(.status == "failed")] | length)",
    "metric reverting \([$j[] | select(.status == "reverting" or .status == "cancel-requested" or .status == "pause-requested")] | length)",
    ($j | group_by([.type, .status])[] | "metric jobs \(length) type=\(.[0].type | tag) status=\(.[0].status | tag)"),
    ([$j[] | select(.status == "failed" or .status == "paused")] | sort_by([rank, -(.modified | n)]) as $w |
        ($w[0:20][] | "id=\(.id | tag) type=\(.type | tag)" as $t |
            if .status == "failed" then "metric job_failed 1 \($t)"
            else "metric job_paused_seconds \([$now - (.modified | n), 0] | max) \($t)" end),
        "metric jobs_not_shown \([($w | length) - 20, 0] | max)"),
    "metric schedules \($s[0] | length)",
    "metric schedules_paused \([$s[0][] | select(.status == "PAUSED")] | length)",
    "metric schedules_late \([$s[0][] | select(.status == "ACTIVE" and .next != null and (.next | n) < $now - 3600)] | length)",
    "metric changefeeds \($c[0] | length)",
    (if ($c[0] | length) > 0 then "metric changefeed_behind_seconds \([$c[0][].behind | n] | max | r2)" else empty end)
' "$work/jobs"
exit 0
