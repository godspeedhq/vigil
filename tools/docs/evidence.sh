#!/usr/bin/env bash
#
# evidence.sh - the Test evidence page, from the logs of a real CI run.
#
#   bash tools/docs/evidence.sh [<run id>]    default: the newest passing
#                                             conformance run on main
#
# Prints Markdown: for Linux, macOS and Windows, the console output of three
# integration tests, as CI printed it, with only its timestamps removed.
# Nothing here is typed by hand, and the page links to the run, so anyone can
# compare it with the original. Prints nothing and returns 1 if it cannot
# reach a passing run: a site is better without the page than with a stale
# or partial one.
#
# Needs gh, signed in or with GH_TOKEN set, curl and awk.

set -u

slug=godspeedhq/vigil
run=${1-}
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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vigil-evidence.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# The console output of the step that ran command $2 in log file $1: the
# first one, with timestamps and the runner's own lines removed.
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

# One operating system: job name $1, title $2, then "<heading>|<command>".
section() {
    local job=$1 title=$2 id item heading cmd
    shift 2
    id=$(gh api "repos/$slug/actions/runs/$run/jobs" --paginate --jq ".jobs[] | select(.name == \"$job\") | .id" 2> /dev/null | head -n 1)
    [ -n "$id" ] || return 1
    curl -sfL -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$slug/actions/jobs/$id/logs" > "$tmp/log" || return 1
    printf '## %s\n\n[The full log of this job](%s/job/%s).\n\n' "$title" "$url" "$id"
    for item in "$@"; do
        heading=${item%%|*}
        cmd=${item#*|}
        step "$tmp/log" "$cmd" > "$tmp/out"
        grep -q ' passed, 0 failed$' "$tmp/out" || return 1
        printf '### %s\n\n```text\n$ %s\n' "$heading" "$cmd"
        cat "$tmp/out"
        printf '```\n\n'
    done
}

{
    printf '# Test evidence\n\n'
    printf 'Real console output from CI, on real Linux, macOS and Windows machines: three integration tests for each. '
    printf 'This page is generated from the logs of the newest passing run on `main`, and only timestamps are removed.\n\n'
    printf '| | |\n| --- | --- |\n'
    printf '| Run | [%s](%s) |\n| Commit | [`%s`](https://github.com/%s/commit/%s) |\n| Finished | %s |\n\n' "$run" "$url" "${sha:0:7}" "$slug" "$sha" "$when"
    printf 'A `SKIP` line means that part did not run on that machine, and says why.\n\n'
    section 'bash (ubuntu-latest)' 'Linux (Ubuntu)' \
        'Self-update|/bin/bash tests/integration/self-update.sh' \
        'Sources and the fetcher|/bin/bash tests/integration/fetch.sh' \
        'Log forwarding|/bin/bash tests/integration/logs.sh' || exit 1
    section 'bash (macos-latest)' 'macOS (bash 3.2)' \
        'Self-update|/bin/bash tests/integration/self-update.sh' \
        'Sources and the fetcher|/bin/bash tests/integration/fetch.sh' \
        'Log forwarding|/bin/bash tests/integration/logs.sh' || exit 1
    section windows 'Windows (PowerShell 5.1)' \
        'Self-update|./tests/integration/Self-Update.ps1' \
        'Sources and the fetcher|./tests/integration/Fetch.ps1' \
        'Log forwarding|./tests/integration/Logs.ps1' || exit 1
} > "$tmp/page" || exit 1
cat "$tmp/page"
