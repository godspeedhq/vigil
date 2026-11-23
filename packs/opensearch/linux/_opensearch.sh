# shellcheck shell=bash
#
# _opensearch.sh - what the opensearch pack's scripts share: the settings, the login,
# one request to OpenSearch's REST API, and jq's helpers. Each job's script
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
# Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret), with curl and jq. The login goes to curl on its standard input, never on a command line.
# Over https, the certificate is checked against OPENSEARCH_CACERT, a CA file,
# when it is set, else the system's CAs. Every request only reads.

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the opensearch pack reads OpenSearch's API with curl and jq" >&2; exit 1; }
done
url=${OPENSEARCH_URL:-https://localhost:9200}
url=${url%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-opensearch.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)

# esc <text>: for a double-quoted value in curl's config.
esc() {
    local s=$1
    s=${s//\\/\\\\}
    printf '%s' "${s//\"/\\\"}"
}
# The login and the CA, as curl's config, on its standard input: never on
# a command line.
login() {
    [ -n "${OPENSEARCH_USER-}" ] && printf 'user = "%s"\n' "$(esc "$OPENSEARCH_USER:${OPENSEARCH_PASSWORD-}")"
    [ -n "${OPENSEARCH_CACERT-}" ] && printf 'cacert = "%s"\n' "$(esc "$OPENSEARCH_CACERT")"
    return 0
}

# get <path> [<request body file>]: the answer in $work/body, its headers in
# $work/head. 0; 2 when OpenSearch does not answer (a reading); 3 when it has no
# such API (an older version, or a feature that is off); 4 when this user
# may not read it; 5 when the cluster has no elected cluster manager (HTTP 503);
# 1 when it answers wrong, said on stderr.
get() {
    local rc code
    if [ -n "${2-}" ]; then
        login | curl -sS -g -m 30 -K - -X GET -H 'Content-Type: application/json' --data-binary "@$2" \
            -D "$work/head" -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    else
        login | curl -sS -g -m 30 -K - -H 'Accept: application/json' \
            -D "$work/head" -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
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
        401) echo "$job: OpenSearch refused the login (HTTP 401): OPENSEARCH_USER or OPENSEARCH_PASSWORD is wrong" >&2; return 1 ;;
        403) return 4 ;;
        400 | 404 | 405 | 501) return 3 ;;
        503) return 5 ;;
        *) echo "$job: $url$1 answered HTTP $code" >&2; return 1 ;;
    esac
}

# why <get's answer> <path>: stop, saying why.
why() {
    case $1 in
        2) echo "$job: OpenSearch stopped answering at $2" >&2 ;;
        3) echo "$job: OpenSearch has no $2 here (an older version, or a feature that is off)" >&2 ;;
        4) echo "$job: this user may not read $2: give it the role packs/opensearch/README.md shows" >&2 ;;
        5) echo "$job: OpenSearch answered $2 with HTTP 503: the cluster has no elected cluster manager" >&2 ;;
    esac
    exit 1
}
# need <path> [<request body file>]: get, or stop, saying why.
need() {
    get "$@"
    local rc=$?
    [ "$rc" -eq 0 ] || why "$rc" "$1"
}

# first: OpenSearch's own page (/), which every job reads first: up, and that it
# is OpenSearch. Kept in $work/root.
first() {
    get '/?filter_path=name,cluster_name,version.number,version.distribution,tagline'
    case $? in
        0) ;;
        2) echo "metric up 0"; exit 0 ;;
        4) echo "metric up 0"; echo "$job: this user may not read OpenSearch's own page (/): give it the role packs/opensearch/README.md shows" >&2; exit 1 ;;
        1) echo "metric up 0"; exit 1 ;;
        *) echo "metric up 0"; echo "$job: $url answers, but not as OpenSearch (HTTP $(cat "$work/code"))" >&2; exit 1 ;;
    esac
    if ! jq -e '.version.distribution == "opensearch"' "$work/body" > /dev/null 2>&1; then
        echo "metric up 0"
        if grep -qi '^x-elastic-product:' "$work/head"; then
            echo "$job: $url is Elasticsearch, not OpenSearch: the elasticsearch pack reads it" >&2
        else
            echo "$job: $url answers, but not as OpenSearch (its version.distribution is not opensearch)" >&2
        fi
        exit 1
    fi
    cp "$work/body" "$work/root"
    echo "metric up 1"
}

# jq's helpers: a tag's value (no spaces, quotes or control characters,
# never empty, at most 120 characters), two decimals, a number from
# anything, a percentage, a health colour's code, and an ISO time's epoch.
# shellcheck disable=SC2016
jqlib='
def tag: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | .[0:120] | if . == "" then "none" else . end;
def r2: (. * 100 | round) / 100;
def n: if . == null then 0 elif type == "string" then (rtrimstr("%") | tonumber? // 0) elif type == "boolean" then (if . then 1 else 0 end) else . end;
def pct(a; b): if (b | n) > 0 then (100 * (a | n) / (b | n) | r2) else 0 end;
def code: {"green": 0, "yellow": 1, "red": 2}[. // ""] // 3;
def epoch: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
'
