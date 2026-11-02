# shellcheck shell=bash
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
# init.sh - vigil init: a starting configuration (SPECIFICATION.md 19).
#
#   vigil_init <root> <instance> <backends>
#
# Writes config/vigil.config, commented, with runners for the shells found
# on this machine and the chosen backends, and no jobs: those are the packs'
# and the operator's. Never overwrites a configuration, never holds a secret
# value. <backends> is a comma-separated list of file, datadog and otel, which
# may be empty. VIGIL_INIT_REF_datadog and VIGIL_INIT_REF_otel, when set, are
# the credential's reference, or none: otherwise env: placeholders.

_vigil_init_err() {
    printf 'vigil: %s\n' "$1" >&2
}

vigil_init() {
    local root=$1 instance=$2 backends=$3 cfg b py env_names='' ref
    cfg=$root/config/vigil.config
    if [ -e "$cfg" ]; then
        _vigil_init_err "$cfg exists; init never overwrites a configuration"
        return 1
    fi
    case $instance in
        '' | *[!A-Za-z0-9_.-]*)
            _vigil_init_err "the instance name may contain only letters, digits and . _ -: '$instance'"
            return 1
            ;;
    esac
    for b in $(printf '%s' "$backends" | tr ',' ' '); do
        case $b in
            file | datadog | otel) ;;
            *)
                _vigil_init_err "init knows the backends file, datadog and otel, not '$b'; add others to the configuration by hand"
                return 1
                ;;
        esac
    done
    mkdir -p "$root/config" "$root/scripts" || return 1
    py=$(command -v python3 2> /dev/null)

    {
        printf '# vigil.config - written by vigil init on %s for %s.\n' "$(date '+%Y-%m-%d')" "$(uname -s)"
        printf '#\n# The format and every key: https://godspeedhq.github.io/vigil/spec/06/\n'
        printf '# Check it after every change: vigil precheck\n#\n'
        printf '# Secrets never go in this file. Credentials are references: env:NAME\n'
        printf '# (the service environment), secret:NAME (vigil secret set NAME) or\n'
        printf '# store:<store>/<name> (an external secret store).\n\n'
        printf '[vigil]\n# Names this deployment; becomes the "instance" tag on every metric.\ninstance = %s\n\n' "$instance"
        printf '[scheduler]\n# How often the supervisor wakes to start due jobs.\ntick = 10s\n\n'
        for b in $(printf '%s' "$backends" | tr ',' ' '); do
            case $b in
                file)
                    printf '# Prometheus text file, for node_exporter'"'"'s textfile collector.\n'
                    printf '[backend.file]\npath = metrics/vigil.prom\n\n'
                    ;;
                datadog)
                    ref=${VIGIL_INIT_REF_datadog:-env:DATADOG_API_KEY}
                    printf '# Datadog. An env: credential goes in the service environment\n'
                    printf '# (systemctl edit vigil, or the plist'"'"'s EnvironmentVariables).\n'
                    printf '[backend.datadog]\nendpoint = https://api.datadoghq.com\napi_key  = %s\ntimeout  = 10s\n\n' "$ref"
                    case $ref in env:*) env_names="$env_names ${ref#env:}" ;; esac
                    ;;
                otel)
                    printf '# OpenTelemetry collector, OTLP/HTTP. Remove api_key if the\n'
                    printf '# collector needs no bearer token.\n'
                    ref=${VIGIL_INIT_REF_otel:-env:OTEL_API_KEY}
                    if [ "$ref" = none ]; then
                        printf '[backend.otel]\nendpoint = http://localhost:4318/v1/metrics\ntimeout  = 10s\n\n'
                    else
                        printf '[backend.otel]\nendpoint = http://localhost:4318/v1/metrics\napi_key  = %s\ntimeout  = 10s\n\n' "$ref"
                    fi
                    case $ref in env:*) env_names="$env_names ${ref#env:}" ;; esac
                    ;;
            esac
        done
        printf '# Runners: how files are run, by extension.\n'
        printf '[runner.sh]\ncommand = /bin/bash\n\n'
        if [ -n "$py" ]; then
            printf '[runner.py]\ncommand = %s\n\n' "$py"
        else
            printf '# python3 was not found; add a runner when it is installed:\n# [runner.py]\n# command = /usr/bin/python3\n\n'
        fi
        printf '[runners]\n.sh = sh\n'
        [ -n "$py" ] && printf '.py = py\n'
        printf '\n'
        printf '# Your jobs: one [job.<name>] section each, with your scripts in scripts/.\n'
        printf '# [job.backup]\n# file        = scripts/backup.sh\n# run_every   = 1h\n# max_runtime = 30m\n'
    } > "$cfg.tmp.$$" && mv -f "$cfg.tmp.$$" "$cfg" || return 1
    printf 'wrote %s\n' "$cfg"

    if [ -n "$env_names" ]; then
        printf '\nSet these in the service environment before starting Vigil:\n'
        for b in $env_names; do printf '  %s\n' "$b"; done
    fi
    return 0
}
