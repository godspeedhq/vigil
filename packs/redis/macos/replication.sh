#!/usr/bin/env bash
#
# replication.sh - a Redis or Valkey server's replication
#
# Asks the server for its INFO, as a user that may run nothing else. On a
# primary: the replicas connected to it, and for each whether it is in step
# and how far behind it is. On a replica: whether its link to the primary is
# up, when it last heard from it, and whether a full copy is under way. A
# server with neither reports is_replica 0 and replicas 0.
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
#   is_replica         1 when it replicates from a primary, else 0
#   replicas           replicas connected to it now
#   online             (primary) 1 while a replica is in step, 0 while it
#                      is still being sent a full copy, tagged
#                      replica=<its address>_<port>
#   lag_bytes          (primary) how far a replica is behind, in bytes of
#                      the replication stream, tagged replica=
#   lag_seconds        (primary) seconds since a replica last said how far
#                      it has got (about once a second), tagged replica=
#   link_up            (replica) 1 while its link to the primary is up
#   last_io_seconds    (replica) seconds since it last heard from the
#                      primary, while the link is up
#   link_down_seconds  (replica) how long the link has been down, while it
#                      is
#   sync_in_progress   (replica) 1 while it takes a full copy from the
#                      primary
#
# Example output, on a primary with one replica:
#   metric is_replica 0
#   metric replicas 1
#   metric online 1 replica=10.0.0.12_6379
#   metric lag_bytes 0 replica=10.0.0.12_6379
#   metric lag_seconds 0 replica=10.0.0.12_6379
#
# Reading the results (starting points: tune them to the server):
#   Healthy  on a primary, replicas as many as you run, each online 1
#            with lag_bytes near 0 and lag_seconds 0 or 1; on a replica,
#            link_up 1 and last_io_seconds below 10.
#   Watch    lag_bytes rising during heavy writes and not falling after
#            them; sync_in_progress 1 for long, or again and again: each
#            full copy costs the primary a fork and the replica a reload.
#   Act      replicas below what you run, on the primary; link_up 0 on a
#            replica: it serves older and older data. Alert on each
#            replica's own link_up and redis.up as well: they say at once
#            what the primary may learn only later.
#
# When the server does not answer, it prints nothing and succeeds:
# redis_status reports that, as redis.up 0.
# A Sentinel has none of this: it prints nothing there, and redis_status
# reports the Sentinel (mode=sentinel).
#
# Requires: bash, redis-cli or valkey-cli, and a user that may run INFO
#   (Redis 6 or Valkey on)
# Exit code: 0 on success, or when the server does not answer; 1 if the
#   client is missing or the server refuses the login or INFO
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

client=$(command -v redis-cli || command -v valkey-cli) ||
    { echo "replication: redis-cli not found: install the Redis or Valkey client (redis-cli or valkey-cli)" >&2; exit 1; }
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
    *) echo "replication: REDIS_TLS is '$REDIS_TLS': set it to 1 for TLS, or 0" >&2; exit 1 ;;
esac

# INFO: the server's default sections, as name:value lines.
out=$("$client" "${args[@]}" INFO 2> "$errf" | tr -d '\r')
# A refused password: the client says so on stderr, then carries on as the
# server's default user, which may answer. That is not this user's reading.
if grep -q 'AUTH failed' "$errf"; then
    echo "replication: the server refused the login: $(grep 'AUTH failed' "$errf" | head -n 1)" >&2
    exit 1
fi
case $out in
    '# '*) ;;
    *)
        # It could not be reached at all: a reading, not a failure. A TLS
        # handshake that failed (a certificate it cannot trust) is not that,
        # though the client says "Could not connect" for it too.
        if { cat "$errf"; printf '%s\n' "$out"; } | grep '^Could not connect to' | grep -qv 'SSL\|TLS\|certificate'; then
            exit 0
        fi
        # An error reply (NOAUTH, NOPERM, a full server) or a failed TLS
        # handshake. The client exits 0 on an error reply, so what it
        # printed is what says.
        echo "replication: INFO failed: $({ printf '%s\n' "$out"; cat "$errf"; } | grep -v '^$' | head -n 3 | tr '\n' ' ')" >&2
        exit 1
        ;;
esac

printf '%s\n' "$out" | awk '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function put(name, key) { if ((key in v) && num(v[key])) print "metric " name " " v[key] }
    function tag(x) { gsub(/[^A-Za-z0-9_.-]/, "_", x); return x == "" ? "unknown" : x }
    { i = index($0, ":"); if (i > 1) v[substr($0, 1, i - 1)] = substr($0, i + 1) }
    END {
        # A Sentinel has none of this: redis_status reports it.
        if (v["redis_mode"] == "sentinel" || v["server_mode"] == "sentinel") exit
        role = v["role"]
        replica = (role == "slave" || role == "replica")
        print "metric is_replica " (replica ? 1 : 0)
        if (num(v["connected_slaves"])) put("replicas", "connected_slaves")
        else put("replicas", "connected_replicas")
        # Each replica, as the primary lists it: slave0:ip=...,port=...,
        # state=online,offset=...,lag=...
        for (n = 0; (("slave" n) in v) || (("replica" n) in v); n++) {
            line = (("slave" n) in v) ? v["slave" n] : v["replica" n]
            ip = ""; port = ""; state = ""; offset = ""; lag = ""
            c = split(line, f, ",")
            for (j = 1; j <= c; j++) {
                e = index(f[j], "=")
                k = substr(f[j], 1, e - 1); x = substr(f[j], e + 1)
                if (k == "ip") ip = x; else if (k == "port") port = x; else if (k == "state") state = x
                else if (k == "offset") offset = x; else if (k == "lag") lag = x
            }
            name = tag(ip "_" port)
            print "metric online " (state == "online" ? 1 : 0) " replica=" name
            if (num(offset) && num(v["master_repl_offset"])) {
                d = v["master_repl_offset"] - offset
                # Printed whole, not with %d, which some awks cap at 2^31.
                print "metric lag_bytes " (d < 0 ? 0 : d) " replica=" name
            }
            if (num(lag)) print "metric lag_seconds " lag " replica=" name
        }
        if (replica) {
            up = (v["master_link_status"] == "up")
            print "metric link_up " (up ? 1 : 0)
            if (up && num(v["master_last_io_seconds_ago"]) && v["master_last_io_seconds_ago"] + 0 >= 0)
                put("last_io_seconds", "master_last_io_seconds_ago")
            if (!up && num(v["master_link_down_since_seconds"]) && v["master_link_down_since_seconds"] + 0 >= 0)
                put("link_down_seconds", "master_link_down_since_seconds")
            put("sync_in_progress", "master_sync_in_progress")
        }
    }'
