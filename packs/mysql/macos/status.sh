#!/usr/bin/env bash
#
# status.sh - a MySQL or MariaDB server's health
#
# Asks the server, as a read-only user, whether it answers, then for its
# connections against the limit, the threads running a statement, the
# longest statement running, and running totals of statements, slow ones,
# failed connection attempts and temporary tables that spilled to disk.
# Connects to MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password
# in MYSQL_PWD, all set by the job; never on a command line.
#
# Metrics:
#   up                      1 when the server answers, else 0
#   connections             client connections now
#   max_connections         the server's limit
#   connections_pct         connections as a percent of the limit
#   running                 client connections running a statement now,
#                           leaving out this one and replication threads
#   longest_query_seconds   the longest statement running now (replication
#                           threads left out)
#   queries_count           statements run (a running total)
#   slow_queries_count      statements over long_query_time (a running total)
#   aborted_connects_count  failed connection attempts (a running total)
#   tmp_disk_tables_count   temporary tables that spilled to disk (a running
#                           total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric connections 12
#   metric max_connections 151
#   metric connections_pct 7
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; connections_pct below 70; running a handful; no statement
#            running for minutes.
#   Watch    connections_pct 70 to 90; running in the tens for long: the
#            server is busy, or statements queue on locks; slow_queries_count
#            or tmp_disk_tables_count rising faster than usual.
#   Act      up 0; connections_pct above 90, and new connections will soon be
#            refused; aborted_connects_count rising fast: bad passwords, or a
#            full server. The _count totals restart with the server: graph
#            them as a rate.
#
# Requires: bash, the mysql client (MySQL's, or MariaDB's mariadb), and a
#   user with PROCESS
# Exit code: 0 on success, server up or down; 1 if the client is missing or
#   the server refuses the login or the queries
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
    { echo "status: mysql not found: install the MySQL or MariaDB client" >&2; exit 1; }
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

# A server that does not answer is a reading, not a failure.
if ! sql "SELECT 1" > /dev/null; then
    down && { echo "metric up 0"; exit 0; }
    echo "status: the server refused the login or the queries: $(err)" >&2
    exit 1
fi

out=$(sql "
SHOW GLOBAL STATUS WHERE Variable_name IN
    ('Threads_connected', 'Questions', 'Slow_queries', 'Aborted_connects', 'Created_tmp_disk_tables')") ||
    { echo "status: the server refused the queries: $(err)" >&2; exit 1; }
max=$(sql "SELECT @@GLOBAL.max_connections") || { echo "status: the server refused the queries: $(err)" >&2; exit 1; }
# Client statements only: the server's own threads (replication, the event
# scheduler) run for as long as the server does.
clients=$(sql "
SELECT COUNT(*), COALESCE(MAX(TIME), 0) FROM information_schema.PROCESSLIST
    WHERE COMMAND = 'Query' AND ID <> CONNECTION_ID() AND USER NOT IN ('system user', 'event_scheduler')") ||
    { echo "status: the server refused the queries: $(err)" >&2; exit 1; }
IFS=$'\t' read -r running longest <<EOF
$clients
EOF

echo "metric up 1"
connections=''
while IFS=$'\t' read -r name value; do
    case $name in
        Threads_connected) connections=$value; echo "metric connections $value" ;;
        Questions) echo "metric queries_count $value" ;;
        Slow_queries) echo "metric slow_queries_count $value" ;;
        Aborted_connects) echo "metric aborted_connects_count $value" ;;
        Created_tmp_disk_tables) echo "metric tmp_disk_tables_count $value" ;;
    esac
done <<EOF
$out
EOF
echo "metric max_connections $max"
if [ -n "$connections" ] && [ "$max" -gt 0 ] 2> /dev/null; then
    echo "metric connections_pct $((100 * connections / max))"
fi
echo "metric running $running"
echo "metric longest_query_seconds $longest"
