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
# setup.sh <backend address> - starts the fleet test's backend (compose.yaml)
# and makes Gitea ready for the fleet:
#   - an admin (fleetadmin) and a user the fleet reads as (fleet-reader),
#     each with a random password Gitea makes;
#   - a token for each: the admin's to manage the repository, the reader's
#     to read it (read:repository, nothing more);
#   - a private repository, fleet/config, the reader its only collaborator,
#     with the configurations config/make-configs.sh writes, at wave 1.
# Everything secret goes into backend/out/ (this account's, ignored by
# Git), never onto a command line: Git reads the admin's token through an
# askpass helper. Run again, it keeps what exists.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ "$#" -eq 1 ] || { echo "usage: setup.sh <backend address>" >&2; exit 64; }
addr=$1
out=$here/out
ca=$here/../tls/out/ca.crt
[ -f "$ca" ] || { echo "no CA: run tls/make-tls.sh $addr first" >&2; exit 1; }
mkdir -p "$out" && chmod 700 "$out"
export FLEET_ADDR=$addr
dc() { docker compose -p vigil-fleet --project-directory "$here" -f "$here/compose.yaml" "$@"; }
dc up -d --quiet-pull
g() { docker exec -u git vigil-fleet-gitea-1 gitea "$@"; }
for _ in $(seq 1 60); do g admin user list > /dev/null 2>&1 && break; sleep 2; done

# curl, with the CA (and on Windows, no revocation check: the test CA has
# no revocation list), its header on standard input, never on the line.
cu() {
    local o='--cacert'
    curl --version | grep -qi schannel && o='--ssl-no-revoke --cacert'
    # shellcheck disable=SC2086
    printf 'header = "Authorization: token %s"\n' "$(cat "$out/admin.token")" | curl -sS -K - $o "$ca" "$@"
}
api=https://$addr:8443/api/v1

for u in fleetadmin fleet-reader; do
    if ! g admin user list | awk '{ print $2 }' | grep -qx "$u"; then
        extra=''; [ "$u" = fleetadmin ] && extra=--admin
        # shellcheck disable=SC2086
        g admin user create $extra --username "$u" --email "$u@fleet.test" --random-password --must-change-password=false \
            | sed -n 's/.*generated random password is .\(.*\).$/\1/p' > "$out/$u.pw"
        echo "user     $u"
    fi
done
[ -s "$out/admin.token" ] || g admin user generate-access-token --username fleetadmin --token-name setup \
    --scopes write:repository,write:organization,write:user --raw > "$out/admin.token"
[ -s "$out/reader.token" ] || g admin user generate-access-token --username fleet-reader --token-name fleet \
    --scopes read:repository --raw > "$out/reader.token"
chmod 600 "$out"/*
echo 'tokens   fleetadmin (manages), fleet-reader (read:repository)'

cu -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"username":"fleet","visibility":"private"}' "$api/orgs" || true
cu -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"name":"config","private":true,"default_branch":"main"}' "$api/orgs/fleet/repos" || true
cu -o /dev/null -X PUT -H 'Content-Type: application/json' -d '{"permission":"read"}' "$api/repos/fleet/config/collaborators/fleet-reader"
echo "repo     https://$addr:8443/fleet/config (private; fleet-reader may read it)"

# The configurations, at wave 1, unless the repository has them already.
repo=$out/config-repo
cat > "$out/askpass.sh" <<EOF
#!/bin/sh
case "\$1" in Username*) echo fleetadmin ;; *) cat "$out/admin.token" ;; esac
EOF
chmod 700 "$out/askpass.sh"
gitf() { GIT_ASKPASS=$out/askpass.sh GIT_TERMINAL_PROMPT=0 git -C "$repo" -c credential.helper= -c http.sslCAInfo="$ca" -c http.sslBackend=openssl "$@"; }
if [ ! -d "$repo/.git" ]; then
    git init -q -b main "$repo"
    git -C "$repo" config user.name 'fleet test' && git -C "$repo" config user.email 'fleet@fleet.test'
    git -C "$repo" config core.autocrlf false
    git -C "$repo" remote add origin "https://$addr:8443/fleet/config.git"
    if gitf fetch -q origin main 2> /dev/null; then
        gitf reset -q --hard origin/main
    else
        bash "$here/../config/make-configs.sh" "$addr" "$repo" 1 > /dev/null
        gitf add -A && gitf commit -q -m 'The fleet configuration, wave 1'
        gitf push -q -u origin main
    fi
fi
echo "config   $(gitf log --oneline -1)"
echo "grafana  https://$addr:3000 (admin/admin, as the LGTM image ships: change it if this is not a test)"

# The dashboard (dashboards/fleet.json), through Grafana's API.
o='--cacert'; curl --version | grep -qi schannel && o='--ssl-no-revoke --cacert'
for _ in $(seq 1 30); do
    # shellcheck disable=SC2086
    curl -s $o "$ca" -o /dev/null "https://$addr:3000/api/health" && break; sleep 2
done
# shellcheck disable=SC2086
jq '{dashboard: ., overwrite: true}' "$here/dashboards/fleet.json" \
    | curl -sS $o "$ca" -u admin:admin -H 'Content-Type: application/json' -d @- "https://$addr:3000/api/dashboards/db" > /dev/null
echo "dashboard https://$addr:3000/d/vigil-fleet"
