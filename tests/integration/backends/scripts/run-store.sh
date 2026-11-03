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
# run-store.sh - tests one of Vigil's secret stores against a test service
# from compose.secrets.yaml (backlog task 24).
#
#   scripts/start.sh openbao        (or vault, aws)
#   scripts/run-store.sh openbao
#
#   openbao, vault  Vigil's hashicorp_vault store, the same tests for both
#   aws             Vigil's aws_secrets_manager store, against Floci
#
# Needs .secrets/<target>.env and .secrets/tls/ca.pem, which start.sh makes;
# on another host, copy both, keeping their paths, and reach the service's
# port on 127.0.0.1 there (an SSH tunnel; see README.md).
#
# Vigil is set up in a temporary folder with one store per way of reaching
# the service. vigil precheck fetches every job's secret, then each job runs
# once (vigil run), and both must end as the suite's table says. Then:
#   - rotation: the secret is given a new value, and the next run gets it
#   - restart, on the Docker host only (reported NOT RUN elsewhere): the
#     service stopped, then started again, and Vigil recovering at its next
#     run
#   - leaks: no secret value or credential anywhere under the Vigil root
#     (logs, state, spool, telemetry) or in anything Vigil printed
#
# Results: PASS, FAIL, NOT RUN (with why), and for an emulator, EMULATOR
# LIMITATION, where it doesn't behave as the real service would (such as
# accepting any credentials). None of those is ever counted as a pass.
#
# Linux and macOS. Exit code: 0 when every check that ran passed.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

t=${1-}
case $t in openbao | vault | aws) ;; *) die 'usage: run-store.sh openbao|vault|aws' ;; esac
envf=$bk_dir/.secrets/$t.env
ca=$bk_dir/.secrets/tls/ca.pem
[ -f "$envf" ] && [ -f "$ca" ] || die "no .secrets/$t.env or .secrets/tls/ca.pem: run scripts/start.sh $t first, or copy them from the host that did"
load_env() {
    set -a
    # shellcheck disable=SC1090
    . "$envf"
    set +a
}
load_env
sha() { if command -v sha256sum > /dev/null 2>&1; then printf '%s' "$1" | sha256sum; else printf '%s' "$1" | shasum -a 256; fi | cut -d' ' -f1; }
rnd() { openssl rand -hex 16; }

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-store.XXXXXX") || exit 1
root=$work/root
trap 'rm -rf "$work"' EXIT
trap 'exit 1' TERM INT HUP
mkdir -p "$root/scripts" "$root/config" && cp -R "$bk_repo/app" "$root/" &&
    cp "$bk_dir/workloads/secret.sh" "$root/scripts/" && cp "$ca" "$root/config/store-ca.pem" || exit 1

vigil() { bash "$root/app/vigil" --root "$root" "$@" < /dev/null; }
pass=0 fail=0 notrun=0 limits=0
ok() { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
limit() { printf '  EMULATOR LIMITATION  %s\n' "$*"; limits=$((limits + 1)); }

# The suite's jobs, one per line: name, store, path, the status and reason
# (spaces as _, - for none) they must end with, and the value they must get
# (the name of a variable, or - for a failure).
jobs=''
# Values set by the run (rotation), by name.
first='' rotated='' current=''

# A store section: name, its keys (\n between), and whether it trusts the
# test CA.
store() {
    printf '[secret_store.%s]\n%b\n' "$1" "$2"
    [ "$3" = trusted ] && printf 'ca_file = config/store-ca.pem\n'
    printf '\n'
}
# The config: the suite's stores, then a job per line of $jobs.
write_config() {
    local name st path status reason want
    {
        printf '[vigil]\ninstance = store-test\n\n[runner.sh]\ncommand = /bin/bash\n\n[runners]\n.sh = sh\n\n'
        printf '[backend.file]\npath = metrics/vigil.prom\n\n'
        stores
        while read -r name st path status reason want; do
            [ -n "$name" ] || continue
            printf '[job.%s]\nfile = scripts/secret.sh\nrun_every = 3650d\nsecret = BK_SECRET=store:%s/%s\n' "$name" "$st" "$path"
            [ "$want" != - ] && printf 'env = BK_SECRET_SHA256=%s\n' "$(sha "${!want}")"
            printf '\n'
        done <<EOF
$jobs
EOF
    } > "$root/config/vigil.config"
}

# Runs job $1 once; it must end with status $2 and, unless $3 is -, a reason
# holding $3. $4 labels it. Leaves the outcome in $got.
run_job() {
    local status reason label=${4:-$1}
    vigil run "$1" >> "$work/vigil.out" 2>&1
    status=$(sed -n 's/^status *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    reason=$(sed -n 's/^reason *= *//p' "$root/state/jobs/$1.state" 2> /dev/null)
    got="${status:-no state}${reason:+: $reason}"
    if [ "$status" = "$2" ] && { [ "$3" = - ] || case $reason in *"$3"*) true ;; *) false ;; esac; }; then
        ok "$(printf '%-36s %s' "$label" "$got")"
    else
        bad "$(printf '%-36s %s (wanted %s%s)' "$label" "$got" "$2" "$([ "$3" = - ] || printf ': %s' "$3")")"
    fi
}

# Precheck, which fetches every secret too, must say what each job will.
precheck_jobs() {
    local name st path status reason want
    vigil precheck > "$work/precheck.out" 2>&1
    cat "$work/precheck.out" >> "$work/vigil.out"
    while read -r name st path status reason want; do
        [ -n "$name" ] || continue
        reason=${reason//_/ }
        if [ "$status" = succeeded ]; then
            grep -qF -- "ok    job.$name" "$work/precheck.out" && ok "precheck $name: fetched" || bad "precheck $name: not fetched"
        else
            grep -F -- "job.$name: " "$work/precheck.out" | grep -qF -- "$reason" && ok "precheck $name: $reason" || bad "precheck $name: wanted $reason"
        fi
    done <<EOF
$jobs
EOF
}
run_jobs() {
    local name st path status reason want
    while read -r name st path status reason want; do
        [ -n "$name" ] || continue
        run_job "$name" "$status" "${reason//_/ }" "$(label "$name")"
    done <<EOF
$jobs
EOF
}
label() { printf '%s' "$1"; }

rotate() { printf '%s' "$1" | bash "$bk_dir/configs/secrets/rotate.sh" "$t" "$envf" "$ca"; }
# Rotation: the job's secret given a new value, and the next run gets it,
# with nothing restarted.
rotation() {
    rotated=$(rnd)
    if rotate "$rotated"; then
        current=$rotated
        write_config
        run_job bk_rotating succeeded - 'bk_rotating after rotation (new value)'
    else
        bad 'rotation: cannot write the new value'
    fi
}

# The Compose services of this target, when this host runs them.
dc() { docker compose --project-directory "$bk_dir" -f "$bk_dir/compose.yaml" "$@"; }
here_running() { dc ps -q --status running $1 2> /dev/null | grep -q .; }

# ---- openbao, vault: hashicorp_vault --------------------------------------
vault_suite() {
    VIGIL_ST_BAD_TOKEN=$(rnd) VIGIL_ST_BAD_SECRET_ID=$(rnd)
    export VIGIL_ST_BAD_TOKEN VIGIL_ST_BAD_SECRET_ID
    jobs="bk_approle st vigil/probe succeeded - ST_PROBE
bk_token st_token vigil/probe succeeded - ST_PROBE
bk_missing st vigil/nosuch failed not_found_(HTTP_404) -
bk_denied st other/probe failed permission_denied_(HTTP_403) -
bk_untrusted st_untrusted vigil/probe failed is_not_trusted -
bk_bad_token st_bad_token vigil/probe failed permission_denied_(HTTP_403) -
bk_expired st_expired vigil/probe failed permission_denied_(HTTP_403) -
bk_bad_secret_id st_bad_secret_id vigil/probe failed sign-in_failed: -
bk_kv1 st_kv1 vigil/probe failed not_found_(HTTP_404) -
bk_rotating st vigil/rotating succeeded - current"
    # shellcheck disable=SC2329
    stores() {
        local v="type = hashicorp_vault\nurl = $ST_URL"
        store st "$v\nauth = approle\nrole_id = $ST_ROLE_ID\nsecret_id = env:VIGIL_ST_SECRET_ID" trusted
        store st_token "$v\nauth = token\ntoken = env:VIGIL_ST_TOKEN" trusted
        store st_untrusted "$v\nauth = token\ntoken = env:VIGIL_ST_TOKEN" untrusted
        store st_bad_token "$v\nauth = token\ntoken = env:VIGIL_ST_BAD_TOKEN" trusted
        store st_expired "$v\nauth = token\ntoken = env:VIGIL_ST_EXPIRING_TOKEN" trusted
        store st_bad_secret_id "$v\nauth = approle\nrole_id = $ST_ROLE_ID\nsecret_id = env:VIGIL_ST_BAD_SECRET_ID" trusted
        store st_kv1 "$v\nmount = kv1\nauth = token\ntoken = env:VIGIL_ST_TOKEN" trusted
    }
    # shellcheck disable=SC2329
    label() { case $1 in bk_kv1) printf 'bk_kv1 (KV v1: not supported)' ;; *) printf '%s' "$1" ;; esac; }

    # The expiring token must have expired.
    while [ "$(date '+%s')" -le "$ST_EXPIRES_AT" ]; do sleep 1; done
    # The rotating secret gets a value of this run's own first: another
    # host's run may have rotated it since provisioning.
    first=$(rnd)
    rotate "$first" || bad 'rotation: cannot write the first value'
    current=$first
    write_config
    precheck_jobs
    run_jobs
    rotation

    if here_running "$t"; then
        dc stop "$t" > /dev/null 2>&1
        run_job bk_token failed 'cannot connect to' 'bk_token, store stopped'
        dc start "$t" > /dev/null 2>&1
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
    leak_values="$ST_PROBE $ST_ROTATING $ST_KV1 $VIGIL_ST_TOKEN $VIGIL_ST_SECRET_ID $VIGIL_ST_EXPIRING_TOKEN $ST_ROTATE_TOKEN $VIGIL_ST_BAD_TOKEN $VIGIL_ST_BAD_SECRET_ID"
}

# ---- aws: aws_secrets_manager, against Floci ------------------------------
aws_suite() {
    VIGIL_ST_BAD_SECRET_KEY=$(rnd)$(rnd)
    export VIGIL_ST_BAD_SECRET_KEY
    jobs="bk_probe aws vigil/probe succeeded - ST_PROBE
bk_field aws_field vigil/json succeeded - ST_PASSWORD
bk_missing aws vigil/nosuch failed not_found_(ResourceNotFoundException) -
bk_bad_field aws_bad_field vigil/json failed the_secret's_value: -
bk_binary aws vigil/binary failed SecretString -
bk_other_region aws_eu vigil/probe failed not_found_(ResourceNotFoundException) -
bk_untrusted aws_untrusted vigil/probe failed is_not_trusted -
bk_rotating aws vigil/rotating succeeded - current"
    # shellcheck disable=SC2329
    stores() {
        local a="type = aws_secrets_manager\nclient = http\nendpoint = $ST_URL\nauth = access_keys\naccess_key_id = $ST_ACCESS_KEY_ID"
        store aws "$a\nregion = $ST_REGION\nsecret_access_key = env:VIGIL_ST_SECRET_KEY" trusted
        store aws_field "$a\nregion = $ST_REGION\nsecret_access_key = env:VIGIL_ST_SECRET_KEY\nfield = password" trusted
        store aws_bad_field "$a\nregion = $ST_REGION\nsecret_access_key = env:VIGIL_ST_SECRET_KEY\nfield = nosuch" trusted
        store aws_eu "$a\nregion = eu-west-2\nsecret_access_key = env:VIGIL_ST_SECRET_KEY" trusted
        store aws_untrusted "$a\nregion = $ST_REGION\nsecret_access_key = env:VIGIL_ST_SECRET_KEY" untrusted
        store aws_bad_key "$a\nregion = $ST_REGION\nsecret_access_key = env:VIGIL_ST_BAD_SECRET_KEY" trusted
    }
    # shellcheck disable=SC2329
    label() { case $1 in bk_other_region) printf 'bk_other_region (eu-west-2)' ;; *) printf '%s' "$1" ;; esac; }

    first=$(rnd)
    rotate "$first" || bad 'rotation: cannot write the first value'
    current=$first
    write_config
    precheck_jobs
    run_jobs
    rotation

    # A wrong secret key: AWS refuses it (InvalidSignatureException). An
    # emulator that doesn't check signatures accepts it, and is reported so.
    jobs="$jobs
bk_bad_key aws_bad_key vigil/probe failed permission_denied ST_PROBE"
    write_config
    vigil run bk_bad_key >> "$work/vigil.out" 2>&1
    status=$(sed -n 's/^status *= *//p' "$root/state/jobs/bk_bad_key.state" 2> /dev/null)
    reason=$(sed -n 's/^reason *= *//p' "$root/state/jobs/bk_bad_key.state" 2> /dev/null)
    case $status:$reason in
        failed:*'permission denied'*) ok "$(printf '%-36s %s: %s' 'bk_bad_key (wrong secret key)' "$status" "$reason")" ;;
        succeeded:*) limit 'bk_bad_key (wrong secret key): accepted; the emulator does not check signatures' ;;
        *) bad "$(printf '%-36s %s%s' 'bk_bad_key (wrong secret key)' "${status:-no state}" "${reason:+: $reason}")" ;;
    esac

    if here_running 'floci-aws floci-aws-tls'; then
        dc stop floci-aws floci-aws-tls > /dev/null 2>&1
        run_job bk_probe failed 'cannot connect to' 'bk_probe, emulator stopped'
        dc start floci-aws floci-aws-tls > /dev/null 2>&1
        # In memory: its fixtures are written again, with new values.
        bash "$bk_dir/configs/secrets/aws/provision.sh" > /dev/null || bad 'cannot provision the emulator again'
        old="$ST_PROBE $ST_PASSWORD $ST_ROTATING $ST_BINARY"
        load_env
        write_config
        run_job bk_probe succeeded - 'bk_probe, emulator restarted (recovered)'
    else
        printf '  NOT RUN  restart: %s does not run here (it needs the Docker host)\n' "$t"
        notrun=$((notrun + 1))
    fi
    leak_values="${old-} $ST_PROBE $ST_PASSWORD $ST_ROTATING $ST_BINARY $VIGIL_ST_SECRET_KEY $VIGIL_ST_BAD_SECRET_KEY"
}

# Not a case inside $(...): bash 3.2 cannot parse one there.
kind=hashicorp_vault
[ "$t" = aws ] && kind=aws_secrets_manager
printf '\n%s, %s store\n' "$t" "$kind"
case $t in
    openbao | vault) vault_suite ;;
    aws) aws_suite ;;
esac

# Leaks: every secret value and credential, under the root and in what Vigil
# printed.
leaked=''
for v in $leak_values $first $rotated; do
    [ -n "$v" ] || continue
    if grep -rqF -- "$v" "$root" "$work/vigil.out"; then leaked="$leaked $(grep -rlF -- "$v" "$root" "$work/vigil.out" | sed "s|^$work/||" | tr '\n' ' ')"; fi
done
if [ -n "$leaked" ]; then bad "a secret or credential was written down:$leaked"; else ok 'no secret or credential under the Vigil root or in its output'; fi

printf '\n%s passed, %s failed, %s not run, %s emulator limitations\n' "$pass" "$fail" "$notrun" "$limits"
[ "$fail" -eq 0 ]
