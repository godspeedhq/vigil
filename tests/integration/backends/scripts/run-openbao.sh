#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-openbao.sh - the openbao pack against real OpenBao and HashiCorp Vault
# clusters in trouble on purpose, with its evidence kept like the other
# runs'.
#
#   scripts/run-openbao.sh
#
# It writes each node's configuration and starts compose.openbao.yaml: an
# OpenBao 2.7 and a Vault 2.2 Raft cluster of three. On each: initialized
# (three key shares, two needed) and unsealed; a policy that may read
# sys/metrics, and a token with it alone, as packs/openbao/README.md says;
# userpass, with logins that work, logins with a wrong password, and a
# user locked out by them; tokens with leases. Every job is run against the
# active node and a standby, and what each reads is checked. Then a node is
# restarted (sealed: the cluster unhealthy, the node named), and unsealed a
# key at a time; the active node is stopped (another takes over); a token
# that may not read the metrics, none at all, a Vault standby that sends
# its metrics to the active node, and nothing listening. Then
# tests/integration/service-packs.sh runs the pack through Vigil, against
# both. The keys and tokens are made here, into this run's own folder, and
# kept out of the evidence. VIGIL_IT_OPENBAO_HOLD (below) keeps the
# clusters up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: OpenBao and Vault run in containers'
for p in curl jq; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.openbao.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-openbao-it.XXXXXX") || exit 1
chmod 700 "$work"
root=$work/none
export OPENBAO_CONF=$work/conf
mkdir -p "$OPENBAO_CONF"
dc() { docker compose -p vigil-openbao --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
# The keys and tokens, each made here: none is printed, and the evidence
# leaves out any file that holds one.
secrets() {
    local f
    for f in "$work"/secret.*; do
        [ -f "$f" ] || continue
        case $f in
            */secret.init-*) jq -r '.keys[]?, .keys_base64[]?, .root_token?' "$f" 2> /dev/null ;;
            *) cat "$f" ;;
        esac
    done
}
trap 'dc down -v > /dev/null 2>&1; evidence_save $(secrets); rm -rf "$work"' EXIT

# Each node's configuration: Raft storage that joins the others, a listener
# on 8200 (v2 lets anyone read its metrics), Prometheus telemetry kept 24h.
for n in o1 o2 o3 v1 v2 v3; do
    p=${n%?}
    data=/tmp/raft
    [ "$p" = v ] && data=/vault/file
    open=''
    [ "$n" = v2 ] && open='  telemetry {
    unauthenticated_metrics_access = true
  }'
    cat > "$OPENBAO_CONF/$n.hcl" << EOF
storage "raft" {
  path    = "$data"
  node_id = "$n"
  retry_join { leader_api_addr = "http://${p}1:8200" }
  retry_join { leader_api_addr = "http://${p}2:8200" }
  retry_join { leader_api_addr = "http://${p}3:8200" }
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
$open
}
api_addr      = "http://$n:8200"
cluster_addr  = "http://$n:8201"
disable_mlock = true
telemetry {
  prometheus_retention_time = "24h"
  disable_hostname          = true
}
EOF
done
chmod 644 "$OPENBAO_CONF"/*.hcl
evidence_start pack-openbao "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/openbao/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/openbao/macos

port() { case $1 in o1) echo 18301 ;; o2) echo 18302 ;; o3) echo 18303 ;; v1) echo 18201 ;; v2) echo 18202 ;; v3) echo 18203 ;; esac; }
url() { echo "http://127.0.0.1:$(port "$1")"; }
# api <node> <method> <path> [<json>]: with the cluster's root token, given
# to curl on its standard input, never on a command line.
api() {
    local n=$1 m=$2 path=$3 body=${4-}
    printf 'header = "X-Vault-Token: %s"\n' "$(cat "$work/secret.root-${n%?}")" |
        curl -s -K - -X "$m" "$(url "$n")$path" ${body:+-d "$body"}
}
sealed() { [ "$(curl -s "$(url "$1")/v1/sys/seal-status" | jq -r .sealed)" = true ]; }
unseal() {
    local n=$1 k
    for k in 0 1; do
        curl -s -X PUT "$(url "$n")/v1/sys/unseal" -d "{\"key\":\"$(jq -r ".keys[$k]" "$work/secret.init-${n%?}")\"}" > /dev/null
    done
}
say() { printf '\n# %s\n' "$*"; }

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'OpenBao and Vault would not start'; }
for n in o1 o2 o3 v1 v2 v3; do
    for _ in $(seq 1 60); do curl -s -o /dev/null "$(url "$n")/v1/sys/seal-status" && break; sleep 1; done
done
printf 'servers  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say "Each cluster initialized and unsealed; a token that may read the metrics, and logins."
for p in o v; do
    (umask 077 && curl -sf -X PUT "$(url "${p}1")/v1/sys/init" -d '{"secret_shares":3,"secret_threshold":2}' > "$work/secret.init-$p") ||
        die "${p}1 would not initialize"
    (umask 077 && jq -r .root_token "$work/secret.init-$p" > "$work/secret.root-$p")
    for n in "${p}1" "${p}2" "${p}3"; do
        for _ in $(seq 1 30); do unseal "$n"; sealed "$n" || break; sleep 2; done
        sealed "$n" && die "$n would not unseal"
    done
    for _ in $(seq 1 30); do [ "$(curl -s "$(url "${p}1")/v1/sys/leader" | jq -r .is_self)" = true ] && break; sleep 1; done
    # The pack's token, as packs/openbao/README.md says: sys/metrics, read, and
    # nothing else; an orphan that renews by period, never expires by TTL.
    api "${p}1" PUT /v1/sys/policies/acl/vigil-metrics '{"policy":"path \"sys/metrics\" { capabilities = [\"read\"] }"}' > /dev/null
    (umask 077 && api "${p}1" POST /v1/auth/token/create-orphan \
        '{"policies":["vigil-metrics"],"no_default_policy":true,"period":"768h","display_name":"vigil"}' | jq -r .auth.client_token > "$work/secret.token-$p")
    # A token that may not read them.
    (umask 077 && api "${p}1" POST /v1/auth/token/create-orphan '{"policies":["default"],"ttl":"1h"}' | jq -r .auth.client_token > "$work/secret.other-$p")
    api "${p}1" POST /v1/sys/auth/userpass '{"type":"userpass"}' > /dev/null
    api "${p}1" POST /v1/auth/userpass/users/app '{"password":"app-password","token_ttl":"1h"}' > /dev/null
    api "${p}1" POST /v1/auth/userpass/users/guessed '{"password":"guessed-password","token_ttl":"1h"}' > /dev/null
    ok=0 bad=0
    for _ in 1 2 3 4 5; do [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$(url "${p}1")/v1/auth/userpass/login/app" -d '{"password":"app-password"}')" = 200 ] && ok=$((ok + 1)); done
    for _ in 1 2 3; do curl -s -o /dev/null -X POST "$(url "${p}1")/v1/auth/userpass/login/app" -d '{"password":"wrong"}'; bad=$((bad + 1)); done
    codes=''
    for _ in 1 2 3 4 5 6 7; do codes="$codes $(curl -s -o /dev/null -w '%{http_code}' -X POST "$(url "${p}1")/v1/auth/userpass/login/guessed" -d '{"password":"wrong"}')"; bad=$((bad + 1)); done
    # Tokens with leases, as an application that logs in again and again.
    for _ in $(seq 1 20); do api "${p}1" POST /v1/auth/token/create '{"ttl":"2h","policies":["default"]}' > /dev/null; done
    printf '%s        %s: initialized, 3 key shares, 2 needed; unsealed; a metrics token; %d logins, %d with a wrong password (the user guessed answered:%s); 20 tokens of 2 h\n' \
        "$p" "$([ "$p" = o ] && echo OpenBao || echo Vault)" "$ok" "$bad" "$codes"
done

# The users locked out are counted every 15 minutes or so: read at the end.
locked_at=$(date +%s)

pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ OPENBAO_URL=%s bash packs/openbao/linux/%s.sh%s\n' "$OPENBAO_URL" "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"; echo $?; }
use() { export OPENBAO_URL; OPENBAO_URL=$(url "$1"); OPENBAO_TOKEN=$(cat "$work/secret.token-${1%?}"); export OPENBAO_TOKEN; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/openbao/pack.config")

for p in o v; do
    P=$([ "$p" = o ] && echo OpenBao || echo Vault)
    say "$P, ${p}1, the active node: every job, as the pack's scripts print it."
    use "${p}1"
    for j in $jobs; do run "$j"; done
    say "$P, ${p}1: what they read."
    for j in $jobs; do check "${p}1: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
    check "${p}1: $P, initialized, unsealed, active, HA" "yes 1 0 1 1" "$(has status info "product=$([ "$p" = o ] && echo openbao || echo vault) ") $(val status initialized '') $(val status sealed '') $(val status active '') $(val status ha_enabled '')"
    check "${p}1: Shamir, 2 keys of 3, on Raft" 'yes 2 3' "$(has status info 'seal=shamir storage=raft') $(val status unseal_threshold '') $(val status unseal_shares '')"
    check "${p}1: autopilot healthy, three nodes, one may be lost" '1 3 0 1' "$(val storage autopilot_healthy '') $(val storage nodes '') $(val storage nodes_unhealthy '') $(val storage failure_tolerance '')"
    check "${p}1: storage reads and writes, timed" 'yes yes' "$(least storage storage_writes_count '' 1) $(has storage storage_write_avg_ms '')"
    check "${p}1: the leases, the logins' and the tokens'" yes "$(least leases leases '' 25)"
    check "${p}1: tokens created by userpass" yes "$(least leases tokens_created 'method=userpass' 5)"
    check "${p}1: logins: 5 that worked, 10 that failed" 'yes yes' "$(least requests logins_ok_count '' 5) $(least requests logins_failed_count '' 10)"
    if [ "$p" = v ]; then
        check 'v1: responses refused, and those of them 403 (the lockout)' 'yes yes' "$(least requests responses_4xx_count '' 10) $(least requests permission_denied_count '' 1)"
    fi
    say "$P, ${p}2, a standby."
    [ "$p" = o ] && use o2 || use v2
    run status
    run storage
    check "${p}2: a standby, unsealed, the leader known" '1 0 0 1' "$(val status standby '') $(val status sealed '') $(val status active '') $(val status leader_known '')"
    check "${p}2: its own metrics read, as a standby" '1 0' "$(val storage up '') $(val storage active '')"
done

say "Vault, v3: a standby whose metrics are sent to the active node."
use v3
run storage 'v3, without unauthenticated_metrics_access'
check 'v3: the run fails, saying HTTP 307' '1 yes' "$(tail -n 1 "$work/storage.err" | awk '{ print $2 }') $(grep -q 'HTTP 307' "$work/storage.err" && echo yes || echo no)"

for p in o v; do
    P=$([ "$p" = o ] && echo OpenBao || echo Vault)
    say "$P: ${p}3 restarts, and comes back sealed."
    dc restart "${p}3" > /dev/null 2>&1
    for _ in $(seq 1 30); do curl -s -o /dev/null "$(url "${p}3")/v1/sys/seal-status" && break; sleep 1; done
    use "${p}3"
    run status "${p}3 sealed"
    check "${p}3: sealed, its unseal not begun" '1 1 0' "$(val status up '') $(val status sealed '') $(val status unseal_progress '')"
    check "${p}3: its metrics jobs read nothing, sealed" '0 0' "$(quiet storage) $(val storage up '')"
    use "${p}1"
    for _ in $(seq 1 30); do quiet storage > /dev/null; [ "$(val storage nodes_unhealthy '')" = 1 ] && break; sleep 2; done
    run storage "${p}3 sealed"
    check "${p}1: autopilot unhealthy, ${p}3 named, nothing more may be lost" "0 1 1 0" "$(val storage autopilot_healthy '') $(val storage nodes_unhealthy '') $(val storage node_unhealthy "node=${p}3") $(val storage failure_tolerance '')"
    curl -s -X PUT "$(url "${p}3")/v1/sys/unseal" -d "{\"key\":\"$(jq -r '.keys[0]' "$work/secret.init-$p")\"}" > /dev/null
    use "${p}3"
    run status "${p}3, one key of two given"
    check "${p}3: still sealed, one key of two given" '1 1' "$(val status sealed '') $(val status unseal_progress '')"
    curl -s -X PUT "$(url "${p}3")/v1/sys/unseal" -d "{\"key\":\"$(jq -r '.keys[1]' "$work/secret.init-$p")\"}" > /dev/null
    for _ in $(seq 1 30); do quiet status > /dev/null; [ "$(val status leader_known '')" = 1 ] && break; sleep 1; done
    check "${p}3: unsealed, a standby again" '0 1' "$(val status sealed '') $(val status standby '')"

    say "$P: the active node, ${p}1, stops; another takes over."
    dc stop "${p}1" > /dev/null 2>&1
    new=''
    for _ in $(seq 1 60); do
        for n in "${p}2" "${p}3"; do use "$n"; quiet status > /dev/null; [ "$(val status active '')" = 1 ] && new=$n; done
        [ -n "$new" ] && break
        sleep 1
    done
    use "${new:-${p}2}"
    run status "${p}1 stopped"
    check "$P: a new active node, ${new:-none}" '1 1' "$(val status active '') $(val status leader_known '')"
    dc start "${p}1" > /dev/null 2>&1
    for _ in $(seq 1 30); do curl -s -o /dev/null "$(url "${p}1")/v1/sys/seal-status" && break; sleep 1; done
    unseal "${p}1"
done

say "The users locked out, counted (every 15 minutes or so) on each active node."
for p in o v; do
    act=''
    for n in "${p}1" "${p}2" "${p}3"; do [ "$(curl -s "$(url "$n")/v1/sys/leader" | jq -r .is_self 2> /dev/null)" = true ] && act=$n; done
    use "${act:-${p}1}"
    while :; do
        quiet requests > /dev/null
        [ "$(val requests locked_users '')" = 1 ] && break
        [ "$(date +%s)" -lt $((locked_at + 1200)) ] || break
        sleep 30
    done
    run requests "$act, $(( ($(date +%s) - locked_at) / 60 )) minutes after the lockout"
    check "$act: the user locked out" 1 "$(val requests locked_users '')"
done

say "Tokens, and nothing listening."
use o2
OPENBAO_TOKEN=$(cat "$work/secret.other-o") bash "$pack/storage.sh" > "$work/other.out" 2>&1
check 'a token without the policy: the run fails, saying the login may not read it' '1 yes' "$? $(grep -q 'may not read it' "$work/other.out" && echo yes || echo no)"
sed 's/^/        /' "$work/other.out"
OPENBAO_TOKEN='' bash "$pack/storage.sh" > "$work/none.out" 2>&1
check 'no token: the same' '1 yes' "$? $(grep -q 'HTTP 403' "$work/none.out" && echo yes || echo no)"
OPENBAO_URL=http://127.0.0.1:18399 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: up 0, the run succeeding' '0 metric up 0' "$? $(cat "$work/down.out")"

say "The pack through Vigil, against OpenBao's o2 (and, for up 0, a port nothing listens on)."
export VIGIL_IT_OBS_OPENBAO="OPENBAO_URL=$(url o2)" VIGIL_IT_OBS_OPENBAO_DOWN=OPENBAO_URL=http://127.0.0.1:18399
export VIGIL_IT_OBS_OPENBAO_TOKEN; VIGIL_IT_OBS_OPENBAO_TOKEN=$(cat "$work/secret.token-o")
unset OPENBAO_URL OPENBAO_TOKEN
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_OPENBAO_HOLD=<file>: the clusters stay up, the metrics tokens in
# <file>.d/ (this account's alone), for the tests of other machines, until
# <file> is deleted.
if [ -n "${VIGIL_IT_OPENBAO_HOLD-}" ]; then
    (umask 077 && mkdir -p "$VIGIL_IT_OPENBAO_HOLD.d" && cp "$work/secret.token-o" "$work/secret.token-v" "$VIGIL_IT_OPENBAO_HOLD.d/")
    : > "$VIGIL_IT_OPENBAO_HOLD"
    printf 'hold     the clusters stay up (OpenBao 18301-18303, Vault 18201-18203) until %s is deleted\n' "$VIGIL_IT_OPENBAO_HOLD"
    while [ -e "$VIGIL_IT_OPENBAO_HOLD" ]; do sleep 5; done
    rm -rf "$VIGIL_IT_OPENBAO_HOLD.d"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
