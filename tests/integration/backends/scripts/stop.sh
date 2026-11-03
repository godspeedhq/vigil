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
# stop.sh - stops targets, keeping their data.
#
#   scripts/stop.sh lgtm
#   scripts/stop.sh all          every target this environment started

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -gt 0 ] || die 'usage: stop.sh <target>... | all'

if [ "$1" = all ]; then
    compose --profile '*' stop
    for p in vigil-signoz vigil-uptrace vigil-graylog; do
        docker compose -p "$p" stop 2> /dev/null
    done
    exit 0
fi

for t in "$@"; do
    endpoints "$t"
    if is_upstream "$t"; then
        docker compose -p "vigil-$t" stop
    else
        # shellcheck disable=SC2046
        compose --profile "$t" stop $(services_of "$t")
    fi
done
