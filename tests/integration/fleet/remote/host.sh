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
# A fleet host on macOS or Linux outside Docker, reaching the fleet's
# servers through SSH tunnels on 127.0.0.1 (2222 git, 2223 sftp, 8080 http).
# Runs in the foreground until its session ends: a release server on
# 127.0.0.1 serving <dir>/www, Vigil installed from it once, a pointer file,
# then the supervisor.
#
#   host.sh <dir> <git|https|sftp> <file in the source> <first release>
#
# <dir> holds what fleet.sh made: www/, release.pem, mock-files.py and
# keys/fleet, keys/known_hosts. Nothing outside <dir> is touched: HOME is
# <dir>/home, and ssh reads <dir>/ssh_config only.
set -eu
dir=$(cd "$1" && pwd) src=$2 file=$3 start=$4
export HOME=$dir/home
mkdir -p "$HOME"
chmod 600 "$dir/keys/fleet"
printf 'Host 127.0.0.1\n  IdentityFile %s\n  UserKnownHostsFile %s\n  IdentitiesOnly yes\n' \
    "$dir/keys/fleet" "$dir/keys/known_hosts" > "$dir/ssh_config"
export GIT_SSH_COMMAND="ssh -F $dir/ssh_config" VIGIL_TEST_SSH_CONFIG=$dir/ssh_config
# The release server serves <dir>/www, and writes its port to <dir>/port.
rm -f "$dir/port"
python3 "$dir/mock-files.py" "$dir" 2> "$dir/mock.err" &
for i in $(seq 100); do [ -s "$dir/port" ] && break; sleep 0.1; done
export VIGIL_TEST_RELEASE_URL=http://127.0.0.1:$(cat "$dir/port") VIGIL_TEST_RELEASE_KEY=$dir/release.pem
root=$dir/root
[ -f "$root/app/VERSION" ] || sh "$dir/www/releases/download/v$start/install.sh" --user --version "$start" --prefix "$root" --no-init --no-service
mkdir -p "$root/config"
{
    printf '[vigil]\nconfig_source = fleet\nconfig_file   = %s\n\n[source.fleet]\n' "$file"
    case $src in
        git) printf 'type = git\nurl  = ssh://git@127.0.0.1:2222/home/git/fleet.git\nref  = main\n' ;;
        https) printf 'type = https\nurl  = http://127.0.0.1:8080/fleet/\n' ;;
        sftp) printf 'type = sftp\nhost = 127.0.0.1\nport = 2223\nuser = files\npath = /home/files/fleet\n' ;;
    esac
    printf 'check_every = 10s\n'
} > "$root/config/vigil.config"
exec bash "$root/app/vigil" --root "$root" supervise
