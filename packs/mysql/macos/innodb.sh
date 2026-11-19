#!/usr/bin/env bash
#
# innodb.sh - a MySQL or MariaDB server's InnoDB buffer pool, purge and
# locks
#
# How many reads the buffer pool served without going to disk, how full it
# is, how much undo history waits for purge (it grows behind long
# transactions), and running totals of row lock waits and deadlocks. MySQL
# keeps the last two in information_schema.INNODB_METRICS, MariaDB in its
# status variables; this reads either. Connects to MYSQL_HOST and
# MYSQL_TCP_PORT as MYSQL_USER, with the password in MYSQL_PWD, all set by
# the job; never on a command line.
#
# Metrics:
#   buffer_pool_hit_pct   reads served from the buffer pool, since the
#                         server started; left out while the server's
#                         counters cannot give it (MariaDB counts read
#                         requests only in part, and on a fresh server can
#                         show more reads from disk than requests)
#   buffer_pool_used_pct  pages of the buffer pool in use
#   history_list_count    undo log entries waiting for purge
#   row_lock_waits_count  times a statement waited for a row lock (a running
#                         total)
#   deadlocks_count       deadlocks InnoDB detected (a running total)
#
# Example output:
#   metric buffer_pool_hit_pct 99
#   metric buffer_pool_used_pct 41
#   metric history_list_count 12
#   metric row_lock_waits_count 3
#   metric deadlocks_count 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  buffer_pool_hit_pct above 99 on a busy server; history_list_count
#            in the thousands at most, and falling back after bursts.
#   Watch    buffer_pool_used_pct at 100 with the hit rate falling: the
#            working set no longer fits (innodb_buffer_pool_size).
#            history_list_count climbing for hours: purge cannot keep up, or a
#            long transaction holds it back (mysql_activity).
#   Act      history_list_count in the millions: queries slow down as they
#            read old row versions; end the transaction holding it back.
#            deadlocks_count rising: transactions take their locks in
#            different orders (SHOW ENGINE INNODB STATUS shows the last one).
#            The _count totals restart with the server: graph them as a rate.
#
# When the server does not answer, it prints nothing and succeeds:
# mysql_status reports that, as mysql.up 0.
#
# Requires: bash, the mysql client (MySQL's, or MariaDB's mariadb), and a
#   user with PROCESS
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   client is missing or the server refuses the login or the queries
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

set -u

client=$(command -v mysql || command -v mariadb) ||
    { echo "innodb: mysql not found: install the MySQL or MariaDB client" >&2; exit 1; }
# The client's stderr goes to a file of its own: MariaDB's prints warnings
# there even when a query works, which must never be read as data.
errf=$(mktemp "${TMPDIR:-/tmp}/vigil-mysql.XXXXXX") || exit 1
trap 'rm -f "$errf"' EXIT
sql() {
    "$client" --protocol=TCP -h "${MYSQL_HOST:-127.0.0.1}" -P "${MYSQL_TCP_PORT:-3306}" \
        -u "${MYSQL_USER:-vigil_monitor}" --connect-timeout=5 -N -B -e "$1" 2> "$errf"
}
# What the client said, on one line, for a message.
err() { grep -v '^WARNING' "$errf" | tr '\n' ' '; }
# Whether it failed to reach the server at all: errors 2002, 2003, 2005 and
# 2013. Anything else, a refused login for one, is a failure.
down() { grep -qE 'ERROR (2002|2003|2005|2013)' "$errf"; }

if ! status=$(sql "
SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads',
    'Innodb_buffer_pool_pages_total', 'Innodb_buffer_pool_pages_free', 'Innodb_row_lock_waits',
    'Innodb_deadlocks', 'Innodb_history_list_length')"); then
    down && exit 0
    echo "innodb: the server refused the login or the queries: $(err)" >&2
    exit 1
fi

requests=0 reads=0 total=0 free=0 waits=0 deadlocks='' history=''
while IFS=$'\t' read -r name value; do
    case $name in
        Innodb_buffer_pool_read_requests) requests=$value ;;
        Innodb_buffer_pool_reads) reads=$value ;;
        Innodb_buffer_pool_pages_total) total=$value ;;
        Innodb_buffer_pool_pages_free) free=$value ;;
        Innodb_row_lock_waits) waits=$value ;;
        Innodb_deadlocks) deadlocks=$value ;;
        Innodb_history_list_length) history=$value ;;
    esac
done <<EOF
$status
EOF

# MySQL has neither as a status variable: INNODB_METRICS keeps them, both
# counted by default.
if [ -z "$deadlocks" ] || [ -z "$history" ]; then
    metrics=$(sql "SELECT NAME, COUNT FROM information_schema.INNODB_METRICS
        WHERE NAME IN ('lock_deadlocks', 'trx_rseg_history_len')") ||
        { echo "innodb: the server refused the queries: $(err)" >&2; exit 1; }
    while IFS=$'\t' read -r name value; do
        case $name in
            lock_deadlocks) [ -n "$deadlocks" ] || deadlocks=$value ;;
            trx_rseg_history_len) [ -n "$history" ] || history=$value ;;
        esac
    done <<EOF
$metrics
EOF
fi

# Left out when the counters cannot give it: MariaDB counts read requests
# only in part, and can show more reads from disk than requests.
if [ "$requests" -gt 0 ] && [ "$reads" -le "$requests" ]; then
    echo "metric buffer_pool_hit_pct $((100 * (requests - reads) / requests))"
fi
[ "$total" -gt 0 ] && echo "metric buffer_pool_used_pct $((100 * (total - free) / total))"
echo "metric history_list_count ${history:-0}"
echo "metric row_lock_waits_count $waits"
echo "metric deadlocks_count ${deadlocks:-0}"
exit 0
