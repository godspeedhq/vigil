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
# tour-page.sh - the "Logs and output" pages, from the tour CI ran.
#
#   bash tools/docs/tour-page.sh <dir> [<run id>]   default: the newest
#                                                   passing conformance
#                                                   run on main
#
# Writes linux.md, macos.md and windows.md into <dir>: the console output of
# tour.sh and Tour.ps1 as CI printed it, with only timestamps removed, set
# out as commands and files. Nothing here is typed by hand, and each page
# links to the run. Writes nothing and returns 1 if a tour is missing or did
# not finish: a site is better without the pages than with partial ones.
#
# Needs gh, signed in or with GH_TOKEN set, curl and awk.

set -u

slug=godspeedhq/vigil
dir=${1:?usage: tour-page.sh <dir> [<run id>]}
run=${2-}
if [ -z "$run" ]; then
    run=$(gh run list --repo "$slug" --workflow conformance --branch main --status success --limit 1 \
        --json databaseId --jq '.[0].databaseId' 2> /dev/null)
fi
[ -n "$run" ] || exit 1
info=$(gh run view "$run" --repo "$slug" --json headSha,updatedAt,url,conclusion \
    --jq '[.headSha, .updatedAt, .url, .conclusion] | join(" ")' 2> /dev/null) || exit 1
set -- $info
sha=$1 when=$2 url=$3 conclusion=$4
[ "$conclusion" = success ] || exit 1

token=${GH_TOKEN:-$(gh auth token 2> /dev/null)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vigil-tour-page.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# The console output of the step that ran command $2 in log file $1, as in
# evidence.sh: timestamps and the runner's own lines removed.
step() {
    awk -v cmd="$2" '
        { sub(/^\xef\xbb\xbf/, ""); sub(/^[0-9-]+T[0-9:.]+Z /, ""); sub(/\r$/, "") }
        !on && !done && /^##\[group\]Run / && index($0, cmd) { on = 1; head = 1; next }
        on && /^##\[group\]Run / { on = 0; done = 1 }
        on && head { if (/^##\[endgroup\]/) head = 0; next }
        on && /^##\[(group|endgroup)\]/ { next }
        on && /^##\[error\]/ { next }
        on { print }
    ' "$1"
}

# The tour's markers as Markdown: a heading per section, a paragraph per
# note, and a block per command or file.
render() {
    awk '
        function close_block() { if (open) { print "```\n"; open = 0 } }
        /^::section / { close_block(); print "## " substr($0, 11) "\n"; next }
        /^::note / { close_block(); print substr($0, 8) "\n"; next }
        /^::cmd / { close_block(); print "```text\n$ " substr($0, 7); open = 1; next }
        /^::file / { close_block(); print "`" substr($0, 8) "`\n\n```text"; open = 1; next }
        /^::done$/ { close_block(); exit }
        open { print }
    '
}

# One operating system: job name $1, command $2, title $3, output file $4.
tour() {
    local job=$1 cmd=$2 title=$3 file=$4 id
    id=$(gh api "repos/$slug/actions/runs/$run/jobs" --paginate --jq ".jobs[] | select(.name == \"$job\") | .id" 2> /dev/null | head -n 1)
    [ -n "$id" ] || return 1
    curl -sfL -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$slug/actions/jobs/$id/logs" > "$tmp/log" || return 1
    step "$tmp/log" "$cmd" > "$tmp/out"
    grep -qx '::done' "$tmp/out" || return 1
    {
        printf '# %s\n\n' "$title"
        printf 'Real output from a CI machine running %s, from [this run](%s/job/%s) ' "$title" "$url" "$id"
        printf 'of commit [`%s`](https://github.com/%s/commit/%s), finished %s. ' "${sha:0:7}" "$slug" "$sha" "$when"
        printf 'Only timestamps the CI added are removed, and the temporary install folder is shown where a system install puts it.\n\n'
        render < "$tmp/out"
    } > "$tmp/$file"
}

tour 'bash (ubuntu-latest)' '/bin/bash tools/docs/tour.sh' 'Linux (Ubuntu)' linux.md &&
    tour 'bash (macos-latest)' '/bin/bash tools/docs/tour.sh' 'macOS' macos.md &&
    tour 'windows (PowerShell 5.1)' './tools/docs/Tour.ps1' 'Windows (PowerShell 5.1)' windows.md || exit 1
mkdir -p "$dir" && cp "$tmp/linux.md" "$tmp/macos.md" "$tmp/windows.md" "$dir/"
