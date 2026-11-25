#!/usr/bin/env bash
#
# status.sh - Podman: up, its version, and its containers by state
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
# Whether Podman answers, and what it holds: containers running, paused,
# stopped, those whose health check fails, those that ended with an error, and
# its images.
#
# Asks Podman with its own command, as the account the job runs as, and reads
# the answers with jq. It only reads (info, ps, inspect, stats, system df,
# images): nothing is started, stopped, removed or pruned.
#
# Metrics:
#   up                     1 when Podman answers, else 0 (and nothing more is
#                          read)
#   version                always 1, tagged version=<Podman's version>,
#                          os=<linux> and rootless=<true or false>
#   rootless               1 when these are an account's own containers
#                          (rootless), 0 when they are root's
#   containers             containers it holds, running or not
#   running                of those, running
#   paused                 paused
#   exited                 stopped: they ran, and ended
#   created                created, and never started
#   unhealthy              running, with a health check that fails
#   health_starting        running, with a health check that has not passed
#                          yet
#   exited_nonzero         stopped with an exit code other than 0
#   restarts_total_count   times a restart policy started a container again,
#                          over all of them (a running total): under Podman a
#                          container in a loop reads as running, and this is
#                          what rises
#   pods                   pods these containers are in
#   images                 images it holds
#   cpus                   processors Podman sees
#   memory_bytes           memory Podman sees
#
# Example output:
#   metric up 1
#   metric version 1 version=5.8.9 os=linux rootless=true
#   metric rootless 1
#   metric containers 11
#   metric running 6
#   metric paused 1
#   metric exited 3
#   metric created 1
#   metric unhealthy 1
#   metric health_starting 0
#   metric exited_nonzero 2
#   metric restarts_total_count 11
#   metric pods 0
#   metric images 2
#   metric cpus 4
#   metric memory_bytes 8188477440
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  up 1; unhealthy 0; restarts_total_count flat; exited_nonzero
#            steady (a job that failed once stays counted until its container
#            is removed).
#   Watch    health_starting above 0 for minutes: a health check that never
#            passes. running lower than it was: something stopped and nothing
#            started it again.
#   Act      up 0: Podman cannot be asked (on a Mac, its machine is stopped).
#            unhealthy above 0. restarts_total_count rising: a container in a
#            restart loop, which Podman shows as running (podman_containers
#            names it).
#
# Requires: bash, podman and jq
# Exit code: 0 on success, Podman answering or not; 1 if podman or jq is
#   missing, or Podman answers with an error

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_podman.sh"
needs podman jq

engine
ask list ps -a --format json || exit 1
jq -r -s "$defs"'
    .[0] as $i | (.[1] // []) as $c |
    def count(f): [$c[] | select(f)] | length;
    "metric version 1 version=\(($i.version.Version // "none") | safe) os=\(($i.host.os // "none") | safe) rootless=\(($i.host.security.rootless // false) | tostring)",
    "metric rootless \(if $i.host.security.rootless == true then 1 else 0 end)",
    "metric containers \($c | length)",
    "metric running \(count(.State == "running"))",
    "metric paused \(count(.State == "paused"))",
    "metric exited \(count(.State == "exited" or .State == "stopped"))",
    "metric created \(count(.State == "created" or .State == "configured"))",
    "metric unhealthy \(count((.Status // "") | test("\\(unhealthy\\)")))",
    "metric health_starting \(count((.Status // "") | test("\\(starting\\)")))",
    "metric exited_nonzero \(count((.State == "exited" or .State == "stopped") and (.ExitCode // 0) != 0))",
    "metric restarts_total_count \([$c[] | .Restarts // 0] | add // 0)",
    "metric pods \([$c[] | select((.Pod // "") != "") | .Pod] | unique | length)",
    "metric images \($i.store.imageStore.number // 0)",
    "metric cpus \($i.host.cpus // 0)",
    "metric memory_bytes \($i.host.memTotal // 0)"
' "$work/info" "$work/list" || exit 1
exit 0
