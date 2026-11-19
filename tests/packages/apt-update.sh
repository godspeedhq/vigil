#!/bin/sh
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
# apt-update.sh - apt-get update that either fetches every index or stops,
# for the package tests in a Debian or Ubuntu container.
#
# apt-get update exits 0 when a mirror is down and some indexes could not be
# fetched; installing then fails on a half-stale index ("held broken
# packages"), and every check after it fails for a reason that is not
# Vigil's. With --error-on=any a failed fetch is an error: tried five times,
# 15 seconds apart, and then said plainly.
#
# Exit code: 0 every index fetched; 1 the mirrors kept failing

i=1
while [ "$i" -le 5 ]; do
    if apt-get update -q -o Acquire::Retries=3 --error-on=any > /tmp/apt-update.out 2>&1; then
        exit 0
    fi
    echo "apt-get update failed (try $i of 5): $(grep -E '^(E|W):' /tmp/apt-update.out | head -2 | tr '\n' ' ')" >&2
    i=$((i + 1))
    [ "$i" -le 5 ] && sleep 15
done
echo 'apt-get update kept failing: the package mirrors are unreachable, not Vigil; rerun the job' >&2
exit 1
