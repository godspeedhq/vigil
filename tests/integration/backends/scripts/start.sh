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
# start.sh - starts one or more targets, and waits until they are healthy.
#
#   scripts/start.sh                 lgtm, the default
#   scripts/start.sh splunk          Splunk, then configs/splunk/provision.sh
#   scripts/start.sh openbao         a secret store (or vault): the test CA
#                                    first, then configs/secrets/provision.sh
#   scripts/start.sh mimir loki otel-collector
#
# Healthy means the containers are up, not that anything has been stored:
# run-vigil.sh and verify.sh prove that.

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

[ "$#" -gt 0 ] || set -- lgtm

# Fetches official deployment $1 at the pin in configs/upstream.txt.
fetch_upstream() {
    local name repo ref path dir=$bk_dir/configs/$1/upstream
    read -r name repo ref path < <(grep "^$1 " "$bk_dir/configs/upstream.txt")
    [ -n "${ref-}" ] || die "no pin for $1 in configs/upstream.txt"
    if [ ! -f "$dir/.pinned-$ref" ]; then
        rm -rf "$dir" "$dir.git"
        git clone -q --filter=blob:none --no-checkout "$repo" "$dir.git" &&
            git -C "$dir.git" checkout -q "$ref" -- "$path" &&
            mv "$dir.git/$path" "$dir" && rm -rf "$dir.git" || die "cannot fetch $repo at $ref"
        : > "$dir/.pinned-$ref"
    fi
    printf '%s' "$dir"
}

# The settings in .env target $1 cannot start without. Checked here, not in
# the Compose files: Compose resolves every file it includes, so a value
# required there would stop every other target too.
needs() {
    case $1 in
        splunk) echo SPLUNK_START_ARGS SPLUNK_GENERAL_TERMS SPLUNK_PASSWORD VIGIL_SPLUNK_METRICS_TOKEN VIGIL_SPLUNK_LOGS_TOKEN ;;
        elastic) echo ELASTIC_PASSWORD KIBANA_PASSWORD ;;
        opensearch) echo OPENSEARCH_ADMIN_PASSWORD ;;
        influxdb) echo INFLUXDB_PASSWORD INFLUXDB_TOKEN ;;
        clickhouse) echo CLICKHOUSE_PASSWORD ;;
    esac
}

for t in "$@"; do
    endpoints "$t"
    missing=''
    for v in $(needs "$t"); do
        [ -n "${!v-}" ] || missing="$missing $v"
    done
    case $missing in
        *SPLUNK_START_ARGS* | *SPLUNK_GENERAL_TERMS*)
            die "$t: read Splunk's licence and General Terms, then set SPLUNK_START_ARGS and SPLUNK_GENERAL_TERMS in .env yourself. Also missing:${missing}" ;;
        ?*) die "$t needs these set in .env:$missing" ;;
    esac
    case $t in
        signoz)
            command -v foundryctl > /dev/null 2>&1 ||
                die 'signoz needs foundryctl, SigNoz'"'"'s installer: see README.md. It is not installed for you.'
            (cd "$bk_dir/configs/signoz" && foundryctl gauge -f casting.yaml && foundryctl forge -f casting.yaml) || die 'foundryctl failed'
            docker compose -p vigil-signoz -f "$bk_dir/configs/signoz/pours/deployment/compose.yaml" up -d --wait || die 'signoz did not start'
            ;;
        uptrace)
            d=$(fetch_upstream uptrace) || exit 1
            # Only the services Uptrace itself needs, not the example's extras.
            docker compose -p vigil-uptrace -f "$d/docker-compose.yml" up -d --wait clickhouse postgres redis uptrace || die 'uptrace did not start'
            ;;
        graylog)
            d=$(fetch_upstream graylog) || exit 1
            [ -f "$d/.env" ] || { cp "$d/.env.example" "$d/.env"; die "fill in $d/.env (Graylog's own settings), then run this again"; }
            docker compose -p vigil-graylog --project-directory "$d" -f "$d/docker-compose.yml" up -d --wait || die 'graylog did not start'
            ;;
        *)
            s=$(services_of "$t")
            [ -n "$s" ] || die "no services for $t"
            # The secret stores' certificate exists before they first start.
            case $t in openbao | vault) bash "$bk_dir/configs/secrets/tls.sh" || die 'cannot make the test CA' ;; esac
            # shellcheck disable=SC2086
            compose --profile "$t" up -d --wait $s || die "$t did not become healthy"
            [ "$t" = splunk ] && { bash "$bk_dir/configs/splunk/provision.sh" || die 'provisioning Splunk failed'; }
            case $t in openbao | vault) bash "$bk_dir/configs/secrets/provision.sh" "$t" || die "provisioning $t failed" ;; esac
            ;;
    esac
    printf 'started: %s\n' "$t"
done
