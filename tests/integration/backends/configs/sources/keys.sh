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
# keys.sh - the dummy SSH keys the source tests use, made once and kept in
# .sources/ssh/ (git-ignored). scripts/start.sh runs it before starting a
# source server. Test keys for servers on 127.0.0.1, worth nothing anywhere
# else; never a production key.
#
#   bash configs/sources/keys.sh
#
#   vigil_sources        the key Vigil signs in with: a Gitea deploy key, the
#                        SFTP user's authorised key
#   vigil_sources_wrong  a key no server knows, for the refusal tests
#   sftp_host_ed25519    the SFTP server's host key, fixed so known_hosts
#                        stays right across restarts

set -u
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$here/../.." && pwd)/.sources/ssh

command -v ssh-keygen > /dev/null 2>&1 || { echo 'keys.sh needs ssh-keygen' >&2; exit 1; }
mkdir -p "$dir" && chmod 700 "$dir" || exit 1
for k in vigil_sources vigil_sources_wrong sftp_host_ed25519; do
    [ -f "$dir/$k" ] && continue
    ssh-keygen -q -t ed25519 -N '' -C "vigil-source-tests $k" -f "$dir/$k" || { echo "keys.sh: cannot make $k" >&2; exit 1; }
done
# Private keys stay 0600: the SFTP container reads its host key as root,
# and sshd refuses one anyone else could read.
chmod 600 "$dir/vigil_sources" "$dir/vigil_sources_wrong" "$dir/sftp_host_ed25519"
chmod 644 "$dir"/*.pub
