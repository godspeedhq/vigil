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
#   scripts/start.sh splunk          Splunk, then configs/platforms/splunk/provision.sh
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

# Fetches official deployment $1 at the pin in configs/platforms/upstream.txt.
fetch_upstream() {
    local name repo ref path dir=$bk_dir/configs/platforms/$1/upstream
    read -r name repo ref path < <(grep "^$1 " "$bk_dir/configs/platforms/upstream.txt")
    [ -n "${ref-}" ] || die "no pin for $1 in configs/platforms/upstream.txt"
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

# The readiness URL of target $1, asked from this host, for the images with
# no shell or HTTP client to run a Compose health check in.
ready_url() {
    case $1 in
        loki) echo http://127.0.0.1:3100/ready ;;
        mimir) echo http://127.0.0.1:9009/ready ;;
        tempo) echo http://127.0.0.1:3200/ready ;;
        pyroscope) echo http://127.0.0.1:4040/ready ;;
        otel-collector) echo http://127.0.0.1:13133/ ;;
        alloy) echo http://127.0.0.1:12345/-/ready ;;
        # And the collector in front of them.
        victoriametrics) echo http://127.0.0.1:13134/ ;;
        victorialogs) echo http://127.0.0.1:9428/health http://127.0.0.1:13134/ ;;
        victoriatraces) echo http://127.0.0.1:10428/health ;;
        # The collectors in front of the stores, which have health checks.
        elastic) echo http://127.0.0.1:13135/ ;;
        opensearch) echo http://127.0.0.1:13136/ ;;
        influxdb) echo http://127.0.0.1:13137/ ;;
        clickhouse) echo http://127.0.0.1:13138/ ;;
        # Traces only, which Vigil does not send: started to show they run.
        jaeger) echo http://127.0.0.1:16686/ ;;
        zipkin) echo http://127.0.0.1:9411/health ;;
    esac
}

# Waits up to five minutes for each of target $1's readiness URLs to answer
# 2xx.
wait_ready() {
    local url i=0
    for url in $(ready_url "$1"); do
        until curl -fsS -m 5 -o /dev/null "$url" 2> /dev/null; do
            i=$((i + 1))
            [ "$i" -ge 60 ] && return 1
            sleep 5
        done
    done
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
            (cd "$bk_dir/configs/platforms/signoz" && foundryctl gauge -f casting.yaml && foundryctl forge -f casting.yaml) || die 'foundryctl failed'
            docker compose -p vigil-signoz -f "$bk_dir/configs/platforms/signoz/pours/deployment/compose.yaml" up -d --wait || die 'signoz did not start'
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
            case $t in openbao | vault | aws | azure | gcp | azure-alt | gcp-alt) bash "$bk_dir/configs/secrets/tls.sh" || die 'cannot make the test CA' ;; esac
            case $t in git-* | https-* | sftp-*) bash "$bk_dir/configs/secrets/tls.sh" && bash "$bk_dir/configs/sources/keys.sh" || die 'cannot make the test CA or keys' ;; esac
            # Splunk's management API serves the test CA's certificate: the
            # certificate, its key and the CA in one file, as Splunk wants it.
            if [ "$t" = splunk ]; then
                bash "$bk_dir/configs/secrets/tls.sh" &&
                    cat "$bk_dir/.secrets/tls/server.pem" "$bk_dir/.secrets/tls/server-key.pem" "$bk_dir/.secrets/tls/ca.pem" \
                        > "$bk_dir/.secrets/tls/splunk-server.pem" && chmod 644 "$bk_dir/.secrets/tls/splunk-server.pem" ||
                    die 'cannot make the test CA or Splunk'"'"'s certificate'
            fi
            # OpenSearch first: its demo root CA is copied out for the
            # collector and Dashboards before they start, so they verify it.
            if [ "$t" = opensearch ]; then
                compose --profile opensearch up -d --wait opensearch || die 'opensearch did not become healthy'
                bash "$bk_dir/configs/platforms/opensearch/ca.sh" || die "cannot copy OpenSearch's root CA"
            fi
            # shellcheck disable=SC2086
            compose --profile "$t" up -d --wait $s || die "$t did not become healthy"
            wait_ready "$t" || die "$t did not become ready: $(ready_url "$t")"
            [ "$t" = splunk ] && { bash "$bk_dir/configs/platforms/splunk/provision.sh" || die 'provisioning Splunk failed'; }
            case $t in
                openbao | vault) bash "$bk_dir/configs/secrets/provision.sh" "$t" || die "provisioning $t failed" ;;
                aws | azure | gcp | azure-alt | gcp-alt) bash "$bk_dir/configs/secrets/$t/provision.sh" || die "provisioning $t failed" ;;
                git-* | https-* | sftp-*) bash "$bk_dir/configs/sources/${t#*-}/provision.sh" || die "provisioning $t failed" ;;
            esac
            ;;
    esac
    printf 'started: %s\n' "$t"
done
