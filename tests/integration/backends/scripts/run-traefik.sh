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
# run-traefik.sh - the traefik pack against real Traefik 3.8 and 3.7 with a
# configuration in trouble on purpose, with its evidence kept like the
# other runs'.
#
#   scripts/run-traefik.sh
#
# It writes a dynamic configuration and starts compose.traefik.yaml. In it:
# a service of three backends, one of them a host that does not exist (its
# health check fails); a service whose only backend is that host (it
# answers 5xx); a router to a service that is not there and one with a
# middleware that is not there (both in error); a certificate that expires
# in 5 days and one good for a year. Requests to each router, and to a host
# no router takes. Every job is run against each and what it reads is
# checked. Then a second backend stops (two of three down), the
# configuration changes (a reload counted), and nothing listens. Then
# tests/integration/service-packs.sh runs the pack through Vigil.
# VIGIL_IT_TRAEFIK_HOLD (below) keeps it up for other machines' tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: Traefik runs in containers'
for p in curl jq openssl; do command -v "$p" > /dev/null 2>&1 || die "$p not found"; done
file=compose.traefik.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-traefik-it.XXXXXX") || exit 1
root=$work/none
export TRAEFIK_DYN=$work/dyn TRAEFIK_CERTS=$work/certs
mkdir -p "$TRAEFIK_DYN" "$TRAEFIK_CERTS"
dc() { docker compose -p vigil-traefik --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
trap 'dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT

# The certificates: one that expires in 5 days, one good for a year.
for c in soon=5 good=365; do
    n=${c%=*}
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TRAEFIK_CERTS/$n.key" -out "$TRAEFIK_CERTS/$n.crt" -days "${c#*=}" \
        -subj "/CN=$n.example.test" -addext "subjectAltName=DNS:$n.example.test" > /dev/null 2>&1 || die "could not make $n's certificate"
done
chmod 755 "$TRAEFIK_DYN" "$TRAEFIK_CERTS"
chmod 644 "$TRAEFIK_CERTS"/*
dynamic() {
    cat << EOF
http:
  routers:
    app:
      rule: "Host(\`app.example.test\`)"
      entryPoints: [web]
      service: app
    gone:
      rule: "Host(\`gone.example.test\`)"
      entryPoints: [web]
      service: gone
    broken:
      rule: "Host(\`broken.example.test\`)"
      entryPoints: [web]
      service: not-there
    nomiddleware:
      rule: "Host(\`nomw.example.test\`)"
      entryPoints: [web]
      middlewares: [no-such-middleware]
      service: app
    soon:
      rule: "Host(\`soon.example.test\`)"
      entryPoints: [websecure]
      service: app
      tls: {}
    good:
      rule: "Host(\`good.example.test\`)"
      entryPoints: [websecure]
      service: app
      tls: {}
$1
  services:
    app:
      loadBalancer:
        healthCheck: {path: /health, interval: 3s, timeout: 2s}
        servers:
          - url: "http://w1:80"
          - url: "http://w2:80"
          - url: "http://nowhere:80"
    gone:
      loadBalancer:
        servers:
          - url: "http://nowhere:80"
tls:
  certificates:
    - {certFile: /certs/soon.crt, keyFile: /certs/soon.key}
    - {certFile: /certs/good.crt, keyFile: /certs/good.key}
EOF
}
dynamic '' > "$TRAEFIK_DYN/dyn.yml"
chmod 644 "$TRAEFIK_DYN/dyn.yml"
evidence_start pack-traefik "$bk_dir/$file" "$0" "$@"
pack=$bk_repo/packs/traefik/linux
[ "$(uname -s)" = Darwin ] && pack=$bk_repo/packs/traefik/macos

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'Traefik would not start'; }
for p in 18080 18090; do
    for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$p/ping" && break; sleep 1; done
    curl -sf -o /dev/null "http://127.0.0.1:$p/ping" || { dc logs --tail 20; die "Traefik on $p never answered"; }
done
printf 'traefik  %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
# Traffic: each router, a host no router takes, and the two TLS ones.
traffic() {
    local web=$1 tls=$2 i
    for i in $(seq 1 20); do
        for h in app gone broken nomw nothing; do curl -s -o /dev/null -H "Host: $h.example.test" "http://127.0.0.1:$web/"; done
    done
    for h in soon good; do curl -sk -o /dev/null --resolve "$h.example.test:$tls:127.0.0.1" "https://$h.example.test:$tls/"; done
}
sleep 8
traffic 18081 18443
traffic 18091 18453
echo 'config   services app (w1, w2, a host that does not exist) and gone (only that host); routers broken (no service) and nomiddleware (no middleware); certificates for 5 days and for a year'
echo 'traffic  20 requests to each router and to a host no router takes, on each Traefik; one to each TLS router'

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
val() { grep -E "^metric $2 [^ ]+( .*)?$3" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" "$3")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*$3" "$work/$1.out" && echo yes || echo no; }
run() {
    printf '\n$ TRAEFIK_URL=%s bash packs/traefik/linux/%s.sh%s\n' "$TRAEFIK_URL" "$1" "${2:+   ($2)}"
    bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
quiet() { bash "$pack/$1.sh" > "$work/$1.out" 2> "$work/$1.err"; }
jobs=$(sed -n 's/^\[job\.\(.*\)\]$/\1/p' "$bk_repo/packs/traefik/pack.config")

for t in 18080=3.8 18090=3.7; do
    v=${t#*=}
    export TRAEFIK_URL=http://127.0.0.1:${t%=*}
    say "Traefik $v: every job, as the pack's scripts print it."
    for j in $jobs; do run "$j"; done
    say "Traefik $v: what they read."
    for j in $jobs; do check "$v: $j runs" 'exit 0' "$(tail -n 1 "$work/$j.err")"; done
    check "$v: up, ping, its version" '1 1 yes' "$(val status up '') $(val status ping '') $(has config version "version=$v\.")"
    check "$v: requests; 404s for the host no router takes and the routers in error" 'yes yes' "$(least status requests_count '' 100) $(least status requests_4xx_count '' 60)"
    check "$v: 5xx, from the service with no backend" yes "$(least status requests_5xx_count '' 20)"
    check "$v: three backends health-checked, the one that does not exist down, named" '3 1 1' "$(val services servers '') $(val services servers_down '') $(val services server_down 'url=http://nowhere:80')"
    check "$v: the 5xx, by service and by router" 'yes yes' "$(least services requests_5xx 'service=gone@file' 20) $(least routers requests_5xx 'router=gone@file' 20)"
    check "$v: the two routers in error, each named, with why" '2 yes yes' "$(val config routers_errors 'protocol=http') $(has config router_error 'router=broken@file reason=the_service__not-there@file__does_not_exist') $(has config router_error 'router=nomiddleware@file reason=.*no-such-middleware')"
    check "$v: two certificates, the one for 5 days warned of" '2 1 1' "$(val config certificates '') $(val config certificates_warnings '') $(val config certs_expiring_30d '')"
    check "$v: the soonest expires in under 5 days" yes "$(awk -v d="$(val config cert_expires_days '')" 'BEGIN { print (d > 4 && d <= 5) ? "yes" : "no [" d "]" }')"
    check "$v: when it expires, by the metrics" yes "$(awk -v t="$(val status cert_expires_at '')" -v now="$(date +%s)" 'BEGIN { d = (t - now) / 86400; print (d > 4 && d <= 5) ? "yes" : "no [" d "]" }')"
done

say "A second backend, w2, stops: two of app's three are down."
dc stop w2 > /dev/null 2>&1
export TRAEFIK_URL=http://127.0.0.1:18080
for _ in $(seq 1 20); do quiet services; [ "$(val services servers_down '')" = 2 ] && break; sleep 1; done
run services 'w2 stopped'
check '3.8: two down, both named; app has two of three down' '2 1 2' "$(val services servers_down '') $(val services server_down 'url=http://w2:80') $(val services down_by_service 'service=app@file')"
dc start w2 > /dev/null 2>&1

say "The configuration changes: a router added; each Traefik loads it."
quiet status
before=$(val status reloads_count '')
dynamic '    added:
      rule: "Host(`added.example.test`)"
      entryPoints: [web]
      service: app' > "$work/dyn.new"
cat "$work/dyn.new" > "$TRAEFIK_DYN/dyn.yml"
for _ in $(seq 1 20); do quiet status; [ "$(val status reloads_count '')" -gt "$before" ] 2> /dev/null && break; sleep 1; done
run status 'the configuration changed'
check '3.8: the reload counted, a moment ago' "yes yes" "$(least status reloads_count '' $((before + 1))) $(awk -v s="$(val status last_reload_seconds '')" 'BEGIN { print (s < 30) ? "yes" : "no [" s "]" }')"

say "Nothing listening."
TRAEFIK_URL=http://127.0.0.1:18099 bash "$pack/status.sh" > "$work/down.out" 2>&1
check 'nothing listening: up 0, the run succeeding' '0 metric up 0' "$? $(cat "$work/down.out")"
TRAEFIK_URL=http://127.0.0.1:18099 bash "$pack/config.sh" > "$work/down2.out" 2>&1
check 'and the config job: up 0, the run succeeding' '0 metric up 0' "$? $(cat "$work/down2.out")"

say "The pack through Vigil, against 3.8 (and, for up 0, a port nothing listens on)."
export VIGIL_IT_OBS_TRAEFIK=TRAEFIK_URL=http://127.0.0.1:18080 VIGIL_IT_OBS_TRAEFIK_DOWN=TRAEFIK_URL=http://127.0.0.1:18099
unset TRAEFIK_URL
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_TRAEFIK_HOLD=<file>: Traefik stays up for the tests of other
# machines, until <file> is deleted.
if [ -n "${VIGIL_IT_TRAEFIK_HOLD-}" ]; then
    : > "$VIGIL_IT_TRAEFIK_HOLD"
    printf 'hold     Traefik stays up (3.8 on 18080, 3.7 on 18090) until %s is deleted\n' "$VIGIL_IT_TRAEFIK_HOLD"
    while [ -e "$VIGIL_IT_TRAEFIK_HOLD" ]; do sleep 5; done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
