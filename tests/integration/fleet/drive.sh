#!/usr/bin/env bash
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
# Drives the fleet of fleet.sh from a workstation that reaches all three
# test machines over SSH: the Docker host with fleet.sh, and the macOS and
# Windows hosts of remote/. Every command and its output is appended to
# $FLEET_LOG, which is the run's evidence.
#
#   drive.sh status                     every host, one line each
#   drive.sh log                        every supervisor's update lines
#   drive.sh set <v> <file>...          version <v> in those files
#   drive.sh publish <v>                release <v>, on every host's server
#   drive.sh broken <from> <v>          a release <v> that does not run
#   drive.sh refuse <host>              vigil self update on a Docker host
#   drive.sh wait <secs> <v> <hosts>    until those hosts' app is <v>
#
# Settings: FLEET_DOCKER, FLEET_MAC, FLEET_WINDOWS (ssh targets),
# FLEET_KEY (ssh key), FLEET_DIR (the checkout on the Docker host),
# FLEET_LOG (the console file).

set -u
here=$(cd "$(dirname "$0")" && pwd)
docker=${FLEET_DOCKER:?} mac=${FLEET_MAC:?} win=${FLEET_WINDOWS:?} key=${FLEET_KEY:?}
dir=${FLEET_DIR:-vc/tests/integration/fleet}
log=${FLEET_LOG:?}
s() { ssh -i "$key" -o LogLevel=ERROR "$@"; }

fleet() { s "$docker" "cd $dir && bash fleet.sh $*"; }
status() {
    fleet status
    bash "$here/remote/status.sh" "$mac" "$win" -i "$key" -o LogLevel=ERROR
}

# Copies release $1 from the Docker host to the macOS and Windows hosts'
# release servers.
push() {
    s "$docker" "cd $dir/share && tar -cf - www/releases/download/v$1 www/releases/tag/v$1" > "${TMPDIR:-/tmp}/fleet-release.tar"
    s "$mac" 'tar -xf - -C fleet/mac' < "${TMPDIR:-/tmp}/fleet-release.tar"
    s "$win" 'tar -xf - -C fleet/https' < "${TMPDIR:-/tmp}/fleet-release.tar"
    s "$win" 'tar -xf - -C fleet/sftp' < "${TMPDIR:-/tmp}/fleet-release.tar"
    rm -f "${TMPDIR:-/tmp}/fleet-release.tar"
    printf 'copied %s to the macOS and Windows hosts\n' "$1"
}

run() {
    case $1 in
        status) status ;;
        log)
            fleet log
            bash "$here/remote/status.sh" log "$mac" "$win" -i "$key" -o LogLevel=ERROR
            ;;
        set)
            local v=$2 f
            shift 2
            for f in "$@"; do fleet version "$f" "$v"; done
            ;;
        publish) fleet release "$2" && push "$2" ;;
        broken) fleet broken "$2" "$3" && push "$3" ;;
        refuse) fleet refuse "$2" ;;
        wait)
            local secs=$2 v=$3 hosts=$4 n=0 left
            while :; do
                left=$(status | awk -v v="$v" -v hosts=" $hosts " '{ k = $1 ($1 == "win" ? "-" $2 : "") } index(hosts, " " k " ") && $3 != v { print k }' | tr '\n' ' ')
                [ -z "$left" ] && { printf 'all on %s after %ss: %s\n' "$v" "$n" "$hosts"; return 0; }
                [ "$n" -ge "$secs" ] && { printf 'not on %s after %ss: %s\n' "$v" "$n" "$left"; return 1; }
                sleep 10
                n=$((n + 10))
            done
            ;;
        *) sed -n '/^#   drive.sh/,/^$/p' "$0"; exit 64 ;;
    esac
}

{
    printf '\n$ drive.sh %s    # %s\n' "$*" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    run "$@" 2>&1
    printf '[exit %s]\n' "$?"
} | tee -a "$log"
