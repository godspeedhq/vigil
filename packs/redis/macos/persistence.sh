#!/usr/bin/env bash
#
# persistence.sh - whether a Redis or Valkey server writes its data to disk
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
# reports whether its last snapshot (RDB) was written, how long ago, and the
# changes since; and, with the append-only file (AOF) on, whether its
# writes and its last rewrite worked.
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
#   last_save_ok             1 when the last snapshot was written, 0 when
#                            it failed
#   last_save_age_seconds    seconds since the last snapshot was written,
#                            or since the start when none has been
#   changes_since_save       writes since then, which a crash would lose
#                            without the AOF
#   save_in_progress         1 while a snapshot is written
#   last_fork_usec           how long the last fork took, in microseconds:
#                            the server stops for it
#   aof_enabled              1 when the append-only file is on
#   aof_last_write_ok        1 when the last write to it worked
#   aof_last_rewrite_ok      1 when its last rewrite worked
#   aof_rewrite_in_progress  1 while it is rewritten
#
# Example output:
#   metric last_save_ok 1
#   metric last_save_age_seconds 212
#   metric changes_since_save 40
#   metric save_in_progress 0
#   metric last_fork_usec 310
#   metric aof_enabled 0
#   metric aof_last_write_ok 1
#   metric aof_last_rewrite_ok 1
#   metric aof_rewrite_in_progress 0
#
# Reading the results (starting points: tune them to the server):
#   Healthy  last_save_ok 1 and aof_last_write_ok 1; last_save_age_seconds
#            within your snapshot schedule (the save setting).
#   Watch    last_save_age_seconds well past the schedule while
#            changes_since_save grows; last_fork_usec in the hundreds of
#            thousands: each snapshot stalls the server for that long.
#   Act      last_save_ok 0 or aof_last_write_ok 0: the disk is full or not
#            writable, and by default the server then refuses writes
#            (stop-writes-on-bgsave-error). With snapshots off (save ""),
#            last_save_age_seconds only grows: read the AOF metrics instead,
#            or none if it is a cache with nothing to keep.
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
    { echo "persistence: redis-cli not found: install the Redis or Valkey client (redis-cli or valkey-cli)" >&2; exit 1; }
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
    *) echo "persistence: REDIS_TLS is '$REDIS_TLS': set it to 1 for TLS, or 0" >&2; exit 1 ;;
esac

# INFO: the server's default sections, as name:value lines.
out=$("$client" "${args[@]}" INFO 2> "$errf" | tr -d '\r')
# A refused password: the client says so on stderr, then carries on as the
# server's default user, which may answer. That is not this user's reading.
if grep -q 'AUTH failed' "$errf"; then
    echo "persistence: the server refused the login: $(grep 'AUTH failed' "$errf" | head -n 1)" >&2
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
        echo "persistence: INFO failed: $({ printf '%s\n' "$out"; cat "$errf"; } | grep -v '^$' | head -n 3 | tr '\n' ' ')" >&2
        exit 1
        ;;
esac

printf '%s\n' "$out" | awk -v here="$(date +%s)" '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function put(name, key) { if ((key in v) && num(v[key])) print "metric " name " " v[key] }
    function tag(x) { gsub(/[^A-Za-z0-9_.-]/, "_", x); return x == "" ? "unknown" : x }
    { i = index($0, ":"); if (i > 1) v[substr($0, 1, i - 1)] = substr($0, i + 1) }
    END {
        # A Sentinel has none of this: redis_status reports it.
        if (v["redis_mode"] == "sentinel" || v["server_mode"] == "sentinel") exit
        # The clock of the server, when it says (6.2 on); else the one here.
        now = num(v["server_time_usec"]) ? int(v["server_time_usec"] / 1000000) : here
        if ("rdb_last_bgsave_status" in v) print "metric last_save_ok " (v["rdb_last_bgsave_status"] == "ok" ? 1 : 0)
        if (num(v["rdb_last_save_time"])) {
            a = now - v["rdb_last_save_time"]
            print "metric last_save_age_seconds " (a < 0 ? 0 : int(a))
        }
        put("changes_since_save", "rdb_changes_since_last_save")
        put("save_in_progress", "rdb_bgsave_in_progress")
        put("last_fork_usec", "latest_fork_usec")
        put("aof_enabled", "aof_enabled")
        if ("aof_last_write_status" in v) print "metric aof_last_write_ok " (v["aof_last_write_status"] == "ok" ? 1 : 0)
        if ("aof_last_bgrewrite_status" in v) print "metric aof_last_rewrite_ok " (v["aof_last_bgrewrite_status"] == "ok" ? 1 : 0)
        put("aof_rewrite_in_progress", "aof_rewrite_in_progress")
    }'
