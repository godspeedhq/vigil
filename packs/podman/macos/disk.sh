#!/usr/bin/env bash
#
# disk.sh - the disk Podman uses: images, containers, volumes, and what could be given back
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
# What Podman keeps on disk and how much of it is in use: images (unused ones,
# and those with no name left), what containers wrote in their own layers,
# volumes (and those no container uses). A full disk under Podman stops every
# container on the machine at once.
#
# How full the disk itself is, is the base pack's to say (its disk job): this
# job says what is on it.
#
# Asks Podman with its own command, as the account the job runs as, and reads
# the answers with jq. It only reads (info, ps, inspect, stats, system df,
# images): nothing is started, stopped, removed or pruned.
#
# Metrics:
#   up                             1 when Podman answers, else 0 (and nothing
#                                  more is read)
#   images                         images it holds
#   images_unused                  of those, used by no container
#   images_dangling                with no name left: an older build of a tag
#                                  that moved on
#   images_bytes                   disk the images take
#   images_reclaimable_bytes       of that, what removing the unused ones
#                                  would give back
#   containers                     containers it holds, running or not
#   containers_bytes               disk the containers take: what each wrote
#                                  in its own layer
#   containers_reclaimable_bytes   of that, held by containers that are not
#                                  running
#   container_bytes                what one container wrote in its own layer,
#                                  the 20 largest, tagged name=<the
#                                  container's name>
#   container_bytes_not_shown      past those 20, how many were left out
#   volumes                        volumes it holds
#   volumes_unused                 of those, used by no container
#   volumes_bytes                  disk the volumes take
#   volumes_reclaimable_bytes      of that, in volumes no container uses
#
# Example output:
#   metric up 1
#
# Reading the results (starting points: tune them to the machine):
#   Healthy  images_bytes and volumes_bytes steady; images_reclaimable_bytes a
#            small share.
#   Watch    images_dangling or images_reclaimable_bytes growing: builds and
#            pulls that nothing clears. container_bytes large and growing: a
#            container writing into its own layer what belongs in a volume (or
#            logs nobody rotates).
#   Act      any of them growing run after run while the base pack shows the
#            disk filling. volumes_unused with volumes_reclaimable_bytes
#            large: data left behind by containers that are gone, to keep or
#            to remove on purpose.
#
# Requires: bash, podman and jq
# Exit code: 0 on success, Podman answering or not; 1 if podman or jq is
#   missing, or Podman answers with an error

set -u

job=disk
# shellcheck source=/dev/null
. "$(dirname "$0")/_podman.sh"
needs podman jq

engine
ask df system df --format json || exit 1
ask images images --format json || exit 1
ask sizes ps -a --size --format json || exit 1
jq -r -s "$defs"'
    (.[0] // []) as $df | (.[1] // []) as $im | (.[2] // []) as $c |
    def row($t): ([$df[] | select(.Type == $t)][0] // {});
    row("Images") as $i | row("Containers") as $k | row("Local Volumes") as $v |
    ($c | map(select((.Size.rwSize // 0) > 0)) | sort_by(-.Size.rwSize)) as $big |
    "metric images \($i.Total // ($im | length))",
    "metric images_unused \([($i.Total // 0) - ($i.Active // 0), 0] | max)",
    "metric images_dangling \([$im[] | select(.Dangling == true or (((.Names // .names // []) | length) == 0))] | length)",
    "metric images_bytes \($i.RawSize // 0)",
    "metric images_reclaimable_bytes \($i.RawReclaimable // 0)",
    "metric containers \($k.Total // ($c | length))",
    "metric containers_bytes \($k.RawSize // 0)",
    "metric containers_reclaimable_bytes \($k.RawReclaimable // 0)",
    ($big[0:20][] | "metric container_bytes \(.Size.rwSize) name=\(cname | safe)"),
    "metric container_bytes_not_shown \([($big | length) - 20, 0] | max)",
    "metric volumes \($v.Total // 0)",
    "metric volumes_unused \([($v.Total // 0) - ($v.Active // 0), 0] | max)",
    "metric volumes_bytes \($v.RawSize // 0)",
    "metric volumes_reclaimable_bytes \($v.RawReclaimable // 0)"
' "$work/df" "$work/images" "$work/sizes" || exit 1
exit 0
