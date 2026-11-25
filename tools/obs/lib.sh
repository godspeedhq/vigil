# shellcheck shell=bash
#
# _@p@.sh - what the @p@ pack's scripts share: one request, and the readings
# taken from a page of metrics in Prometheus' text format. Each job's script
# sources it; it is never run as a job.
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
# Reads @P@ at @E@_URL (default @URL@). @E@_USER and @E@_PASSWORD log in with
# basic authentication, or @E@_TOKEN sends a bearer token; keep the password
# or the token in Vigil's secret store (secret = @E@_PASSWORD=secret:...).
# Over https, the certificate is checked against @E@_CACERT, a CA file, when
# it is set, else the system's CAs. Every request is a GET.

export LC_ALL=C
url=${@E@_URL:-@URL@}
url=${url%/}
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

# esc <text>: for a double-quoted value in curl's config.
esc() {
    local s=$1
    s=${s//\\/\\\\}
    printf '%s' "${s//\"/\\\"}"
}
# The login and the CA, as curl's config, on its standard input: never on a
# command line.
login() {
    if [ -n "${@E@_TOKEN-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$(esc "$@E@_TOKEN")"
    elif [ -n "${@E@_USER-}" ]; then
        printf 'user = "%s:%s"\n' "$(esc "$@E@_USER")" "$(esc "${@E@_PASSWORD-}")"
    fi
    [ -n "${@E@_CACERT-}" ] && printf 'cacert = "%s"\n' "$(esc "$@E@_CACERT")"
    return 0
}

# get <path> [<file>]: the answer in $work/<file> (body by default). 0; 2
# when nothing answers (a reading); 3 when @P@ has no such page (HTTP 404);
# 4 when this login may not read it (401, 403); 5 when it answers that it
# is not ready (503); 1 when it answers wrong, said on stderr.
get() {
    local rc code out=$work/${2:-body}
    login | curl -sS -g -m 20 -K - -o "$out" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    rc=$?
    code=$(cat "$work/code" 2> /dev/null)
    case $rc in
        0) ;;
        6 | 7 | 28 | 35 | 52 | 56) return 2 ;;
        *) echo "$job: $url$1: $(head -n 1 "$work/err")" >&2; return 1 ;;
    esac
    case $code in
        200) return 0 ;;
        404) return 3 ;;
        401 | 403) echo "$job: $url$1 answered HTTP $code: this login may not read it (@E@_USER and @E@_PASSWORD, or @E@_TOKEN)" >&2; return 4 ;;
        503) return 5 ;;
    esac
    echo "$job: $url$1 answered HTTP $code" >&2
    return 1
}

# page <path>: the page of metrics at <path>, in $work/body, with "up": 1
# when @P@ answered it. When it did not, the job ends there: "up 0" is its
# reading, and the run succeeds.
page() {
    get "$1"
    case $? in
        0) echo "metric up 1" ;;
        2 | 5) echo "metric up 0"; exit 0 ;;
        3) echo "metric up 0"; echo "$job: $url$1: no such page (HTTP 404): is @E@_URL @P@'s address?" >&2; exit 0 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

# answers <name> <path>: "<name> 1" when the page answers 200, else 0 (a
# health or readiness page: not ready is a reading).
answers() {
    get "$2" probe
    case $? in
        0) echo "metric $1 1" ;;
        *) echo "metric $1 0" ;;
    esac
}

# readings [<file>]: takes the readings its standard input lists from a page
# of metrics ($work/body by default), in one pass. One reading a line:
#
#   name|op|metric|filters|arg
#
# A name starting with "_" is worked out and not printed (for the ones
# after it). The filters are label tests, separated by commas, all of which
# must hold: label=value, label!=value, label~regex, label!~regex.
#
#   sum, max, min   of the series' values; arg, a number to multiply by.
#                   A metric that is not on the page: sum is 0, max and min
#                   print nothing.
#   minpos          the smallest value above 0 (nothing when there is none)
#   maxpct          the largest of 100*a/b, a and b being the series of this
#                   metric and of the one in arg that carry the same labels
#                   (a queue's size and its capacity): how full the fullest
#                   is. Nothing when no pair has a b above 0.
#   count           how many series; arg, a test of the value (=0 >0 <1 !=1)
#   age, oldest     seconds since the latest (age) or the earliest
#                   (oldest) of the series' values, which are times (arg
#                   "ms": in milliseconds). Nothing when the metric is not
#                   there, or is 0.
#   by              one line for each value of the label in arg, tagged with
#                   it (label, or label:tag), the series summed; the 20
#                   largest, and <name>_not_shown for the rest
#   countby         the same, counting the series that pass the test after
#                   the label (arg: "label:tag =0")
#   info            1, tagged with labels of the first series (arg:
#                   label:tag,label:tag)
#   pct, div, sub, add, mul   of two readings above, or numbers: 100*a/b,
#                   a/b, a-b, a+b, a*b (nothing when one is missing; pct
#                   and div are 0 when b is 0)
#
# An op ending in "?" prints nothing when its metric is not on the page.
readings() {
    cat > "$work/table"
    awk -v table="$work/table" -v now="$now" '
        # A number, never with an exponent: 15 significant digits at most (all
        # a double holds for certain, and what every awk and PowerShell agree
        # on), and 6 decimals at most.
        function fmt(v,   s, a, d, e, digits) {
            a = (v < 0 ? -v : v)
            if (a >= 1e15) {
                s = sprintf("%.14e", a)
                e = substr(s, index(s, "e") + 1) + 0
                digits = substr(s, 1, 1) substr(s, 3, 14)
                while (length(digits) < e + 1) digits = digits "0"
                return (v < 0 ? "-" : "") digits
            }
            if (v == int(v)) return sprintf("%.0f", v)
            d = 15 - length(sprintf("%.0f", int(a)))
            if (d > 6) d = 6
            if (d < 1) return sprintf("%.0f", v)
            s = sprintf("%." d "f", v)
            sub(/0+$/, "", s); sub(/\.$/, "", s)
            return s
        }
        function tagv(s) {
            gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s)
            if (s == "") s = "none"
            return substr(s, 1, 120)
        }
        function test(v, t,   o, n) {
            if (t == "") return 1
            o = substr(t, 1, 1); n = substr(t, 2)
            if (o == "!") { n = substr(t, 3); return v != n + 0 }
            if (o == "=") return v == n + 0
            if (o == ">") return v > n + 0
            if (o == "<") return v < n + 0
            return 1
        }
        # The labels of a series, from the text between its braces.
        function labels(s,   i, n, k, v, c, L) {
            for (k in lab) delete lab[k]
            L = length(s); i = 1
            while (i <= L) {
                n = index(substr(s, i), "=")
                if (!n) break
                k = substr(s, i, n - 1); gsub(/^[ ,]+/, "", k)
                i += n
                if (substr(s, i, 1) != "\"") break
                i++; v = ""
                while (i <= L) {
                    c = substr(s, i, 1)
                    if (c == "\\") { v = v substr(s, i + 1, 1); i += 2; continue }
                    if (c == "\"") break
                    v = v c; i++
                }
                lab[k] = v
                i++
            }
        }
        function passes(r,   j, k, o, v, have) {
            for (j = 1; j <= nf[r]; j++) {
                k = fk[r, j]; o = fo[r, j]; v = fv[r, j]
                have = (k in lab) ? lab[k] : ""
                if (o == "=" && have != v) return 0
                if (o == "!=" && have == v) return 0
                if (o == "~" && have !~ v) return 0
                if (o == "!~" && have ~ v) return 0
            }
            return 1
        }
        BEGIN {
            while ((getline line < table) > 0) {
                if (line == "" || substr(line, 1, 1) == "#") continue
                n = split(line, f, "|")
                R++
                name[R] = f[1]; op[R] = f[2]; a[R] = f[3]; b[R] = (n >= 4 ? f[4] : ""); arg[R] = (n >= 5 ? f[5] : "")
                quiet[R] = 0
                if (substr(op[R], length(op[R])) == "?") { quiet[R] = 1; op[R] = substr(op[R], 1, length(op[R]) - 1) }
                o = op[R]
                if (o == "pct" || o == "div" || o == "sub" || o == "add" || o == "mul") continue
                wanted[a[R]] = wanted[a[R]] " " R
                if (o == "maxpct") wantedb[arg[R]] = wantedb[arg[R]] " " R
                nf[R] = 0
                if (b[R] != "") {
                    m = split(b[R], t, ",")
                    for (j = 1; j <= m; j++) {
                        if ((p = index(t[j], "!~")) > 0) { oo = "!~"; w = 2 }
                        else if ((p = index(t[j], "!=")) > 0) { oo = "!="; w = 2 }
                        else if ((p = index(t[j], "~")) > 0) { oo = "~"; w = 1 }
                        else { p = index(t[j], "="); oo = "="; w = 1 }
                        nf[R]++
                        fk[R, nf[R]] = substr(t[j], 1, p - 1); fo[R, nf[R]] = oo; fv[R, nf[R]] = substr(t[j], p + w)
                    }
                }
                if (o == "by" || o == "countby") {
                    s = arg[R]; vt[R] = ""
                    if ((p = index(s, " ")) > 0) { vt[R] = substr(s, p + 1); s = substr(s, 1, p - 1) }
                    bl[R] = s; bt[R] = s
                    if ((p = index(s, ":")) > 0) { bl[R] = substr(s, 1, p - 1); bt[R] = substr(s, p + 1) }
                }
            }
            close(table)
        }
        /^#/ || /^$/ { next }
        {
            p = index($0, "{"); q = index($0, " ")
            if (p > 0 && (q == 0 || p < q)) {
                nm = substr($0, 1, p - 1)
                if (!(nm in wanted) && !(nm in wantedb)) next
                # The closing brace: the last one before the value.
                rest = substr($0, p + 1); e = 0; inq = 0; L = length(rest)
                for (i = 1; i <= L; i++) {
                    c = substr(rest, i, 1)
                    if (c == "\\" && inq) { i++; continue }
                    if (c == "\"") inq = !inq
                    else if (c == "}" && !inq) { e = i; break }
                }
                if (!e) next
                lt = substr(rest, 1, e - 1)
                labels(lt)
                vs = substr(rest, e + 1)
            } else {
                nm = substr($0, 1, q - 1)
                if (!(nm in wanted) && !(nm in wantedb)) next
                for (k in lab) delete lab[k]
                lt = ""
                vs = substr($0, q + 1)
            }
            sub(/^ +/, "", vs)
            if ((sp = index(vs, " ")) > 0) vs = substr(vs, 1, sp - 1)
            if (vs == "NaN" || vs == "") next
            if (vs == "+Inf" || vs == "Inf") next
            if (vs == "-Inf") next
            v = vs + 0
            # The other half of a maxpct: what each series is a share of.
            if (nm in wantedb) {
                m = split(wantedb[nm], rr, " ")
                for (x = 1; x <= m; x++) { r = rr[x] + 0; if (passes(r)) pd[r, lt] = v }
            }
            if (!(nm in wanted)) next
            m = split(wanted[nm], rr, " ")
            for (x = 1; x <= m; x++) {
                r = rr[x] + 0
                if (!passes(r)) continue
                o = op[r]; seen[r] = 1
                if (o == "sum") acc[r] += v
                else if (o == "max" || o == "age") { if (!(r in has) || v > acc[r]) acc[r] = v }
                else if (o == "min" || o == "oldest") { if (!(r in has) || v < acc[r]) acc[r] = v }
                else if (o == "minpos") { if (v <= 0) continue; if (!(r in has) || v < acc[r]) acc[r] = v }
                else if (o == "count") { if (test(v, arg[r])) acc[r]++ }
                else if (o == "maxpct") {
                    if (!((r, lt) in pn)) { nk[r]++; pk[r, nk[r]] = lt }
                    pn[r, lt] = v
                }
                else if (o == "by" || o == "countby") {
                    key = (bl[r] in lab) ? lab[bl[r]] : ""
                    if (!((r, key) in grp)) { ng[r]++; gk[r, ng[r]] = key; grp[r, key] = 0 }
                    if (o == "by") grp[r, key] += v
                    else if (test(v, vt[r])) grp[r, key]++
                }
                else if (o == "info" && !(r in has)) {
                    out = ""
                    mm = split(arg[r], pr, ",")
                    for (y = 1; y <= mm; y++) {
                        lk = pr[y]; lt = pr[y]
                        if ((pp = index(pr[y], ":")) > 0) { lk = substr(pr[y], 1, pp - 1); lt = substr(pr[y], pp + 1) }
                        out = out " " lt "=" tagv((lk in lab) ? lab[lk] : "")
                    }
                    inf[r] = out
                }
                has[r] = 1
            }
        }
        function operand(s) {
            if (s in val) return val[s]
            if (s ~ /^-?[0-9.]+$/) return s + 0
            missing = 1
            return 0
        }
        END {
            for (r = 1; r <= R; r++) {
                o = op[r]; show = (substr(name[r], 1, 1) != "_")
                if (o == "pct" || o == "div" || o == "sub" || o == "add" || o == "mul") {
                    missing = 0
                    x = operand(a[r]); y = operand(b[r])
                    if (missing) continue
                    if (o == "pct") v = (y == 0 ? 0 : 100 * x / y)
                    else if (o == "div") v = (y == 0 ? 0 : x / y)
                    else if (o == "sub") v = x - y
                    else if (o == "add") v = x + y
                    else v = x * y
                    if (o == "pct") v = sprintf("%.2f", v) + 0
                    val[name[r]] = v
                    if (show) print "metric " name[r] " " fmt(v)
                    continue
                }
                if (!(r in seen) && quiet[r]) continue
                if (o == "sum" || o == "count") {
                    v = (r in has) ? acc[r] : 0
                    if (o == "sum" && arg[r] != "") v *= arg[r]
                    val[name[r]] = v
                    if (show) print "metric " name[r] " " fmt(v)
                } else if (o == "max" || o == "min" || o == "minpos") {
                    if (!(r in has)) continue
                    v = acc[r]; if (arg[r] != "") v *= arg[r]
                    val[name[r]] = v
                    if (show) print "metric " name[r] " " fmt(v)
                } else if (o == "maxpct") {
                    best = -1
                    for (g = 1; g <= nk[r] + 0; g++) {
                        k = pk[r, g]
                        if (((r, k) in pd) && pd[r, k] > 0) { v = 100 * pn[r, k] / pd[r, k]; if (v > best) best = v }
                    }
                    if (best < 0) continue
                    v = sprintf("%.2f", best) + 0
                    val[name[r]] = v
                    if (show) print "metric " name[r] " " fmt(v)
                } else if (o == "age" || o == "oldest") {
                    if (!(r in has) || acc[r] <= 0) continue
                    v = acc[r]; if (arg[r] == "ms") v /= 1000
                    v = now - v; if (v < 0) v = 0
                    val[name[r]] = v
                    if (show) print "metric " name[r] " " fmt(int(v))
                } else if (o == "info") {
                    if (r in inf) print "metric " name[r] " 1" inf[r]
                } else if (o == "by" || o == "countby") {
                    total = ng[r] + 0; shown = 0
                    while (shown < 20 && shown < total) {
                        best = 0
                        for (g = 1; g <= total; g++) {
                            if ((r, g) in done) continue
                            if (!best || grp[r, gk[r, g]] > grp[r, gk[r, best]]) best = g
                        }
                        done[r, best] = 1; shown++
                        print "metric " name[r] " " fmt(grp[r, gk[r, best]]) " " bt[r] "=" tagv(gk[r, best])
                    }
                    print "metric " name[r] "_not_shown " (total - shown)
                }
            }
        }
    ' "${1:-$work/body}"
}
