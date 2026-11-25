# _docker.sh - what every job of the docker pack shares: where the engine
# is, a GET to it, and the helpers its jq programs use. Not a job: each job
# script sources it.
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
# Reads the Docker engine's API at DOCKER_HOST: unix:///var/run/docker.sock
# by default (and, where that is not there, Docker Desktop's own
# ~/.docker/run/docker.sock). Every request is a GET. The account the job runs as must be
# allowed to use the socket (root, or a member of the docker group): that
# is as good as root on the machine, as it is for anyone who can run docker.

export LC_ALL=C
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-docker.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)
# How many containers a job names, one by one; the rest are counted.
most=${DOCKER_MOST:-100}
case $most in '' | *[!0-9]*) most=100 ;; esac

# needs <program>...: stop, saying which is missing.
needs() {
    local p
    for p in "$@"; do
        command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the docker pack reads the engine's API with curl and jq" >&2; exit 1; }
    done
}

host=${DOCKER_HOST-}
if [ -z "$host" ]; then
    host=unix:///var/run/docker.sock
    [ -S /var/run/docker.sock ] || { [ -S "${HOME-}/.docker/run/docker.sock" ] && host=unix://$HOME/.docker/run/docker.sock; }
fi
case $host in
    unix://*) sock=${host#unix://} ;;
    *) echo "$job: DOCKER_HOST is $host: the docker pack reads the engine on this machine, at unix:///path/to/docker.sock" >&2; exit 1 ;;
esac
base=http://docker

# fetch <config file>: one curl for every "url = / output =" pair in the
# file, over one connection. 0, or 2 when no engine answers (a reading), or
# 1 when the account may not use the socket or it answers wrong (said on
# stderr).
fetch() {
    local code
    curl -sS -g -m "${DOCKER_TIMEOUT:-60}" --unix-socket "$sock" -K "$1" > /dev/null 2> "$work/err"
    code=$?
    case $code in
        0) return 0 ;;
    esac
    if grep -qi 'permission denied' "$work/err"; then
        echo "$job: this account may not use $host: run the job as root, or add the account to the docker group (which is as good as root on this machine)" >&2
        return 1
    fi
    case $code in
        6 | 7 | 28 | 52 | 56) return 2 ;;
    esac
    echo "$job: $host: $(cat "$work/err")" >&2
    return 1
}

# get <path> <name>: the answer in $work/<name>.
get() {
    printf 'url = "%s%s"\noutput = "%s/%s"\n' "$base" "$1" "$work" "$2" > "$work/one.cfg"
    fetch "$work/one.cfg"
}

# engine: the engine's version in $work/version, and "metric up". Nothing
# answering is a reading: up 0, and the run succeeds.
engine() {
    get /version version
    case $? in
        0) ;;
        2) echo 'metric up 0'; exit 0 ;;
        *) echo 'metric up 0'; exit 1 ;;
    esac
    if ! jq -e 'type == "object" and has("ApiVersion")' "$work/version" > /dev/null 2>&1; then
        echo 'metric up 0'
        echo "$job: $host answers, but not as a Docker engine" >&2
        exit 1
    fi
    echo 'metric up 1'
}

# each <list file> <path with %s> <prefix>: one GET for each id in the list
# (one a line), the answers in $work/<prefix>.<id>, then all of them, those
# that are still there, as one JSON array in $work/<prefix>.all.
each() {
    local id
    : > "$work/each.cfg"
    : > "$work/$3.files"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        # shellcheck disable=SC2059
        printf "url = \"$base$2\"\noutput = \"%s/%s.%s\"\n" "$id" "$work" "$3" "$id" >> "$work/each.cfg"
        printf '%s/%s.%s\n' "$work" "$3" "$id" >> "$work/$3.files"
    done < "$1"
    if [ -s "$work/each.cfg" ]; then
        fetch "$work/each.cfg" || return $?
    fi
    # A container removed since the list was read answers {"message": ...}.
    # Each answer keeps the id it was asked for, in asked: some engines leave
    # a container's name out of its statistics.
    [ -s "$work/$3.files" ] || { echo '[]' > "$work/$3.all"; return 0; }
    # shellcheck disable=SC2046
    jq -n '[inputs as $x | select(($x | type) == "object" and ($x | has("message") | not)) | $x + {asked: (input_filename | sub("^.*[.]"; ""))}]' $(cat "$work/$3.files") > "$work/$3.all" 2> /dev/null || return 1
}

# jq helpers: a tag's value (no spaces, never empty, at most 120
# characters); a container's name; a number with at most three decimals
# and never an exponent; a time as seconds since 1970, or 0.
defs='def safe: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | if . == "" then "none" else .[0:120] end;
      def cname: ((.Names // [])[0] // .Name // .Id // "none") | sub("^/"; "");
      def num: if . == null then 0 elif . == (. | floor) then floor else (. * 1000 | round) / 1000 | if . == (. | floor) then floor else . end end;
      def epoch: if . == null or . == "" or startswith("0001-") then 0 else (try (sub("[.][0-9]+"; "") | fromdateiso8601) catch 0) end;'
