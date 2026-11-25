#!/usr/bin/env bash
#
# status.sh - the engine: up, its version, and its containers by state
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
# Whether the engine answers, and what it holds: containers running, paused,
# stopped, restarting, those whose health check fails, those that ended with
# an error, and its images.
#
# Reads the Docker engine's API at DOCKER_HOST (unix:///var/run/docker.sock by
# default) with curl and jq. Every request is a GET: nothing is started,
# stopped, removed or pruned.
#
# Metrics:
#   up                1 when the engine answers, else 0 (and nothing more is
#                     read)
#   version           always 1, tagged version=<the engine's version>,
#                     api=<its API's version> and os=<linux or windows: the
#                     containers it runs>
#   containers        containers it holds, running or not
#   running           of those, running
#   paused            paused
#   restarting        between two starts: the container stopped, and its
#                     restart policy is starting it again. One that stays here
#                     is in a loop
#   exited            stopped: they ran, and ended
#   created           created, and never started
#   dead              that the engine could not remove
#   unhealthy         running, with a health check that fails
#   health_starting   running, with a health check that has not passed yet
#   exited_nonzero    stopped with an exit code other than 0
#   images            images it holds
#   cpus              processors the engine sees
#   memory_bytes      memory the engine sees
#   warnings          what the engine warns about itself (docker info prints
#                     them)
#
# Example output:
#   metric up 1
#   metric version 1 version=29.9.3 api=1.56 os=linux
#   metric containers 16
#   metric running 11
#   metric paused 1
#   metric restarting 0
#   metric exited 3
#   metric created 1
#   metric dead 0
#   metric unhealthy 1
#   metric health_starting 0
#   metric exited_nonzero 2
#   metric images 18
#   metric cpus 4
#   metric memory_bytes 8188477440
#   metric warnings 0
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  up 1; unhealthy 0; restarting 0; exited_nonzero steady (a job
#            that failed once stays counted until its container is removed).
#   Watch    health_starting above 0 for minutes: a health check that never
#            passes. running lower than it was: something stopped and nothing
#            started it again.
#   Act      up 0: the engine is down, and so is every container without live
#            restore. unhealthy above 0. restarting above 0 on two runs in a
#            row: a container in a restart loop (docker_containers names it,
#            by restarts_count rising).
#
# Requires: bash, curl 7.40 or later, and jq
# Exit code: 0 on success, the engine up or down; 1 if curl or jq is missing,
#   DOCKER_HOST is wrong, this account may not use the engine, or what answers
#   is not a Docker engine

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_docker.sh"
needs curl jq

engine
get /info info || exit 1
get '/containers/json?all=1' list || exit 1
jq -r -s "$defs"'
    .[0] as $v | .[1] as $i | .[2] as $c |
    def count(f): [$c[] | select(f)] | length;
    "metric version 1 version=\($v.Version | safe) api=\($v.ApiVersion | safe) os=\(($i.OSType // $v.Os // "none") | safe)",
    "metric containers \($c | length)",
    "metric running \(count(.State == "running"))",
    "metric paused \(count(.State == "paused"))",
    "metric restarting \(count(.State == "restarting"))",
    "metric exited \(count(.State == "exited"))",
    "metric created \(count(.State == "created"))",
    "metric dead \(count(.State == "dead"))",
    "metric unhealthy \(count((.Status // "") | test("\\(unhealthy\\)")))",
    "metric health_starting \(count((.Status // "") | test("\\(health: starting\\)")))",
    "metric exited_nonzero \(count(.State == "exited" and ((.Status // "") | test("^Exited \\([1-9-]"))))",
    "metric images \($i.Images // 0)",
    "metric cpus \($i.NCPU // 0)",
    "metric memory_bytes \($i.MemTotal // 0)",
    "metric warnings \(($i.Warnings // []) | length)"
' "$work/version" "$work/info" "$work/list" || exit 1
exit 0
