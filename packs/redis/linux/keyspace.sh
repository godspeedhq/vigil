#!/usr/bin/env bash
#
# keyspace.sh - the keys in each of a Redis or Valkey server's databases
#
# Asks the server for its INFO, as a user that may run nothing else, and
# reports how many keys each database holds, and how many of them expire.
# It reads the server's own counts: it never lists or reads a key.
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
#   keys     keys in a database, tagged db=<db0, db1 and so on>; an
#            empty server reports keys 0 for db0
#   expires  of those, the keys with a time to live, tagged db=
#
# Example output:
#   metric keys 1520 db=db0
#   metric expires 1200 db=db0
#   metric keys 12 db=db3
#   metric expires 0 db=db3
#
# Reading the results (starting points: tune them to the server):
#   Healthy  keys steady, or rising and falling with the work; on a
#            cache, expires close to keys.
#   Watch    keys growing without end, with expires flat: keys written
#            without a time to live, which only eviction or a person will
#            remove.
#   Act      keys falling to 0 when they should not: a FLUSHALL, or a
#            restart that loaded nothing (redis.uptime_seconds says which).
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
    { echo "keyspace: redis-cli not found: install the Redis or Valkey client (redis-cli or valkey-cli)" >&2; exit 1; }
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
    *) echo "keyspace: REDIS_TLS is '$REDIS_TLS': set it to 1 for TLS, or 0" >&2; exit 1 ;;
esac

# INFO: the server's default sections, as name:value lines.
out=$("$client" "${args[@]}" INFO 2> "$errf" | tr -d '\r')
# A refused password: the client says so on stderr, then carries on as the
# server's default user, which may answer. That is not this user's reading.
if grep -q 'AUTH failed' "$errf"; then
    echo "keyspace: the server refused the login: $(grep 'AUTH failed' "$errf" | head -n 1)" >&2
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
        echo "keyspace: INFO failed: $({ printf '%s\n' "$out"; cat "$errf"; } | grep -v '^$' | head -n 3 | tr '\n' ' ')" >&2
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
        # db0:keys=1520,expires=1200,avg_ttl=0, in the order of the numbers.
        top = -1
        for (k in v) if (k ~ /^db[0-9]+$/ && substr(k, 3) + 0 > top) top = substr(k, 3) + 0
        if (top < 0) { print "metric keys 0 db=db0"; print "metric expires 0 db=db0" }
        for (n = 0; n <= top; n++) {
            if (!(("db" n) in v)) continue
            c = split(v["db" n], f, ",")
            for (j = 1; j <= c; j++) {
                e = index(f[j], "=")
                k = substr(f[j], 1, e - 1); x = substr(f[j], e + 1)
                if ((k == "keys" || k == "expires") && num(x)) print "metric " k " " x " db=db" n
            }
        }
    }'
