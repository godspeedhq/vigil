# shellcheck shell=bash
#
# _cockroachdb.sh - what the cockroachdb pack's scripts share: the settings,
# the node's metrics, the login, one read of CockroachDB's HTTP API, and
# jq's helpers. Each job's script sources it; it is never run as a job.
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
# Reads the CockroachDB node at COCKROACH_URL (default https://localhost:8080),
# its HTTP port (the DB Console's). A node's own metrics (/_status/vars) and
# health need no login. The cluster's nodes and jobs do: COCKROACH_USER with
# the password in COCKROACH_PASSWORD (a secret), given to curl on its standard
# input, never on a command line; an insecure cluster needs none. Over https,
# the certificate is checked against COCKROACH_CACERT, the cluster's CA file
# (ca.crt), when it is set, else the system's CAs. Every request only reads:
# the SQL the jobs send is SELECT and SHOW.

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the cockroachdb pack reads CockroachDB's HTTP API with curl and jq" >&2; exit 1; }
done
url=${COCKROACH_URL:-https://localhost:8080}
url=${url%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-cockroachdb.XXXXXX") || exit 1
session=''
# The session is ended when the job ends, so none is left open.
trap 'logout; rm -rf "$work"' EXIT
now=$(date +%s)

# esc <text>: for a double-quoted value in curl's config.
esc() {
    local s=$1
    s=${s//\\/\\\\}
    printf '%s' "${s//\"/\\\"}"
}
# curl's config, on its standard input: the CA, and the session once there
# is one. Never on a command line.
conf() {
    [ -n "${COCKROACH_CACERT-}" ] && printf 'cacert = "%s"\n' "$(esc "$COCKROACH_CACERT")"
    [ -n "$session" ] && printf 'header = "X-Cockroach-API-Session: %s"\n' "$(esc "$session")"
    return 0
}

# get <path> [<JSON body file>]: the answer in $work/body. 0; 2 when the
# node does not answer (a reading); 3 when it answers 503 (not ready, or the
# cluster not available); 4 when this user may not read it; 1 when it
# answers wrong, said on stderr.
get() {
    local rc code
    if [ -n "${2-}" ]; then
        conf | curl -sS -g -m 30 -K - -H 'Content-Type: application/json' --data-binary "@$2" \
            -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    else
        conf | curl -sS -g -m 30 -K - -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    fi
    rc=$?
    code=$(cat "$work/code" 2> /dev/null)
    case $rc in
        0) ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) echo "$job: $url: $(head -n 1 "$work/err")" >&2; return 1 ;;
    esac
    case $code in
        200) return 0 ;;
        401) echo "$job: CockroachDB refused the login (HTTP 401): COCKROACH_USER or COCKROACH_PASSWORD is wrong" >&2; return 1 ;;
        403) return 4 ;;
        503) return 3 ;;
        *) echo "$job: $url$1 answered HTTP $code" >&2; return 1 ;;
    esac
}

# vars: the node's metrics (/_status/vars), in $work/vars, and "metric up".
# A node that does not answer is up 0, and the run succeeds.
vars() {
    get /_status/vars
    case $? in
        0) ;;
        2) echo "metric up 0"; exit 0 ;;
        1) echo "metric up 0"; exit 1 ;;
        *) echo "metric up 0"; echo "$job: $url/_status/vars answered HTTP $(cat "$work/code")" >&2; exit 1 ;;
    esac
    grep -q '^build_timestamp' "$work/body" || { echo "metric up 0"; echo "$job: $url answers, but not as a CockroachDB node (no build_timestamp in /_status/vars)" >&2; exit 1; }
    mv "$work/body" "$work/vars"
    echo "metric up 1"
}

# prom <name> [sum|max|min]: a metric of the node's, every series of it
# together (the sum: a node with two stores counts both), or the largest or
# smallest; nothing when the node has no such metric. %.15g, never awk's
# six digits (1.79551e+09).
prom() {
    awk -v m="$1" -v how="${2:-sum}" '
        index($0, m "{") == 1 || index($0, m " ") == 1 {
            v = $NF + 0
            if (!seen) r = v
            else if (how == "max") { if (v > r) r = v }
            else if (how == "min") { if (v < r) r = v }
            else r += v
            seen = 1
        }
        END { if (seen) printf "%.15g\n", r }' "$work/vars"
}
# say <name> <metric> [sum|max|min] [divide by] [times]: "metric <name> <v>"
# when the node has it, divided or multiplied (nanoseconds to seconds, a
# ratio to a percentage), two decimals when it is not whole.
say() {
    local v
    v=$(prom "$2" "${3:-sum}")
    [ -n "$v" ] || return 0
    awk -v v="$v" -v d="${4:-1}" -v x="${5:-1}" -v n="$1" 'BEGIN {
        r = v * x / d
        if (r == int(r)) printf "metric %s %.0f\n", n, r
        else printf "metric %s %.2f\n", n, r
    }'
}

# login: a session for COCKROACH_USER, when it is set (POST /api/v2/login/,
# the password on curl's standard input). An insecure cluster needs none.
login() {
    [ -n "${COCKROACH_USER-}" ] || return 0
    [ -n "${COCKROACH_PASSWORD-}" ] || { echo "$job: COCKROACH_USER is set, and COCKROACH_PASSWORD is not: secret = COCKROACH_PASSWORD=secret:COCKROACH_PASSWORD, then vigil secret set COCKROACH_PASSWORD" >&2; exit 1; }
    local rc
    {
        conf
        printf 'data-urlencode = "username=%s"\n' "$(esc "$COCKROACH_USER")"
        printf 'data-urlencode = "password=%s"\n' "$(esc "$COCKROACH_PASSWORD")"
    } | curl -sS -g -m 30 -K - -o "$work/body" -w '%{http_code}' "$url/api/v2/login/" > "$work/code" 2> "$work/err"
    rc=$?
    case $rc in
        0) ;;
        6 | 7 | 28 | 52 | 56) echo "metric up 0"; exit 0 ;;
        *) echo "metric up 0"; echo "$job: $url: $(head -n 1 "$work/err")" >&2; exit 1 ;;
    esac
    case $(cat "$work/code") in
        200) ;;
        401) echo "metric up 0"; echo "$job: CockroachDB refused the login (HTTP 401): COCKROACH_USER or COCKROACH_PASSWORD is wrong" >&2; exit 1 ;;
        *) echo "metric up 0"; echo "$job: $url/api/v2/login/ answered HTTP $(cat "$work/code")" >&2; exit 1 ;;
    esac
    session=$(jq -r '.session // empty' "$work/body")
    [ -n "$session" ] || { echo "metric up 0"; echo "$job: $url/api/v2/login/ gave no session" >&2; exit 1; }
}
logout() {
    [ -n "$session" ] || return 0
    conf | curl -sS -g -m 10 -K - -X POST -o /dev/null "$url/api/v2/logout/" 2> /dev/null
    session=''
}

# sql <statement>: its rows, a JSON array, in $work/rows, read through the
# SQL API (/api/v2/sql/). 0; else stops: a missing privilege names the one
# packs/cockroachdb/README.md grants.
sql() {
    jq -n --arg s "$1" '{statements: [{sql: $s}], execute: true, max_result_size: 1000000}' > "$work/q"
    get /api/v2/sql/ "$work/q"
    case $? in
        0) ;;
        2) echo "$job: CockroachDB stopped answering at /api/v2/sql/" >&2; exit 1 ;;
        3) echo "$job: CockroachDB answered /api/v2/sql/ with HTTP 503: the cluster is not available" >&2; exit 1 ;;
        4) echo "$job: this user may not use the SQL API: give it the privileges packs/cockroachdb/README.md shows" >&2; exit 1 ;;
        *) exit 1 ;;
    esac
    if jq -e '.error' "$work/body" > /dev/null 2>&1; then
        local m
        m=$(jq -r '.error.message | sub("^executing stmt 1: run-query-via-api: "; "")' "$work/body")
        case $m in
            *privilege* | *'does not have'* | *'not allowed'*) m="$m: packs/cockroachdb/README.md shows the privileges to grant" ;;
        esac
        echo "$job: $m" >&2
        exit 1
    fi
    jq '.execution.txn_results[0].rows // []' "$work/body" > "$work/rows"
}

# jq's helpers: a tag's value (no spaces, quotes or control characters,
# never empty, at most 120 characters), two decimals, and a number from
# anything.
# shellcheck disable=SC2016
jqlib='
def tag: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def r2: (. * 100 | round) / 100;
def n: if . == null then 0 elif type == "string" then (tonumber? // 0) elif type == "boolean" then (if . then 1 else 0 end) else . end;
'
