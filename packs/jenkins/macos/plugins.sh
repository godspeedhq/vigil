#!/usr/bin/env bash
#
# plugins.sh - Jenkins' plugins: how many, those with an update, those not
# active, pinned or about to go; and the update sites
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
# The plugin manager (/pluginManager/api/json) and the update sites
# (/updateCenter/api/json). The plugins need more than a read-only user:
# Overall/SystemRead (Jenkins started with
# -Djenkins.security.SystemReadPermission=true) or Overall/Administer.
# Without it, this job says readable 0, and nothing else: no failure.
#
# Reads Jenkins' REST API at JENKINS_URL, as JENKINS_USER with the API token
# in JENKINS_API_TOKEN (a secret), with curl and jq; the token goes to curl
# on its standard input, never on a command line. Over https, the
# certificate is checked against JENKINS_CACERT when it is set.
#
# Metrics:
#   up                  1 when Jenkins answers, else 0
#   readable            1 when this user may read the plugins, else 0
#   plugins             plugins installed
#   updates             of those, with a newer version to install
#   inactive            of those, not active (failed to load, or a
#                       dependency missing)
#   disabled            of those, disabled
#   pinned              of those, pinned to their version
#   bundled             of those, that came with Jenkins
#   deleted             of those, to be removed at the next restart
#   downgradable        of those, with an older version kept to go back to
#   update              always 1, for one plugin with an update, tagged
#                       plugin=<its name> and version=<the version
#                       installed>
#   inactive_plugin     always 1, for one plugin not active, tagged the
#                       same
#   sites               update sites
#   sites_with_updates  of those, offering updates
#   updates_not_shown   past the first 100, how many were left out
#
# Example output:
#   metric up 1
#   metric readable 1
#   metric plugins 52
#   metric updates 0
#   metric inactive 0
#   metric disabled 0
#   metric pinned 0
#   metric bundled 0
#   metric deleted 0
#   metric downgradable 0
#   metric updates_not_shown 0
#   metric sites 1
#   metric sites_with_updates 0
#
# Reading the results (starting points: tune them to the controller):
#   Healthy  inactive 0; updates few, and applied on a schedule.
#   Watch    updates climbing: plugins left behind (and their security
#            fixes); deleted above 0: a restart is due; readable 0: give the
#            user Overall/SystemRead to see the plugins.
#   Act      inactive above 0: a plugin failed to load, and what depends
#            on it does not work (the reason is in Jenkins' log).
#
# Requires: bash, curl and jq
# Exit code: 0 on success, Jenkins up or down; 1 if curl or jq is missing,
#   a setting is wrong, the login is refused, or the address is not Jenkins

set -u

for p in curl jq; do
    command -v "$p" > /dev/null 2>&1 || { echo "plugins: $p not found: the jenkins pack reads Jenkins' API with curl and jq" >&2; exit 1; }
done
url=${JENKINS_URL:-http://127.0.0.1:8080}
url=${url%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-jenkins.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# get <path>: the body in $work/body; 0, or 2 when Jenkins does not answer
# (a reading), 3 when this user may not read the page, or 1 when it
# answers wrong (said on stderr). The login goes on curl's standard input.
get() {
    local code status
    {
        [ -n "${JENKINS_USER-}" ] && printf 'user = "%s:%s"\n' "$JENKINS_USER" "${JENKINS_API_TOKEN-}"
        [ -n "${JENKINS_CACERT-}" ] && printf 'cacert = "%s"\n' "$JENKINS_CACERT"
    } | curl -sS -g -m 60 -K - -D "$work/head" -o "$work/body" -w '%{http_code}' "$url$1" > "$work/code" 2> "$work/err"
    code=$?
    status=$(cat "$work/code" 2> /dev/null)
    case $code in
        0) ;;
        6 | 7 | 28 | 52 | 56) return 2 ;;
        *) echo "plugins: $url$1: $(cat "$work/err")" >&2; return 1 ;;
    esac
    case $status in
        200) ;;
        401) echo "plugins: Jenkins refused the login (HTTP 401): JENKINS_USER, or the API token in JENKINS_API_TOKEN, is wrong" >&2; return 1 ;;
        403) return 3 ;;
        *) echo "plugins: $url$1 answered HTTP $status" >&2; return 1 ;;
    esac
    if ! grep -qi '^x-jenkins:' "$work/head"; then
        echo "plugins: $url answers, but not as Jenkins (no X-Jenkins header)" >&2
        return 1
    fi
}

# jq helpers: a tag's value, and a job's full name from its URL.
defs='def safe: tostring | gsub("[^A-Za-z0-9@._:/+-]"; "_") | if . == "" then "none" else .[0:120] end;
      def fullname: (.url // "") | sub("^.*?/job/"; "") | gsub("/job/"; "/") | sub("/$"; "") | if . == "" then "none" else . end;'

# up, from the page this job reads.
read_page() {
    get "$1"
    case $? in
        0) echo "metric up 1" ;;
        2) echo "metric up 0"; exit 0 ;;
        3) echo "metric up 0"; echo "plugins: this user may not read $1: give it Overall/Read, Job/Read and Agent/Read" >&2; exit 1 ;;
        *) echo "metric up 0"; exit 1 ;;
    esac
}

get '/pluginManager/api/json?depth=1&tree=plugins[shortName,version,active,enabled,hasUpdate,pinned,bundled,deleted,downgradable]'
case $? in
    0) ;;
    2) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 1"; echo "metric readable 0"; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
echo "metric up 1"
echo "metric readable 1"
jq -r "$defs"'
    .plugins as $p |
    "metric plugins \($p | length)",
    "metric updates \([$p[] | select(.hasUpdate)] | length)",
    "metric inactive \([$p[] | select(.active | not)] | length)",
    "metric disabled \([$p[] | select(.enabled | not)] | length)",
    "metric pinned \([$p[] | select(.pinned == true)] | length)",
    "metric bundled \([$p[] | select(.bundled == true)] | length)",
    "metric deleted \([$p[] | select(.deleted == true)] | length)",
    "metric downgradable \([$p[] | select(.downgradable == true)] | length)",
    ([$p[] | select(.hasUpdate)][0:100][] | "metric update 1 plugin=\(.shortName | safe) version=\(.version | safe)"),
    ([$p[] | select(.active | not)][0:100][] | "metric inactive_plugin 1 plugin=\(.shortName | safe) version=\(.version | safe)"),
    "metric updates_not_shown \([([$p[] | select(.hasUpdate)] | length) - 100, 0] | max)"
' "$work/body" || exit 1
if get '/updateCenter/api/json?tree=sites[id,hasUpdates]'; then
    jq -r '"metric sites \(.sites | length)", "metric sites_with_updates \([.sites[] | select(.hasUpdates)] | length)"' "$work/body" || exit 1
fi
exit 0
