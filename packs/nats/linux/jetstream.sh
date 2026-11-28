#!/usr/bin/env bash
#
# jetstream.sh - a NATS server's JetStream: storage, the meta leader, streams and consumers
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
# Reports whether JetStream is on, its memory and file storage against the
# limits it was given, its streams, consumers, messages and bytes on this
# server, its API calls and errors; in a cluster, the meta leader, whether it
# is known and whether it is this server, and, on the leader, the servers
# behind. Then, for the streams and consumers this server leads: the replicas
# behind, each named; each stream's messages and bytes, and how full it is
# against its own limits (max_bytes, max_msgs); the messages consumers have
# not been given, those given and not acked, and those redelivered, each
# consumer named. And the streams with no leader, which take no writes. Only a
# stream's leader reports it, so a cluster's streams are counted once: sum
# them by stream in the backend. It only reads: every request is a GET, and it
# changes nothing.
#
# Reads NATS_URL (default http://localhost:8222), its monitoring port: /varz
# and /jsz?accounts=true&streams=true&consumers=true&config=true.
# What the scripts share is in _nats.sh, beside this one.
#
# Metrics:
#   up                              1 when the server answered, else 0 (and
#                                   nothing more is read)
#   jetstream                       1 when JetStream is on; 0 (and nothing
#                                   more) when it is off
#   memory_bytes                    memory its streams use
#   storage_bytes                   file storage its streams use
#   max_memory_bytes                the memory it may use (max_memory_store)
#   max_storage_bytes               the file storage it may use
#                                   (max_file_store)
#   memory_pct                      memory_bytes, of max_memory_bytes
#   storage_pct                     storage_bytes, of max_storage_bytes
#   streams                         streams on this server, replicas included
#   consumers                       consumers on this server, replicas
#                                   included
#   messages                        messages in them
#   bytes                           bytes in them
#   api_count                       JetStream API calls (a running total)
#   api_errors_count                of them, errors: a stream full, a stream
#                                   or consumer not found, no leader (a
#                                   running total)
#   meta_cluster_size               servers in the JetStream cluster
#   meta_leader_known               1 when it knows the meta leader; 0: no
#                                   leader, so no stream or consumer can be
#                                   made or changed
#   meta_is_leader                  1 on the meta leader
#   meta_replicas_behind            on the meta leader: servers not current
#                                   with it
#   streams_led                     streams this server leads: the rest below
#                                   are theirs
#   streams_no_leader               streams it holds a replica of that have no
#                                   leader: they take no writes
#   stream_replicas_behind          replicas of its streams not current with
#                                   it
#   stream_behind                   always 1, one line for each, tagged
#                                   stream= and replica=<the server>
#   stream_behind_not_shown         how many more there were than the 20 shown
#   stream_messages                 messages in a stream, tagged stream= (the
#                                   20 largest)
#   stream_bytes                    bytes in a stream, tagged stream=
#   stream_not_shown                streams past the 20 shown
#   stream_used_pct                 how full a stream with limits is, of
#                                   max_bytes or max_msgs, whichever is
#                                   fuller, tagged stream=
#   stream_used_pct_not_shown       how many more there were than the 20 shown
#   consumers_led                   consumers this server leads
#   consumers_pending               messages their consumers have not been
#                                   given yet, all together
#   consumers_ack_pending           messages given and not acked yet, all
#                                   together
#   consumers_redelivered           messages given more than once, all
#                                   together
#   consumer_pending                one consumer's messages not given yet,
#                                   tagged stream= and consumer= (the 20
#                                   furthest behind)
#   consumer_pending_not_shown      how many more there were than the 20 shown
#   consumer_ack_pending            one consumer's messages given and not
#                                   acked
#   consumer_ack_pending_not_shown  how many more there were than the 20 shown
#   consumer_redelivered            one consumer's messages given more than
#                                   once
#   consumer_redelivered_not_shown  how many more there were than the 20 shown
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  jetstream 1; storage_pct and memory_pct below 75;
#            meta_leader_known 1; streams_no_leader 0; stream_replicas_behind
#            0; consumer_pending steady or falling.
#   Watch    storage_pct or memory_pct above 75; a stream_used_pct above 90
#            (at its limit it drops its oldest messages, or refuses new ones);
#            consumer_pending growing run after run: that consumer is falling
#            behind; consumer_redelivered growing: its messages are not being
#            acked in time.
#   Act      meta_leader_known 0 or streams_no_leader above 0: the cluster has
#            lost its majority, and those streams take no writes;
#            stream_replicas_behind above 0 for long: a server is down or
#            cannot keep up (stream_behind says which); storage_pct near 100:
#            publishes to its streams fail; api_errors_count moving fast.
#
# Requires: bash, curl, jq
# Exit code: 0, whatever it reads, and when NATS does not answer (up 0 is the
#   reading); 1 when it answers wrong (not HTTP, a page missing), said on
#   stderr, or curl or jq is missing

set -u

job=jetstream
# shellcheck source=/dev/null
. "$(dirname "$0")/_nats.sh"
needs curl jq

get '/varz' varz
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/varz: no such page (HTTP 404): is NATS_URL its monitoring port (-m 8222)?" >&2; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
me=$(jq -r '.server_name' "$work/varz")
get '/jsz?accounts=true&streams=true&consumers=true&config=true' jsz || { echo "$job: $url/jsz did not answer" >&2; exit 1; }
jq -r --arg me "$me" 'def t: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def ts: .[0:19] + "Z" | fromdateiso8601;
def pct(a; b): if b > 0 then (a * 10000 / b | round) / 100 else 0 end;
def ms: [scan("([0-9.]+)(h|ms|m|s|µs|us|ns)")]
    | map((.[0] | tonumber) * ({"h": 3600000, "m": 60000, "s": 1000, "ms": 1, "µs": 0.001, "us": 0.001, "ns": 0.000001}[.[1]]))
    | (add // 0) * 1000 | round / 1000;

def leader: if (.cluster.raft_group // "") != "" then (.cluster.leader // "") else $me end;
def top(f): sort_by(-(f)) | .[0:20];
if .disabled == true or (.config // null) == null then "metric jetstream 0" else
    "metric jetstream 1",
    "metric memory_bytes \(.memory)",
    "metric storage_bytes \(.storage)",
    "metric max_memory_bytes \(.config.max_memory)",
    "metric max_storage_bytes \(.config.max_storage)",
    "metric memory_pct \(pct(.memory; .config.max_memory))",
    "metric storage_pct \(pct(.storage; .config.max_storage))",
    "metric streams \(.streams)",
    "metric consumers \(.consumers)",
    "metric messages \(.messages)",
    "metric bytes \(.bytes)",
    "metric api_count \(.api.total)",
    "metric api_errors_count \(.api.errors)",
    (.meta_cluster // empty |
        "metric meta_cluster_size \(.cluster_size)",
        "metric meta_leader_known \(if (.leader // "") != "" then 1 else 0 end)",
        "metric meta_is_leader \(if .leader == $me then 1 else 0 end)",
        (if .leader == $me then "metric meta_replicas_behind \([(.replicas // [])[] | select(.current != true)] | length)" else empty end)),
    ([(.account_details // [])[] | (.stream_detail // [])[]] as $all |
     [$all[] | select(leader == $me)] as $led |
     [$led[] | .name as $s | (.cluster.replicas // [])[] | select(.current != true) | {s: $s, r: .name}] as $behind |
     [$all[] | (.consumer_detail // [])[] | select(leader == $me)] as $cons |
     [$led[] | select(((.config.max_bytes // -1) > 0) or ((.config.max_msgs // -1) > 0)) |
        {s: .name, p: ([pct(.state.bytes; .config.max_bytes // -1), pct(.state.messages; .config.max_msgs // -1)] | max)}] as $lim |
        "metric streams_led \($led | length)",
        "metric streams_no_leader \([$all[] | select(leader == "")] | length)",
        "metric stream_replicas_behind \($behind | length)",
        ($behind[0:20][] | "metric stream_behind 1 stream=\(.s | t) replica=\(.r | t)"),
        "metric stream_behind_not_shown \([($behind | length) - 20, 0] | max)",
        ($led | top(.state.bytes)[] | "metric stream_messages \(.state.messages) stream=\(.name | t)", "metric stream_bytes \(.state.bytes) stream=\(.name | t)"),
        "metric stream_not_shown \([($led | length) - 20, 0] | max)",
        ($lim | top(.p)[] | "metric stream_used_pct \(.p) stream=\(.s | t)"),
        "metric stream_used_pct_not_shown \([($lim | length) - 20, 0] | max)",
        "metric consumers_led \($cons | length)",
        "metric consumers_pending \([$cons[] | .num_pending] | add // 0)",
        "metric consumers_ack_pending \([$cons[] | .num_ack_pending] | add // 0)",
        "metric consumers_redelivered \([$cons[] | .num_redelivered] | add // 0)",
        ([$cons[] | select(.num_pending > 0)] | top(.num_pending)[] | "metric consumer_pending \(.num_pending) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_pending_not_shown \([([$cons[] | select(.num_pending > 0)] | length) - 20, 0] | max)",
        ([$cons[] | select(.num_ack_pending > 0)] | top(.num_ack_pending)[] | "metric consumer_ack_pending \(.num_ack_pending) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_ack_pending_not_shown \([([$cons[] | select(.num_ack_pending > 0)] | length) - 20, 0] | max)",
        ([$cons[] | select(.num_redelivered > 0)] | top(.num_redelivered)[] | "metric consumer_redelivered \(.num_redelivered) stream=\(.stream_name | t) consumer=\(.name | t)"),
        "metric consumer_redelivered_not_shown \([([$cons[] | select(.num_redelivered > 0)] | length) - 20, 0] | max)")
end' "$work/jsz"
exit 0
