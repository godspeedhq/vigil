#!/bin/sh
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
# Run by each server of compose.mysql.yaml at its first start: the mysql
# pack's read-only user, vigil_monitor, with what README says to grant, made
# on this server only (not written to the binary log, so a replica never
# copies it over its own); on a source, a database for the tests, and the
# user its replica copies as. MariaDB names the right to read replication
# status REPLICA MONITOR; MySQL has it in REPLICATION CLIENT.

set -eu
: "${MONITOR_PASSWORD:?set MYSQL_MONITOR_PASSWORD in .env}"
client=mysql
command -v mariadb > /dev/null 2>&1 && client=mariadb
root_pw=${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}
extra=''
[ "$client" = mariadb ] && extra=', REPLICA MONITOR'
MYSQL_PWD=$root_pw "$client" -uroot <<SQL
SET sql_log_bin = 0;
CREATE USER 'vigil_monitor'@'%' IDENTIFIED BY '$MONITOR_PASSWORD';
GRANT PROCESS, REPLICATION CLIENT$extra ON *.* TO 'vigil_monitor'@'%';
SET sql_log_bin = 1;
SQL
if [ "${ROLE:-}" = source ]; then
    : "${REPLICATION_PASSWORD:?set MYSQL_REPLICATION_PASSWORD in .env}"
    MYSQL_PWD=$root_pw "$client" -uroot <<SQL
CREATE DATABASE orders;
CREATE USER 'repl'@'%' IDENTIFIED BY '$REPLICATION_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
SQL
fi
