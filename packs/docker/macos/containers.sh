#!/usr/bin/env bash
#
# containers.sh - each container: running or not, restarts, health, exit code, killed for memory
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
# Each container by name (the first 100; DOCKER_MOST sets another number):
# whether it runs, how many times its restart policy has started it again,
# whether its health check passes, the exit code of one that stopped, and
# whether the kernel killed it for memory.
#
# Reads the Docker engine's API at DOCKER_HOST (unix:///var/run/docker.sock by
# default) with curl and jq. Every request is a GET: nothing is started,
# stopped, removed or pruned.
#
# Metrics:
#   up                          1 when the engine answers, else 0 (and nothing
#                               more is read)
#   containers                  containers it holds, running or not
#   containers_restarting       of those named below, between two starts
#   containers_unhealthy        of those named below, with a health check that
#                               fails
#   containers_oom_killed       killed for memory: the kernel ended them at
#                               their limit
#   containers_exited_nonzero   stopped with an exit code other than 0
#   restarts_total_count        times a restart policy started them again (a
#                               running total, over those named below)
#   running                     1 when the container runs, 0 when it does not
#                               (stopped, paused, created, between two
#                               starts), tagged name=<the container's name>
#                               and state=<its state>
#   restarts_count              times its restart policy started it again (a
#                               running total), tagged name=<the container's
#                               name>
#   oom_killed                  1 when it was killed for memory, tagged
#                               name=<the container's name>
#   uptime_seconds              for one that runs: seconds since it last
#                               started, tagged name=<the container's name>
#   healthy                     for one with a health check that has run: 1
#                               healthy, 0 unhealthy, tagged name=<the
#                               container's name>
#   exit_code                   for one that stopped: its exit code, tagged
#                               name=<the container's name>
#   containers_not_shown        past the first 100 by name (DOCKER_MOST), how
#                               many were not named
#
# Example output:
#   metric up 1
#   metric containers 16
#   metric containers_restarting 1
#   metric containers_unhealthy 1
#   metric containers_oom_killed 1
#   metric containers_exited_nonzero 2
#   metric restarts_total_count 7
#   metric running 1 name=vigilit_busy state=running
#   metric restarts_count 0 name=vigilit_busy
#   metric oom_killed 0 name=vigilit_busy
#   metric uptime_seconds 13 name=vigilit_busy
#   metric running 0 name=vigilit_loop state=restarting
#   metric restarts_count 7 name=vigilit_loop
#   metric oom_killed 0 name=vigilit_loop
#   metric running 1 name=vigilit_ok state=running
#   metric restarts_count 0 name=vigilit_ok
#   metric oom_killed 0 name=vigilit_ok
#   metric uptime_seconds 18 name=vigilit_ok
#   metric running 0 name=vigilit_oom state=exited
#   metric restarts_count 0 name=vigilit_oom
#   metric oom_killed 1 name=vigilit_oom
#   metric exit_code 137 name=vigilit_oom
#   metric running 1 name=vigilit_unhealthy state=running
#   metric restarts_count 0 name=vigilit_unhealthy
#   metric oom_killed 0 name=vigilit_unhealthy
#   metric uptime_seconds 17 name=vigilit_unhealthy
#   metric healthy 0 name=vigilit_unhealthy
#   metric running 1 name=vigilit_writes state=running
#   metric restarts_count 0 name=vigilit_writes
#   metric oom_killed 0 name=vigilit_writes
#   metric uptime_seconds 12 name=vigilit_writes
#   metric containers_not_shown 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  running 1 for every container meant to run; restarts_count flat;
#            healthy 1; oom_killed 0.
#   Watch    restarts_count rising slowly: a container that falls over now and
#            then. uptime_seconds small on a container nobody restarted.
#   Act      running 0 on a container meant to run. restarts_count rising on
#            every run: a restart loop. healthy 0. oom_killed 1: it needs more
#            memory, or leaks it. exit_code other than 0 on a job that should
#            have succeeded (137: killed; 139: it crashed; 143: stopped by a
#            signal).
#
# Requires: bash, curl 7.40 or later, and jq
# Exit code: 0 on success, the engine up or down; 1 if curl or jq is missing,
#   DOCKER_HOST is wrong, this account may not use the engine, or what answers
#   is not a Docker engine

set -u

job=containers
# shellcheck source=/dev/null
. "$(dirname "$0")/_docker.sh"
needs curl jq

engine
get '/containers/json?all=1' list || exit 1
jq -r --argjson most "$most" 'sort_by((.Names // [])[0] // .Id) | .[0:$most][] | .Id' "$work/list" > "$work/ids" || exit 1
each "$work/ids" '/containers/%s/json' inspect || exit 1
jq -r -s --argjson now "$now" --argjson most "$most" "$defs"'
    .[0] as $list | (.[1] | sort_by(.Name)) as $c |
    def health: (.State.Health.Status // "none");
    def up: .State.Running == true and .State.Restarting != true and .State.Paused != true;
    "metric containers \($list | length)",
    "metric containers_restarting \([$c[] | select(.State.Restarting == true)] | length)",
    "metric containers_unhealthy \([$c[] | select(health == "unhealthy")] | length)",
    "metric containers_oom_killed \([$c[] | select(.State.OOMKilled == true)] | length)",
    "metric containers_exited_nonzero \([$c[] | select(.State.Status == "exited" and (.State.ExitCode // 0) != 0)] | length)",
    "metric restarts_total_count \([$c[] | .RestartCount // 0] | add // 0)",
    ($c[] | (cname | safe) as $n |
        "metric running \(if up then 1 else 0 end) name=\($n) state=\((.State.Status // "none") | safe)",
        "metric restarts_count \(.RestartCount // 0) name=\($n)",
        "metric oom_killed \(if .State.OOMKilled == true then 1 else 0 end) name=\($n)",
        (select(up) | "metric uptime_seconds \([$now - (.State.StartedAt | epoch), 0] | max) name=\($n)"),
        (select(health == "healthy" or health == "unhealthy") | "metric healthy \(if health == "healthy" then 1 else 0 end) name=\($n)"),
        (select(.State.Status == "exited" or .State.Status == "dead") | "metric exit_code \(.State.ExitCode // 0) name=\($n)")),
    "metric containers_not_shown \([($list | length) - $most, 0] | max)"
' "$work/list" "$work/inspect.all" || exit 1
exit 0
