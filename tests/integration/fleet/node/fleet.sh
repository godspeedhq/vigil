#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# fleet.sh - the fleet test's containers on this Docker host, from the
# repository's root or anywhere in it:
#
#   fleet.sh build                     the image (node/Dockerfile)
#   fleet.sh up <count> <backend address> <token file>
#                                      that many instances in all on this
#                                      host (more are started, none
#                                      stopped), named <host>-c1, -c2, ...
#   fleet.sh down                      every instance this host runs
#   fleet.sh status                    how many run, and their memory
#
# Each instance: its own hostname (the host tag of everything it sends),
# 64 MB and half a CPU at most (FLEET_CPUS), the token file mounted
# read-only. FLEET_HOST names them (default this host's name).
# Only containers labelled vigil.fleet=node are ever started or removed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
img=vigil-fleet-node
host=$(hostname | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
host=${FLEET_HOST:-$host}
case ${1-} in
    build)
        [ -f "$repo/tests/integration/fleet/tls/out/ca.crt" ] || { echo "no tls/out/ca.crt: copy the fleet's CA there first" >&2; exit 1; }
        docker build -q -f "$here/Dockerfile" -t $img "$repo" ;;
    up)
        n=${2:?count} addr=${3:?backend address} tok=${4:?token file}
        [ -r "$tok" ] || { echo "cannot read $tok" >&2; exit 1; }
        # Docker Desktop on Windows (Git Bash) wants C:/..., unconverted
        tok=$(cd "$(dirname "$tok")" && { pwd -W 2> /dev/null || pwd; })/$(basename "$tok")
        export MSYS_NO_PATHCONV=1
        for i in $(seq 1 "$n"); do
            name=$host-c$i
            docker inspect "$name" > /dev/null 2>&1 && continue
            docker run -d --name "$name" --hostname "$name" --label vigil.fleet=node \
                --memory 64m --cpus "${FLEET_CPUS:-0.5}" --restart unless-stopped \
                -e FLEET_ADDR="$addr" -e FLEET_KIND=linux-container \
                -v "$tok:/run/secrets/fleet_git_token:ro" $img > /dev/null
        done
        echo "$(docker ps -q --filter label=vigil.fleet=node | wc -l | tr -d ' ') instances running on $host" ;;
    down)
        ids=$(docker ps -aq --filter label=vigil.fleet=node)
        # shellcheck disable=SC2086
        [ -z "$ids" ] || docker rm -f $ids > /dev/null
        echo "removed $(printf '%s\n' $ids | grep -c .) instances" ;;
    status)
        echo "$(docker ps -q --filter label=vigil.fleet=node | wc -l | tr -d ' ') running"
        docker stats --no-stream --format '{{.Name}} {{.MemUsage}} {{.CPUPerc}}' $(docker ps -q --filter label=vigil.fleet=node) 2> /dev/null | sort | head -n 20 ;;
    *) sed -n '11,21p' "$0"; exit 64 ;;
esac
