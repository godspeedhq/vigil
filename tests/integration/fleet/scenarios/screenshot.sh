#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# screenshot.sh <backend address> <from, UTC ISO> <to, UTC ISO> <out.png> -
# the fleet dashboard over that time, as a picture, with a headless Chrome
# or Edge. Host names listed in backend/out/mask.txt (name=label lines; it
# is not in Git, so the names it hides are not either) are replaced: the
# picture is of a copy of the dashboard (vigil-fleet-evidence) whose
# queries rename them.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -eq 4 ] || { sed -n '10,16p' "$0"; exit 64; }
addr=$1 from=$(( $(date -d "$2" +%s) * 1000 )) to=$(( $(date -d "$3" +%s) * 1000 )) png=$4
mask=$here/../backend/out/mask.txt
o='--cacert'; curl --version | grep -qi schannel && o='--ssl-no-revoke --cacert'
# Each host-carrying query, wrapped in one label_replace per masked name.
wrap='.'
if [ -f "$mask" ]; then
    while IFS='=' read -r n l; do
        [ -n "$n" ] || continue
        wrap="$wrap | \"label_replace(\" + . + \", \\\"host\\\", \\\"$l\\\", \\\"host\\\", \\\"$n\\\")\""
    done < "$mask"
    hostfmt='{{ .host' ; while IFS='=' read -r n l; do [ -n "$n" ] && hostfmt="$hostfmt | replace \\\"$n\\\" \\\"$l\\\""; done < "$mask"; hostfmt="$hostfmt }}"
else
    hostfmt='{{.host}}'
fi
# shellcheck disable=SC2086
jq --arg hostfmt "$hostfmt" "
  .uid = \"vigil-fleet-evidence\" | .title = \"Vigil fleet test (evidence)\" |
  .panels |= map(if .datasource.type == \"prometheus\" then .targets |= map(.expr |= ($wrap)) else . end) |
  .panels |= map(if .type == \"logs\" then .options.showLabels = false | .options.enableLogDetails = false
    | .targets |= map(.expr |= sub(\"line_format .*$\"; \"line_format \\\"\" + \$hostfmt + \"  {{ __line__ }}\\\" | keep kind\")) else . end) |
  {dashboard: ., overwrite: true}" "$here/../backend/dashboards/fleet.json" \
    | curl -sS $o "$here/../tls/out/ca.crt" -u admin:admin -H 'Content-Type: application/json' -d @- \
        "https://$addr:3000/api/dashboards/db" > /dev/null
rm -f "$png"
url="https://$addr:3000/d/vigil-fleet-evidence/x?orgId=1&kiosk&from=$from&to=$to&refresh=&var-kind=All"
for b in 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' 'C:/Program Files/Google/Chrome/Application/chrome.exe' \
         /usr/bin/google-chrome /usr/bin/chromium '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; do
    [ -x "$b" ] || [ -f "$b" ] || continue
    prof=$(mktemp -d); out=$png
    command -v cygpath > /dev/null && { prof=$(cygpath -w "$prof"); out=$(cygpath -w "$png"); }
    "$b" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$prof" --window-size=1900,1650 \
        --virtual-time-budget=90000 --screenshot="$out" "$url" > /dev/null 2>&1 || true
    [ -s "$png" ] && { echo "$png"; exit 0; }
done
echo "no Chrome or Edge made a picture" >&2; exit 1
