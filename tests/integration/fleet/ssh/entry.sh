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
# Starts sshd for $SSH_USER, with the run's host key and authorized key.
set -eu
id "$SSH_USER" > /dev/null 2>&1 || useradd -m -s /bin/bash "$SSH_USER"
home=$(getent passwd "$SSH_USER" | cut -d: -f6)
install -d -o "$SSH_USER" -g "$SSH_USER" -m 700 "$home/.ssh"
install -o "$SSH_USER" -g "$SSH_USER" -m 600 /fleet/keys/fleet.pub "$home/.ssh/authorized_keys"
install -m 600 /fleet/keys/host /etc/ssh/ssh_host_ed25519_key
# The repository is mounted, so it belongs to the Docker host's account, not this
# one; git refuses that unless told. Test server only.
git config --system --add safe.directory '*'
exec /usr/sbin/sshd -D -e -o HostKey=/etc/ssh/ssh_host_ed25519_key -o PasswordAuthentication=no -o PermitRootLogin=no
