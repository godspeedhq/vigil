#!/usr/bin/env bash
#
# databases.sh - MongoDB's databases: their size on disk, data and
# indexes, collections and documents
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
# Reports the databases of the server at MONGODB_URL, the largest first:
# how many, and their size on disk; for each, its size, its data and its
# indexes (uncompressed), collections, indexes and documents. Past
# MONGODB_MOST (50) the rest are counted. From listDatabases, then one
# dbStats each.
#
# Reads the server at MONGODB_URL (default mongodb://localhost:27017), as
# MONGODB_USER (default vigil, with the clusterMonitor role) with the
# password in MONGODB_PASSWORD (a secret), with mongosh (MONGOSH names
# another): it runs _databases.js, beside this script, with no connection of its
# own, and _databases.js logs in from the environment, so the password is never
# on a command line. Over TLS, MONGODB_CACERT names the CA file when the
# system's are not enough. One server is read, as it is (never moved to the
# primary), unless MONGODB_URL names a replica set. What the jobs share is
# in _mongodb.js.
#
# Metrics:
#   up                         1 when the server answers, else 0
#   databases                  databases
#   size_bytes                 their size on disk
#   db_size_bytes              a database's size on disk, tagged db=<name>
#   db_data_bytes              its data, uncompressed
#   db_index_bytes             its indexes
#   db_collections             its collections
#   db_indexes                 its indexes
#   db_documents               its documents
#   databases_not_shown        past MONGODB_MOST, the databases not listed
#
# Example output (the rest are in the same form):
#   metric databases 4
#   metric size_bytes 1097728
#   metric db_size_bytes 69632 db=app
#   metric db_documents 10000 db=app
#
# Reading the results (starting points: tune them to the server):
#   Healthy  db_size_bytes growing as the application does.
#   Watch    a database growing faster than usual; db_index_bytes past
#            its data (indexes nobody uses).
#   Act      size_bytes near the disk's free space (the base pack has it).
#
# Requires: bash and mongosh
# Exit code: 0 on success, server up or down; 1 if mongosh is missing,
#   the login is refused, or the user may not run what the job asks
#
# Example (vigil.config):
#   [job.mongodb_databases]
#   file        = packs/mongodb/databases.sh
#   metric_name = mongodb.databases
#   run_every   = 15m
#   env         = MONGODB_URL=mongodb://localhost:27017
#   env         = MONGODB_USER=vigil
#   secret      = MONGODB_PASSWORD=secret:MONGODB_PASSWORD

set -u

prog=${MONGOSH:-mongosh}
command -v "$prog" > /dev/null 2>&1 || { echo "databases: $prog not found: the mongodb pack reads MongoDB with mongosh (MONGOSH names another)" >&2; exit 1; }
exec "$prog" --nodb --quiet --norc --file "$(dirname "$0")/_databases.js"
