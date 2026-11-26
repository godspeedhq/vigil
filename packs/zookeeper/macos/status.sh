#!/usr/bin/env bash
#
# status.sh - ZooKeeper servers: up and serving, leader and followers in
# sync, latency, outstanding requests, znodes and watches, fsync and JVM
# pauses
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
# Reports each ZooKeeper server in ZOOKEEPER_SERVERS (default
# localhost:2181), each tagged server=<host:port>: whether it answers, and
# whether it serves (a server cut off from its quorum answers, and serves
# nothing); its version and role (leader, follower, observer, standalone);
# read-only mode; latency; connections and requests waiting; znodes,
# watches, ephemeral nodes and the data they hold; file descriptors; the
# longest fsync and JVM pause; elections, failed logins, requests
# throttled and errors; and on the leader, its followers and how many are
# in sync. Then the ensemble as this machine sees it: servers up, serving,
# and how many are leader (one, and only one, when all is well). Name
# every server of an ensemble on one machine, or each its own on each.
#
# Reads ZooKeeper's four-letter words on its client port: ruok, mntr and
# isro, each over a connection of its own, with bash alone (/dev/tcp).
# ZooKeeper answers only the words in its whitelist, which since 3.5.3 is
# srvr alone: the servers need 4lw.commands.whitelist=mntr,ruok,isro (or
# *) in zoo.cfg. The words are plain text on the client port: a port that
# takes TLS alone (secureClientPort) cannot be read this way.
#
# Metrics:
#   servers                    servers named in ZOOKEEPER_SERVERS
#   servers_up                 of those, answering
#   servers_serving            of those, serving requests
#   leaders                    of those, leader: 1 for an ensemble
#                              (standalone servers are not counted)
#   up                         1 when the server answers ruok, else 0
#   serving                    1 when it serves requests (it answered
#                              mntr), else 0: it has no quorum
#   info                       always 1, tagged version=<3.9.7>
#                              role=<leader, follower, observer,
#                              standalone, readonly>
#   readonly                   1 in read-only mode (cut off from its
#                              quorum, with readonlymode.enabled): it
#                              serves reads, and refuses writes
#   uptime_seconds             since it started
#   latency_avg_ms             time to answer a request, on average
#   latency_max_ms             the longest (since it started, or since
#                              srst)
#   connections                clients connected
#   outstanding_requests       requests waiting to be processed
#   znodes                     znodes in its tree
#   watches                    watches set by clients
#   ephemerals                 ephemeral znodes (each held by a session)
#   data_bytes                 the data its znodes hold, approximately
#   fds_open                   file descriptors open
#   fds_pct                    fds_open, of the most it may open
#   fsync_max_ms               the longest write to its transaction log
#                              took (since it started)
#   jvm_pause_max_ms           the longest the JVM stopped it (garbage
#                              collection, since it started)
#   packets_received_count     packets received (a running total)
#   packets_sent_count         packets sent (a running total)
#   elections_count            times it looked for a leader (a running
#                              total)
#   auth_failed_count          logins refused (a running total)
#   throttled_count            requests throttled (a running total)
#   errors_count               errors it could not recover from (a
#                              running total)
#   quorum_size                servers of the ensemble that vote
#   followers                  on the leader: followers and observers
#                              connected
#   followers_synced           on the leader: followers in sync
#   pending_syncs              on the leader: followers still syncing
#
# Example output (the rest are in the same form):
#   metric servers 3
#   metric servers_serving 3
#   metric leaders 1
#   metric up 1 server=zk1:2181
#   metric info 1 server=zk1:2181 version=3.9.7 role=leader
#   metric latency_avg_ms 0.4 server=zk1:2181
#   metric followers_synced 2 server=zk1:2181
#
# Reading the results (starting points: tune them to the ensemble):
#   Healthy  servers_serving equal to servers; leaders 1; on the leader,
#            followers_synced the quorum less one; latency_avg_ms below 10;
#            outstanding_requests near 0; fds_pct below 50.
#   Watch    latency_avg_ms past 50; outstanding_requests above 10 for
#            several runs; fsync_max_ms past 1000 (a slow disk: sessions
#            time out); jvm_pause_max_ms past 1000; elections_count rising;
#            watches or znodes growing without end; fds_pct past 70.
#   Act      up 0; serving 0 (no quorum: clients of this server get
#            nothing); leaders 0 or above 1; readonly 1 (writes refused);
#            followers_synced below a majority; auth_failed_count rising.
#
# Requires: bash
# Exit code: 0 on success, servers up or down; 1 when a server refuses a
#   four-letter word (not in its whitelist), or ZOOKEEPER_SERVERS is wrong
#
# Example (vigil.config):
#   [job.zookeeper_status]
#   file        = packs/zookeeper/status.sh
#   metric_name = zookeeper
#   run_every   = 1m
#   env         = ZOOKEEPER_SERVERS=zk1:2181; zk2:2181; zk3:2181

set -u

list=$(printf '%s' "${ZOOKEEPER_SERVERS-}" | tr ';,' '  ')
[ -n "${list// /}" ] || list=localhost:2181
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-zookeeper.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# word <host> <port> <word>: its answer in $work/answer; 1 when nothing
# answers within 5 seconds.
word() {
    rm -f "$work/answer"
    (exec 3<> "/dev/tcp/$1/$2" && printf '%s' "$3" >&3 && cat <&3 > "$work/answer") 2> /dev/null &
    local pid=$! i=0
    while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill "$pid" 2> /dev/null && return 1
    wait "$pid" && [ -f "$work/answer" ]
}
refused() { grep -q 'is not executed because it is not in the whitelist' "$work/answer"; }

n=0 up_n=0 serving_n=0 leaders=0 failed=''
for s in $list; do
    case $s in
        \[*\]:*) host=${s%]:*} host=${host#[} port=${s##*]:} ;;
        *:*:*) host=$s port=2181 ;;
        *:*) host=${s%:*} port=${s##*:} ;;
        *) host=$s port=2181 ;;
    esac
    case $port in '' | *[!0-9]*) echo "status: ZOOKEEPER_SERVERS: '$s' is not host or host:port" >&2; exit 1 ;; esac
    n=$((n + 1))
    t="server=$host:$port"
    if ! word "$host" "$port" ruok; then
        echo "metric up 0 $t"
        echo "metric serving 0 $t"
        continue
    fi
    no=''
    if refused; then
        no=ruok
    elif [ "$(cat "$work/answer")" != imok ]; then
        echo "metric up 0 $t"
        echo "metric serving 0 $t"
        continue
    fi
    up_n=$((up_n + 1))
    echo "metric up 1 $t"
    if ! word "$host" "$port" mntr; then
        echo "metric serving 0 $t"
        [ -z "$no" ] || failed="$failed${failed:+; }$host:$port refuses $no"
        continue
    fi
    if refused; then
        echo "metric serving 0 $t"
        failed="$failed${failed:+; }$host:$port refuses ${no:+$no, }mntr"
        continue
    fi
    [ -z "$no" ] || failed="$failed${failed:+; }$host:$port refuses $no"
    if ! grep -q '^zk_server_state' "$work/answer"; then
        # "This ZooKeeper instance is not currently serving requests"
        echo "metric serving 0 $t"
        continue
    fi
    serving_n=$((serving_n + 1))
    echo "metric serving 1 $t"
    cp "$work/answer" "$work/mntr"
    ro=''
    if word "$host" "$port" isro && ! refused; then ro=$(tr -d '\r\n' < "$work/answer"); fi
    grep -q '^zk_server_state[[:space:]]leader' "$work/mntr" && leaders=$((leaders + 1))
    awk -F '\t' -v t="$t" -v ro="$ro" '
        { v[$1] = $2 }
        function num(x) { return (x ~ /^-?[0-9.]+$/) ? x + 0 : 0 }
        function out(name, key, scale) {
            if (key in v) printf "metric %s %s %s\n", name, r2(num(v[key]) / scale), t
        }
        function r2(x) { x = int(x * 100 + (x < 0 ? -0.5 : 0.5)) / 100; return x }
        END {
            ver = v["zk_version"]; sub(/[-, ].*/, "", ver); gsub(/[^A-Za-z0-9._-]/, "_", ver)
            role = v["zk_server_state"]; gsub(/[^A-Za-z]/, "", role)
            printf "metric info 1 %s version=%s role=%s\n", t, (ver == "" ? "unknown" : ver), (role == "" ? "unknown" : role)
            if (ro == "ro") printf "metric readonly 1 %s\n", t
            else if (ro == "rw") printf "metric readonly 0 %s\n", t
            out("uptime_seconds", "zk_uptime", 1000)
            out("latency_avg_ms", "zk_avg_latency", 1)
            out("latency_max_ms", "zk_max_latency", 1)
            out("connections", "zk_num_alive_connections", 1)
            out("outstanding_requests", "zk_outstanding_requests", 1)
            out("znodes", "zk_znode_count", 1)
            out("watches", "zk_watch_count", 1)
            out("ephemerals", "zk_ephemerals_count", 1)
            out("data_bytes", "zk_approximate_data_size", 1)
            out("fds_open", "zk_open_file_descriptor_count", 1)
            if (num(v["zk_max_file_descriptor_count"]) > 0)
                printf "metric fds_pct %s %s\n", r2(100 * num(v["zk_open_file_descriptor_count"]) / num(v["zk_max_file_descriptor_count"])), t
            out("fsync_max_ms", "zk_max_fsynctime", 1)
            out("jvm_pause_max_ms", "zk_max_jvm_pause_time_ms", 1)
            out("packets_received_count", "zk_packets_received", 1)
            out("packets_sent_count", "zk_packets_sent", 1)
            out("elections_count", "zk_looking_count", 1)
            out("auth_failed_count", "zk_auth_failed_count", 1)
            out("throttled_count", "zk_throttled_ops", 1)
            out("errors_count", "zk_unrecoverable_error_count", 1)
            out("quorum_size", "zk_quorum_size", 1)
            if (role == "leader") {
                out("followers", "zk_learners", 1)
                out("followers_synced", "zk_synced_followers", 1)
                out("pending_syncs", "zk_pending_syncs", 1)
            }
        }' "$work/mntr"
done
echo "metric servers $n"
echo "metric servers_up $up_n"
echo "metric servers_serving $serving_n"
echo "metric leaders $leaders"
if [ -n "$failed" ]; then
    echo "status: $failed: add the words to its whitelist in zoo.cfg, 4lw.commands.whitelist=mntr,ruok,isro, and restart it (packs/zookeeper/README.md)" >&2
    exit 1
fi
exit 0
