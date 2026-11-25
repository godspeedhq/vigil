#!/usr/bin/env bash
#
# resources.sh - each running container: CPU, memory against its limit, processes, network and disk
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
# Each running container by name (the first 100; DOCKER_MOST sets another
# number): the CPU time it has used, its memory and how near its limit that
# is, its processes, and what it has sent, received, read and written.
#
# Reads the Docker engine's API at DOCKER_HOST (unix:///var/run/docker.sock by
# default) with curl and jq. Every request is a GET: nothing is started,
# stopped, removed or pruned.
#
# Metrics:
#   up                            1 when the engine answers, else 0 (and
#                                 nothing more is read)
#   containers_measured           running containers measured
#   memory_total_bytes            memory they use, together
#   memory_fullest_pct            the fullest of those with a memory limit:
#                                 its memory, as a share of its limit
#   cpu_throttled_containers      containers held back at their CPU limit at
#                                 least once since they started
#   cpu_seconds_count             CPU time it has used since it started, in
#                                 seconds (a running total: its rate is the
#                                 processors it uses), tagged name=<the
#                                 container's name>
#   cpu_throttled_seconds_count   time it was held back at its CPU limit (a
#                                 running total), tagged name=<the container's
#                                 name>
#   memory_bytes                  memory it uses, without the file cache that
#                                 can be given back, tagged name=<the
#                                 container's name>
#   memory_limit_bytes            its memory limit, 0 when it has none, tagged
#                                 name=<the container's name>
#   memory_pct                    for one with a limit: its memory, as a share
#                                 of it, tagged name=<the container's name>
#   pids                          processes and threads in it, tagged
#                                 name=<the container's name>
#   network_rx_bytes_count        bytes it received, over its networks (a
#                                 running total), tagged name=<the container's
#                                 name>
#   network_tx_bytes_count        bytes it sent (a running total), tagged
#                                 name=<the container's name>
#   block_read_bytes_count        bytes it read from disk (a running total),
#                                 tagged name=<the container's name>
#   block_write_bytes_count       bytes it wrote to disk (a running total),
#                                 tagged name=<the container's name>
#   containers_not_shown          past the first 100 by name (DOCKER_MOST),
#                                 how many were not measured
#
# Example output:
#   metric up 1
#   metric containers_measured 11
#   metric memory_total_bytes 838373376
#   metric memory_fullest_pct 1.41
#   metric cpu_throttled_containers 1
#   metric cpu_seconds_count 4.112 name=vigilit_busy
#   metric cpu_throttled_seconds_count 9.003 name=vigilit_busy
#   metric memory_bytes 471040 name=vigilit_busy
#   metric memory_limit_bytes 0 name=vigilit_busy
#   metric pids 1 name=vigilit_busy
#   metric network_rx_bytes_count 3054 name=vigilit_busy
#   metric network_tx_bytes_count 126 name=vigilit_busy
#   metric block_read_bytes_count 0 name=vigilit_busy
#   metric block_write_bytes_count 0 name=vigilit_busy
#   metric cpu_seconds_count 0.142 name=vigilit_ok
#   metric cpu_throttled_seconds_count 0 name=vigilit_ok
#   metric memory_bytes 946176 name=vigilit_ok
#   metric memory_limit_bytes 67108864 name=vigilit_ok
#   metric memory_pct 1.41 name=vigilit_ok
#   metric pids 2 name=vigilit_ok
#   metric network_rx_bytes_count 4384 name=vigilit_ok
#   metric network_tx_bytes_count 126 name=vigilit_ok
#   metric block_read_bytes_count 0 name=vigilit_ok
#   metric block_write_bytes_count 811008 name=vigilit_ok
#   metric cpu_seconds_count 0.41 name=vigilit_unhealthy
#   metric cpu_throttled_seconds_count 0 name=vigilit_unhealthy
#   metric memory_bytes 495616 name=vigilit_unhealthy
#   metric memory_limit_bytes 0 name=vigilit_unhealthy
#   metric pids 1 name=vigilit_unhealthy
#   metric network_rx_bytes_count 3920 name=vigilit_unhealthy
#   metric network_tx_bytes_count 126 name=vigilit_unhealthy
#   metric block_read_bytes_count 0 name=vigilit_unhealthy
#   metric block_write_bytes_count 0 name=vigilit_unhealthy
#   metric cpu_seconds_count 0.066 name=vigilit_writes
#   metric cpu_throttled_seconds_count 0 name=vigilit_writes
#   metric memory_bytes 512000 name=vigilit_writes
#   metric memory_limit_bytes 0 name=vigilit_writes
#   metric pids 1 name=vigilit_writes
#   metric network_rx_bytes_count 2970 name=vigilit_writes
#   metric network_tx_bytes_count 126 name=vigilit_writes
#   metric block_read_bytes_count 0 name=vigilit_writes
#   metric block_write_bytes_count 655360 name=vigilit_writes
#   metric containers_not_shown 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  memory_pct well under 100; memory_bytes steady for a container
#            doing steady work; cpu_throttled_seconds_count flat.
#   Watch    memory_bytes climbing run after run with no more work to do: a
#            leak, on its way to the limit. cpu_throttled_seconds_count
#            rising: its CPU limit holds it back. pids climbing: processes or
#            threads that are never reaped.
#   Act      memory_fullest_pct above 90: a container about to be killed for
#            memory (memory_pct says which). pids near the limit of the
#            machine.
#
# Requires: bash, curl 7.40 or later, and jq
# Exit code: 0 on success, the engine up or down; 1 if curl or jq is missing,
#   DOCKER_HOST is wrong, this account may not use the engine, or what answers
#   is not a Docker engine

set -u

job=resources
# shellcheck source=/dev/null
. "$(dirname "$0")/_docker.sh"
needs curl jq

engine
get /info info || exit 1
get '/containers/json' list || exit 1
# A container between two starts has nothing to measure.
jq -r --argjson most "$most" 'map(select(.State != "restarting")) | sort_by((.Names // [])[0] // .Id) | .[0:$most][] | .Id' "$work/list" > "$work/ids" || exit 1
each "$work/ids" '/containers/%s/stats?stream=false&one-shot=true' stats || exit 1
jq -r -s --argjson most "$most" "$defs"'
    .[0] as $i | .[1] as $list |
    # The name the list gives each container: the statistics of some engines leave it out.
    ($list | map({key: .Id, value: cname}) | from_entries) as $names |
    (.[2] | map(select(has("cpu_stats")) | . + {name: ($names[.asked] // .name // .id // "none")}) | sort_by(.name)) as $s |
    (($i.OSType // "linux") == "windows") as $win |
    # Memory in use, as docker stats counts it: without the file cache that
    # can be given back (cgroup v2: inactive_file; v1: total_inactive_file).
    def mem: if $win then (.memory_stats.privateworkingset // 0)
        else ((.memory_stats.usage // 0) - (.memory_stats.stats.inactive_file // .memory_stats.stats.total_inactive_file // 0)) | if . < 0 then 0 else . end end;
    # A limit of its own: where there is none, the engine reports the memory of the machine.
    def limit: (.memory_stats.limit // 0) as $l | if $win or $l == 0 or $l >= ($i.MemTotal // 0) then 0 else $l end;
    def cpu: (.cpu_stats.cpu_usage.total_usage // 0) / (if $win then 10000000 else 1000000000 end);
    def rx: [(.networks // {})[] | .rx_bytes // 0] | add // 0;
    def tx: [(.networks // {})[] | .tx_bytes // 0] | add // 0;
    def blk(o): if $win then (if o == "read" then .storage_stats.read_size_bytes else .storage_stats.write_size_bytes end) // 0
        else [(.blkio_stats.io_service_bytes_recursive // [])[] | select((.op | ascii_downcase) == o) | .value] | add // 0 end;
    def pct: limit as $l | if $l > 0 then (mem * 100 / $l) else null end;
    "metric containers_measured \($s | length)",
    "metric memory_total_bytes \([$s[] | mem] | add // 0)",
    "metric memory_fullest_pct \([$s[] | pct | select(. != null)] | max // 0 | num)",
    "metric cpu_throttled_containers \([$s[] | select((.cpu_stats.throttling_data.throttled_periods // 0) > 0)] | length)",
    ($s[] | ((.name // .id // "none") | sub("^/"; "") | safe) as $n |
        "metric cpu_seconds_count \(cpu | num) name=\($n)",
        "metric cpu_throttled_seconds_count \(((.cpu_stats.throttling_data.throttled_time // 0) / 1000000000) | num) name=\($n)",
        "metric memory_bytes \(mem) name=\($n)",
        "metric memory_limit_bytes \(limit) name=\($n)",
        (pct | select(. != null) | "metric memory_pct \(num) name=\($n)"),
        "metric pids \(.pids_stats.current // .num_procs // 0) name=\($n)",
        "metric network_rx_bytes_count \(rx) name=\($n)",
        "metric network_tx_bytes_count \(tx) name=\($n)",
        "metric block_read_bytes_count \(blk("read")) name=\($n)",
        "metric block_write_bytes_count \(blk("write")) name=\($n)"),
    "metric containers_not_shown \([($list | length) - $most, 0] | max)"
' "$work/info" "$work/list" "$work/stats.all" || exit 1
exit 0
