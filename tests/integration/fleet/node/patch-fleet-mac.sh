#!/bin/bash
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
# patch-fleet-mac.sh [--undo] [file [target]]
# Puts one fixed Vigil file into every fleet test container on this Mac's
# Docker Desktop (containers labelled vigil.fleet=node), as
# Patch-FleetContainers.ps1 does on Windows. The file defaults to
# backends.sh beside this script, the target to lib/posix/backends.sh; the
# original is kept as <target>.orig in the container, once. Its log goes
# to /Users/Shared/vigil-fleet/patch-fleet-mac.log.
set -u
here=$(cd "$(dirname "$0")" && pwd)
undo=0
[ "${1-}" = --undo ] && { undo=1; shift; }
file=${1:-$here/backends.sh}
dest=/home/vigil/vigil/app/${2:-lib/posix/backends.sh}
log=${FLEET_PATCH_LOG:-/Users/Shared/vigil-fleet/patch-fleet-mac.log}
PATH=$PATH:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin
exec > >(tee "$log") 2>&1
docker version --format 'Docker {{.Server.Version}} ({{.Server.Os}})' || { echo 'Docker does not answer: is Docker Desktop running?'; exit 1; }
[ "$undo" = 1 ] || { [ -f "$file" ] || { echo "no file $file"; exit 1; }; echo "file: $file, sha256 $(shasum -a 256 "$file" | cut -d' ' -f1)"; }
names=$(docker ps --filter label=vigil.fleet=node --format '{{.Names}}')
[ -n "$names" ] || { echo 'no running container labelled vigil.fleet=node'; exit 1; }
for n in $names; do
    if [ "$undo" = 1 ]; then
        docker exec "$n" sh -c "test -f '$dest.orig' && cat '$dest.orig' > '$dest' && rm -f '$dest.orig' && echo restored || echo 'nothing to restore'"
    else
        # docker cp, then cat into place: the installed file keeps its owner and mode.
        docker cp "$file" "$n:/tmp/vigil-patch" &&
            docker exec "$n" sh -c "test -f '$dest' || { echo 'no such file in the container'; exit 3; }; test -f '$dest.orig' || cp -p '$dest' '$dest.orig'; cat /tmp/vigil-patch > '$dest' && rm -f /tmp/vigil-patch" ||
            { echo "FAILED: could not patch $n"; exit 1; }
    fi
    echo "$n  $(docker exec "$n" sha256sum "$dest" | cut -d' ' -f1)"
done
