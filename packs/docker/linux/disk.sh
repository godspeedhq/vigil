#!/usr/bin/env bash
#
# disk.sh - the disk the engine uses: images, containers, volumes and the build cache, and what could be given back
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
# What the engine keeps on disk and how much of it is in use: images (unused
# ones, and those with no name left), what containers wrote in their own
# layers, volumes (and those no container uses), and the build cache. A full
# disk under the engine stops every container on the machine at once.
#
# How full the disk itself is, is the base pack's to say (its disk job): this
# job says what is on it.
#
# Reads the Docker engine's API at DOCKER_HOST (unix:///var/run/docker.sock by
# default) with curl and jq. Every request is a GET: nothing is started,
# stopped, removed or pruned.
#
# Metrics:
#   up                              1 when the engine answers, else 0 (and
#                                   nothing more is read)
#   images                          images it holds
#   images_unused                   of those, used by no container
#   images_dangling                 with no name left: an older build of a tag
#                                   that moved on
#   images_bytes                    disk the images take
#   images_reclaimable_bytes        of that, what removing the unused ones
#                                   would give back
#   containers                      containers it holds, running or not
#   containers_bytes                disk the containers take: what each wrote
#                                   in its own layer
#   containers_stopped_bytes        of that, held by containers that are not
#                                   running
#   container_bytes                 what one container wrote in its own layer,
#                                   the 20 largest, tagged name=<the
#                                   container's name>
#   container_bytes_not_shown       past those 20, how many were left out
#   volumes                         volumes it holds
#   volumes_unused                  of those, used by no container
#   volumes_bytes                   disk the volumes take
#   volumes_unused_bytes            of that, in volumes no container uses
#   volume_bytes                    the size of one volume, the 20 largest,
#                                   tagged name=<the volume's name>
#   volume_bytes_not_shown          past those 20, how many were left out
#   build_cache_bytes               disk the build cache takes
#   build_cache_reclaimable_bytes   of that, not in use by a build
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
#            disk filling. volumes_unused with volumes_unused_bytes large:
#            data left behind by containers that are gone, to keep or to
#            remove on purpose.
#
# Requires: bash, curl 7.40 or later, and jq
# Exit code: 0 on success, the engine up or down; 1 if curl or jq is missing,
#   DOCKER_HOST is wrong, this account may not use the engine, or what answers
#   is not a Docker engine

set -u

job=disk
# shellcheck source=/dev/null
. "$(dirname "$0")/_docker.sh"
needs curl jq

engine
get /system/df df || exit 1
jq -r "$defs"'
    (.Images // .ImageUsage.Items // []) as $im | (.Containers // .ContainerUsage.Items // []) as $c |
    (.Volumes // .VolumeUsage.Items // []) as $v | (.BuildCache // .BuildCacheUsage.Items // []) as $b |
    def vsize: (.UsageData.Size // 0) | if . < 0 then 0 else . end;
    ($c | map(select((.SizeRw // 0) > 0)) | sort_by(-.SizeRw)) as $big |
    "metric images \($im | length)",
    "metric images_unused \([$im[] | select((.Containers // 0) == 0)] | length)",
    "metric images_dangling \([$im[] | select(((.RepoTags // []) | length) == 0 or (.RepoTags == ["<none>:<none>"]))] | length)",
    "metric images_bytes \(.LayersSize // .ImageUsage.TotalSize // 0)",
    "metric images_reclaimable_bytes \(.ImageUsage.Reclaimable // ([$im[] | select((.Containers // 0) == 0) | .Size // 0] | add // 0))",
    "metric containers \($c | length)",
    "metric containers_bytes \([$c[] | .SizeRw // 0] | add // 0)",
    "metric containers_stopped_bytes \([$c[] | select(.State != "running" and .State != "paused") | .SizeRw // 0] | add // 0)",
    ($big[0:20][] | "metric container_bytes \(.SizeRw) name=\(cname | safe)"),
    "metric container_bytes_not_shown \([($big | length) - 20, 0] | max)",
    "metric volumes \($v | length)",
    "metric volumes_unused \([$v[] | select((.UsageData.RefCount // 0) == 0)] | length)",
    "metric volumes_bytes \([$v[] | vsize] | add // 0)",
    "metric volumes_unused_bytes \([$v[] | select((.UsageData.RefCount // 0) == 0) | vsize] | add // 0)",
    ($v | sort_by(-vsize) | .[0:20][] | "metric volume_bytes \(vsize) name=\(.Name | safe)"),
    "metric volume_bytes_not_shown \([($v | length) - 20, 0] | max)",
    "metric build_cache_bytes \([$b[] | .Size // 0] | add // 0)",
    "metric build_cache_reclaimable_bytes \([$b[] | select(.InUse != true) | .Size // 0] | add // 0)"
' "$work/df" || exit 1
exit 0
