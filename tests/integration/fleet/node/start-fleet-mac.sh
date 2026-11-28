#!/bin/bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# start-fleet-mac.sh [<count>] [--stop] - the fleet test's containers on
# this Mac's Docker Desktop, run as the user Docker Desktop belongs to:
# builds the image and starts mac-c1..mac-c<count> (default 5) with
# node/fleet.sh, from the kit this script is in. --stop removes them. Its
# log goes beside the kit: start-fleet-mac.log.
here=$(cd "$(dirname "$0")" && pwd)
kit=$(cd "$here/../../../.." && pwd)
PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH
export PATH FLEET_HOST=mac
{
    date -u
    if [ "${1-}" = --stop ]; then bash "$here/fleet.sh" down; exit; fi
    docker version --format 'Docker {{.Server.Version}} ({{.Server.Os}})' || { echo 'Docker does not answer: is Docker Desktop running?'; exit 1; }
    bash "$here/fleet.sh" build && bash "$here/fleet.sh" up "${1:-5}" 192.168.4.40 "$kit/fleet-token"
    docker ps --filter label=vigil.fleet=node --format '{{.Names}}  {{.Status}}'
} 2>&1 | tee "$kit/start-fleet-mac.log"
