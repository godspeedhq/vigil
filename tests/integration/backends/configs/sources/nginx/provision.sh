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
# provision.sh - what the test nginx serves, for Vigil's https sources.
# scripts/start.sh https-nginx runs it after every start. Safe to run
# again: the files are written again, the same.
#
#   bash configs/sources/nginx/provision.sh
#
# In .sources/https/, served at https://127.0.0.1:9443/ (and plain http on
# 9080):
#   files/    the fixture scripts as they are (check-v1, check-v2, in both
#             flavours), corrupt.txt, and current.{sh,ps1}, a copy of
#             version 1 that the tests replace to publish an update
#   configs/  the remote configurations: v1, v2, broken
#   conf/token.map   the authentication header's token, for /auth/
#
# The token is random, made once, in .sources/nginx.env (0600), with the
# fixtures' SHA-256s.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../../scripts/common.sh"

src=$bk_dir/.sources
srv=$src/https
fx=$bk_dir/fixtures/sources
out=$src/nginx.env
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1; }

mkdir -p "$srv/files" "$srv/configs" "$srv/conf" || exit 1
cp "$fx"/scripts/check-v*.sh "$fx"/scripts/check-v*.ps1 "$fx/scripts/corrupt.txt" "$srv/files/" &&
    cp "$fx/scripts/check-v1.sh" "$srv/files/current.sh" && cp "$fx/scripts/check-v1.ps1" "$srv/files/current.ps1" &&
    cp -R "$fx"/https/v1 "$fx"/https/v2 "$fx"/https/broken "$srv/configs/" || die 'cannot copy the fixtures'
# nginx reads them as another user.
chmod -R a+rX "$srv"

token=''
[ -f "$out" ] && token=$(sed -n 's/^SRC_TOKEN=//p' "$out")
[ -n "$token" ] || token=$(openssl rand -hex 16)
printf '"%s" ok;\n' "$token" > "$srv/conf/token.map" && chmod 644 "$srv/conf/token.map" || exit 1
docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" exec -T nginx-sources nginx -s reload > /dev/null 2>&1 ||
    die 'cannot reload nginx'

(umask 077 && {
    printf '# Written by configs/sources/nginx/provision.sh at %s; a test value for a test server.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'SRC_URL=https://127.0.0.1:9443\nSRC_HTTP_URL=http://127.0.0.1:9080\nSRC_TOKEN=%s\n' "$token"
    for v in 1 2; do
        printf 'SRC_SHA_V%s_SH=%s\nSRC_SHA_V%s_PS1=%s\n' "$v" "$(sha "$fx/scripts/check-v$v.sh")" "$v" "$(sha "$fx/scripts/check-v$v.ps1")"
    done
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "https-nginx provisioned: files/, configs/ (v1, v2, broken), /auth/ behind a token; see .sources/nginx.env"
