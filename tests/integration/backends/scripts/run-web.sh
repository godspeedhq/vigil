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
# run-web.sh - the web packs (nginx, httpd, caddy, haproxy, phpfpm) against
# real servers with trouble on purpose, with its evidence kept like the
# other runs'.
#
#   scripts/run-web.sh
#
# It copies configs/services/web into this run's own folder, makes its
# certificates (a CA; one it signed that expires in five days, one that
# expired, one for HAProxy; one no CA signed), and starts compose.web.yaml:
# nginx 1.30.8 and 1.31.10, httpd 2.4.71 (event and prefork), Caddy 2.11.9,
# HAProxy 3.4.8 and 3.2.27, PHP-FPM 8.6.0 and 8.3.37. Then, in one minute,
# it sends each server answers of every kind (200, 404, 403, 500, 502, 503,
# 504), slow PHP requests that fill PHP-FPM's two workers and HAProxy's
# queue; runs every job of every pack on the minute after, and checks what
# they read. Then the trouble one at a time: a configuration edited and not
# reloaded (nginx, httpd), then reloaded; a log this account may not read; a
# log that grows faster than the job reads; a configuration Caddy refuses;
# HAProxy's socket file through socat and through nc; servers that are down.
# Then tests/integration/service-packs.sh runs the packs through Vigil.
# VIGIL_IT_WEB_HOLD, at the end, keeps the servers up for other machines'
# tests.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: the servers run in containers'
for p in curl jq openssl socat nc; do command -v "$p" > /dev/null 2>&1 || die "$p not found: the packs (or these tests) need it"; done
file=compose.web.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-web-it.XXXXXX") || exit 1
root=$work/none
export VIGIL_WEB_DIR=$work/web
dc() { docker compose -p vigil-web --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
trap 'dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT
evidence_start pack-web "$bk_dir/$file" "$0" "$@"

# This run's copy of the configurations, its certificates, and the folders
# the servers write to.
cp -R "$bk_dir/configs/services/web" "$VIGIL_WEB_DIR"
mkdir -p "$VIGIL_WEB_DIR/certs" "$VIGIL_WEB_DIR/logs/nginx" "$VIGIL_WEB_DIR/logs/httpd" "$VIGIL_WEB_DIR/haproxy/run"
chmod 777 "$VIGIL_WEB_DIR/haproxy/run"
c=$VIGIL_WEB_DIR/certs
{
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=vigil web test CA' -keyout "$c/ca.key" -out "$c/ca.crt"
    sign() { # <name> <x509 dates...>
        local n=$1
        shift
        openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' -keyout "$c/$n.key" -out "$c/$n.csr"
        printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$c/san"
        openssl x509 -req -in "$c/$n.csr" -CA "$c/ca.crt" -CAkey "$c/ca.key" -CAcreateserial -extfile "$c/san" "$@" -out "$c/$n.crt"
    }
    sign soon -days 5
    sign good -days 300
    sign expired -not_before 20250101000000Z -not_after 20250201000000Z
    openssl req -x509 -newkey rsa:2048 -nodes -days 300 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' -keyout "$c/self.key" -out "$c/self.crt"
    cat "$c/good.crt" "$c/good.key" > "$c/haproxy.pem"
} > "$work/certs.log" 2>&1 || { cat "$work/certs.log"; die 'the certificates could not be made'; }
chmod 644 "$c"/*

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'the servers would not start'; }
for u in 18180/nginx_status 18181/nginx_status 18280/server-status 18281/server-status 18380/ 18480/; do
    # Any answer will do: Caddy may say 502 until its health checks have run.
    for _ in $(seq 1 60); do [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$u")" != 000 ] && break; sleep 1; done
    [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$u")" != 000 ] || { dc logs --tail 20; die "127.0.0.1:$u does not answer"; }
done
for _ in $(seq 1 30); do curl -sf -o /dev/null http://127.0.0.1:18219/config/ && break; sleep 1; done
printf 'web      %s\n' "$(dc ps --format '{{.Service}} {{.Image}}' | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

say() { printf '\n# %s\n' "$*"; }
pass=0 fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
# val <out> <metric> '' [<tags>]: the value of the first line with them.
# least and most <out> <metric> '' <bound> [<tags>]: yes, or no and the value.
val() { grep -E "^metric $2 [^ ]+( .*)?${4-}" "$work/$1.out" | head -n 1 | awk '{ print $3 }'; }
least() { awk -v v="$(val "$1" "$2" '' "${5-}")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 >= a) ? "yes" : "no [" v "]" }'; }
most() { awk -v v="$(val "$1" "$2" '' "${5-}")" -v a="$4" 'BEGIN { print (v ~ /^-?[0-9.]+$/ && v + 0 <= a) ? "yes" : "no [" v "]" }'; }
has() { grep -qE "^metric $2( |$).*${3-}" "$work/$1.out" && echo yes || echo no; }
# job <pack> <job> <out name> [VAR=value...]: run one job's script as the
# packs ship it, with the settings given, print what it printed.
job() {
    local p=$1 j=$2 o=$3
    shift 3
    printf '\n$ %sbash packs/%s/linux/%s.sh\n' "$(for e in "$@"; do printf '%s ' "${e%%=*}=..."; done)" "$p" "$j"
    env "$@" bash "$bk_repo/packs/$p/linux/$j.sh" > "$work/$o.out" 2> "$work/$o.err"
    echo $? > "$work/$o.rc"
    cat "$work/$o.out"
    [ -s "$work/$o.err" ] && sed 's/^/  stderr: /' "$work/$o.err"
    return 0
}
rc() { cat "$work/$1.rc"; }
code() { curl -s -o /dev/null -m 30 -w '%{http_code}' "$@"; }

# The minute of traffic. It starts at second 2 of a minute, so the logs'
# last whole minute holds all of it when the jobs run on the next.
say 'One minute of traffic, of every kind.'
while [ $(( $(date +%s) % 60 )) -ne 2 ]; do sleep 1; done
minute_start=$(date +%s)
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:18180/; curl -s -o /dev/null http://127.0.0.1:18280/; done
for i in $(seq 1 10); do curl -s -o /dev/null http://127.0.0.1:18180/missing; curl -s -o /dev/null http://127.0.0.1:18280/missing; done
for i in $(seq 1 5); do curl -s -o /dev/null -X POST -d x=1 http://127.0.0.1:18180/php/ok.php; curl -s -o /dev/null -I http://127.0.0.1:18180/; done
for i in $(seq 1 4); do curl -s -o /dev/null http://127.0.0.1:18180/php/fail.php; curl -s -o /dev/null http://127.0.0.1:18280/php/fail.php; done
for i in 1 2 3; do curl -s -o /dev/null http://127.0.0.1:18180/refused/; done
for i in 1 2; do curl -s -o /dev/null http://127.0.0.1:18180/noanswer/; done
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:18380/; done
for i in 1 2 3; do curl -s -o /dev/null -m 5 http://127.0.0.1:18380/noanswer; done
for i in 1 2; do curl -s -o /dev/null -k --resolve shop.test:18343:127.0.0.1 https://shop.test:18343/boom; done
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:18480/; curl -s -o /dev/null -k https://127.0.0.1:18443/; done
for i in 1 2 3; do curl -s -o /dev/null http://127.0.0.1:18480/admin; curl -s -o /dev/null http://127.0.0.1:18480/dead; done
for i in $(seq 1 5); do curl -s -o /dev/null http://127.0.0.1:18481/; done
printf '  sent: nginx %s %s %s %s %s; httpd %s %s; caddy %s %s; haproxy %s %s %s\n' \
    "$(code http://127.0.0.1:18180/)" "$(code http://127.0.0.1:18180/missing)" "$(code http://127.0.0.1:18180/php/fail.php)" \
    "$(code http://127.0.0.1:18180/refused/)" "$(code http://127.0.0.1:18180/noanswer/)" \
    "$(code http://127.0.0.1:18280/)" "$(code http://127.0.0.1:18280/php/fail.php)" \
    "$(code http://127.0.0.1:18380/)" "$(code -m 5 http://127.0.0.1:18380/noanswer)" \
    "$(code http://127.0.0.1:18480/)" "$(code http://127.0.0.1:18480/admin)" "$(code http://127.0.0.1:18480/dead)"
# Slow PHP: through nginx, more than PHP 8.6's two workers (its queue, and
# its status page waiting with them); through httpd, fewer than PHP 8.3's
# five (httpd's workers busy, and PHP-FPM's page still answering). They run
# past the minute, so the jobs see them in flight: they start at second 50.
while [ "$(date +%s)" -lt $((minute_start + 48)) ]; do sleep 1; done
for i in $(seq 1 4); do curl -s -o /dev/null -m 150 "http://127.0.0.1:18180/php/slow.php?s=30" & done
for i in $(seq 1 3); do curl -s -o /dev/null -m 150 "http://127.0.0.1:18280/php/slow.php?s=40" & done
while [ "$(date +%s)" -lt $((minute_start + 60)) ]; do sleep 1; done
sleep 3

nginx_pid=$(docker inspect -f '{{.State.Pid}}' vigil-web-nginx-1)
echo "$nginx_pid" > "$work/nginx.pid"
docker inspect -f '{{.State.Pid}}' vigil-web-httpd-1 > "$work/httpd.pid"
NG=(NGINX_STATUS_URL=http://127.0.0.1:18180/nginx_status NGINX_PID_FILE="$work/nginx.pid" NGINX_CONF="$VIGIL_WEB_DIR/nginx/nginx.conf"
    NGINX_ACCESS_LOG="$VIGIL_WEB_DIR/logs/nginx/access.log" NGINX_TLS="localhost:18143 localhost:18144 127.0.0.1:18199" NGINX_CACERT="$c/ca.crt")
HT=(HTTPD_STATUS_URL=http://127.0.0.1:18280/server-status HTTPD_CONF="$VIGIL_WEB_DIR/httpd/vigil.conf" HTTPD_PID_FILE="$work/httpd.pid"
    HTTPD_ACCESS_LOG="$VIGIL_WEB_DIR/logs/httpd/vigil_access.log" HTTPD_TLS="localhost:18243 localhost:18143" HTTPD_CACERT="$c/ca.crt")
CA=(CADDY_ADMIN=http://127.0.0.1:18219 CADDY_TLS_ADDRESS=127.0.0.1:18343)
HA=(HAPROXY_SOCKET=127.0.0.1:18499)
PF=(PHPFPM_STATUS_URLS="http://127.0.0.1:18280/fpm-status http://127.0.0.1:18280/fpm-status-api http://127.0.0.1:18199/fpm-status")

say 'nginx 1.30.8: every job, as the pack ships it.'
job nginx status ng-status "${NG[@]}"
job nginx server ng-server "${NG[@]}"
job nginx log ng-log "${NG[@]}"
job nginx tls ng-tls "${NG[@]}"
for j in status server log tls; do check "nginx: $j runs" 0 "$(rc ng-$j)"; done
check 'nginx: up' 1 "$(val ng-status up)"
check 'nginx: connections, the slow ones too' yes "$(least ng-status active_connections '' 3)"
check 'nginx: its master runs' 1 "$(val ng-server running)"
check 'nginx: two workers, as configured' 2 "$(val ng-server workers)"
check 'nginx: worker_connections read' 64 "$(val ng-server worker_connections)"
check 'nginx: how full, from both' yes "$(least ng-server connections_capacity_pct '' 2)"
check 'nginx: no edit waiting' 0 "$(val ng-server config_changed)"
check 'nginx: a worker may open files' yes "$(least ng-server worker_open_files_limit '' 1)"
check 'nginx: the whole minute read' 1 "$(val ng-log window_complete)"
check 'nginx: requests logged' yes "$(least ng-log requests '' 70)"
check 'nginx: 404s' yes "$(least ng-log status '' 10 'code=404')"
check 'nginx: 500s from PHP' yes "$(least ng-log status '' 4 'code=500')"
check 'nginx: 502s, nothing listening' yes "$(least ng-log status '' 3 'code=502')"
check 'nginx: 504s, no answer' yes "$(least ng-log status '' 2 'code=504')"
check 'nginx: the 5xx share' yes "$(least ng-log errors_5xx_pct '' 5)"
check 'nginx: POST and HEAD apart' yes "$( [ "$(has ng-log method method=POST)$(has ng-log method method=HEAD)" = yesyes ] && echo yes || echo no)"
check 'nginx: response times, from rt=' yes "$(has ng-log response_p99_ms)"
check 'nginx: upstream times, from urt=' yes "$(has ng-log upstream_p99_ms)"
check 'nginx: the certificate, five days left' 4 "$(val ng-tls cert_expires_days '' 'endpoint=localhost:18143')"
check 'nginx: and it checks against the CA' 1 "$(val ng-tls cert_verified '' 'endpoint=localhost:18143')"
check 'nginx 1.31.10: an expired certificate' 0 "$(val ng-tls cert_valid '' 'endpoint=localhost:18144')"
check 'nginx: nothing answering TLS' 0 "$(val ng-tls tls_up '' 'endpoint=127.0.0.1:18199')"

say 'nginx 1.31.10: stub_status.'
job nginx status ng2-status NGINX_STATUS_URL=http://127.0.0.1:18181/nginx_status
check 'nginx 1.31.10: up' 1 "$(val ng2-status up)"

say 'httpd 2.4.71: every job, as the pack ships it.'
job httpd status ht-status "${HT[@]}"
job httpd log ht-log "${HT[@]}"
job httpd tls ht-tls "${HT[@]}"
for j in status log tls; do check "httpd: $j runs" 0 "$(rc ht-$j)"; done
check 'httpd: up' 1 "$(val ht-status up)"
check 'httpd: the event MPM' yes "$(has ht-status info 'mpm=event')"
check 'httpd: ExtendedStatus on' 1 "$(val ht-status extended_status)"
check 'httpd: its scoreboard' yes "$(least ht-status scoreboard_slots '' 20)"
check 'httpd: busy with the slow requests' yes "$(least ht-status busy_workers '' 3)"
check 'httpd: workers sending a reply' yes "$(least ht-status workers_in_state '' 1 'state=sending')"
check 'httpd: the TLS session cache' yes "$(has ht-status ssl_cache_entries)"
check 'httpd: no edit waiting' 0 "$(val ht-status config_changed)"
check 'httpd: requests logged' yes "$(least ht-log requests '' 50)"
check 'httpd: 500s from PHP' yes "$(least ht-log status '' 4 'code=500')"
check 'httpd: response times, from rtus=' yes "$(has ht-log response_p99_ms)"
check 'httpd: a certificate no CA signed' 0 "$(val ht-tls cert_verified '' 'endpoint=localhost:18243')"
check 'httpd: and why' yes "$(has ht-tls cert_verified 'endpoint=localhost:18243 reason=self.signed')"

say 'httpd 2.4.71, prefork.'
job httpd status ht2-status HTTPD_STATUS_URL=http://127.0.0.1:18281/server-status
check 'httpd: the prefork MPM' yes "$(has ht2-status info 'mpm=prefork')"
check 'httpd prefork: its workers' yes "$(least ht2-status idle_workers '' 1)"

say 'PHP-FPM 8.3.37: two pools with room, while slow requests run; and one that does not answer.'
job phpfpm pools pf-pools "${PF[@]}"
check 'phpfpm: pools runs' 0 "$(rc pf-pools)"
check 'phpfpm: two pools answer' 2 "$(grep -c '^metric up 1 ' "$work/pf-pools.out")"
check 'phpfpm: where nothing listens, no time out' 0 "$(val pf-pools timed_out '' 'url=http://127.0.0.1:18199')"
check 'phpfpm: requests running for seconds' yes "$(least pf-pools longest_request_ms '' 1000 'pool=www')"
check 'phpfpm: workers running them' yes "$(least pf-pools processes_in_state '' 3 'pool=www state=Running')"
check 'phpfpm: the static pool' yes "$(has pf-pools info 'pool=api pm=static')"

say 'PHP-FPM 8.6.0 with every worker busy: its status page waits with the requests.'
for i in 1 2 3; do curl -s -o /dev/null -m 90 "http://127.0.0.1:18180/php/slow.php?s=25" & done
sleep 2
job phpfpm pools pf-full PHPFPM_STATUS_URLS=http://127.0.0.1:18180/fpm-status
check 'phpfpm: the full pool runs' 0 "$(rc pf-full)"
check 'phpfpm: its page does not answer in time' 1 "$(val pf-full timed_out)"
check 'phpfpm: and reads as up 0' 0 "$(val pf-full up)"

say 'Caddy 2.11.9: every job, as the pack ships it.'
job caddy status ca-status "${CA[@]}"
job caddy traffic ca-traffic "${CA[@]}"
job caddy upstreams ca-upstreams "${CA[@]}"
job caddy tls ca-tls "${CA[@]}"
for j in status traffic upstreams tls; do check "caddy: $j runs" 0 "$(rc ca-$j)"; done
check 'caddy: up' 1 "$(val ca-status up)"
check 'caddy: two servers' 2 "$(val ca-status servers)"
check 'caddy: its reverse proxies' 3 "$(val ca-status reverse_proxies)"
check 'caddy: its configuration loaded' 1 "$(val ca-status reload_ok)"
check 'caddy: its HTTP metrics on' 1 "$(val ca-traffic metrics_enabled)"
check 'caddy: requests counted' yes "$(least ca-traffic requests_count '' 20 'server=srv1')"
check 'caddy: 5xx counted' yes "$(least ca-traffic status_5xx_count '' 2 'server=srv1')"
check 'caddy: an upstream that does not exist, unhealthy' 0 "$(val ca-upstreams healthy '' 'upstream=gone:80')"
check 'caddy: the healthy ones' 1 "$(val ca-upstreams healthy '' 'upstream=nginx:80')"
check 'caddy: one site found' 1 "$(val ca-tls sites_found)"
check "caddy: its certificate, from its own CA, checks" 1 "$(val ca-tls cert_verified '' 'endpoint=127.0.0.1:18343/shop.test')"

say 'HAProxy 3.4.8: every job, as the pack ships it, with four slow requests for a backend that takes one at a time.'
for i in $(seq 1 4); do curl -s -o /dev/null -m 150 "http://127.0.0.1:18480/php/slow.php?s=30" & done
sleep 3
job haproxy info hp-info "${HA[@]}"
job haproxy frontends hp-frontends "${HA[@]}"
job haproxy backends hp-backends "${HA[@]}"
job haproxy servers hp-servers "${HA[@]}"
for j in info frontends backends servers; do check "haproxy: $j runs" 0 "$(rc hp-$j)"; done
check 'haproxy: up' 1 "$(val hp-info up)"
check 'haproxy: 3.4.8' yes "$(has hp-info info 'version=3.4.8')"
check 'haproxy: maxconn read' 200 "$(val hp-info maxconn)"
check 'haproxy: TLS connections counted' yes "$(has hp-info ssl_rate)"
check 'haproxy: requests denied' yes "$(least hp-frontends denied_requests_count '' 3 'frontend=fe_web')"
check 'haproxy: 5xx from the dead backend' yes "$(least hp-frontends status_5xx_count '' 3 'frontend=fe_web')"
check 'haproxy: a backend down' 0 "$(val hp-backends backend_up '' 'backend=be_dead')"
check 'haproxy: and counted' yes "$(least hp-backends backends_down '' 2)"
check 'haproxy: a queue' yes "$(least hp-backends queue '' 1 'backend=be_queue')"
check 'haproxy: a server in maintenance' 2 "$(val hp-servers state '' 'backend=be_web server=spare')"
check 'haproxy: a server that refuses, down' 3 "$(val hp-servers state '' 'backend=be_dead server=refused')"
check 'haproxy: and its check' yes "$(has hp-servers check 'backend=be_dead server=refused check=L4CON')"
check 'haproxy: a check that gets a 404' yes "$(has hp-servers check 'backend=be_badcheck server=nginx check=L7STS code=404')"
check 'haproxy: a server not checked' 4 "$(val hp-servers state '' 'backend=be_queue server=nginx')"

say 'HAProxy 3.2.27.'
job haproxy info hp2-info HAPROXY_SOCKET=127.0.0.1:18498
job haproxy servers hp2-servers HAPROXY_SOCKET=127.0.0.1:18498
check 'haproxy 3.2.27: up' yes "$(has hp2-info info 'version=3.2.27')"
check 'haproxy 3.2.27: a server down' 3 "$(val hp2-servers state '' 'backend=be_web server=gone')"

say 'HAProxy through its socket file: socat, then nc.'
job haproxy info hp-socat HAPROXY_SOCKET="$VIGIL_WEB_DIR/haproxy/run/api.sock"
check 'haproxy: the socket file, through socat' 1 "$(val hp-socat up)"
mkdir -p "$work/nosocat"
for p in bash nc awk grep head cat date mktemp rm tr cut sed dirname wc; do ln -sf "$(command -v "$p")" "$work/nosocat/$p" 2> /dev/null; done
job haproxy info hp-nc PATH="$work/nosocat" HAPROXY_SOCKET="$VIGIL_WEB_DIR/haproxy/run/api.sock"
check 'haproxy: the socket file, through nc' 1 "$(val hp-nc up)"

say 'nginx: a configuration edited, then reloaded while a slow request runs.'
touch "$VIGIL_WEB_DIR/nginx/conf.d/default.conf"
job nginx server ng-edited "${NG[@]}"
check 'nginx: the edit seen' 1 "$(val ng-edited config_changed)"
curl -s -o /dev/null -m 120 "http://127.0.0.1:18180/php/slow.php?s=20" &
sleep 2
docker exec vigil-web-nginx-1 nginx -s reload
sleep 3
job nginx server ng-reloaded "${NG[@]}"
check 'nginx: reloaded, nothing waiting' 0 "$(val ng-reloaded config_changed)"
check 'nginx: the old worker finishing' yes "$(least ng-reloaded workers_shutting_down '' 1)"
check 'nginx: reloaded seconds ago' yes "$(most ng-reloaded last_reload_seconds '' 30)"

say 'httpd: a configuration edited, then a graceful restart.'
sleep 2
touch "$VIGIL_WEB_DIR/httpd/vigil.conf"
job httpd status ht-edited "${HT[@]}"
check 'httpd: the edit seen' 1 "$(val ht-edited config_changed)"
docker exec vigil-web-httpd-1 httpd -k graceful
sleep 5
job httpd status ht-graceful "${HT[@]}"
check 'httpd: restarted once' 1 "$(val ht-graceful restarts)"
check 'httpd: nothing waiting' 0 "$(val ht-graceful config_changed)"

say 'Logs: one this account may not read, and one that grows faster than the job reads.'
cp "$VIGIL_WEB_DIR/logs/nginx/access.log" "$work/locked.log"
chmod 000 "$work/locked.log"
job nginx log ng-locked NGINX_ACCESS_LOG="$work/locked.log"
check 'nginx: a log it may not read still runs' 0 "$(rc ng-locked)"
check 'nginx: and says so' 0 "$(val ng-locked log_readable)"
job nginx log ng-nolog NGINX_ACCESS_LOG="$work/none.log"
check 'nginx: no log at all' 0 "$(val ng-nolog log_found)"
stamp=$(date -d "@$(( ($(date +%s) / 60 - 1) * 60 ))" '+%d/%b/%Y:%H:%M')
awk -v s="$stamp" 'BEGIN { for (i = 0; i < 40000; i++) printf "10.0.0.%d - - [%s:%02d +0000] \"GET /x HTTP/1.1\" 200 512 \"-\" \"load\" rt=0.002 urt=0.001\n", i % 250, s, i % 60 }' > "$work/busy.log"
job nginx log ng-busy NGINX_ACCESS_LOG="$work/busy.log" NGINX_LOG_MAX_MB=1
check 'nginx: a log that grew past the limit' 0 "$(val ng-busy window_complete)"
check 'nginx: its end counted' yes "$(least ng-busy requests '' 5000)"

say 'Caddy: a configuration it refuses.'
curl -s -o /dev/null -w '  POST /load: HTTP %{http_code}\n' -H 'Content-Type: application/json' -d '{"admin":{"listen":"0.0.0.0:2019"},"apps":{"http":{"servers":{"x":{"listen":["not an address"]}}}}}' http://127.0.0.1:18219/load
job caddy status ca-refused "${CA[@]}"
check 'caddy: the refused change seen' 0 "$(val ca-refused reload_ok)"
check 'caddy: still serving the old one' 2 "$(val ca-refused servers)"

say "Every job again, on Debian 13 with Debian's own awk (mawk), as on Debian and Ubuntu."
# The same scripts and settings, in a container sharing this machine's
# network and processes; the work folder at the same path.
cat > "$work/mawk.sh" <<EOF
apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq curl jq openssl procps socat > /dev/null 2>&1 || { echo 'apt failed'; exit 1; }
printf 'awk      %s\n' "\$(awk -W version 2>&1 | head -n 1)"
run() { local p=\$1 j=\$2; shift 2; printf '\n\$ bash packs/%s/linux/%s.sh (mawk)\n' "\$p" "\$j"; env "\$@" bash "/packs/\$p/linux/\$j.sh" > "$work/mawk-\$p-\$j.out" 2>&1; echo "rc \$?" >> "$work/mawk-\$p-\$j.out"; cat "$work/mawk-\$p-\$j.out"; }
for j in status server log tls; do run nginx \$j $(printf '%q ' "${NG[@]}"); done
for j in status log tls; do run httpd \$j $(printf '%q ' "${HT[@]}"); done
for j in status traffic upstreams tls; do run caddy \$j $(printf '%q ' "${CA[@]}"); done
for j in info frontends backends servers; do run haproxy \$j $(printf '%q ' "${HA[@]}"); done
run phpfpm pools $(printf '%q ' "${PF[@]}")
EOF
docker run --rm --network host --pid host -v "$bk_repo/packs:/packs:ro,z" -v "$work:$work:z" debian:13-slim bash "$work/mawk.sh" 2>&1 | grep -v '^debconf'
check 'mawk: Debian'"'"'s awk is mawk' yes "$(docker run --rm debian:13-slim awk -W version 2>&1 | head -n 1 | grep -q mawk && echo yes || echo no)"
check 'mawk: every job ran' 16 "$(cat "$work"/mawk-*.out 2> /dev/null | grep -c '^rc 0$')"
check 'mawk: no number in exponent form' '' "$(cat "$work"/mawk-*.out 2> /dev/null | grep -E '^metric [a-z_0-9]+ -?[0-9.]+e[+-]' | head -n 3)"
check 'mawk: haproxy servers read' "$(val hp-servers servers)" "$(grep '^metric servers ' "$work/mawk-haproxy-servers.out" | awk '{ print $3 }')"

say 'Servers that do not answer, and pages that are not theirs.'
job nginx status down-ng NGINX_STATUS_URL=http://127.0.0.1:1/nginx_status
job httpd status down-ht HTTPD_STATUS_URL=http://127.0.0.1:1/server-status
job caddy status down-ca CADDY_ADMIN=http://127.0.0.1:1
job haproxy info down-hp HAPROXY_SOCKET=127.0.0.1:1
job haproxy info down-hpf HAPROXY_SOCKET="$work/no.sock"
job nginx server down-ngs NGINX_PID_FILE="$work/no.pid"
for o in ng ht ca hp hpf; do check "down: $o still runs" 0 "$(rc down-$o)"; check "down: $o reads as up 0" 0 "$(val down-$o up)"; done
check 'down: nginx not running' 0 "$(val down-ngs running)"
job nginx status wrong-ng NGINX_STATUS_URL=http://127.0.0.1:18280/server-status?auto
check 'nginx: a page that is not stub_status fails the run' 1 "$(rc wrong-ng)"
job httpd status wrong-ht HTTPD_STATUS_URL=http://127.0.0.1:18180/nginx_status
check 'httpd: a page that is not server-status fails the run' 1 "$(rc wrong-ht)"

say 'PHP-FPM 8.6.0 once its slow requests are done: what the full pool went through.'
for _ in $(seq 1 60); do curl -sf -o /dev/null -m 5 http://127.0.0.1:18180/fpm-status && break; sleep 5; done
job phpfpm pools pf-after PHPFPM_STATUS_URLS=http://127.0.0.1:18180/fpm-status
check 'phpfpm: answers again' 1 "$(val pf-after up)"
check 'phpfpm: requests waited in its queue' yes "$(least pf-after listen_queue_max '' 1 'pool=www')"
check 'phpfpm: max_children reached' yes "$(least pf-after max_children_reached_count '' 1 'pool=www')"
check 'phpfpm: slow requests counted' yes "$(least pf-after slow_requests_count '' 1 'pool=www')"
check 'phpfpm: both workers were busy at once' 2 "$(val pf-after active_max '' 'pool=www')"

wait
printf '\n%d passed, %d failed\n' "$pass" "$fail"

say 'The packs through Vigil.'
export VIGIL_IT_WEB_NGINX="NGINX_STATUS_URL=http://127.0.0.1:18180/nginx_status|NGINX_PID_FILE=$work/nginx.pid|NGINX_CONF=$VIGIL_WEB_DIR/nginx/nginx.conf|NGINX_ACCESS_LOG=$VIGIL_WEB_DIR/logs/nginx/access.log|NGINX_TLS=localhost:18143 localhost:18144|NGINX_CACERT=$c/ca.crt"
export VIGIL_IT_WEB_NGINX_DOWN=NGINX_STATUS_URL=http://127.0.0.1:1/nginx_status
export VIGIL_IT_WEB_HTTPD="HTTPD_STATUS_URL=http://127.0.0.1:18280/server-status|HTTPD_CONF=$VIGIL_WEB_DIR/httpd/vigil.conf|HTTPD_ACCESS_LOG=$VIGIL_WEB_DIR/logs/httpd/vigil_access.log|HTTPD_TLS=localhost:18243|HTTPD_CACERT=$c/ca.crt"
export VIGIL_IT_WEB_HTTPD_DOWN=HTTPD_STATUS_URL=http://127.0.0.1:1/server-status
export VIGIL_IT_WEB_CADDY="CADDY_ADMIN=http://127.0.0.1:18219|CADDY_TLS_ADDRESS=127.0.0.1:18343"
export VIGIL_IT_WEB_CADDY_DOWN=CADDY_ADMIN=http://127.0.0.1:1
export VIGIL_IT_WEB_HAPROXY="HAPROXY_SOCKET=127.0.0.1:18499"
export VIGIL_IT_WEB_HAPROXY_DOWN=HAPROXY_SOCKET=127.0.0.1:1
export VIGIL_IT_WEB_PHPFPM="PHPFPM_STATUS_URLS=http://127.0.0.1:18180/fpm-status http://127.0.0.1:18280/fpm-status http://127.0.0.1:18280/fpm-status-api"
export VIGIL_IT_WEB_PHPFPM_DOWN=PHPFPM_STATUS_URLS=http://127.0.0.1:1/fpm-status
bash "$bk_repo/tests/integration/service-packs.sh"
rc=$?
# VIGIL_IT_WEB_HOLD=<file>: the servers stay up, for the tests of other
# machines (macOS, Windows), until <file> is deleted.
if [ -n "${VIGIL_IT_WEB_HOLD-}" ]; then
    cp "$c/ca.crt" "$VIGIL_IT_WEB_HOLD.ca.crt"
    : > "$VIGIL_IT_WEB_HOLD"
    printf 'hold     the servers stay up until %s is deleted\n' "$VIGIL_IT_WEB_HOLD"
    while [ -e "$VIGIL_IT_WEB_HOLD" ]; do sleep 5; done
    rm -f "$VIGIL_IT_WEB_HOLD.ca.crt"
fi
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
