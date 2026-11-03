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
# provision.sh - what the test OpenSSH SFTP server serves, for Vigil's sftp
# sources. scripts/start.sh sftp-openssh runs it after every start. Safe to
# run again: the files are written again, the same.
#
#   bash configs/sources/openssh/provision.sh
#
# In .sources/sftp/files/, which the server shows user vigil as /files:
#   the fixture scripts (check-v1, check-v2, both flavours), corrupt.txt
#   nested/deep/check-v1.sh   for a nested path
#   locked.sh                 version 1, 0600: user vigil (uid 2001) may not
#                             read it, so a fetch is refused
#   configs/v1, v2, broken    the remote configurations
#
# .sources/sftp_known_hosts: the server's host key, written from its public
# key, never learned from the server. .sources/openssh.env: what the tests
# need.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

src=$bk_dir/.sources
files=$src/sftp/files
fx=$bk_dir/fixtures/sources
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }

mkdir -p "$files/nested/deep" "$files/configs" || exit 1
cp "$fx"/scripts/check-v*.sh "$fx"/scripts/check-v*.ps1 "$fx/scripts/corrupt.txt" "$files/" &&
    cp "$fx/scripts/check-v1.sh" "$files/nested/deep/check-v1.sh" &&
    cp "$fx/scripts/check-v1.sh" "$files/locked.sh" &&
    cp -R "$fx"/sftp/v1 "$fx"/sftp/v2 "$fx"/sftp/broken "$files/configs/" || die 'cannot copy the fixtures'
chmod -R a+rX "$files" && chmod 600 "$files/locked.sh" || exit 1

printf '[127.0.0.1]:2022 %s\n' "$(cut -d' ' -f1,2 "$src/ssh/sftp_host_ed25519.pub")" > "$src/sftp_known_hosts" || exit 1

i=0
until ssh-keyscan -p 2022 -t ed25519 127.0.0.1 2> /dev/null | grep -q ed25519 || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
# The server must hold the key known_hosts names, or every test would fail
# for the wrong reason.
served=$(ssh-keyscan -p 2022 -t ed25519 127.0.0.1 2> /dev/null | grep -v '^#' | cut -d' ' -f3)
[ "$served" = "$(cut -d' ' -f2 "$src/ssh/sftp_host_ed25519.pub")" ] || die 'the SFTP server does not hold .sources/ssh/sftp_host_ed25519'

(umask 077 && {
    printf '# Written by configs/sources/openssh/provision.sh at %s.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'SRC_HOST=127.0.0.1\nSRC_PORT=2022\nSRC_USER=vigil\n'
    for v in 1 2; do
        printf 'SRC_SHA_V%s_SH=%s\nSRC_SHA_V%s_PS1=%s\n' "$v" "$(sha "$fx/scripts/check-v$v.sh")" "$v" "$(sha "$fx/scripts/check-v$v.ps1")"
    done
} > "$src/openssh.env.tmp") && mv -f "$src/openssh.env.tmp" "$src/openssh.env" || die 'cannot write .sources/openssh.env'
echo "sftp-openssh provisioned: /files (scripts, nested, locked, configs); see .sources/openssh.env"
