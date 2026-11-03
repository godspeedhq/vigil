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
# reset.sh - removes targets and their data, so the next start is fresh.
#
#   scripts/reset.sh splunk
#   scripts/reset.sh all         everything this environment created
#
# Only this environment's containers and volumes: the Compose projects
# vigil-backends, vigil-signoz, vigil-uptrace and vigil-graylog.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -gt 0 ] || die 'usage: reset.sh <target>... | all'

if [ "$1" = all ]; then
    compose --profile '*' down -v
    for p in vigil-signoz vigil-uptrace vigil-graylog; do
        docker compose -p "$p" down -v 2> /dev/null
    done
    exit 0
fi

for t in "$@"; do
    endpoints "$t"
    if is_upstream "$t"; then
        docker compose -p "vigil-$t" down -v
        continue
    fi
    s=$(services_of "$t")
    # shellcheck disable=SC2086
    compose --profile "$t" rm -s -f -v $s
    # Each service's volumes are named after it (lgtm-data, splunk-var, ...),
    # so these are its volumes and no other's.
    for svc in $s; do
        for v in $(docker volume ls -q --filter "name=^vigil-backends_$svc-"); do
            docker volume rm "$v" > /dev/null && printf 'removed volume %s\n' "$v"
        done
    done
done
