# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The traefik pack's jobs (tools/obs/DESIGN.md)."""
from jobs import job, page, answers, table, code

PACK = dict(
    P='Traefik', E='TRAEFIK', url='http://localhost:8080', version='1.0.0',
    description='Traefik: up, its configuration reloads, connections and requests on each entrypoint, 4xx and 5xx; '
                'backend servers up and down (health checks), each named; services and routers answering 5xx; '
                'routers, services and middlewares in error, named; TLS certificates and the soonest to expire',
    works='Traefik 3.x, as a container, a Kubernetes ingress or a binary (tested: 3.8.0 and 3.7.20), with its '
          'Prometheus metrics and its API on the traefik entrypoint',
    head=['traefik - a Traefik proxy, from its own metrics page and its read-only API:',
          'is it up, do its backends answer, which routers and services fail, which',
          'routers are broken in its configuration, and which certificate expires',
          'first.'],
    needs=['its metrics and API: --metrics.prometheus=true (with addRoutersLabels and addServicesLabels for the '
           'routers and services jobs), --api=true and --ping=true; they are served on the traefik entrypoint '
           '(port 8080): env = TRAEFIK_URL=... where it is elsewhere',
           'for backends up and down: health checks on the services (loadBalancer.healthCheck); without one, '
           'Traefik does not know',
           'where the API is behind a login (a router with basicAuth): TRAEFIK_USER and secret = '
           'TRAEFIK_PASSWORD=secret:TRAEFIK_PASSWORD',
           "for Traefik's CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /metrics, Traefik's Prometheus page"

job(pack='traefik', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is Traefik up, and what is it answering',
    what="Reports whether Traefik answers and its ping, how long since its configuration last loaded and how "
         "many times it has, the connections open on each entrypoint, the requests its entrypoints answered and "
         "those 4xx and 5xx, how long they took, and when the first of its TLS certificates expires.",
    reads=READS + ", and /ping.",
    steps=[
        page('/metrics'),
        answers('ping', '/ping', '1 when /ping answers 200 (--ping=true), else 0'),
        table(
            ('last_reload_seconds|age|traefik_config_last_reload_success', 'seconds since its configuration last loaded'),
            ('reloads_count|sum|traefik_config_reloads_total', 'configurations loaded (a running total)'),
            ('connections|sum|traefik_open_connections', 'connections open, every entrypoint'),
            ('connections_by_entrypoint|by|traefik_open_connections||entrypoint', 'the same, for each entrypoint, tagged entrypoint='),
            ('requests_count|sum|traefik_entrypoint_requests_total', 'requests the entrypoints answered (a running total)'),
            ('requests_4xx_count|sum|traefik_entrypoint_requests_total|code~^4', 'of them, 4xx: 404 for a host or path no router takes (a running total)'),
            ('requests_5xx_count|sum|traefik_entrypoint_requests_total|code~^5', 'of them, 5xx: a backend down or failing (a running total)'),
            ('requests_5xx|by|traefik_entrypoint_requests_total|code~^5|entrypoint', 'the 5xx, for each entrypoint, tagged entrypoint='),
            ('_d_s|sum|traefik_entrypoint_request_duration_seconds_sum', None),
            ('_d_n|sum|traefik_entrypoint_request_duration_seconds_count', None),
            ('_d_avg|div|_d_s|_d_n', None),
            ('request_avg_ms|mul|_d_avg|1000', 'a request, on average, in milliseconds, since it started'),
            ('tls_requests_count|sum|traefik_entrypoint_requests_tls_total', 'requests over TLS (a running total)'),
            ('certs|count?|traefik_tls_certs_not_after', 'TLS certificates it serves'),
            ('cert_expires_at|min?|traefik_tls_certs_not_after', 'when the first of them expires, in Unix seconds: compare it with now in the backend (the config job says it in days)'),
        ),
    ],
    healthy='up 1; ping 1; requests_5xx_count rising slowly, if at all; cert_expires_at more than 30 days ahead.',
    watch='requests_4xx_count rising fast: a client calling a host or path no router takes; request_avg_ms rising; '
          'cert_expires_at within 30 days (Traefik renews ACME certificates 30 days ahead: one still within is not '
          'renewing).',
    act='up 0 or ping 0; requests_5xx_count rising: the services job says which; cert_expires_at within 7 days.')

job(pack='traefik', job='services', metric='services', when='run_every   = 1m', runtime='30s',
    title="Traefik's backend servers, up and down, and the services that fail",
    what="Reports the backend servers Traefik health-checks, those up and those down, each down server by its "
         "URL, and for each service the servers down; the requests each service answered, those 5xx, for each "
         "service, and how long they took; and the retries.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('servers|count?|traefik_service_server_up', 'backend servers health-checked'),
            ('servers_down|count?|traefik_service_server_up||=0', 'of them, down: their health check fails'),
            ('server_down|countby?|traefik_service_server_up||url:url =0', 'each server: 1 when down, tagged url=<its URL>'),
            ('down_by_service|countby?|traefik_service_server_up||service:service =0', 'servers down, for each service, tagged service='),
            ('requests_count|sum?|traefik_service_requests_total', 'requests the services answered (a running total)'),
            ('requests_5xx_count|sum?|traefik_service_requests_total|code~^5', 'of them, 5xx (a running total)'),
            ('requests_5xx|by|traefik_service_requests_total|code~^5|service', 'the 5xx, for each service, tagged service='),
            ('_d_s|sum?|traefik_service_request_duration_seconds_sum', None),
            ('_d_n|sum?|traefik_service_request_duration_seconds_count', None),
            ('_d_avg|div|_d_s|_d_n', None),
            ('request_avg_ms|mul|_d_avg|1000', 'a request to a backend, on average, in milliseconds'),
            ('retries_count|sum?|traefik_service_retries_total', 'requests retried on another server (the retry middleware; a running total)'),
        ),
    ],
    healthy='servers_down 0; requests_5xx_count flat.',
    watch='servers_down above 0 in a service with others up: it carries on with fewer; retries_count rising.',
    act='down_by_service equal to a service\'s servers: that service has none, and answers 503; requests_5xx '
        'rising for a service: its backend fails (502 when it cannot be reached, 504 when it is too slow).')

job(pack='traefik', job='routers', metric='routers', when='run_every   = 1m', runtime='30s',
    title="the requests each of Traefik's routers answered, and those that failed",
    what="Reports, for each router, the requests it answered and those 4xx and 5xx: which application a "
         "client's errors belong to. It needs --metrics.prometheus.addRoutersLabels=true; without it, nothing.",
    reads=READS + ".",
    steps=[
        page('/metrics'),
        table(
            ('requests_count|sum?|traefik_router_requests_total', 'requests the routers answered (a running total)'),
            ('requests|by|traefik_router_requests_total||router', 'the same, for each router, tagged router='),
            ('requests_4xx|by|traefik_router_requests_total|code~^4|router', 'the 4xx, for each router'),
            ('requests_5xx|by|traefik_router_requests_total|code~^5|router', 'the 5xx, for each router'),
        ),
    ],
    healthy='requests_5xx flat for each router.',
    watch='requests_4xx rising for one router: a client or a link that is wrong.',
    act='requests_5xx rising for a router: its service fails (the services job).')

CONFIG_SH = r'''# Its read-only API: the version; every router, service and middleware and
# those in error or warning; the routers in error, named, with the reason;
# the certificates and their expiry.
get '/api/version' version
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/api/version: no such page (HTTP 404): is the API on (--api=true), and is @E@_URL its address?" >&2; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
echo "metric version 1 version=$(tag "$(jq -r '.Version // empty' "$work/version")")"
get '/api/overview' overview || { echo "$job: $url/api/overview did not answer" >&2; exit 1; }
jq -r '(["http","tcp","udp"][]) as $k | (["routers","services","middlewares"][]) as $w
    | select(.[$k][$w] != null) | .[$k][$w] as $o
    | "metric \($w) \($o.total) protocol=\($k)", "metric \($w)_errors \($o.errors) protocol=\($k)", "metric \($w)_warnings \($o.warnings) protocol=\($k)"' "$work/overview"
jq -r 'if .certificates then "metric certificates \(.certificates.total)", "metric certificates_warnings \(.certificates.warnings)", "metric certificates_errors \(.certificates.errors)" else empty end' "$work/overview"
# Each router in error, by name, with the first words of its error: the 20
# first by name.
n=0
for k in http tcp udp; do
    get "/api/$k/routers?status=disabled" bad || continue
    jq -r --arg k "$k" 'sort_by(.name) | .[] | [$k, .name, ((.error // ["none"])[0])] | @tsv' "$work/bad" > "$work/bad.tsv"
    while IFS=$'\t' read -r p name why; do
        n=$((n + 1))
        [ "$n" -le 20 ] || continue
        echo "metric router_error 1 protocol=$p router=$(tag "$name") reason=$(tag "$(printf '%s' "$why" | cut -c 1-80)")"
    done < "$work/bad.tsv"
done
echo "metric router_errors_not_shown $((n > 20 ? n - 20 : 0))"
# The certificates: the soonest to expire, and those within 30 days.
if get '/api/certificates' certs; then
    jq -r --argjson now "$now" '[.[] | (.notAfter | fromdateiso8601) - $now] | if length > 0 then
        "metric cert_expires_days \((min / 86400 * 100 | floor) / 100)", "metric certs_expiring_30d \(map(select(. < 2592000)) | length)" else empty end' "$work/certs"
fi
'''

CONFIG_PS = r'''# Its read-only API: the version; every router, service and middleware and
# those in error or warning; the routers in error, named, with the reason;
# the certificates and their expiry.
$r = Get-Answer '/api/version'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/api/version: no such page (HTTP 404): is the API on (--api=true), and is @E@_URL its address?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
Write-Output "metric version 1 version=$(Safe ($r.Body | ConvertFrom-Json).Version)"
$o = Get-Answer '/api/overview'
if ($o.State -ne 'ok') { [Console]::Error.WriteLine("${Job}: $($script:Url)/api/overview did not answer"); exit 1 }
$ov = $o.Body | ConvertFrom-Json
foreach ($k in 'http', 'tcp', 'udp') {
    foreach ($w in 'routers', 'services', 'middlewares') {
        $x = $ov.$k.$w
        if ($null -eq $x) { continue }
        Write-Output "metric $w $($x.total) protocol=$k"
        Write-Output "metric ${w}_errors $($x.errors) protocol=$k"
        Write-Output "metric ${w}_warnings $($x.warnings) protocol=$k"
    }
}
if ($ov.certificates) {
    Write-Output "metric certificates $($ov.certificates.total)"
    Write-Output "metric certificates_warnings $($ov.certificates.warnings)"
    Write-Output "metric certificates_errors $($ov.certificates.errors)"
}
# Each router in error, by name, with the first words of its error: the 20
# first by name.
$n = 0
foreach ($k in 'http', 'tcp', 'udp') {
    $b = Get-Answer "/api/$k/routers?status=disabled"
    if ($b.State -ne 'ok') { continue }
    $parsed = $b.Body | ConvertFrom-Json
    foreach ($rt in @($parsed | ForEach-Object { $_ } | Sort-Object -Property name -CaseSensitive)) {
        $n++
        if ($n -gt 20) { continue }
        $why = if ($rt.error) { [string]@($rt.error)[0] } else { 'none' }
        if ($why.Length -gt 80) { $why = $why.Substring(0, 80) }
        Write-Output "metric router_error 1 protocol=$k router=$(Safe $rt.name) reason=$(Safe $why)"
    }
}
Write-Output "metric router_errors_not_shown $(if ($n -gt 20) { $n - 20 } else { 0 })"
# The certificates: the soonest to expire, and those within 30 days.
$c = Get-Answer '/api/certificates'
if ($c.State -eq 'ok') {
    $left = @(@($c.Body | ConvertFrom-Json) | ForEach-Object { $_ } | ForEach-Object {
        ([DateTimeOffset]::Parse([string]$_.notAfter, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds() - $script:Now) })
    if ($left.Count -gt 0) {
        $min = ($left | Measure-Object -Minimum).Minimum
        Write-Output "metric cert_expires_days $([Math]::Floor($min / 86400 * 100) / 100)"
        Write-Output "metric certs_expiring_30d $(@($left | Where-Object { $_ -lt 2592000 }).Count)"
    }
}
'''

job(pack='traefik', job='config', metric='config', when='run_every   = 5m', runtime='30s',
    needs_sh=['curl', 'jq'],
    title="what in Traefik's configuration is broken, and its certificates",
    what="Reports, from Traefik's read-only API, its version; its routers, services and middlewares, for HTTP, "
         "TCP and UDP, with those in error and in warning; each router in error by name, with the reason (a "
         "router in error takes no traffic); and its TLS certificates, those Traefik warns about, the soonest to "
         "expire and those within 30 days.",
    reads="Reads @E@_URL (default @URL@): /api/version, /api/overview, /api/<http, tcp, udp>/routers?status=disabled "
          "and /api/certificates (--api=true).",
    exit_sh="0, whatever it reads, and when Traefik does not answer (up 0 is the reading); 1 when it answers wrong "
            "(a login refused, not HTTP), said on stderr, or curl or jq is missing",
    steps=[code(CONFIG_SH, CONFIG_PS, [
        ('up', '1 when its API answered, else 0'),
        ('version', 'always 1, tagged version=<its version>'),
        ('routers', 'routers, tagged protocol=<http, tcp or udp>'),
        ('routers_errors', 'of them, in error: they take no traffic'),
        ('routers_warnings', 'in warning'),
        ('services', 'services, tagged protocol='),
        ('services_errors', 'of them, in error'),
        ('services_warnings', 'in warning'),
        ('middlewares', 'middlewares, tagged protocol=<http or tcp>'),
        ('middlewares_errors', 'of them, in error'),
        ('middlewares_warnings', 'in warning'),
        ('certificates', 'TLS certificates'),
        ('certificates_warnings', 'of them, those Traefik warns about (expiring soon)'),
        ('certificates_errors', 'of them, in error'),
        ('router_error', 'a router in error: 1, tagged protocol=, router=<its name> and reason=<the start of its error>'),
        ('router_errors_not_shown', 'routers in error past the first 20'),
        ('cert_expires_days', 'days until the soonest certificate expires (below 0: expired)'),
        ('certs_expiring_30d', 'certificates that expire within 30 days'),
    ])],
    healthy='routers_errors, services_errors and middlewares_errors 0; certificates_warnings 0.',
    watch='the warnings above 0; certs_expiring_30d above 0.',
    act='routers_errors above 0: router_error names it and why (a service that does not exist, a middleware '
        'missing, a rule that does not parse): it takes no traffic; cert_expires_days below 7.')
