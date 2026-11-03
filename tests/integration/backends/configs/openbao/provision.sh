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
# provision.sh - prepares the test OpenBao for Vigil. Dev mode keeps
# nothing, so this runs after every start (scripts/start.sh openbao does).
#
#   bash configs/openbao/provision.sh
#
# In the store:
#   - AppRole sign-in, and the role vigil, whose tokens may only read
#     secret/data/vigil/* (policy vigil-read)
#   - a token with the same policy, for auth = token
#   - the probe secret secret/vigil/probe, field value: 32 random hex
#     characters, new every time
#
# Written next to compose.yaml, both git-ignored, both for
# scripts/run-store.sh (copy them along with the checkout to a test host):
#   .openbao-ca.pem   the CA this start made, for Vigil's ca_file
#   .openbao.env      VIGIL_BAO_ROLE_ID, VIGIL_BAO_SECRET_ID and
#                     VIGIL_BAO_TOKEN; BK_SECRET_SHA256, the probe's
#                     SHA-256; and BK_SECRET_VALUE, the probe itself, so
#                     run-store.sh can prove Vigil never wrote it anywhere.
#                     A test value in a 0600 file, for a container that
#                     forgets it at the stop.
#
# Every command runs OpenBao's own CLI inside the container. The root token
# goes in as an environment variable named on the command line, never as
# its value, and the probe on standard input.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../scripts/common.sh"
[ -n "${OPENBAO_ROOT_TOKEN-}" ] || die 'set OPENBAO_ROOT_TOKEN in .env'

bao() {
    BAO_TOKEN=$OPENBAO_ROOT_TOKEN compose exec -T -e BAO_TOKEN \
        -e BAO_ADDR=https://127.0.0.1:8200 -e BAO_CACERT=/openbao/tls/vault-ca.pem openbao bao "$@"
}

ca=$bk_dir/.openbao-ca.pem
out=$bk_dir/.openbao.env

compose exec -T openbao cat /openbao/tls/vault-ca.pem > "$ca.tmp" && mv -f "$ca.tmp" "$ca" || die 'cannot copy the CA out of the container'

# AppRole, once: dev mode starts without it.
if ! bao auth list -format=json | grep -q '"approle/"'; then
    bao auth enable approle > /dev/null || die 'cannot enable AppRole'
fi
printf 'path "secret/data/vigil/*" {\n  capabilities = ["read"]\n}\n' |
    bao policy write vigil-read - > /dev/null || die 'cannot write the policy'
bao write auth/approle/role/vigil token_policies=vigil-read token_ttl=10m secret_id_ttl=0 > /dev/null ||
    die 'cannot write the AppRole role'

role_id=$(bao read -field=role_id auth/approle/role/vigil/role-id) || die 'cannot read the role id'
secret_id=$(bao write -f -field=secret_id auth/approle/role/vigil/secret-id) || die 'cannot make a secret id'
token=$(bao token create -policy=vigil-read -ttl=24h -field=token) || die 'cannot make a token'

value=$(openssl rand -hex 16) || die 'openssl is needed'
printf '%s' "$value" | bao kv put -mount=secret vigil/probe value=- > /dev/null || die 'cannot write the probe'
if command -v sha256sum > /dev/null 2>&1; then sha=$(printf '%s' "$value" | sha256sum); else sha=$(printf '%s' "$value" | shasum -a 256); fi

umask 077
{
    printf '# Written by configs/openbao/provision.sh at %s; valid until OpenBao stops.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'VIGIL_BAO_ROLE_ID=%s\n' "$role_id"
    printf 'VIGIL_BAO_SECRET_ID=%s\n' "$secret_id"
    printf 'VIGIL_BAO_TOKEN=%s\n' "$token"
    printf 'BK_SECRET_SHA256=%s\n' "${sha%% *}"
    printf 'BK_SECRET_VALUE=%s\n' "$value"
} > "$out.tmp" && mv -f "$out.tmp" "$out" || die "cannot write $out"
printf 'OpenBao provisioned: AppRole vigil, a token, the probe secret/vigil/probe; see %s\n' "${out#"$bk_dir"/}"
