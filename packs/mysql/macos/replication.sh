#!/usr/bin/env bash
#
# replication.sh - a MySQL or MariaDB server's replication
#
# On a replica: whether its two replication threads run (one receives the
# source's changes, one applies them), and how far behind the source it is,
# for each channel (MySQL) or connection (MariaDB) it replicates through. On
# a source: the replicas connected to it now. A server with neither reports
# is_replica 0 and replicas 0. MySQL and MariaDB name these differently; this
# reads either. Connects to MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with
# the password in MYSQL_PWD, all set by the job; never on a command line.
#
# Metrics:
#   is_replica   1 when it replicates from a source, else 0
#   io_running   (replica) 1 while the thread receiving from the source runs,
#                tagged channel=<name, or default>
#   sql_running  (replica) 1 while the thread applying the changes runs,
#                tagged channel=<name, or default>
#   lag_seconds  (replica) how far behind the source it is
#                (Seconds_Behind_Source), tagged channel=<name, or default>;
#                left out while the applying thread is stopped, when the
#                server cannot tell
#   replicas     (source) replicas connected to it now; one whose machine
#                stopped without closing its connection still counts
#                until the source's connection to it times out
#
# Example output, on a replica:
#   metric is_replica 1
#   metric replicas 0
#   metric io_running 1 channel=default
#   metric sql_running 1 channel=default
#   metric lag_seconds 0 channel=default
#
# Reading the results (starting points: tune them to the server):
#   Healthy  on a replica, io_running 1 and sql_running 1, and lag_seconds a
#            few seconds at most; on a source, replicas as many as you run.
#   Watch    lag_seconds rising during heavy writes and not falling after
#            them: the replica applies more slowly than the source writes.
#   Act      io_running 0: the replica cannot reach or log in to its source;
#            sql_running 0: applying stopped on an error (SHOW REPLICA STATUS
#            says which); either way it falls further behind. replicas below
#            what you run, on the source: one is not connected. Alert on
#            each replica's own io_running and mysql.up as well: they say
#            at once what the source may learn only minutes later.
#
# When the server does not answer, it prints nothing and succeeds:
# mysql_status reports that, as mysql.up 0.
#
# Requires: bash, the mysql client (MySQL's, or MariaDB's mariadb), and a
#   user with PROCESS and REPLICATION CLIENT (MariaDB: and REPLICA MONITOR)
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
    { echo "replication: mysql not found: install the MySQL or MariaDB client" >&2; exit 1; }
# The client's stderr goes to a file of its own: MariaDB's prints warnings
# there even when a query works, which must never be read as data. With -N,
# rows only; without it, a first row of column names.
errf=$(mktemp "${TMPDIR:-/tmp}/vigil-mysql.XXXXXX") || exit 1
trap 'rm -f "$errf"' EXIT
sql() {
    "$client" --protocol=TCP -h "${MYSQL_HOST:-127.0.0.1}" -P "${MYSQL_TCP_PORT:-3306}" \
        -u "${MYSQL_USER:-vigil_monitor}" --connect-timeout=5 -B "$@" 2> "$errf"
}
fail() { echo "replication: the server refused the login or the queries: $(grep -v '^WARNING' "$errf" | tr '\n' ' ')" >&2; exit 1; }
# Whether it failed to reach the server at all: errors 2002, 2003, 2005 and
# 2013.
down() { grep -qE 'ERROR (2002|2003|2005|2013)' "$errf"; }

if ! version=$(sql -N -e "SELECT VERSION()"); then
    down && exit 0
    fail
fi
replicas=$(sql -N -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST
    WHERE COMMAND IN ('Binlog Dump', 'Binlog Dump GTID')") || fail

# Every channel's status, with its column names. MariaDB lists every
# connection with SHOW ALL REPLICAS STATUS (10.5.1 on), MySQL every channel
# with SHOW REPLICA STATUS (8.0.22 on); each falls back to its older name.
case $version in
    *MariaDB*) status=$(sql -e "SHOW ALL REPLICAS STATUS") || status=$(sql -e "SHOW ALL SLAVES STATUS") || fail ;;
    *) status=$(sql -e "SHOW REPLICA STATUS") || status=$(sql -e "SHOW SLAVE STATUS") || fail ;;
esac

# One "name value tag" line per metric and channel, the columns found by
# name under either spelling. A channel name in a tag keeps letters, digits,
# _, . and - only.
rows=$(printf '%s\n' "$status" | awk -F '\t' '
    NR == 1 {
        for (i = 1; i <= NF; i++) {
            if ($i == "Replica_IO_Running" || $i == "Slave_IO_Running") io = i
            if ($i == "Replica_SQL_Running" || $i == "Slave_SQL_Running") sq = i
            if ($i == "Seconds_Behind_Source" || $i == "Seconds_Behind_Master") lag = i
            if ($i == "Channel_Name" || $i == "Connection_name") ch = i
        }
        next
    }
    io && sq {
        name = ch ? $ch : ""
        if (name == "") name = "default"
        gsub(/[^A-Za-z0-9_.-]/, "_", name)
        print "io_running", ($io == "Yes" ? 1 : 0), "channel=" name
        print "sql_running", ($sq == "Yes" ? 1 : 0), "channel=" name
        if (lag && $lag ~ /^[0-9]+$/) print "lag_seconds", $lag, "channel=" name
    }')

if [ -n "$rows" ]; then echo "metric is_replica 1"; else echo "metric is_replica 0"; fi
echo "metric replicas $replicas"
while read -r name value tag; do
    [ -n "$name" ] || continue
    echo "metric $name $value $tag"
done <<EOF
$rows
EOF
