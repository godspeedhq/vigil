#!/usr/bin/env bash
#
# certs.sh - TLS certificates, from a handshake with each target: expiry,
# validity, trust, the name, and how long the handshake took
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
# Makes a TLS handshake with each target in TLS_TARGETS, as a client would,
# and reports the certificate it is given: the days until it expires,
# whether today is within its dates, whether it checks against the trusted
# CAs (or TLS_CACERT), and whether it is for the name asked for; and the
# handshake itself: whether it finished, why not, how long it took, and
# the TLS version agreed. It reads what clients get, so it also catches a
# certificate renewed on disk that the server has not loaded yet.
#
# Nothing is sent but the handshake: no request, no login. Any service that
# speaks TLS from its first byte works (HTTPS, LDAPS, SMTPS, IMAPS, a
# database's TLS port, a Kubernetes API); a service that starts in plain
# text and turns to TLS (STARTTLS) does not. Each target has
# TLS_TIMEOUT seconds (10 by default) to finish.
#
# TLS_TARGETS lists the targets, separated by spaces: host, host:port, or
# either followed by /name to ask for a name (SNI) other than the host
# (port 443 when none is given; an IPv6 address in brackets, [::1]:443).
# TLS_CACERT, a CA file in PEM, checks certificates from a private CA as
# well as the trusted ones.
#
# Metrics:
#   targets              the targets in TLS_TARGETS
#   targets_failed       of those, how many failed a check: the handshake,
#                        the dates, trust or the name
#   soonest_days         days until the first of their certificates expires
#                        (below 0: one has expired); none when no target
#                        answered
#   up                   1 when the handshake finished, else 0; tagged
#                        target=<as listed> and reason=<ok, refused,
#                        no_such_host, unreachable, timeout,
#                        handshake_failed>; the rest only when it finished
#   handshake_ms         the time to connect and finish the handshake
#                        (with the start of openssl itself, a few ms)
#   cert_expires_days    days until the certificate expires (below 0:
#                        expired)
#   cert_valid           1 when today is within its dates, else 0
#   cert_trusted         1 when its chain checks against the trusted CAs
#                        (or TLS_CACERT), else 0, tagged reason=<openssl's
#                        words, or ok>
#   cert_name_ok         1 when it is for the name asked for (its subject
#                        alternative names, wildcards as clients take them),
#                        else 0
#   cert_info            always 1, tagged issuer=<its CN>, subject=<its CN>
#                        and protocol=<the TLS version agreed>
#   targets_not_shown    targets past the first 50, left out
#
# Example output (the rest are in the same form):
#   metric up 1 target=example.com reason=ok
#   metric handshake_ms 61 target=example.com
#   metric cert_expires_days 74.21 target=example.com
#   metric cert_valid 1 target=example.com
#   metric cert_trusted 1 target=example.com reason=ok
#   metric cert_name_ok 1 target=example.com
#   metric cert_info 1 target=example.com issuer=R11 subject=example.com protocol=TLSv1.3
#   metric up 0 target=old.example.com:8443 reason=refused
#   metric targets 2
#   metric targets_failed 1
#   metric soonest_days 74.21
#
# Reading the results (starting points: tune them to how you renew):
#   Healthy  up 1; cert_expires_days above 30; cert_valid, cert_trusted and
#            cert_name_ok 1; targets_failed 0.
#   Watch    cert_expires_days below 30: automatic renewal (Let's Encrypt,
#            30 days ahead) should have happened, so it is not working;
#            handshake_ms well above its usual.
#   Act      cert_expires_days below 7; cert_valid 0 (expired, or not yet
#            valid); cert_trusted 0 (reason says why: clients that check,
#            all browsers, refuse it now); cert_name_ok 0 (served for the
#            wrong name); up 0 (reason says why).
#
# Requires: bash, openssl (OpenSSL 1.1 or later, or LibreSSL, as macOS has),
#   awk and date; for handshake_ms, GNU date or perl (macOS has perl)
# Exit code: 0, whatever the certificates; 1 if openssl is missing, or
#   TLS_CACERT cannot be read
#
# Example (vigil.config):
#   [job.tls_certs]
#   file        = packs/tls/certs.sh
#   metric_name = tls
#   run_every   = 15m
#   env         = TLS_TARGETS=example.com mail.example.com:993 10.0.0.5:8443/app.internal

set -u

job=certs
command -v openssl > /dev/null 2>&1 || { echo "$job: openssl not found" >&2; exit 1; }
ca=${TLS_CACERT-}
if [ -n "$ca" ] && [ ! -r "$ca" ]; then echo "$job: TLS_CACERT: cannot read $ca" >&2; exit 1; fi
limit=${TLS_TIMEOUT:-10}
case $limit in '' | *[!0-9]*) limit=10 ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-tls.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)

# tag <text>: as a tag's value: no spaces, quotes or control characters, at
# most 120 characters.
tag() {
    local t=${1//[^A-Za-z0-9@._:\/+-]/_}
    [ -n "$t" ] || t=none
    printf '%s' "${t:0:120}"
}

# ms: milliseconds since 1970, from GNU date or perl; nothing without them.
ms() {
    local t
    t=$(date +%s%N 2> /dev/null)
    case $t in
        '' | *[!0-9]*) command -v perl > /dev/null 2>&1 && perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000' ;;
        *) printf '%s\n' "${t%??????}" ;;
    esac
}

# epoch_of <date>: a date as openssl prints it (Nov 24 06:47:40 2026 GMT),
# as seconds since 1970; empty when it cannot be read.
epoch_of() {
    date -u -d "$1" +%s 2> /dev/null || date -j -u -f '%b %e %T %Y %Z' "$1" +%s 2> /dev/null
}

# within <seconds> <command>...: runs it, stopped (exit 143) when it takes
# longer. openssl has no time limit of its own for connecting.
within() {
    local t=$1 p w rc
    shift
    "$@" &
    p=$!
    (
        trap 'kill "$s" 2> /dev/null; exit 0' TERM
        sleep "$t" &
        s=$!
        wait "$s"
        kill "$p" 2> /dev/null
    ) &
    w=$!
    wait "$p"
    rc=$?
    kill "$w" 2> /dev/null
    wait "$w" 2> /dev/null
    return "$rc"
}

# name_ok <name> <subject alternative names, one a line>: 0 when the name is
# among them, a wildcard taking one label (*.example.com takes
# a.example.com, not example.com or a.b.example.com).
name_ok() {
    awk -v n="$1" '
        BEGIN { n = tolower(n) }
        {
            s = tolower($0)
            if (s == n) { ok = 1; exit }
            if (substr(s, 1, 2) == "*." && index(n, ".") > 1) {
                rest = substr(n, index(n, ".") + 1)
                if (rest == substr(s, 3) && rest ~ /\./) { ok = 1; exit }
            }
        }
        END { exit ok ? 0 : 1 }'
}

# cn <issuer or subject>: its CN, from openssl's or LibreSSL's line.
cn() {
    sed -n "s/^$1= *//p" "$work/cert" | sed 's/.*CN *= *//; s/[,/].*//'
}

# The targets, one a line.
targets() {
    local t
    set -f
    # shellcheck disable=SC2086
    for t in ${TLS_TARGETS-}; do printf '%s\n' "$t"; done
    set +f
}

n=0
failed=0
soonest=''
while IFS= read -r e; do
    [ -n "$e" ] || continue
    n=$((n + 1))
    [ "$n" -gt 50 ] && continue
    t="target=$(tag "$e")"
    # host[:port][/name]; an IPv6 address in brackets.
    hp=${e%%/*}
    name=${e#*/}
    [ "$name" = "$e" ] && name=''
    case $hp in
        \[*\]:*) host=${hp%%]*}; host=${host#[}; port=${hp##*]:} ;;
        \[*\]) host=${hp#[}; host=${host%]}; port=443 ;;
        *:*) host=${hp%:*}; port=${hp##*:} ;;
        *) host=$hp; port=443 ;;
    esac
    [ -n "$name" ] || name=$host
    case $hp in \[*) connect="[$host]:$port" ;; *) connect="$host:$port" ;; esac
    a=(s_client -connect "$connect" -showcerts)
    # SNI is a host name: an address is not sent as one.
    case $name in *:*) ;; *[!0-9.]*) a+=(-servername "$name") ;; esac
    [ -n "$ca" ] && a+=(-CAfile "$ca")
    start=$(ms)
    within "$limit" openssl "${a[@]}" < /dev/null > "$work/out" 2> "$work/err"
    rc=$?
    end=$(ms)
    if ! grep -q 'BEGIN CERTIFICATE' "$work/out"; then
        if [ "$rc" -ge 128 ]; then why=timeout
        elif grep -qi 'refused' "$work/err"; then why=refused
        elif grep -qi 'nodename nor servname\|not known\|no address associated\|BIO_lookup\|gethostbyname\|getaddrinfo\|lookup' "$work/err"; then why=no_such_host
        elif grep -qi 'unreachable\|no route' "$work/err"; then why=unreachable
        else why=handshake_failed
        fi
        echo "metric up 0 $t reason=$why"
        failed=$((failed + 1))
        continue
    fi
    echo "metric up 1 $t reason=ok"
    [ -n "$start" ] && [ -n "$end" ] && echo "metric handshake_ms $((end - start)) $t"
    # The server's certificate: the first the server sent.
    awk '/BEGIN CERTIFICATE/ { on = 1 } on { print } /END CERTIFICATE/ { exit }' "$work/out" > "$work/leaf.pem"
    openssl x509 -in "$work/leaf.pem" -noout -enddate -startdate -issuer -subject > "$work/cert" 2> /dev/null
    openssl x509 -in "$work/leaf.pem" -noout -text 2> /dev/null |
        awk '/Subject Alternative Name/ { getline; print }' | tr ',' '\n' |
        sed -n 's/^ *DNS: *//p; s/^ *IP Address: *//p' > "$work/names"
    notafter=$(epoch_of "$(sed -n 's/^notAfter=//p' "$work/cert")")
    notbefore=$(epoch_of "$(sed -n 's/^notBefore=//p' "$work/cert")")
    bad=0
    if [ -n "$notafter" ]; then
        days=$(awk -v a="$notafter" -v n="$now" 'BEGIN { printf "%.2f", (a - n) / 86400 }')
        echo "metric cert_expires_days $days $t"
        valid=$([ "$now" -lt "$notafter" ] && [ "${notbefore:-0}" -le "$now" ] && echo 1 || echo 0)
        echo "metric cert_valid $valid $t"
        [ "$valid" = 1 ] || bad=1
        soonest=$(awk -v d="$days" -v s="$soonest" 'BEGIN { print (s == "" || d + 0 < s + 0) ? d : s }')
    fi
    code=$(sed -n 's/^ *Verify return code: \([0-9]*\).*/\1/p' "$work/out" | tail -n 1)
    why=$(sed -n 's/^ *Verify return code: [0-9]* (\(.*\))$/\1/p' "$work/out" | tail -n 1)
    [ "$code" = 0 ] && why=ok
    echo "metric cert_trusted $([ "$code" = 0 ] && echo 1 || echo 0) $t reason=$(tag "${why:-unknown}")"
    [ "$code" = 0 ] || bad=1
    if name_ok "$name" < "$work/names"; then echo "metric cert_name_ok 1 $t"; else echo "metric cert_name_ok 0 $t"; bad=1; fi
    proto=$(sed -n 's/^ *Protocol *: *//p; s/^New, \(TLSv[0-9.]*\),.*/\1/p' "$work/out" | head -n 1)
    echo "metric cert_info 1 $t issuer=$(tag "$(cn issuer)") subject=$(tag "$(cn subject)") protocol=$(tag "${proto:-unknown}")"
    failed=$((failed + bad))
done <<< "$(targets)"

echo "metric targets $n"
echo "metric targets_failed $failed"
[ -n "$soonest" ] && echo "metric soonest_days $soonest"
[ "$n" -gt 50 ] && echo "metric targets_not_shown $((n - 50))"
exit 0
