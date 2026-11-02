# shellcheck shell=bash
#
# Vigil HTTP backends - bash 3.2 compatible.
#
# Datadog (Series API v2), OpenTelemetry (OTLP/HTTP, JSON encoding) and Splunk
# (HTTP Event Collector), SPECIFICATION.md 15.3. Builds one request from a batch of spool event
# files, sends it with the HTTPS client of stores.sh, and says what became
# of the batch. Must behave exactly as Backends.ps1 - tests/conformance/backend
# holds the shared cases.
#
#   vigil_backend_body <type> <now> <events file>...
#     The request body for the batch, into _vb_body, with _vb_points events
#     in it. The events left out are counted in _vb_drops ("<reason> <count>"
#     lines): invalid (not an event line, or one with a control character)
#     and, for datadog, too_old (more than an hour old, which Datadog would
#     discard without saying so).
#   vigil_backend_send <root> <name> <type> <events file>...
#     Delivers the batch to [backend.<name>]. Returns 0 when the batch is
#     done with, with _vb_sent the events accepted and _vb_drops the events
#     left out, including those the backend rejected as malformed (rejected);
#     or 1, with _vb_why saying why, when it is to be retried later. The
#     credential reaches curl on its standard input only.
#
# Requires secrets.sh, stores.sh and worker.sh.

# Datadog drops points older than this many seconds without an error.
VIGIL_DATADOG_MAX_AGE=3600

# Patterns kept in variables: bash 3.2 misreads some of them inline.
_vigil_backend_num='^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'
_vigil_backend_epoch='^(0|[1-9][0-9]{0,11})$'
_vigil_backend_name='^[A-Za-z0-9_.]+$'
_vigil_backend_rejected='"rejectedDataPoints"[[:space:]]*:[[:space:]]*"?([0-9]+)'
_vigil_backend_nl=$'\n'

# The time requests are made at; replaced by the conformance runner.
_vigil_backend_now() {
    _vb_now=$(date '+%s')
}

# The name of a tag as a Splunk field, into _vb_key: a name Splunk keeps for
# itself gets a prefix.
_vigil_splunk_key() {
    case $1 in
        metric_name | source | sourcetype | index | time | host | _*) _vb_key=tag_$1 ;;
        *) _vb_key=$1 ;;
    esac
}

# $1 as a JSON string, into _vb_q: escaped only when it needs to be.
_vigil_backend_quote() {
    case $1 in
        *[\"\\]*) _vigil_json_quote "$1"; _vb_q=$_vh_enc ;;
        *) _vb_q="\"$1\"" ;;
    esac
}

_vigil_backend_body_line() {
    local line=$1 epoch name value kind tag key val tags='' attrs='' res='' start='' point IFS=' '
    case $line in
        '') return 0 ;;
        *[[:cntrl:]]*) _vb_invalid=$((_vb_invalid + 1)); return 0 ;;
    esac
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    if [ "$#" -lt 4 ]; then _vb_invalid=$((_vb_invalid + 1)); return 0; fi
    epoch=$1 name=$2 value=$3 kind=$4
    shift 4
    case $kind in gauge | count) ;; *) _vb_invalid=$((_vb_invalid + 1)); return 0 ;; esac
    if ! [[ $epoch =~ $_vigil_backend_epoch ]] || ! [[ $value =~ $_vigil_backend_num ]] || ! [[ $name =~ $_vigil_backend_name ]]; then
        _vb_invalid=$((_vb_invalid + 1))
        return 0
    fi
    # Tags are key=value, keys [A-Za-z0-9_]+ and values non-empty.
    for tag in "$@"; do
        key=${tag%%=*}
        case $tag:$key in
            *=?*:?*) case $key in *[!A-Za-z0-9_]*) _vb_invalid=$((_vb_invalid + 1)); return 0 ;; esac ;;
            *) _vb_invalid=$((_vb_invalid + 1)); return 0 ;;
        esac
    done
    if [ "$_vb_type" = datadog ] && [ $((_vb_now - epoch)) -gt "$VIGIL_DATADOG_MAX_AGE" ]; then
        _vb_old=$((_vb_old + 1))
        return 0
    fi
    for tag in "$@"; do
        key=${tag%%=*}
        val=${tag#*=}
        if [ "$_vb_type" = otel ]; then
            _vigil_backend_quote "$val"
            attrs="$attrs${attrs:+,}{\"key\":\"$key\",\"value\":{\"stringValue\":$_vb_q}}"
        elif [ "$_vb_type" = splunk ]; then
            _vigil_backend_quote "$val"
            if [ "$key" = host ]; then
                res="\"host\":$_vb_q,"
            else
                _vigil_splunk_key "$key"
                tags="$tags,\"$_vb_key\":$_vb_q"
            fi
        elif [ "$key" = host ]; then
            # Datadog's host is a resource, not a tag.
            _vigil_backend_quote "$val"
            res=",\"resources\":[{\"name\":$_vb_q,\"type\":\"host\"}]"
        else
            _vigil_backend_quote "$key:$val"
            tags=$tags${tags:+,}$_vb_q
        fi
    done
    # HEC takes events one after another, not as a list.
    [ "$_vb_points" -gt 0 ] && [ "$_vb_type" != splunk ] && _vb_body="$_vb_body,"
    if [ "$_vb_type" = splunk ]; then
        _vb_body="$_vb_body{\"time\":$epoch,$res\"source\":\"vigil\",\"event\":\"metric\",\"fields\":{\"metric_name\":\"$name\",\"_value\":$value,\"metric_type\":\"$kind\"$tags}}"
    elif [ "$_vb_type" = datadog ]; then
        # Series API types: 1 count, 3 gauge.
        [ "$kind" = count ] && kind=1 || kind=3
        _vb_body="$_vb_body{\"metric\":\"$name\",\"type\":$kind,\"points\":[{\"timestamp\":$epoch,\"value\":$value}]$res,\"tags\":[$tags]}"
    else
        # A count is a delta sum over its own instant.
        [ "$kind" = count ] && start="\"startTimeUnixNano\":\"${epoch}000000000\","
        point="{$start\"timeUnixNano\":\"${epoch}000000000\",\"asDouble\":$value,\"attributes\":[$attrs]}"
        if [ "$kind" = count ]; then
            _vb_body="$_vb_body{\"name\":\"$name\",\"sum\":{\"aggregationTemporality\":1,\"isMonotonic\":true,\"dataPoints\":[$point]}}"
        else
            _vb_body="$_vb_body{\"name\":\"$name\",\"gauge\":{\"dataPoints\":[$point]}}"
        fi
    fi
    _vb_points=$((_vb_points + 1))
}

vigil_backend_body() {
    local LC_ALL=C
    local f line
    _vb_type=$1
    _vb_now=$2
    shift 2
    _vb_body=''
    _vb_points=0
    _vb_invalid=0
    _vb_old=0
    for f in "$@"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            _vigil_backend_body_line "$line"
        done < "$f"
    done
    if [ "$_vb_type" = datadog ]; then
        _vb_body="{\"series\":[$_vb_body]}"
    elif [ "$_vb_type" != splunk ]; then
        _vb_body="{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"vigil\"}}]},\"scopeMetrics\":[{\"scope\":{\"name\":\"vigil\"},\"metrics\":[$_vb_body]}]}]}"
    fi
    _vb_drops=''
    [ "$_vb_invalid" -gt 0 ] && _vb_drops="invalid $_vb_invalid"
    [ "$_vb_old" -gt 0 ] && _vb_drops="$_vb_drops${_vb_drops:+$_vigil_backend_nl}too_old $_vb_old"
    return 0
}

vigil_backend_send() {
    local root=$1 name=$2 type=$3 endpoint='' key='' keyname=api_key ca='' timeout=10 url host meta=0 rejected i end
    shift 3
    _vb_sent=0
    _vb_why=''
    _vb_drops=''
    vigil_config_section "backend.$name"
    if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
        i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
        end=$((i + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC]))
        while [ "$i" -lt "$end" ]; do
            case ${VIGIL_CFG_KEY[$i]} in
                endpoint) endpoint=${VIGIL_CFG_VALUE[$i]} ;;
                api_key) [ "$type" = splunk ] || key=${VIGIL_CFG_VALUE[$i]} ;;
                token) [ "$type" != splunk ] || key=${VIGIL_CFG_VALUE[$i]} ;;
                ca_file) ca=${VIGIL_CFG_VALUE[$i]} ;;
                timeout) _vigil_wk_secs "${VIGIL_CFG_VALUE[$i]}"; timeout=$_vw_secs ;;
            esac
            i=$((i + 1))
        done
    fi
    case $ca in '' | /*) ;; *) ca=$root/$ca ;; esac
    [ "$type" != splunk ] || keyname=token
    if [ -z "$endpoint" ]; then
        case $type in
            datadog) endpoint=https://api.datadoghq.com ;;
            otel) endpoint=http://localhost:4318/v1/metrics ;;
            splunk)
                _vb_why="the backend needs 'endpoint'"
                return 1
                ;;
        esac
    fi

    # https only; plain http only to a collector on this host, never
    # through a proxy (the request does not leave the machine).
    host=${endpoint#*://}
    host=${host%%/*}
    host=${host%%\?*}
    case $endpoint in
        https://*) ;;
        http://localhost | http://localhost[:/]* | http://127.0.0.1 | http://127.0.0.1[:/]* | 'http://[::1]' | 'http://[::1]'[:/]*) meta=1 ;;
        *)
            _vb_why="endpoint must be https (plain http only to this host)"
            return 1
            ;;
    esac
    case $host in *@*) _vb_why='endpoint must not hold credentials'; return 1 ;; esac
    # Datadog's endpoint is the site; the others' is the full URL, or a bare
    # address that gets the standard path.
    url=${endpoint%/}
    case $type:${url#*://} in
        datadog:*) url=$url/api/v2/series ;;
        otel:*/* | splunk:*/*) ;;
        otel:*) url=$url/v1/metrics ;;
        splunk:*) url=$url/services/collector/event ;;
    esac

    _vigil_backend_now
    vigil_backend_body "$type" "$_vb_now" "$@"
    if [ "$_vb_points" -eq 0 ]; then
        _vb_body=''
        return 0
    fi

    _vh_headers=('Content-Type: application/json')
    if [ -n "$key" ]; then
        if ! vigil_secret_resolve "$root" "$key"; then
            _vb_why="$keyname $key: $VIGIL_SECRET_WHY"
            _vb_body=''
            return 1
        fi
        case $VIGIL_SECRET_VALUE in
            *[[:cntrl:]]*)
                VIGIL_SECRET_VALUE=''
                _vb_why="$keyname $key: contains a control character"
                _vb_body=''
                return 1
                ;;
        esac
        case $type in
            datadog) _vh_headers[1]="DD-API-KEY: $VIGIL_SECRET_VALUE" ;;
            otel) _vh_headers[1]="Authorization: Bearer $VIGIL_SECRET_VALUE" ;;
            splunk) _vh_headers[1]="Authorization: Splunk $VIGIL_SECRET_VALUE" ;;
        esac
        VIGIL_SECRET_VALUE=''
    elif [ "$type" != otel ]; then
        _vb_why="the backend needs '$keyname'"
        _vb_body=''
        return 1
    fi

    _vh_body=$_vb_body
    _vb_body=''
    _vigil_http_send "$timeout" POST "$url" "$ca" "$meta"
    i=$?
    _vh_headers=()
    _vh_body=''
    if [ "$i" -ne 0 ]; then
        case $_vh_fail in
            nocurl) _vb_why='curl is not installed' ;;
            cafile) _vb_why="cannot read ca_file $ca" ;;
            resolve) _vb_why="cannot resolve $host" ;;
            connect) _vb_why="cannot connect to $host" ;;
            timeout) _vb_why="no answer from $host within ${timeout}s" ;;
            untrusted) _vb_why="the certificate of $host is not trusted" ;;
            tls) _vb_why="no secure connection to $host" ;;
            *) _vb_why="the request to $host failed" ;;
        esac
        return 1
    fi
    case $_vh_status in
        2??)
            # OTLP's partial success: the points it refused will never be
            # accepted, so they are dropped, not retried.
            rejected=0
            if [ "$type" = otel ] && [[ $_vh_resp =~ $_vigil_backend_rejected ]]; then
                rejected=${BASH_REMATCH[1]}
                if [ "${#rejected}" -gt 9 ]; then rejected=$_vb_points; else rejected=$((10#$rejected)); fi
            fi
            [ "$rejected" -gt "$_vb_points" ] && rejected=$_vb_points
            _vb_sent=$((_vb_points - rejected))
            [ "$rejected" -gt 0 ] && _vb_drops="$_vb_drops${_vb_drops:+$_vigil_backend_nl}rejected $rejected"
            ;;
        400 | 413)
            # Malformed or too large: sending it again cannot succeed.
            _vb_drops="$_vb_drops${_vb_drops:+$_vigil_backend_nl}rejected $_vb_points"
            ;;
        401 | 403) _vb_why="permission denied (HTTP $_vh_status)" ;;
        *) _vb_why="HTTP $_vh_status from $host" ;;
    esac
    _vh_resp=''
    [ -z "$_vb_why" ]
}
