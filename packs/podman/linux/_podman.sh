# _podman.sh - what every job of the podman pack shares: asking Podman, and
# the helpers its jq programs use. Not a job: each job script sources it.
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
# Asks Podman with its own command, as the account the job runs as, and
# only ever to read (info, ps, inspect, stats, system df, images, volume
# ls). Podman keeps containers by account: a job run as root reads root's
# containers, and a job run as another account reads that account's
# (rootless), and no one else's. On macOS, and wherever CONTAINER_HOST or
# CONTAINER_CONNECTION is set, the command asks the Podman it is connected
# to (a podman machine, a remote one).

export LC_ALL=C
# An env line left empty in the configuration is not a setting.
[ -n "${CONTAINER_HOST-}" ] || unset CONTAINER_HOST
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-podman.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)
# How many containers a job names, one by one; the rest are counted.
most=${PODMAN_MOST:-100}
case $most in '' | *[!0-9]*) most=100 ;; esac

# needs <program>...: stop, saying which is missing.
needs() {
    local p
    for p in "$@"; do
        command -v "$p" > /dev/null 2>&1 || { echo "$job: $p not found: the podman pack asks Podman with its own command, and reads the answers with jq" >&2; exit 1; }
    done
}

# ask <name> <podman arguments>...: the answer in $work/<name>; 0, or 1
# with what Podman said on stderr.
ask() {
    local name=$1
    shift
    if ! podman "$@" > "$work/$name" 2> "$work/err"; then
        echo "$job: podman $1: $(head -n 3 "$work/err" | tr '\n' ' ')" >&2
        return 1
    fi
}

# engine: what Podman says about itself in $work/info, and "metric up".
# A Podman that cannot be reached (a machine that is stopped, a remote one
# that does not answer) is a reading: up 0, and the run succeeds.
engine() {
    if podman info --format json > "$work/info" 2> "$work/err" && jq -e 'type == "object" and has("host")' "$work/info" > /dev/null 2>&1; then
        echo 'metric up 1'
        return 0
    fi
    echo 'metric up 0'
    if grep -qiE 'cannot connect|unable to connect|connection refused|no such file or directory|not running|dial ' "$work/err"; then
        exit 0
    fi
    echo "$job: podman info: $(head -n 3 "$work/err" | tr '\n' ' ')" >&2
    exit 1
}

# jq helpers: a tag's value (no spaces, never empty, at most 120
# characters); a container's name; a number with at most three decimals
# and never an exponent.
defs='def safe: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | if . == "" then "none" else .[0:120] end;
      def cname: (if (.Names | type) == "array" then .Names[0] else (.Names // .Name) end) // .Id // "none" | sub("^/"; "");
      def num: if . == null then 0 elif . == (. | floor) then floor else (. * 1000 | round) / 1000 | if . == (. | floor) then floor else . end end;'
