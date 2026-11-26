# shellcheck shell=bash
#
# _clickhouse.sh - what the clickhouse pack's scripts share: the settings,
# the login, one SELECT over ClickHouse's HTTP interface, and jq's helpers.
# Each job's script sources it; it is never run as a job.
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
# Reads the ClickHouse server at CLICKHOUSE_URL (default
# http://localhost:8123), its HTTP interface, as CLICKHOUSE_USER (default
# vigil) with the password in CLICKHOUSE_PASSWORD (a secret). The user and
# password reach curl on its standard input, as headers, never on a command
# line. Over https, the certificate is checked against CLICKHOUSE_CACERT
# when it is set, else the system's CAs. Every statement is a SELECT from
# the system tables, and the user is made read-only (readonly = 1), so the
# server itself refuses anything else.

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the clickhouse pack reads ClickHouse's HTTP interface with curl and jq" >&2; exit 1; }
done
url=${CLICKHOUSE_URL:-http://localhost:8123}
url=${url%/}
user=${CLICKHOUSE_USER-vigil}
most=${CLICKHOUSE_MOST:-50}
case $most in '' | *[!0-9]*) echo "$job: CLICKHOUSE_MOST is '$most': a number" >&2; exit 1 ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-clickhouse.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# esc <text>: for a double-quoted value in curl's config.
esc() {
    local s=$1
    s=${s//\\/\\\\}
    printf '%s' "${s//\"/\\\"}"
}
# curl's config, on its standard input: the CA, and the login. Never on a
# command line.
conf() {
    [ -n "${CLICKHOUSE_CACERT-}" ] && printf 'cacert = "%s"\n' "$(esc "$CLICKHOUSE_CACERT")"
    if [ -n "$user" ]; then
        printf 'header = "X-ClickHouse-User: %s"\n' "$(esc "$user")"
        [ -n "${CLICKHOUSE_PASSWORD-}" ] && printf 'header = "X-ClickHouse-Key: %s"\n' "$(esc "$CLICKHOUSE_PASSWORD")"
    fi
    return 0
}

# up: "metric up 1" when the server answers /ping, else "metric up 0" and
# the run ends, successfully: a server down is a reading.
up() {
    local rc
    conf | curl -sS -g -m 15 -K - -o "$work/ping" -w '%{http_code}' "$url/ping" > "$work/code" 2> "$work/err"
    rc=$?
    case $rc in
        0) ;;
        6 | 7 | 28 | 52 | 56) echo "metric up 0"; exit 0 ;;
        *) echo "metric up 0"; echo "$job: $url: $(head -n 1 "$work/err")" >&2; exit 1 ;;
    esac
    if [ "$(cat "$work/code")" != 200 ] || [ "$(cat "$work/ping")" != 'Ok.' ]; then
        echo "metric up 0"
        echo "$job: $url/ping answered HTTP $(cat "$work/code"), not as ClickHouse does" >&2
        exit 1
    fi
    echo "metric up 1"
}

# sel <statement>: its rows, a JSON array, in $work/rows. 0; 5 when the
# server has no such table or column (an older version), said nowhere;
# else the run ends, saying why: a wrong password, a user that may not read
# the system tables.
sel() {
    local rc code m
    printf '%s FORMAT JSONEachRow' "$1" > "$work/q"
    conf | curl -sS -g -m 50 -K - --data-binary "@$work/q" -o "$work/body" -w '%{http_code}' "$url/" > "$work/code" 2> "$work/err"
    rc=$?
    case $rc in
        0) ;;
        6 | 7 | 28 | 52 | 56) echo "$job: ClickHouse stopped answering at $url" >&2; exit 1 ;;
        *) echo "$job: $url: $(head -n 1 "$work/err")" >&2; exit 1 ;;
    esac
    code=$(cat "$work/code")
    if [ "$code" = 200 ]; then
        jq -s '.' "$work/body" > "$work/rows" 2> /dev/null || { echo "$job: $url answered, but not with rows of JSON" >&2; exit 1; }
        return 0
    fi
    m=$(head -c 400 "$work/body" | tr '\n' ' ')
    case $m in
        *'Code: 60.'* | *'Code: 47.'* | *'Code: 16.'*) return 5 ;;
        *'Code: 516.'* | *'Code: 192.'* | *'Code: 194.'*) echo "$job: ClickHouse refused the login: CLICKHOUSE_USER or CLICKHOUSE_PASSWORD is wrong" >&2; exit 1 ;;
        *'Code: 497.'*) echo "$job: $user may not read the system tables: GRANT SELECT ON system.* TO $user (packs/clickhouse/README.md)" >&2; exit 1 ;;
        *) echo "$job: $url answered HTTP $code: ${m%% (version*}" >&2; exit 1 ;;
    esac
}

# jq's helpers: a tag's value (no spaces, quotes or control characters,
# never empty, at most 120 characters), two decimals, a number from anything
# (ClickHouse writes 64-bit numbers in quotes), and a metric line.
# shellcheck disable=SC2016
jqlib='
def tag: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def n: if . == null then 0 elif type == "string" then (tonumber? // 0) elif type == "boolean" then (if . then 1 else 0 end) else . end;
def r2: (. * 100 | round) / 100;
def m($name; $v): "metric \($name) \($v | n | r2)";
def m($name; $v; $tags): "metric \($name) \($v | n | r2) \($tags)";
'
