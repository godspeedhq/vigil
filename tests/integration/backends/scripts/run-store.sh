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
# run-store.sh - proves Vigil's hashicorp_vault secret store against the
# test OpenBao: a job gets its secret from the store, and the failures say
# what went wrong without showing anything secret.
#
#   scripts/start.sh openbao
#   scripts/run-store.sh openbao
#
# Needs .openbao.env and .openbao-ca.pem, which start.sh's provisioning
# writes; on another host, copy both along with the checkout, and reach
# OpenBao's port 8200 on 127.0.0.1 there (an SSH tunnel; see README.md).
#
# Vigil is set up in a temporary folder with one store per way of reaching
# OpenBao. vigil precheck fetches every job's secret, then each job runs
# once (vigil run), and both must end as listed:
#   bk_secret_approle    AppRole sign-in: the job gets the probe     succeeded
#   bk_secret_token      a token: the job gets the probe             succeeded
#   bk_secret_missing    a path with no secret                       not found (HTTP 404)
#   bk_secret_denied     a path the policy does not allow            permission denied
#   bk_secret_untrusted  no ca_file: OpenBao's CA is not trusted     not trusted
# Then the whole folder is searched for the probe's value, which must
# appear nowhere: not in logs, state or spool.
#
# Linux and macOS. Exit code: 0 when every check passes.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -eq 1 ] && [ "$1" = openbao ] || die 'usage: run-store.sh openbao'
[ -f "$bk_dir/.openbao.env" ] && [ -f "$bk_dir/.openbao-ca.pem" ] ||
    die 'no .openbao.env or .openbao-ca.pem: run scripts/start.sh openbao first, or copy them from the host that did'
set -a
# shellcheck disable=SC1091
. "$bk_dir/.openbao.env"
set +a

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-store.XXXXXX") || exit 1
root=$work/root
trap 'rm -rf "$work"' EXIT
trap 'exit 1' TERM INT HUP
mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" &&
    cp "$bk_dir/workloads/secret.sh" "$root/scripts/" && cp "$bk_dir/.openbao-ca.pem" "$root/config/openbao-ca.pem" || exit 1

# A job reading secret path $2 from store $3.
job() {
    printf '[job.%s]\nfile = scripts/secret.sh\nrun_every = 3650d\nsecret = BK_SECRET=store:%s/%s\nenv = BK_SECRET_SHA256=%s\n\n' "$1" "$3" "$2" "$BK_SECRET_SHA256"
}
{
    printf '[vigil]\ninstance = store-test\n\n'
    printf '[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
    printf '[backend.file]\npath = metrics/vigil.prom\n\n'
    printf '[secret_store.bao]\ntype = hashicorp_vault\nurl = https://127.0.0.1:8200\nca_file = config/openbao-ca.pem\n'
    printf 'auth = approle\nrole_id = %s\nsecret_id = env:VIGIL_BAO_SECRET_ID\n\n' "$VIGIL_BAO_ROLE_ID"
    printf '[secret_store.bao_token]\ntype = hashicorp_vault\nurl = https://127.0.0.1:8200\nca_file = config/openbao-ca.pem\n'
    printf 'auth = token\ntoken = env:VIGIL_BAO_TOKEN\n\n'
    printf '[secret_store.bao_untrusted]\ntype = hashicorp_vault\nurl = https://127.0.0.1:8200\n'
    printf 'auth = token\ntoken = env:VIGIL_BAO_TOKEN\n\n'
    job bk_secret_approle vigil/probe bao
    job bk_secret_token vigil/probe bao_token
    job bk_secret_missing vigil/nosuch bao
    job bk_secret_denied other/probe bao
    job bk_secret_untrusted vigil/probe bao_untrusted
} > "$root/config/vigil.config"

# The probe's value is for the leak check below; no job sees it from here.
probe=$BK_SECRET_VALUE
unset BK_SECRET_VALUE
vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
fail=0

# Precheck fetches every secret too: the first two must be fetched, and the
# other three fail, each for its own reason.
printf '\nopenbao, hashicorp_vault store\n'
vigil precheck > "$work/precheck.out" 2>&1
pre() {
    if grep -qF -- "$2" "$work/precheck.out"; then
        printf '  PASS  precheck %-20s %s\n' "$1" "$3"
    else
        printf '  FAIL  precheck %-20s (wanted: %s)\n' "$1" "$2"
        fail=1
    fi
}
pre bk_secret_approle 'ok    job.bk_secret_approle' 'fetched'
pre bk_secret_token 'ok    job.bk_secret_token' 'fetched'
pre bk_secret_missing 'job.bk_secret_missing: secret store:bao/vigil/nosuch unavailable: not found (HTTP 404)' 'not found (HTTP 404)'
pre bk_secret_denied 'job.bk_secret_denied: secret store:bao/other/probe unavailable: permission denied' 'permission denied'
pre bk_secret_untrusted 'job.bk_secret_untrusted: secret store:bao_untrusted/vigil/probe unavailable: the certificate of' 'not trusted'
[ "$fail" -eq 0 ] || sed 's/^/        /' "$work/precheck.out"
# Runs job $1 once; PASS when its state says status $2, and reason $3 when
# one is given.
check() {
    local status reason
    vigil run "$1" > "$work/$1.out" 2>&1
    status=$(sed -n 's/^status *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    reason=$(sed -n 's/^reason *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    if [ "$status" = "$2" ] && { [ -z "${3-}" ] || case $reason in *"$3"*) true ;; *) false ;; esac; }; then
        printf '  PASS  %-20s %s%s\n' "$1" "$status" "${reason:+: $reason}"
    else
        printf '  FAIL  %-20s %s%s (wanted %s%s)\n' "$1" "${status:-no state}" "${reason:+: $reason}" "$2" "${3:+: $3}"
        sed 's/^/        /' "$work/$1.out"
        fail=1
    fi
}

check bk_secret_approle succeeded
check bk_secret_token succeeded
check bk_secret_missing failed 'not found (HTTP 404)'
check bk_secret_denied failed 'permission denied'
check bk_secret_untrusted failed 'not trusted'
if grep -rqF -- "$probe" "$root"; then
    printf '  FAIL  the probe value was written down:\n'
    grep -rlF -- "$probe" "$root" | sed "s|^$root/|        |"
    fail=1
else
    printf '  PASS  the probe value appears nowhere under the Vigil root\n'
fi
exit "$fail"
