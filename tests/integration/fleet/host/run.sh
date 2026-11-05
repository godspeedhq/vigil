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
# As the vigil account: a release server on this container's 127.0.0.1 (the
# only address the test release override accepts) serving the run's
# releases, Vigil installed from it once, a pointer file naming this host's
# source and file, then the supervisor in the foreground.
#   FLEET_SOURCE  git, https, sftp or local
#   FLEET_FILE    the configuration file inside that source
#   FLEET_START   the release to install the first time
set -eu
mkdir -p /tmp/mock
ln -sfn /fleet/www /tmp/mock/www
rm -f /tmp/mock/port
python3 /fleet/mock-files.py /tmp/mock 2> /tmp/mock/stderr &
for i in $(seq 100); do [ -s /tmp/mock/port ] && break; sleep 0.1; done
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$(cat /tmp/mock/port) VIGIL_TEST_RELEASE_KEY=/fleet/release.pem
root=$HOME/vigil
if [ ! -f "$root/app/VERSION" ]; then
    sh "/fleet/www/releases/download/v$FLEET_START/install.sh" --user --version "$FLEET_START" --prefix "$root" --no-init --no-service
fi
mkdir -p "$root/config"
{
    printf '[vigil]\nconfig_source = fleet\nconfig_file   = %s\n\n[source.fleet]\n' "$FLEET_FILE"
    case $FLEET_SOURCE in
        git) printf 'type = git\nurl  = git@fleet-git:fleet.git\nref  = main\n' ;;
        https) printf 'type = https\nurl  = https://fleet-https/fleet/\n' ;;
        sftp) printf 'type = sftp\nhost = fleet-sftp\nuser = files\npath = /home/files/fleet\n' ;;
        local) printf 'type = local\npath = /fleet/local\n' ;;
    esac
    # Seconds, not the default five minutes, so a change shows within the run.
    printf 'check_every = 10s\n'
} > "$root/config/vigil.config"
exec bash "$root/app/vigil" --root "$root" supervise
