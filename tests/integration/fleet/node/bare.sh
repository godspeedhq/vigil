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
# bare.sh - a fleet test instance on this Linux or macOS machine itself, as
# an ordinary user, in its own folder (~/vigil-fleet-node), beside and
# apart from any Vigil installed here (its service is never touched):
#
#   bare.sh up <backend address> <token file> [<version>]
#       installs Vigil from its release (checked against SHA256SUMS and
#       their signature, with the release key in this repository), points
#       it at the fleet's configuration in Git, and starts `vigil
#       supervise` in the background
#   bare.sh down        stops it (its own pid file, nothing else)
#   bare.sh remove      stops it and deletes the folder and Git's login
#   bare.sh status
#
# Git's login: the read-only token, in a credentials file of its own
# (~/.vigil-fleet-credentials, 600), used only for the backend's URL.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
root=$HOME/vigil-fleet-node
pidf=$root/fleet.pid
cred=$HOME/.vigil-fleet-credentials
running() { [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2> /dev/null; }
case $(uname -s) in Darwin) kind=macos-bare ;; *) kind=linux-bare ;; esac
case ${1-} in
    up)
        addr=${2:?backend address} tok=${3:?token file} ver=${4:-1.5.3}
        running && { echo "already running (pid $(cat "$pidf"))"; exit 0; }
        if [ ! -x "$root/app/vigil" ]; then
            d=$(mktemp -d)
            for f in install.sh "vigil-$ver.tar.gz" SHA256SUMS SHA256SUMS.sig; do
                curl -fsSL -o "$d/$f" "https://github.com/godspeedhq/vigil/releases/download/v$ver/$f"
            done
            sh "$d/install.sh" --user --prefix "$root" --no-service --no-init \
                --archive "$d/vigil-$ver.tar.gz" --key "$repo/app/release-key.pem"
            rm -rf "$d"
        fi
        mkdir -p "$root/config"
        cat > "$root/config/vigil.config" <<EOF
# The fleet test: this instance's configuration is $kind.config in the
# fleet's Git repository, picked up at every check.
[vigil]
config_source = fleet
config_file   = $kind.config

[source.fleet]
type        = git
url         = https://$addr:8443/fleet/config.git
ref         = main
check_every = ${FLEET_CHECK_EVERY:-30s}
EOF
        (umask 077; printf 'https://fleet-reader:%s@%s:8443\n' "$(tr -d '\r\n' < "$tok")" "$addr" > "$cred")
        git config --global "credential.https://$addr:8443.helper" "store --file $cred"
        nohup "$root/app/vigil" --root "$root" supervise > "$root/fleet.out" 2>&1 < /dev/null &
        echo $! > "$pidf"
        echo "started (pid $!), $kind, config from https://$addr:8443/fleet/config" ;;
    down)
        if running; then kill "$(cat "$pidf")"; echo stopped; else echo 'not running'; fi
        rm -f "$pidf" ;;
    remove)
        "$0" down
        for k in $(git config --global --get-regexp '^credential\.https://.*:8443\.helper$' 2> /dev/null | awk '{ print $1 }'); do
            git config --global --get "$k" | grep -q "vigil-fleet-credentials" && git config --global --unset "$k"
        done
        rm -rf "$root" "$cred"; echo removed ;;
    status)
        if running; then echo "running (pid $(cat "$pidf")), $kind"; else echo 'not running'; fi ;;
    *) sed -n '11,25p' "$0"; exit 64 ;;
esac
