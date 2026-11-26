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
# fleet-entrypoint - a fleet test instance's start: Vigil's pointer file
# (its configuration comes from Git, config_file by FLEET_KIND), Git's
# login for the fleet's read-only user from /run/secrets/fleet_git_token (a
# file mounted read-only, never the environment), then supervisord, which
# keeps `vigil supervise` running as the vigil user.
#   FLEET_ADDR         the backend's address (required)
#   FLEET_KIND         default linux-container
#   FLEET_CHECK_EVERY  how often the configuration is checked, default 30s
set -eu
: "${FLEET_ADDR:?the backend address}"
kind=${FLEET_KIND:-linux-container}
root=/home/vigil/vigil
mkdir -p "$root/config"
cat > "$root/config/vigil.config" <<EOF
# The fleet test: this instance's configuration is $kind.config in the
# fleet's Git repository, picked up at every check.
[vigil]
config_source = fleet
config_file   = $kind.config

[source.fleet]
type        = git
url         = https://$FLEET_ADDR:8443/fleet/config.git
ref         = main
check_every = ${FLEET_CHECK_EVERY:-30s}
EOF
t=/run/secrets/fleet_git_token
[ -r "$t" ] || { echo "fleet-entrypoint: no $t" >&2; exit 1; }
umask 077
printf 'https://fleet-reader:%s@%s:8443\n' "$(tr -d '\r\n' < "$t")" "$FLEET_ADDR" > /home/vigil/.git-credentials
printf '[credential]\n\thelper = store\n' > /home/vigil/.gitconfig
chown -R vigil:vigil "$root/config" /home/vigil/.git-credentials /home/vigil/.gitconfig
exec /usr/bin/supervisord -n -c /etc/supervisord.conf
