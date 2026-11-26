#!/usr/bin/env bash
#
# status.sh - a MongoDB server: up, connections, operations and their
# latency, the WiredTiger cache, queues, memory, asserts
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
# Reports one server, the one at MONGODB_URL: whether it answers, its
# version and storage engine, its uptime; connections open and their share
# of the most it takes; operations by kind and how long they took on
# average; operations queued for a lock; its memory; the WiredTiger cache,
# how full and how dirty, and pages evicted by the threads that serve
# requests (a cache that cannot keep up); cursors; asserts; network; and
# transactions. From one serverStatus.
#
# Reads the server at MONGODB_URL (default mongodb://localhost:27017), as
# MONGODB_USER (default vigil, with the clusterMonitor role) with the
# password in MONGODB_PASSWORD (a secret), with mongosh (MONGOSH names
# another): it runs _status.js, beside this script, with no connection of its
# own, and _status.js logs in from the environment, so the password is never
# on a command line. Over TLS, MONGODB_CACERT names the CA file when the
# system's are not enough. One server is read, as it is (never moved to the
# primary), unless MONGODB_URL names a replica set. What the jobs share is
# in _mongodb.js.
#
# Metrics:
#   up                         1 when the server answers, else 0
#   info                       always 1, tagged version=<9.0.8>
#                              engine=<wiredTiger>
#   uptime_seconds             since it started
#   connections                connections open
#   connections_available      connections it still takes
#   connections_pct            connections, of the most it takes
#   connections_active         of those, running an operation
#   connections_created_count  connections opened (a running total)
#   operations_count           operations (a running total), tagged
#                              op=<insert, query, update, delete, getmore,
#                              command>
#   latency_avg_ms             time an operation took on average, since it
#                              started, tagged op=<reads, writes, commands>
#   queued                     operations waiting for a lock, tagged
#                              for=<read, write>
#   memory_resident_bytes      memory it holds
#   cache_bytes                WiredTiger's cache, in use
#   cache_max_bytes            the most it may hold
#   cache_pct                  cache_bytes, of cache_max_bytes
#   cache_dirty_pct            changes not yet written, of cache_max_bytes
#   cache_evicted_by_threads_count  pages the threads serving requests had to
#                              evict themselves (a running total)
#   cursors_open               cursors open
#   cursors_timed_out_count    cursors closed for idling (a running total)
#   asserts_count              asserts (a running total), tagged
#                              kind=<regular, warning, msg, user>
#   page_faults_count          page faults (a running total)
#   network_in_bytes_count     bytes received (a running total)
#   network_out_bytes_count    bytes sent (a running total)
#   transactions_open          multi-document transactions open
#   transactions_aborted_count transactions aborted (a running total)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 version=9.0.8 engine=wiredTiger
#   metric connections 15
#   metric connections_pct 3.67
#   metric latency_avg_ms 45.51 op=writes
#   metric cache_pct 3.46
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; connections_pct below 50; cache_pct near 80 (WiredTiger
#            keeps it there) and cache_dirty_pct below 5; queued near 0;
#            cache_evicted_by_threads_count flat.
#   Watch    connections_pct past 70; cache_dirty_pct past 10; queued above
#            0 on several runs; latency_avg_ms rising; asserts_count
#            kind=regular or warning rising.
#   Act      up 0; connections_pct past 90 (new clients refused);
#            cache_dirty_pct past 20 or cache_evicted_by_threads_count
#            rising fast (writes stall); queued rising run after run.
#
# Requires: bash and mongosh
# Exit code: 0 on success, server up or down; 1 if mongosh is missing,
#   the login is refused, or the user may not run what the job asks
#
# Example (vigil.config):
#   [job.mongodb_status]
#   file        = packs/mongodb/status.sh
#   metric_name = mongodb
#   run_every   = 1m
#   env         = MONGODB_URL=mongodb://localhost:27017
#   env         = MONGODB_USER=vigil
#   secret      = MONGODB_PASSWORD=secret:MONGODB_PASSWORD

set -u

prog=${MONGOSH:-mongosh}
command -v "$prog" > /dev/null 2>&1 || { echo "status: $prog not found: the mongodb pack reads MongoDB with mongosh (MONGOSH names another)" >&2; exit 1; }
exec "$prog" --nodb --quiet --norc --file "$(dirname "$0")/_status.js"
