#!/usr/bin/env bash
#
# activity.sh - a MySQL or MariaDB server's open InnoDB transactions
#
# Finds the longest open transaction, the transactions open on a connection
# that is doing nothing (they hold their locks and hold back purge), and the
# transactions waiting on a row lock. Leaves out its own connection. Reads
# information_schema.INNODB_TRX, which MySQL and MariaDB both have. Connects
# to MYSQL_HOST and MYSQL_TCP_PORT as MYSQL_USER, with the password in
# MYSQL_PWD, all set by the job; never on a command line.
#
# Metrics:
#   longest_transaction_seconds          the longest open transaction now
#   idle_in_transaction                  transactions open on a connection
#                                        that is doing nothing
#   longest_idle_in_transaction_seconds  the longest of those idle times
#   waiting                              transactions waiting on a row lock
#   longest_wait_seconds                 the longest row lock wait now
#
# Example output:
#   metric longest_transaction_seconds 3
#   metric idle_in_transaction 0
#   metric longest_idle_in_transaction_seconds 0
#   metric waiting 0
#   metric longest_wait_seconds 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  waiting at 0, or briefly above it; no transaction open for
#            minutes; no connection idle in a transaction for more than a few
#            seconds.
#   Watch    longest_wait_seconds above a few seconds, again and again:
#            statements queue behind each other's row locks.
#   Act      longest_wait_seconds nearing innodb_lock_wait_timeout (50 s by
#            default), when statements start failing; a transaction idle for
#            minutes holds its locks and lets the undo history grow
#            (mysql_innodb history_list_count): find it in
#            information_schema.INNODB_TRX and fix the application, or
#            lower wait_timeout.
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
    { echo "activity: mysql not found: install the MySQL or MariaDB client" >&2; exit 1; }
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

# One query, one "name value" row per metric. A transaction's connection is
# idle when its command is Sleep.
if ! out=$(sql "
SELECT 'longest_transaction_seconds', COALESCE(MAX(TIMESTAMPDIFF(SECOND, t.trx_started, NOW())), 0)
    FROM information_schema.INNODB_TRX t WHERE t.trx_mysql_thread_id <> CONNECTION_ID()
UNION ALL SELECT 'idle_in_transaction', COUNT(*)
    FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p ON p.ID = t.trx_mysql_thread_id
    WHERE p.COMMAND = 'Sleep'
UNION ALL SELECT 'longest_idle_in_transaction_seconds', COALESCE(MAX(p.TIME), 0)
    FROM information_schema.INNODB_TRX t JOIN information_schema.PROCESSLIST p ON p.ID = t.trx_mysql_thread_id
    WHERE p.COMMAND = 'Sleep'
UNION ALL SELECT 'waiting', COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_state = 'LOCK WAIT'
UNION ALL SELECT 'longest_wait_seconds', COALESCE(MAX(TIMESTAMPDIFF(SECOND, trx_wait_started, NOW())), 0)
    FROM information_schema.INNODB_TRX WHERE trx_state = 'LOCK WAIT'"); then
    down && exit 0
    echo "activity: the server refused the login or the queries: $(err)" >&2
    exit 1
fi

while IFS=$'\t' read -r name value; do
    [ -n "$name" ] && echo "metric $name $value"
done <<EOF
$out
EOF
