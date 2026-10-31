# shellcheck shell=bash
#
# init.sh - vigil init: a starting configuration (SPECIFICATION.md 19).
#
#   vigil_init <root> <instance> <backends> <sample>
#
# Writes config/vigil.config, commented, with runners for the shells found
# on this machine, the chosen backends with env: placeholders for their
# credentials, and one sample job (scripts/disk.sh) unless <sample> is 0.
# Never overwrites a configuration, never asks for or stores a secret
# value. <backends> is a comma-separated list of file, datadog and otel.

_vigil_init_err() {
    printf 'vigil: %s\n' "$1" >&2
}

vigil_init() {
    local root=$1 instance=$2 backends=$3 sample=$4 cfg b py env_names=''
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
                    printf '# Datadog. Set DATADOG_API_KEY in the service environment\n'
                    printf '# (systemctl edit vigil, or the plist'"'"'s EnvironmentVariables).\n'
                    printf '[backend.datadog]\nendpoint = https://api.datadoghq.com\napi_key  = env:DATADOG_API_KEY\ntimeout  = 10s\n\n'
                    env_names="$env_names DATADOG_API_KEY"
                    ;;
                otel)
                    printf '# OpenTelemetry collector, OTLP/HTTP. Remove api_key if the\n'
                    printf '# collector needs no bearer token.\n'
                    printf '[backend.otel]\nendpoint = http://localhost:4318/v1/metrics\napi_key  = env:OTEL_API_KEY\ntimeout  = 10s\n\n'
                    env_names="$env_names OTEL_API_KEY"
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
        if [ "$sample" = 1 ]; then
            printf '# A sample job: the root filesystem'"'"'s use, every 5 minutes.\n'
            printf '[job.disk]\nmetric_name = os.disk\nfile        = scripts/disk.sh\nrun_every   = 5m\nmax_runtime = 30s\n'
        else
            printf '# Jobs: one [job.<name>] section each. For example:\n'
            printf '# [job.disk]\n# file        = scripts/disk.sh\n# run_every   = 5m\n# max_runtime = 30s\n'
        fi
    } > "$cfg.tmp.$$" && mv -f "$cfg.tmp.$$" "$cfg" || return 1
    printf 'wrote %s\n' "$cfg"

    if [ "$sample" = 1 ] && [ ! -e "$root/scripts/disk.sh" ]; then
        cat > "$root/scripts/disk.sh" <<'EOF'
# disk.sh - the root filesystem's use, as a metric (vigil init sample).
# Prints: metric used_pct <percent>. Fails above 95%.
used=$(df -P / | awk 'NR == 2 { v = $(NF - 1); sub("%", "", v); print v }')
echo "metric used_pct $used"
[ "$used" -le 95 ]
EOF
        printf 'wrote %s\n' "$root/scripts/disk.sh"
    fi

    if [ -n "$env_names" ]; then
        printf '\nSet these in the service environment before starting Vigil:\n'
        for b in $env_names; do printf '  %s\n' "$b"; done
    fi
    printf '\nNext: vigil precheck, then vigil service install\n'
    return 0
}
