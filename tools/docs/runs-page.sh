#!/usr/bin/env bash
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
# runs-page.sh - the "Real systems" pages, from the evidence the
# real-backend tests keep (tests/integration/backends/reports/runs).
#
#   bash tools/docs/runs-page.sh <dir>
#
# Writes <dir>/index.md, a table of every run, and <dir>/<host>.md, each
# run's console output as it printed it, with a link to its logs and state
# in the repository. Only each host's newest run of each suite. Writes
# nothing and returns 1 when there are no runs.

set -u

repo=$(cd "$(dirname "$0")/../.." && pwd)
dir=${1:?usage: runs-page.sh <dir>}
runs=$repo/tests/integration/backends/reports/runs
tree=https://github.com/godspeedhq/vigil/tree/main/tests/integration/backends/reports/runs

# Every run folder, newest date first, as <date>/<host>/<name>.
all=$(cd "$runs" 2> /dev/null && ls -d */*/*/ 2> /dev/null | sed 's#/$##' | sort -r)
[ -n "$all" ] || exit 1
# Each host's newest run of each name.
latest=$(printf '%s\n' "$all" | awk -F/ '!seen[$2 "/" $3]++' | sort -t/ -k2,2 -k3,3)
hosts=$(printf '%s\n' "$latest" | cut -d/ -f2 | sort -u)

# What a run's console says, as "<pass> <fail> <not run> <other>".
counts() {
    tr -d '\r' < "$1" | awk '
        /^ +PASS /                 { p++ }
        /^ +FAIL /                 { f++ }
        /^ +NOT RUN /              { n++ }
        /^ +(EMULATOR LIMITATION|NOT SUPPORTED|NOT APPLICABLE) / { o++ }
        END { printf "%d %d %d %d\n", p, f, n, o }'
}
# The value of header field $2 in console $1.
field() { tr -d '\r' < "$1" | sed -n "s/^$2 *//p" | head -n 1; }
title() {
    case $1 in
        fedora) echo 'Fedora' ;;
        macos) echo 'macOS' ;;
        windows) echo 'Windows' ;;
        *) echo "$1" ;;
    esac
}

mkdir -p "$dir"
{
    printf '# Real systems\n\n'
    printf 'Vigil against real servers on real machines: the secret stores, sources and backends of [`tests/integration/backends`](https://github.com/godspeedhq/vigil/tree/main/tests/integration/backends), run on Fedora (the Docker host), macOS 12 (bash 3.2) and Windows 11 (PowerShell 5.1). '
    printf 'Each run keeps everything it printed, with a header naming the commit and the versions of every tool and image, and Vigil'"'"'s own configuration, logs, state and metrics as the run left them. Nothing here is typed by hand: these pages are built from those files.\n\n'
    printf 'An emulator proves Vigil'"'"'s requests and how it reads the answers, not the real cloud: where one behaves differently, the run says EMULATOR LIMITATION, and never counts it as a pass. NOT RUN always says why.\n\n'
    printf '| Host | Run | Date | Passed | Failed | Not run | Other |\n| --- | --- | --- | --- | --- | --- | --- |\n'
    printf '%s\n' "$latest" | while IFS=/ read -r d h n; do
        c=$runs/$d/$h/$n/console.txt
        [ -f "$c" ] || continue
        set -- $(counts "$c")
        printf '| %s | [%s](/vigil/real/%s/#%s) | %s | %s | %s | %s | %s |\n' "$(title "$h")" "$n" "$h" "$n" "$d" "$1" "$2" "$3" "$4"
    done
    printf '\n*Other* is emulator limitations, and what Vigil does not support or does not send (traces, KV v1).\n'
} > "$dir/index.md"

for h in $hosts; do
    {
        printf '# %s\n\n' "$(title "$h")"
        printf '%s\n' "$latest" | awk -F/ -v h="$h" '$2 == h' | while IFS=/ read -r d _ n; do
            c=$runs/$d/$h/$n/console.txt
            [ -f "$c" ] || continue
            printf '## %s\n\n' "$n"
            printf -- '- **Commit:** %s\n' "$(field "$c" vigil)"
            printf -- '- **System:** %s\n' "$(field "$c" os)"
            printf -- '- **Logs, state and metrics:** [%s/%s/%s](%s/%s/%s/%s)\n\n' "$d" "$h" "$n" "$tree" "$d" "$h" "$n"
            printf '```text\n'
            # The transcript's own banner says nothing the header doesn't.
            tr -d '\r' < "$c" | awk '
                /^\*{22}$/ { banner = !banner; next }
                banner { next }
                { print }' | sed 's/```/` ` `/g'
            printf '```\n\n'
        done
    } > "$dir/$h.md"
done
