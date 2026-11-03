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
# run-store.sh - tests Vigil's hashicorp_vault secret store against the test
# OpenBao or Vault (backlog task 24), the same way for both.
#
#   scripts/start.sh openbao       (or vault)
#   scripts/run-store.sh openbao
#
# Needs .secrets/<target>.env and .secrets/tls/ca.pem, which start.sh makes;
# on another host, copy both, keeping their paths, and reach the store's
# port on 127.0.0.1 there (an SSH tunnel; see README.md).
#
# Vigil is set up in a temporary folder with one store per way of reaching
# the server. vigil precheck fetches every job's secret, then each job runs
# once (vigil run), and both must end as listed in the table below. Then:
#   - rotation: the secret is given a new value, and the next run gets it
#   - restart, on the Docker host only (reported NOT RUN elsewhere): the
#     server stopped, then started (sealed), then unsealed, and Vigil
#     recovering at its next run
#   - leaks: no secret value, token or secret id anywhere under the Vigil
#     root (logs, state, spool, telemetry) or in anything Vigil printed
#
# Only what Vigil implements is tested (spec 6.5.3): KV version 2, the latest
# version, token or AppRole. KV v1 is shown to be not supported, as it is:
# Vigil asks for kv1/data/vigil/probe, which a KV v1 mount does not have,
# though kv1/vigil/probe exists and the token may read all of kv1/.
#
# Linux and macOS. Exit code: 0 when every check that ran passed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

t=${1-}
case $t in openbao | vault) ;; *) die 'usage: run-store.sh openbao|vault' ;; esac
envf=$bk_dir/.secrets/$t.env
ca=$bk_dir/.secrets/tls/ca.pem
[ -f "$envf" ] && [ -f "$ca" ] || die "no .secrets/$t.env or .secrets/tls/ca.pem: run scripts/start.sh $t first, or copy them from the host that did"
set -a
# shellcheck disable=SC1090
. "$envf"
set +a
# Credentials that are wrong on purpose.
VIGIL_ST_BAD_TOKEN=$(openssl rand -hex 16)
VIGIL_ST_BAD_SECRET_ID=$(openssl rand -hex 16)
export VIGIL_ST_BAD_TOKEN VIGIL_ST_BAD_SECRET_ID
sha() { if command -v sha256sum > /dev/null 2>&1; then printf '%s' "$1" | sha256sum; else printf '%s' "$1" | shasum -a 256; fi | cut -d' ' -f1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-store.XXXXXX") || exit 1
root=$work/root
trap 'rm -rf "$work"' EXIT
trap 'exit 1' TERM INT HUP
mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" &&
    cp "$bk_dir/workloads/secret.sh" "$root/scripts/" && cp "$ca" "$root/config/store-ca.pem" || exit 1

# The jobs: name, store, path, then the status and reason they must end with.
jobs="bk_approle st vigil/probe succeeded -
bk_token st_token vigil/probe succeeded -
bk_missing st vigil/nosuch failed not_found_(HTTP_404)
bk_denied st other/probe failed permission_denied_(HTTP_403)
bk_untrusted st_untrusted vigil/probe failed is_not_trusted
bk_bad_token st_bad_token vigil/probe failed permission_denied_(HTTP_403)
bk_expired st_expired vigil/probe failed permission_denied_(HTTP_403)
bk_bad_secret_id st_bad_secret_id vigil/probe failed sign-in_failed:
bk_kv1 st_kv1 vigil/probe failed not_found_(HTTP_404)
bk_rotating st vigil/rotating succeeded -"

# A store section: name, auth lines, and whether it trusts the test CA.
store() {
    printf '[secret_store.%s]\ntype = hashicorp_vault\nurl = %s\n' "$1" "$ST_URL"
    [ "$3" = trusted ] && printf 'ca_file = config/store-ca.pem\n'
    printf '%b\n' "$2"
}
# The config; $1 is the SHA-256 bk_rotating expects.
write_config() {
    local name st path rest want
    {
        printf '[vigil]\ninstance = store-test\n\n[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
        printf '[backend.file]\npath = metrics/vigil.prom\n\n'
        store st "auth = approle\nrole_id = $ST_ROLE_ID\nsecret_id = env:VIGIL_ST_SECRET_ID" trusted
        store st_token 'auth = token\ntoken = env:VIGIL_ST_TOKEN' trusted
        store st_untrusted 'auth = token\ntoken = env:VIGIL_ST_TOKEN' untrusted
        store st_bad_token 'auth = token\ntoken = env:VIGIL_ST_BAD_TOKEN' trusted
        store st_expired 'auth = token\ntoken = env:VIGIL_ST_EXPIRING_TOKEN' trusted
        store st_bad_secret_id "auth = approle\nrole_id = $ST_ROLE_ID\nsecret_id = env:VIGIL_ST_BAD_SECRET_ID" trusted
        store st_kv1 'mount = kv1\nauth = token\ntoken = env:VIGIL_ST_TOKEN' trusted
        while read -r name st path rest; do
            want=$(sha "$ST_PROBE")
            [ "$name" = bk_rotating ] && want=$1
            printf '[job.%s]\nfile = scripts/secret.sh\nrun_every = 3650d\nsecret = BK_SECRET=store:%s/%s\nenv = BK_SECRET_SHA256=%s\n\n' "$name" "$st" "$path" "$want"
        done <<EOF
$jobs
EOF
    } > "$root/config/vigil.config"
}
write_config "$(sha "$ST_ROTATING")"

vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
pass=0 fail=0 notrun=0
ok() { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
# Runs job $1 once; it must end with status $2 and, unless $3 is -, a reason
# holding $3.
run_job() {
    local status reason label=$1
    vigil run "$1" >> "$work/vigil.out" 2>&1
    status=$(sed -n 's/^status *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    reason=$(sed -n 's/^reason *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    [ -n "${4-}" ] && label=$4
    if [ "$status" = "$2" ] && { [ "$3" = - ] || case $reason in *"$3"*) true ;; *) false ;; esac; }; then
        ok "$(printf '%-34s %s%s' "$label" "$status" "${reason:+: $reason}")"
    else
        bad "$(printf '%-34s %s%s (wanted %s%s)' "$label" "${status:-no state}" "${reason:+: $reason}" "$2" "$([ "$3" = - ] || printf ': %s' "$3")")"
    fi
}

printf '\n%s, hashicorp_vault store\n' "$t"
# The expiring token must have expired.
while [ "$(date '+%s')" -le "$ST_EXPIRES_AT" ]; do sleep 1; done

# The rotating secret gets a value of this run's own first: another host's
# run may have rotated it since provisioning.
rotate() { printf '%s' "$1" | bash "$bk_dir/configs/secrets/rotate.sh" "$envf" "$ca"; }
first=$(openssl rand -hex 16)
rotate "$first" || bad 'rotation: cannot write the first value'
write_config "$(sha "$first")"

# Precheck fetches every secret too, and must say the same.
vigil precheck > "$work/precheck.out" 2>&1
cat "$work/precheck.out" >> "$work/vigil.out"
while read -r name st path status reason; do
    reason=${reason//_/ }
    if [ "$status" = succeeded ]; then
        grep -qF -- "ok    job.$name" "$work/precheck.out" && ok "precheck $name: fetched" || bad "precheck $name: not fetched"
    else
        grep -F -- "job.$name: " "$work/precheck.out" | grep -qF -- "$reason" && ok "precheck $name: $reason" || bad "precheck $name: wanted $reason"
    fi
done <<EOF
$jobs
EOF

while read -r name st path status reason; do
    reason=${reason//_/ }
    case $name in
        bk_kv1) run_job "$name" "$status" "$reason" 'bk_kv1 (KV v1: not supported)' ;;
        *) run_job "$name" "$status" "$reason" ;;
    esac
done <<EOF
$jobs
EOF

# Rotation: a new value, and the next run gets it, with nothing restarted.
rotated=$(openssl rand -hex 16)
if rotate "$rotated"; then
    write_config "$(sha "$rotated")"
    run_job bk_rotating succeeded - 'bk_rotating after rotation (new value)'
else
    bad 'rotation: cannot write the new value'
fi

# Restart: only where this host runs the store's container.
if docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" ps -q --status running "$t" 2> /dev/null | grep -q .; then
    dc() { docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" "$@" > /dev/null 2>&1; }
    dc stop "$t"
    run_job bk_token failed 'cannot connect to' 'bk_token, store stopped'
    dc start "$t"
    i=0
    until curl -q -s --cacert "$ca" -o /dev/null "$ST_URL/v1/sys/health" || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
    run_job bk_token failed 'HTTP 503' 'bk_token, store restarted, sealed'
    bash "$bk_dir/configs/secrets/provision.sh" "$t" unseal > /dev/null
    run_job bk_token succeeded - 'bk_token, store unsealed (recovered)'
    run_job bk_approle succeeded - 'bk_approle, store unsealed (recovered)'
else
    printf '  NOT RUN  restart: %s does not run here (it needs the Docker host)\n' "$t"
    notrun=$((notrun + 1))
fi

# Leaks: every secret value and credential, under the root and in what Vigil
# printed.
leaked=''
for v in "$ST_PROBE" "$ST_ROTATING" "$first" "$rotated" "$ST_KV1" "$VIGIL_ST_TOKEN" "$VIGIL_ST_SECRET_ID" \
    "$VIGIL_ST_EXPIRING_TOKEN" "$ST_ROTATE_TOKEN" "$VIGIL_ST_BAD_TOKEN" "$VIGIL_ST_BAD_SECRET_ID"; do
    if grep -rqF -- "$v" "$root" "$work/vigil.out"; then leaked="$leaked $(grep -rlF -- "$v" "$root" "$work/vigil.out" | sed "s|^$work/||" | tr '\n' ' ')"; fi
done
if [ -n "$leaked" ]; then bad "a secret or credential was written down:$leaked"; else ok 'no secret or credential under the Vigil root or in its output'; fi

printf '\n%s passed, %s failed, %s not run\n' "$pass" "$fail" "$notrun"
[ "$fail" -eq 0 ]
