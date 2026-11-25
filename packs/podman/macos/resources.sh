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
# Each running container by name (the first 100; PODMAN_MOST sets another
# number): the CPU time it has used, its memory and how near its limit that
# is, its processes, and what it has sent, received, read and written.
#
# Asks Podman with its own command, as the account the job runs as, and reads
# the answers with jq. It only reads (info, ps, inspect, stats, system df,
# images): nothing is started, stopped, removed or pruned.
#
# Metrics:
#   up                        1 when Podman answers, else 0 (and nothing more
#                             is read)
#   containers_measured       running containers measured
#   memory_total_bytes        memory they use, together
#   memory_fullest_pct        the fullest of those with a memory limit: its
#                             memory, as a share of its limit
#   cpu_seconds_count         CPU time it has used since it started, in
#                             seconds (a running total: its rate is the
#                             processors it uses), tagged name=<the
#                             container's name>
#   memory_bytes              memory it uses, without the file cache that can
#                             be given back, tagged name=<the container's
#                             name>
#   memory_limit_bytes        its memory limit, 0 when it has none, tagged
#                             name=<the container's name>
#   memory_pct                for one with a limit: its memory, as a share of
#                             it, tagged name=<the container's name>
#   pids                      processes and threads in it, tagged name=<the
#                             container's name>
#   network_rx_bytes_count    bytes it received, over its networks (a running
#                             total), tagged name=<the container's name>
#   network_tx_bytes_count    bytes it sent (a running total), tagged
#                             name=<the container's name>
#   block_read_bytes_count    bytes it read from disk (a running total),
#                             tagged name=<the container's name>
#   block_write_bytes_count   bytes it wrote to disk (a running total), tagged
#                             name=<the container's name>
#   containers_not_shown      past the first 100 by name (PODMAN_MOST), how
#                             many were not measured
#
# Example output:
#   metric up 1
#   metric containers_measured 6
#   metric memory_total_bytes 2564096
#   metric memory_fullest_pct 0.873
#   metric cpu_seconds_count 4.139 name=vigilit_busy
#   metric memory_bytes 356352 name=vigilit_busy
#   metric memory_limit_bytes 0 name=vigilit_busy
#   metric pids 1 name=vigilit_busy
#   metric network_rx_bytes_count 258 name=vigilit_busy
#   metric network_tx_bytes_count 612 name=vigilit_busy
#   metric block_read_bytes_count 0 name=vigilit_busy
#   metric block_write_bytes_count 0 name=vigilit_busy
#   metric cpu_seconds_count 0.009 name=vigilit_loop
#   metric memory_bytes 548864 name=vigilit_loop
#   metric memory_limit_bytes 0 name=vigilit_loop
#   metric pids 2 name=vigilit_loop
#   metric network_rx_bytes_count 258 name=vigilit_loop
#   metric network_tx_bytes_count 112 name=vigilit_loop
#   metric block_read_bytes_count 0 name=vigilit_loop
#   metric block_write_bytes_count 0 name=vigilit_loop
#   metric cpu_seconds_count 0.085 name=vigilit_ok
#   metric memory_bytes 585728 name=vigilit_ok
#   metric memory_limit_bytes 67108864 name=vigilit_ok
#   metric memory_pct 0.873 name=vigilit_ok
#   metric pids 2 name=vigilit_ok
#   metric network_rx_bytes_count 258 name=vigilit_ok
#   metric network_tx_bytes_count 612 name=vigilit_ok
#   metric block_read_bytes_count 0 name=vigilit_ok
#   metric block_write_bytes_count 1146880 name=vigilit_ok
#   metric cpu_seconds_count 0.046 name=vigilit_unhealthy
#   metric memory_bytes 339968 name=vigilit_unhealthy
#   metric memory_limit_bytes 0 name=vigilit_unhealthy
#   metric pids 1 name=vigilit_unhealthy
#   metric network_rx_bytes_count 258 name=vigilit_unhealthy
#   metric network_tx_bytes_count 612 name=vigilit_unhealthy
#   metric block_read_bytes_count 0 name=vigilit_unhealthy
#   metric block_write_bytes_count 0 name=vigilit_unhealthy
#   metric cpu_seconds_count 0.038 name=vigilit_writes
#   metric memory_bytes 393216 name=vigilit_writes
#   metric memory_limit_bytes 0 name=vigilit_writes
#   metric pids 1 name=vigilit_writes
#   metric network_rx_bytes_count 258 name=vigilit_writes
#   metric network_tx_bytes_count 612 name=vigilit_writes
#   metric block_read_bytes_count 0 name=vigilit_writes
#   metric block_write_bytes_count 0 name=vigilit_writes
#   metric containers_not_shown 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  memory_pct well under 100; memory_bytes steady for a container
#            doing steady work.
#   Watch    memory_bytes climbing run after run with no more work to do: a
#            leak, on its way to the limit. pids climbing: processes or
#            threads that are never reaped.
#   Act      memory_fullest_pct above 90: a container about to be killed for
#            memory (memory_pct says which). pids near the limit of the
#            machine.
#
# Requires: bash, podman and jq
# Exit code: 0 on success, Podman answering or not; 1 if podman or jq is
#   missing, or Podman answers with an error

set -u

job=resources
# shellcheck source=/dev/null
. "$(dirname "$0")/_podman.sh"
needs podman jq

engine
# One JSON object a line, with the numbers as Podman holds them (the json
# format of podman stats prints them for people: "585.7kB / 67.11MB").
ask stats stats --no-stream --format '{{json .}}' || exit 1
jq -r -s --argjson most "$most" "$defs"'
    .[0] as $i | (.[1:] | map(select(type == "object")) | sort_by(.Name)) as $all | $all[0:$most] as $s |
    # A limit of its own: where there is none, Podman reports the memory of the machine.
    def limit: (.MemLimit // 0) as $l | if $l == 0 or $l >= ($i.host.memTotal // 0) then 0 else $l end;
    def pct: limit as $l | if $l > 0 then ((.MemUsage // 0) * 100 / $l) else null end;
    def rx: [(.Network // {})[] | .RxBytes // 0] | add // 0;
    def tx: [(.Network // {})[] | .TxBytes // 0] | add // 0;
    "metric containers_measured \($s | length)",
    "metric memory_total_bytes \([$all[] | .MemUsage // 0] | add // 0)",
    "metric memory_fullest_pct \([$all[] | pct | select(. != null)] | max // 0 | num)",
    ($s[] | ((.Name // .ContainerID // "none") | safe) as $n |
        "metric cpu_seconds_count \(((.CPUNano // 0) / 1000000000) | num) name=\($n)",
        "metric memory_bytes \(.MemUsage // 0) name=\($n)",
        "metric memory_limit_bytes \(limit) name=\($n)",
        (pct | select(. != null) | "metric memory_pct \(num) name=\($n)"),
        "metric pids \(.PIDs // 0) name=\($n)",
        "metric network_rx_bytes_count \(rx) name=\($n)",
        "metric network_tx_bytes_count \(tx) name=\($n)",
        "metric block_read_bytes_count \(.BlockInput // 0) name=\($n)",
        "metric block_write_bytes_count \(.BlockOutput // 0) name=\($n)"),
    "metric containers_not_shown \([($all | length) - $most, 0] | max)"
' "$work/info" "$work/stats" || exit 1
exit 0
