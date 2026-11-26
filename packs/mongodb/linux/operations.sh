#!/usr/bin/env bash
#
# operations.sh - MongoDB's operations running now: how many, those past
# a minute, the longest, those waiting for a lock
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
# Reports the operations the server at MONGODB_URL is running for its
# clients: how many, those running past a minute, the longest, those
# waiting for a lock, and transactions open; and the five longest, each by
# namespace, kind and operation ID, never by its text, which may hold
# data. MongoDB's own background work, and this job's own currentOp, are
# left out. From one currentOp.
#
# Reads the server at MONGODB_URL (default mongodb://localhost:27017), as
# MONGODB_USER (default vigil, with the clusterMonitor role) with the
# password in MONGODB_PASSWORD (a secret), with mongosh (MONGOSH names
# another): it runs _operations.js, beside this script, with no connection of its
# own, and _operations.js logs in from the environment, so the password is never
# on a command line. Over TLS, MONGODB_CACERT names the CA file when the
# system's are not enough. One server is read, as it is (never moved to the
# primary), unless MONGODB_URL names a replica set. What the jobs share is
# in _mongodb.js.
#
# Metrics:
#   up                         1 when the server answers, else 0
#   running                    operations running
#   slow                       of those, running past 60 seconds
#   longest_seconds            the longest running
#   waiting_for_lock           of those, waiting for a lock
#   transactions_open          operations in a transaction
#   op_seconds                 the five longest, tagged ns=<db.collection>
#                              op=<query, command, ...> id=<opid>
#
# Example output (the rest are in the same form):
#   metric running 2
#   metric slow 1
#   metric longest_seconds 312.5
#   metric op_seconds 312.5 ns=app.events op=command id=7781
#
# Reading the results (starting points: tune them to the server):
#   Healthy  slow 0; waiting_for_lock 0.
#   Watch    slow above 0 on two runs in a row; waiting_for_lock above 0.
#   Act      an operation running for hours that nobody expects:
#            db.killOp(<id>), as an admin.
#
# Requires: bash and mongosh
# Exit code: 0 on success, server up or down; 1 if mongosh is missing,
#   the login is refused, or the user may not run what the job asks
#
# Example (vigil.config):
#   [job.mongodb_operations]
#   file        = packs/mongodb/operations.sh
#   metric_name = mongodb.operations
#   run_every   = 1m
#   env         = MONGODB_URL=mongodb://localhost:27017
#   env         = MONGODB_USER=vigil
#   secret      = MONGODB_PASSWORD=secret:MONGODB_PASSWORD

set -u

prog=${MONGOSH:-mongosh}
command -v "$prog" > /dev/null 2>&1 || { echo "operations: $prog not found: the mongodb pack reads MongoDB with mongosh (MONGOSH names another)" >&2; exit 1; }
exec "$prog" --nodb --quiet --norc --file "$(dirname "$0")/_operations.js"
