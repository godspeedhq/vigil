#!/usr/bin/env bash
#
# config.sh - what in Traefik's configuration is broken, and its certificates
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
# Reports, from Traefik's read-only API, its version; its routers, services
# and middlewares, for HTTP, TCP and UDP, with those in error and in warning;
# each router in error by name, with the reason (a router in error takes no
# traffic); and its TLS certificates, those Traefik warns about, the soonest
# to expire and those within 30 days. It only reads: every request is a GET,
# and it changes nothing.
#
# Reads TRAEFIK_URL (default http://localhost:8080): /api/version,
# /api/overview, /api/<http, tcp, udp>/routers?status=disabled and
# /api/certificates (--api=true).
# What the scripts share is in _traefik.sh, beside this one.
#
# Metrics:
#   up                       1 when its API answered, else 0
#   version                  always 1, tagged version=<its version>
#   routers                  routers, tagged protocol=<http, tcp or udp>
#   routers_errors           of them, in error: they take no traffic
#   routers_warnings         in warning
#   services                 services, tagged protocol=
#   services_errors          of them, in error
#   services_warnings        in warning
#   middlewares              middlewares, tagged protocol=<http or tcp>
#   middlewares_errors       of them, in error
#   middlewares_warnings     in warning
#   certificates             TLS certificates
#   certificates_warnings    of them, those Traefik warns about (expiring
#                            soon)
#   certificates_errors      of them, in error
#   router_error             a router in error: 1, tagged protocol=,
#                            router=<its name> and reason=<the start of its
#                            error>
#   router_errors_not_shown  routers in error past the first 20
#   cert_expires_days        days until the soonest certificate expires (below
#                            0: expired)
#   certs_expiring_30d       certificates that expire within 30 days
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  routers_errors, services_errors and middlewares_errors 0;
#            certificates_warnings 0.
#   Watch    the warnings above 0; certs_expiring_30d above 0.
#   Act      routers_errors above 0: router_error names it and why (a service
#            that does not exist, a middleware missing, a rule that does not
#            parse): it takes no traffic; cert_expires_days below 7.
#
# Requires: bash, curl, jq
# Exit code: 0, whatever it reads, and when Traefik does not answer (up 0 is
#   the reading); 1 when it answers wrong (a login refused, not HTTP), said on
#   stderr, or curl or jq is missing

set -u

job=config
# shellcheck source=/dev/null
. "$(dirname "$0")/_traefik.sh"
needs curl jq

# Its read-only API: the version; every router, service and middleware and
# those in error or warning; the routers in error, named, with the reason;
# the certificates and their expiry.
get '/api/version' version
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/api/version: no such page (HTTP 404): is the API on (--api=true), and is TRAEFIK_URL its address?" >&2; exit 0 ;;
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
exit 0
