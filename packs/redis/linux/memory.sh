#!/usr/bin/env bash
#
# memory.sh - a Redis or Valkey server's memory
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
# reports the memory its data takes against its limit (maxmemory), what the
# operating system gives it, the most it has taken, and how fragmented it
# is.
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
#   used_bytes           memory the server has allocated for its data
#                        and itself (used_memory)
#   rss_bytes            memory the operating system gives the process
#   peak_bytes           the most used_bytes has been since the start
#   max_bytes            the limit (maxmemory), 0 for none, tagged
#                        policy=<what it does at the limit:
#                        maxmemory-policy>
#   used_pct             used_bytes as a percent of the limit; left out
#                        with no limit
#   fragmentation_ratio  rss_bytes over used_bytes
#
# Example output:
#   metric used_bytes 1272640
#   metric rss_bytes 11059200
#   metric peak_bytes 1272640
#   metric max_bytes 268435456 policy=allkeys-lru
#   metric used_pct 0
#   metric fragmentation_ratio 8.69
#
# Reading the results (starting points: tune them to the server):
#   Healthy  used_pct below 80, or steady at the limit on a cache meant to
#            evict (policy allkeys-lru and the like); fragmentation_ratio
#            1 to 1.5 on a server holding real data.
#   Watch    used_pct 80 to 95 with policy noeviction: at 100 writes are
#            refused; max_bytes 0: the server grows until the machine runs
#            out; fragmentation_ratio above 1.5: memory held but not used.
#   Act      used_pct at 100 with policy noeviction: writes fail with OOM;
#            fragmentation_ratio below 1: the system is swapping the server
#            out, and it slows down. A small server reads a high
#            fragmentation_ratio with no harm: judge it once there is data.
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

set -u

client=$(command -v redis-cli || command -v valkey-cli) ||
    { echo "memory: redis-cli not found: install the Redis or Valkey client (redis-cli or valkey-cli)" >&2; exit 1; }
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
    *) echo "memory: REDIS_TLS is '$REDIS_TLS': set it to 1 for TLS, or 0" >&2; exit 1 ;;
esac

# INFO: the server's default sections, as name:value lines.
out=$("$client" "${args[@]}" INFO 2> "$errf" | tr -d '\r')
# A refused password: the client says so on stderr, then carries on as the
# server's default user, which may answer. That is not this user's reading.
if grep -q 'AUTH failed' "$errf"; then
    echo "memory: the server refused the login: $(grep 'AUTH failed' "$errf" | head -n 1)" >&2
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
        echo "memory: INFO failed: $({ printf '%s\n' "$out"; cat "$errf"; } | grep -v '^$' | head -n 3 | tr '\n' ' ')" >&2
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
        put("used_bytes", "used_memory")
        put("rss_bytes", "used_memory_rss")
        put("peak_bytes", "used_memory_peak")
        if (num(v["maxmemory"])) print "metric max_bytes " v["maxmemory"] " policy=" tag(v["maxmemory_policy"])
        if (num(v["maxmemory"]) && v["maxmemory"] + 0 > 0 && num(v["used_memory"]))
            print "metric used_pct " int(100 * v["used_memory"] / v["maxmemory"])
        put("fragmentation_ratio", "mem_fragmentation_ratio")
    }'
