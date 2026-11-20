#!/usr/bin/env bash
#
# status.sh - a Redis or Valkey server's health
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
# Asks the server for its INFO, as a user that may run nothing else, and
# reports whether it answers and what it is, its clients against the limit,
# and running totals of connections, commands, lookups that found their key
# and those that did not, keys evicted and expired, and error replies.
#
# Connects to REDIS_HOST and REDIS_PORT as REDIS_USER, with the password in
# REDISCLI_AUTH, all set by the job; never on a command line. With no
# password, it sends no user: the server's default user. REDIS_TLS=1
# connects with TLS, the server's certificate checked against the system's
# CAs or REDIS_CACERT, a CA file; REDIS_CERT and REDIS_KEY give a client
# certificate, for a server that asks for one. redis-cli and valkey-cli
# check that the certificate is from a CA they trust, not that it names the
# server: give REDIS_CACERT a CA that signs only your servers.
#
# Metrics:
#   up                          1 when the server answers, else 0
#   info                        always 1, tagged server=<redis or valkey>,
#                               version=<its version> and mode=<standalone,
#                               cluster or sentinel>
#   loading                     1 while it loads its data from disk after a
#                               start, when it answers little else
#   uptime_seconds              how long it has run
#   clients                     client connections now
#   blocked_clients             clients waiting in a blocking command (BLPOP
#                               and the like)
#   max_clients                 the server's limit (maxclients)
#   clients_pct                 clients as a percent of the limit
#   rejected_connections_count  connections refused at the limit (a running
#                               total)
#   connections_count           connections accepted (a running total)
#   commands_count              commands run (a running total)
#   ops_per_sec                 commands a second, as the server counts them
#                               now
#   hits_count                  lookups that found their key (a running total)
#   misses_count                lookups that did not (a running total)
#   hit_pct                     hits as a percent of all lookups since the
#                               server started; left out before the first
#   evicted_keys_count          keys removed to stay under maxmemory (a
#                               running total)
#   expired_keys_count          keys removed as their time ran out (a running
#                               total)
#   error_replies_count         commands answered with an error (a running
#                               total; Redis 6.2 and Valkey on)
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 server=valkey version=9.2.0 mode=standalone
#   metric clients 12
#   metric max_clients 10000
#   metric clients_pct 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  up 1; clients_pct below 70; rejected_connections_count flat;
#            evicted_keys_count flat, unless it is a cache meant to evict.
#   Watch    clients_pct 70 to 90; blocked_clients growing where nothing
#            should wait; hit_pct falling on a cache: it holds less of what
#            is asked for; error_replies_count rising faster than usual.
#   Act      up 0; loading 1 for long; rejected_connections_count rising:
#            clients are turned away at maxclients; evicted_keys_count
#            rising where keys must not be lost. The _count totals restart
#            with the server: graph them as a rate.
#
# Requires: bash, redis-cli or valkey-cli, and a user that may run INFO
#   (Redis 6 or Valkey on)
# Exit code: 0 on success, server up or down; 1 if the client is missing or
#   the server refuses the login or INFO

set -u

client=$(command -v redis-cli || command -v valkey-cli) ||
    { echo "status: redis-cli not found: install the Redis or Valkey client (redis-cli or valkey-cli)" >&2; exit 1; }
# The client's stderr goes to a file of its own, read only to say what went
# wrong, never as data.
errf=$(mktemp "${TMPDIR:-/tmp}/vigil-redis.XXXXXX") || exit 1
trap 'rm -f "$errf"' EXIT

# Where the server is, as the client takes it. The password stays in
# REDISCLI_AUTH, which both clients read for themselves.
args=(-h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}")
# A connect timeout, where the client has one (Redis 7.4 and Valkey 8.1
# on); without one, the job's max_runtime ends a run that waits.
"$client" --help 2>&1 | grep -q -- '-t <timeout>' && args+=(-t 5)
[ -n "${REDISCLI_AUTH-}" ] && args+=(--user "${REDIS_USER:-vigil_monitor}")
case ${REDIS_TLS:-0} in
    1 | yes | true)
        args+=(--tls)
        [ -n "${REDIS_CACERT-}" ] && args+=(--cacert "$REDIS_CACERT")
        [ -n "${REDIS_CERT-}" ] && args+=(--cert "$REDIS_CERT" --key "${REDIS_KEY-}")
        ;;
    0 | no | false) ;;
    *) echo "status: REDIS_TLS is '$REDIS_TLS': set it to 1 for TLS, or 0" >&2; exit 1 ;;
esac

# INFO: the server's default sections, as name:value lines.
out=$("$client" "${args[@]}" INFO 2> "$errf" | tr -d '\r')
# A refused password: the client says so on stderr, then carries on as the
# server's default user, which may answer. That is not this user's reading.
if grep -q 'AUTH failed' "$errf"; then
    echo "status: the server refused the login: $(grep 'AUTH failed' "$errf" | head -n 1)" >&2
    exit 1
fi
case $out in
    '# '*) ;;
    *)
        # It could not be reached at all: a reading, not a failure. A TLS
        # handshake that failed (a certificate it cannot trust) is not that,
        # though the client says "Could not connect" for it too.
        if { cat "$errf"; printf '%s\n' "$out"; } | grep '^Could not connect to' | grep -qv 'SSL\|TLS\|certificate'; then
            echo "metric up 0"; exit 0
        fi
        # An error reply (NOAUTH, NOPERM, a full server) or a failed TLS
        # handshake. The client exits 0 on an error reply, so what it
        # printed is what says.
        echo "status: INFO failed: $({ printf '%s\n' "$out"; cat "$errf"; } | grep -v '^$' | head -n 3 | tr '\n' ' ')" >&2
        exit 1
        ;;
esac

printf '%s\n' "$out" | awk '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function put(name, key) { if ((key in v) && num(v[key])) print "metric " name " " v[key] }
    function tag(x) { gsub(/[^A-Za-z0-9_.-]/, "_", x); return x == "" ? "unknown" : x }
    { i = index($0, ":"); if (i > 1) v[substr($0, 1, i - 1)] = substr($0, i + 1) }
    END {
        print "metric up 1"
        server = ("server_name" in v) ? v["server_name"] : "redis"
        version = ("valkey_version" in v) ? v["valkey_version"] : v["redis_version"]
        mode = ("server_mode" in v) ? v["server_mode"] : v["redis_mode"]
        print "metric info 1 server=" tag(server) " version=" tag(version) " mode=" tag(mode)
        put("loading", "loading")
        put("uptime_seconds", "uptime_in_seconds")
        put("clients", "connected_clients")
        put("blocked_clients", "blocked_clients")
        put("max_clients", "maxclients")
        if (num(v["connected_clients"]) && num(v["maxclients"]) && v["maxclients"] + 0 > 0)
            print "metric clients_pct " int(100 * v["connected_clients"] / v["maxclients"])
        put("rejected_connections_count", "rejected_connections")
        put("connections_count", "total_connections_received")
        put("commands_count", "total_commands_processed")
        put("ops_per_sec", "instantaneous_ops_per_sec")
        put("hits_count", "keyspace_hits")
        put("misses_count", "keyspace_misses")
        if (num(v["keyspace_hits"]) && num(v["keyspace_misses"]) && v["keyspace_hits"] + v["keyspace_misses"] > 0)
            print "metric hit_pct " int(100 * v["keyspace_hits"] / (v["keyspace_hits"] + v["keyspace_misses"]))
        put("evicted_keys_count", "evicted_keys")
        put("expired_keys_count", "expired_keys")
        put("error_replies_count", "total_error_replies")
    }'
