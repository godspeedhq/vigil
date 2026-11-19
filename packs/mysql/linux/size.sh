#!/usr/bin/env bash
#
# size.sh - each database's size on a MySQL or MariaDB server
#
# The size on disk of each database's InnoDB tables, data and indexes, from
# the server's list of InnoDB tablespaces (a table each, by default), which a
# user with PROCESS may read without being able to read the tables
# themselves. The server's own databases (mysql, sys, performance_schema)
# are left out. Connects to MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with
# the password in MYSQL_PWD, all set by the job; never on a command line.
#
# Metrics:
#   size_bytes  a database's InnoDB tables on disk, tagged database=<name>
#
# Example output:
#   metric size_bytes 114688 database=orders
#   metric size_bytes 4194304 database=shop
#
# Reading the results (starting points: tune them to the server):
#   Healthy  growth in line with the data the database takes in.
#   Watch    a database growing much faster than usual.
#   Act      growth that will fill the disk soon: compare with the disk's
#            free space (the base pack's disk job).
#
# Tables in the shared system tablespace (innodb_file_per_table off) or in
# another engine, such as MyISAM, are not counted. When the server does not
# answer, it prints nothing and succeeds: mysql_status reports that, as
# mysql.up 0.
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
    { echo "size: mysql not found: install the MySQL or MariaDB client" >&2; exit 1; }
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

if ! version=$(sql "SELECT VERSION()"); then
    down && exit 0
    echo "size: the server refused the login or the queries: $(err)" >&2
    exit 1
fi

# A file-per-table tablespace is named <database>/<table>. MySQL lists them
# in INNODB_TABLESPACES, MariaDB in INNODB_SYS_TABLESPACES.
case $version in
    *MariaDB*) view=INNODB_SYS_TABLESPACES ;;
    *) view=INNODB_TABLESPACES ;;
esac
out=$(sql "SELECT SUBSTRING_INDEX(NAME, '/', 1) AS db, SUM(FILE_SIZE) FROM information_schema.$view
    WHERE NAME LIKE '%/%' AND SUBSTRING_INDEX(NAME, '/', 1) NOT IN ('mysql', 'sys', 'performance_schema')
    GROUP BY db ORDER BY db") || { echo "size: the server refused the queries: $(err)" >&2; exit 1; }

while IFS=$'\t' read -r name bytes; do
    [ -n "$name" ] || continue
    echo "metric size_bytes $bytes database=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')"
done <<EOF
$out
EOF
