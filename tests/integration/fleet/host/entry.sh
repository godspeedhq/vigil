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
# As root: trusts the run's certificate authority (for the https source),
# gives the vigil account the run's key and known hosts (for git and sftp),
# then runs run.sh as that account. Vigil itself never runs as root here.
set -eu
cp /fleet/ca/ca.pem /usr/local/share/ca-certificates/fleet-ca.crt
update-ca-certificates > /dev/null 2>&1
h=/home/vigil
install -d -o vigil -g vigil -m 700 "$h/.ssh"
install -o vigil -g vigil -m 600 /fleet/keys/fleet "$h/.ssh/id_ed25519"
install -o vigil -g vigil -m 644 /fleet/keys/known_hosts "$h/.ssh/known_hosts"
exec runuser -u vigil -- env FLEET_SOURCE="$FLEET_SOURCE" FLEET_FILE="$FLEET_FILE" FLEET_START="$FLEET_START" \
    HOME="$h" bash /fleet-bin/run.sh
