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
# provision.sh - prepares the test OpenBao or Vault for Vigil's store tests.
# scripts/start.sh runs it after every start, and run-store.sh to unseal
# after a restart. Safe to run again.
#
#   bash configs/secrets/provision.sh openbao|vault [unseal]
#
# The first time, it initialises the server with one unseal key, kept with
# the root token in .secrets/<target>.init (0600, git-ignored; test values
# for a test server). Every time, it unseals the server, then, unless only
# "unseal" was asked for, sets up the same fixtures in both:
#   - secret/  KV version 2, and kv1/  KV version 1
#   - policy vigil-read: read secret/data/vigil/* and all of kv1/
#   - policy vigil-rotate: write secret/data/vigil/rotating only
#   - AppRole, role vigil with vigil-read, and a new secret id
#   - tokens with vigil-read: one for 24 hours, one that expires after 5 s
#   - a token with vigil-rotate, for the rotation test
#   - secrets, each a new random value: secret/vigil/probe,
#     secret/vigil/rotating, kv1/vigil/probe; all field value
#
# What the tests need goes in .secrets/<target>.env (0600): the address,
# the credentials, and the probe values, so run-store can check none of
# them is ever written down. Copy .secrets/<target>.env and .secrets/tls/ca.pem
# to any other test host.
#
# The CLI runs inside the container. Tokens and keys go in as environment
# variables named on its command line, never as values, and secrets on
# standard input.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/../../scripts/common.sh"

t=${1-}
case $t in
    openbao) cli=bao env=BAO port=8200 ;;
    vault) cli=vault env=VAULT port=8210 ;;
    *) die 'usage: provision.sh openbao|vault [unseal]' ;;
esac
only_unseal=${2-}
sec=$bk_dir/.secrets
init=$sec/$t.init
out=$sec/$t.env
mkdir -p "$sec" && chmod 700 "$sec" || exit 1

# The CLI in the container, with $tok (when set) as its token.
run() {
    local -a e=(-e "${env}_ADDR=https://127.0.0.1:8200" -e "${env}_CACERT=/tls/ca.pem")
    [ -n "${tok-}" ] && e+=(-e "${env}_TOKEN")
    env "${env}_TOKEN=${tok-}" docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" \
        exec -T "${e[@]}" "$t" "$cli" "$@"
}
# A random value: test data only.
rnd() { openssl rand -hex 16; }

# A field of "status": Initialized or Sealed, true or false.
field() { printf '%s\n' "$status" | awk -v k="$1" '$1 == k { print $2 }'; }

tok=''
status=$(run status 2> /dev/null)
[ -n "$status" ] || die "$t does not answer: is it started (scripts/start.sh $t)?"
case $(field Initialized) in
    false)
        # Text output: "Unseal Key 1: ..." and "Initial Root Token: ...".
        o=$(run operator init -key-shares=1 -key-threshold=1) || die "cannot initialise $t"
        key=$(printf '%s\n' "$o" | sed -n 's/^Unseal Key 1: //p')
        root=$(printf '%s\n' "$o" | sed -n 's/^Initial Root Token: //p')
        [ -n "$key" ] && [ -n "$root" ] || die "$t: no unseal key or root token in its answer"
        (umask 077 && printf 'UNSEAL_KEY=%s\nROOT_TOKEN=%s\n' "$key" "$root" > "$init") || exit 1
        status=$(run status 2> /dev/null)
        ;;
esac
[ -f "$init" ] || die "$t was initialised without this checkout keeping its key: scripts/reset.sh $t, then start it again"
key=$(sed -n 's/^UNSEAL_KEY=//p' "$init")
root=$(sed -n 's/^ROOT_TOKEN=//p' "$init")
if [ "$(field Sealed)" = true ]; then
    # The key on standard input, through the API path: "operator unseal"
    # wants a terminal for it, or the key on its command line.
    printf '%s' "$key" | run write sys/unseal key=- > /dev/null || die "cannot unseal $t"
fi
[ -n "$only_unseal" ] && { echo "$t unsealed"; exit 0; }

tok=$root
mounts=$(run secrets list) || die "$t: cannot list its secret engines"
case $mounts in *'secret/'*) ;; *) run secrets enable -path=secret kv-v2 > /dev/null || die "$t: cannot enable KV v2" ;; esac
case $mounts in *'kv1/'*) ;; *) run secrets enable -path=kv1 -version=1 kv > /dev/null || die "$t: cannot enable KV v1" ;; esac
case $(run auth list) in *'approle/'*) ;; *) run auth enable approle > /dev/null || die "$t: cannot enable AppRole" ;; esac

# All of kv1/, so that reading it fails only because it is KV v1, not for
# want of permission.
printf 'path "secret/data/vigil/*" {\n  capabilities = ["read"]\n}\npath "kv1/*" {\n  capabilities = ["read"]\n}\n' |
    run policy write vigil-read - > /dev/null || die "$t: cannot write policy vigil-read"
printf 'path "secret/data/vigil/rotating" {\n  capabilities = ["create", "update"]\n}\n' |
    run policy write vigil-rotate - > /dev/null || die "$t: cannot write policy vigil-rotate"
run write auth/approle/role/vigil token_policies=vigil-read token_ttl=10m secret_id_ttl=0 > /dev/null ||
    die "$t: cannot write the AppRole role"

role_id=$(run read -field=role_id auth/approle/role/vigil/role-id) || die "$t: cannot read the role id"
secret_id=$(run write -f -field=secret_id auth/approle/role/vigil/secret-id) || die "$t: cannot make a secret id"
token=$(run token create -policy=vigil-read -ttl=24h -field=token) || die "$t: cannot make a token"
expiring=$(run token create -policy=vigil-read -ttl=5s -explicit-max-ttl=5s -field=token) || die "$t: cannot make the expiring token"
expires=$(($(date '+%s') + 5))
rotator=$(run token create -policy=vigil-rotate -ttl=24h -field=token) || die "$t: cannot make the rotation token"

probe=$(rnd) rotating=$(rnd) kv1=$(rnd)
printf '%s' "$probe" | run kv put -mount=secret vigil/probe value=- > /dev/null || die "$t: cannot write secret/vigil/probe"
printf '%s' "$rotating" | run kv put -mount=secret vigil/rotating value=- > /dev/null || die "$t: cannot write secret/vigil/rotating"
printf '%s' "$kv1" | run kv put -mount=kv1 vigil/probe value=- > /dev/null || die "$t: cannot write kv1/vigil/probe"

(umask 077 && {
    printf '# Written by configs/secrets/provision.sh %s at %s; test values for a test server.\n' "$t" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'ST_URL=https://127.0.0.1:%s\n' "$port"
    printf 'ST_ROLE_ID=%s\nVIGIL_ST_SECRET_ID=%s\nVIGIL_ST_TOKEN=%s\n' "$role_id" "$secret_id" "$token"
    printf 'VIGIL_ST_EXPIRING_TOKEN=%s\nST_EXPIRES_AT=%s\nST_ROTATE_TOKEN=%s\n' "$expiring" "$expires" "$rotator"
    printf 'ST_PROBE=%s\nST_ROTATING=%s\nST_KV1=%s\n' "$probe" "$rotating" "$kv1"
} > "$out.tmp") && mv -f "$out.tmp" "$out" || die "cannot write $out"
echo "$t provisioned: fixtures in secret/ (KV v2) and kv1/ (KV v1); see .secrets/$t.env"
