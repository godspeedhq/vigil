#!/usr/bin/env bash
#
# check.sh - SQLite databases checked for damage, with PRAGMA quick_check:
# off until SQLITE_CHECK=quick
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
# Checks each database in SQLITE_FILES with PRAGMA quick_check, opened
# read-only with the sqlite3 program: every page and every row read, which
# finds a damaged page, a broken index structure, a row out of place. It
# changes nothing and repairs nothing.
#
# It does nothing (checked 0) until SQLITE_CHECK=quick, because it costs: it
# reads the whole file, so it takes seconds a gigabyte and fills the cache
# with it, and in rollback mode (not WAL) it holds a shared lock while it
# runs, so the application's writes wait for it (and fail with "database is
# locked" when they wait longer than the application allows). In WAL mode
# writers do not wait. Once a day, at a quiet hour, is plenty. A database
# that stays locked by a writer for 30 seconds is not checked: busy 1.
#
# Reads with sqlite3 (SQLITE3, else the one on the PATH), as this account:
# it needs read access to the database and, in WAL mode, to its -wal and
# -shm files, and the folder they are in. Missing databases are skipped: the
# status job reports them.
#
# Metrics:
#   checked          databases checked; 0 while SQLITE_CHECK is not quick
#   ok               1 when the check found nothing wrong, else 0, tagged
#                    db=<path>
#   problems         what it found wrong (at most 100): 0 when ok
#   check_seconds    how long the check took
#   busy             1 when the database stayed locked and could not be
#                    checked
#   not_ok           databases whose check found something wrong
#
# Example output (the rest are in the same form):
#   metric ok 1 db=/var/lib/grafana/grafana.db
#   metric problems 0 db=/var/lib/grafana/grafana.db
#   metric check_seconds 0.12 db=/var/lib/grafana/grafana.db
#   metric checked 1
#   metric not_ok 0
#
# Reading the results (starting points: tune them to the application):
#   Healthy  not_ok 0; check_seconds steady.
#   Watch    busy 1 on two days running (a writer holds the database most of
#            the time: pick another hour); check_seconds near max_runtime.
#   Act      not_ok above 0: copy the database aside (with its -wal), and
#            run sqlite3 <file> "PRAGMA integrity_check" on the copy to see
#            what is wrong; restore from a backup, or .recover what can be.
#
# Requires: bash, and sqlite3 when SQLITE_CHECK=quick
# Exit code: 0 on success, damaged or not; 1 if sqlite3 is missing, or a
#   database cannot be opened by this account (it says which)
#
# Example (vigil.config):
#   [job.sqlite_check]
#   file        = packs/sqlite/check.sh
#   metric_name = sqlite.check
#   run_every   = 1d
#   max_runtime = 30m
#   env         = SQLITE_FILES=/var/lib/grafana/grafana.db
#   env         = SQLITE_CHECK=quick

set -u

job=check
# shellcheck source=/dev/null
. "$(dirname "$0")/_sqlite.sh"

case ${SQLITE_CHECK:-off} in
    quick) ;;
    off) echo "metric checked 0"; exit 0 ;;
    *) echo "$job: SQLITE_CHECK is '$SQLITE_CHECK': quick, or off" >&2; exit 1 ;;
esac
prog=${SQLITE3:-sqlite3}
command -v "$prog" > /dev/null 2>&1 || { echo "$job: $prog not found: the check runs PRAGMA quick_check with the sqlite3 program (SQLITE3 names another)" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-sqlite.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Now, in seconds: to the microsecond in bash 5, else whole.
clock() {
    if [ -n "${EPOCHREALTIME-}" ]; then printf '%s' "${EPOCHREALTIME/,/.}"; else date +%s; fi
}

checked=0
bad=0
failed=''
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    t=$(tag "$f")
    start=$(clock)
    "$prog" -readonly -batch -bail -cmd '.timeout 30000' "$f" 'PRAGMA quick_check(100);' > "$work/out" 2> "$work/err" < /dev/null
    rc=$?
    took=$(awk -v a="$start" -v b="$(clock)" 'BEGIN { d = b - a; if (d < 0) d = 0; if (d == int(d)) printf "%d", d; else printf "%.2f", d }')
    if [ "$rc" -ne 0 ]; then
        case $(cat "$work/err") in
            *'database is locked'* | *busy*)
                echo "metric busy 1 db=$t"
                continue ;;
            *'malformed'* | *'not a database'* | *corrupt*)
                n=1 ;;
            *)
                failed="$failed${failed:+; }$f: $(head -n 1 "$work/err")"
                continue ;;
        esac
    elif [ "$(cat "$work/out")" = ok ]; then
        n=0
    else
        n=$(grep -c . "$work/out")
    fi
    checked=$((checked + 1))
    if [ "$n" -eq 0 ]; then
        echo "metric ok 1 db=$t"
    else
        bad=$((bad + 1))
        echo "metric ok 0 db=$t"
    fi
    echo "metric problems $n db=$t"
    echo "metric check_seconds $took db=$t"
    echo "metric busy 0 db=$t"
done <<< "$(databases)"
echo "metric checked $checked"
echo "metric not_ok $bad"
if [ -n "$failed" ]; then
    echo "$job: sqlite3 could not check $failed" >&2
    exit 1
fi
exit 0
