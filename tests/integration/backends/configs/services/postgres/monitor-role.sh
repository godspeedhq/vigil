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
# monitor-role.sh - run once by the postgres image at its first start: the
# read-only role the postgres pack logs in as, as an operator would make it,
# and a second database for the pack's size job to find.
set -eu
: "${POSTGRES_MONITOR_PASSWORD:?set POSTGRES_MONITOR_PASSWORD in .env}"
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -v pw="$POSTGRES_MONITOR_PASSWORD" <<'SQL'
CREATE ROLE vigil_monitor LOGIN PASSWORD :'pw' IN ROLE pg_monitor;
CREATE DATABASE orders;
SQL
