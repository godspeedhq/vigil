# shellcheck shell=bash
#
# _@p@.sh - what the @p@ pack's scripts share: one request, the tags, the
# times, the access log and the certificates. Each job's script sources it;
# it is never run as a job.
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

export LC_ALL=C
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-@p@.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)

# needs <program>...: stop, saying which is missing.
needs() {
    local p
    for p in "$@"; do
        command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the @p@ pack's $job job needs it" >&2; exit 1; }
    done
}

# tag <text>: a tag's value: no spaces, quotes or control characters, never
# empty, at most 120 characters.
tag() {
    local s
    s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9@._:/+-' '_' | cut -c 1-120)
    printf '%s' "${s:-none}"
}

# fetch <url> [<curl option>...]: the answer in $work/body. 0; 2 when nothing
# answers (a reading); 1 when it answers wrong, said on stderr.
fetch() {
    local u=$1 rc code
    shift
    curl -sS -g -m 10 "$@" -o "$work/body" -w '%{http_code}' "$u" > "$work/code" 2> "$work/err"
    rc=$?
    case $rc in
        0) ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) echo "$job: $u: $(head -n 1 "$work/err")" >&2; return 1 ;;
    esac
    code=$(cat "$work/code")
    [ "$code" = 200 ] && return 0
    echo "$job: $u answered HTTP $code" >&2
    return 1
}

# epoch_of <date>: a date as openssl prints it (Nov 24 06:47:40 2026 GMT),
# as seconds since 1970; empty when it cannot be read.
epoch_of() {
    date -u -d "$1" +%s 2> /dev/null || date -j -u -f '%b %e %T %Y %Z' "$1" +%s 2> /dev/null
}

# changed_since <epoch> <path>...: how many files under the paths changed
# after that time (those this account may not read are not counted).
changed_since() {
    local t
    t=$(date -u -d "@$1" +%Y%m%d%H%M.%S 2> /dev/null || date -u -r "$1" +%Y%m%d%H%M.%S) || return 1
    TZ=UTC touch -t "$t" "$work/since" || return 1
    shift
    find "$@" -type f -newer "$work/since" 2> /dev/null | wc -l | tr -d ' '
}

# log_minute <file> <max MB>: the access log's last whole minute, from its
# last <max MB> only (the job never reads the whole file). Prints the
# readings; "log_readable 0" when this account may not read it.
log_minute() {
    local f=$1 cap=$(( ${2:-32} * 1048576 )) start stamp size
    if [ ! -e "$f" ]; then
        echo "metric log_found 0"
        echo "$job: no access log at $f: set the job's @E@_ACCESS_LOG" >&2
        return 0
    fi
    echo "metric log_found 1"
    if [ ! -r "$f" ]; then
        echo "metric log_readable 0"
        echo "$job: this account may not read $f: add it to the log's group (packs/@p@/README.md says how), or turn this job off" >&2
        return 0
    fi
    echo "metric log_readable 1"
    # The minute before this one, in the log's own form (local time).
    start=$(( (now / 60 - 1) * 60 ))
    stamp=$(date -d "@$start" '+%d/%b/%Y:%H:%M' 2> /dev/null || date -r "$start" '+%d/%b/%Y:%H:%M')
    size=$(wc -c < "$f" | tr -d ' ')
    echo "metric log_bytes $size"
    tail -c "$cap" "$f" | awk -v want="[$stamp:" -v cut="$([ "$size" -gt "$cap" ] && echo 1 || echo 0)" -v dir="$work" '
        function pct(a, b) { return b > 0 ? sprintf("%.2f", 100 * a / b) + 0 : 0 }
        NR == 1 && cut { next }   # the first line may be cut in two
        {
            i = index($0, "[")
            if (!i) next
            t = substr($0, i, 19)
            if (t != substr(want, 1, 19)) { if (!inside) before = 1; next }
            inside = 1
            # "METHOD path protocol" status bytes
            if (!match($0, /" [0-9][0-9][0-9] [0-9-]+/)) next
            split(substr($0, RSTART + 2, RLENGTH - 2), sb, " ")
            st = sb[1]; by = sb[2] + 0
            q = index($0, "\"")
            m = substr($0, q + 1); m = substr(m, 1, index(m, " ") - 1)
            if (m !~ /^(GET|POST|HEAD|PUT|DELETE|PATCH|OPTIONS)$/) m = "other"
            n++; bytes += by; code[st]++; cls[substr(st, 1, 1)]++; meth[m]++
            ip = substr($0, 1, index($0, " ") - 1); if (!(ip in ips)) { ips[ip] = 1; nip++ }
            for (k = 1; k <= NF; k++) {
                if ($k ~ /^rt=[0-9.]+$/) print substr($k, 4) * 1000 > (dir "/rt")
                else if ($k ~ /^rtus=[0-9]+$/) print substr($k, 6) / 1000 > (dir "/rt")
                else if ($k ~ /^urt=[0-9.]+/) { split(substr($k, 5), u, ","); print u[1] * 1000 > (dir "/urt") }
            }
        }
        END {
            # Read from its end, a log is whole for the minute when a line
            # from before it was read too.
            complete = (!cut || (before && n > 0)) ? 1 : 0
            print "metric window_complete " complete
            print "metric requests " n + 0
            for (c = 1; c <= 5; c++) print "metric status_" c "xx " cls[c] + 0
            print "metric errors_4xx_pct " pct(cls[4], n)
            print "metric errors_5xx_pct " pct(cls[5], n)
            printf "metric bytes_sent %.0f\n", bytes
            print "metric clients " nip + 0
            nc = 0
            for (s in code) if (++nc <= 40) print "metric status " code[s] " code=" s
            for (s in meth) print "metric method " meth[s] " method=" s
        }'
    log_times rt response
    log_times urt upstream
}

# log_times <file> <name>: the times log_minute kept (milliseconds), as an
# average, percentiles and the longest.
log_times() {
    [ -s "$work/$1" ] || return 0
    sort -n "$work/$1" | awk -v n="$2" '
        { v[NR] = $1; s += $1 }
        END {
            printf "metric %s_avg_ms %.1f\n", n, s / NR
            printf "metric %s_p50_ms %.1f\n", n, v[int(NR * 0.50 + 0.999)]
            printf "metric %s_p90_ms %.1f\n", n, v[int(NR * 0.90 + 0.999)]
            printf "metric %s_p99_ms %.1f\n", n, v[int(NR * 0.99 + 0.999)]
            printf "metric %s_max_ms %.1f\n", n, v[NR]
        }'
}

# certs <endpoint>...: each endpoint's certificate, from a TLS handshake
# (host:port, or host:port/name to ask for another name, SNI). Nothing is
# sent but the handshake.
certs() {
    local e hp name host port n=0 out end start rc why proto a
    for e in "$@"; do
        n=$((n + 1))
        [ "$n" -gt 50 ] && { echo "metric certs_not_shown $(( $# - 50 ))"; return 0; }
        hp=${e%%/*}
        name=${e#*/}
        [ "$name" = "$e" ] && name=${hp%:*}
        host=${hp%:*} port=${hp##*:}
        a=(-connect "$host:$port" -servername "$name")
        [ -n "${@E@_CACERT-}" ] && a+=(-CAfile "$@E@_CACERT")
        out=$(openssl s_client "${a[@]}" -verify_hostname "$name" < /dev/null 2> "$work/tls.err")
        # An openssl without -verify_hostname (LibreSSL): the chain alone.
        grep -qi 'unknown option\|usage' "$work/tls.err" && out=$(openssl s_client "${a[@]}" < /dev/null 2> "$work/tls.err")
        if ! printf '%s\n' "$out" | grep -q 'BEGIN CERTIFICATE'; then
            echo "metric tls_up 0 endpoint=$(tag "$e")"
            continue
        fi
        echo "metric tls_up 1 endpoint=$(tag "$e")"
        printf '%s\n' "$out" | openssl x509 -noout -enddate -startdate -issuer -subject > "$work/cert" 2> /dev/null
        end=$(epoch_of "$(sed -n 's/^notAfter=//p' "$work/cert")")
        start=$(epoch_of "$(sed -n 's/^notBefore=//p' "$work/cert")")
        rc=$(printf '%s\n' "$out" | sed -n 's/^ *Verify return code: \([0-9]*\).*/\1/p' | tail -n 1)
        why=$(printf '%s\n' "$out" | sed -n 's/^ *Verify return code: [0-9]* (\(.*\))$/\1/p' | tail -n 1)
        proto=$(printf '%s\n' "$out" | sed -n 's/^ *Protocol *: *//p; s/^New, \(TLSv[0-9.]*\),.*/\1/p' | head -n 1)
        if [ -n "$end" ]; then
            echo "metric cert_expires_days $(( (end - now) / 86400 )) endpoint=$(tag "$e")"
            echo "metric cert_valid $([ "$now" -lt "$end" ] && [ "${start:-0}" -le "$now" ] && echo 1 || echo 0) endpoint=$(tag "$e")"
        fi
        echo "metric cert_verified $([ "$rc" = 0 ] && echo 1 || echo 0) endpoint=$(tag "$e") reason=$(tag "${why:-unknown}")"
        echo "metric cert_info 1 endpoint=$(tag "$e") issuer=$(tag "$(sed -n 's/^issuer=//p' "$work/cert" | sed 's/.*CN *= *//; s/,.*//')") protocol=$(tag "${proto:-unknown}")"
    done
}
