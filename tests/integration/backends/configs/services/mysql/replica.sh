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
# Run by each replica of compose.mysql.yaml at its first start, after
# monitor-user.sh: replicate from its source by GTID, read-only.

set -eu
: "${REPLICATION_PASSWORD:?set MYSQL_REPLICATION_PASSWORD in .env}"
: "${SOURCE_HOST:?}"
if command -v mariadb > /dev/null 2>&1; then
    MYSQL_PWD=$MARIADB_ROOT_PASSWORD mariadb -uroot <<SQL
CHANGE MASTER TO MASTER_HOST = '$SOURCE_HOST', MASTER_USER = 'repl',
    MASTER_PASSWORD = '$REPLICATION_PASSWORD', MASTER_USE_GTID = slave_pos;
START SLAVE;
SET GLOBAL read_only = 1;
SQL
else
    MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot <<SQL
CHANGE REPLICATION SOURCE TO SOURCE_HOST = '$SOURCE_HOST', SOURCE_USER = 'repl',
    SOURCE_PASSWORD = '$REPLICATION_PASSWORD', SOURCE_AUTO_POSITION = 1, GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
SET GLOBAL super_read_only = 1;
SQL
fi
