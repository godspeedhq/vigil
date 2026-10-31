# shellcheck shell=bash
#
# Vigil's built-in secret stores - bash 3.2 compatible.
#
# HashiCorp Vault and Azure Key Vault over HTTPS with curl, so nothing else
# needs installing (SPECIFICATION.md 6.5.3). Credentials and tokens reach
# curl on its standard input (curl -K -), never on its command line, and are
# sent in headers or request bodies, never in URLs. Values live only in shell
# variables, cleared once used.
#
#   vigil_json_get <json> <key>...
#     The string at that path of objects. Sets VIGIL_JSON_VALUE and returns
#     0, or returns 1 with VIGIL_JSON_WHY set. Strict on the path it follows;
#     everything else is only skipped.
#   vigil_store_fetch <root> <section index> <type> <name>
#     Sets VIGIL_SECRET_VALUE and returns 0, or returns 1 with
#     VIGIL_SECRET_WHY set, never containing a value.
#   _vigil_http_send: one request; the conformance suite replaces it.
#
# Requires config.sh, secrets.sh and worker.sh.

# --- JSON --------------------------------------------------------------------

# The document, its length and the position being read.
_vj=''
_vjn=0
_vjp=0
_vigil_json_re_num='^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
# What ends a run of plain characters in a string, and in a container. In
# variables: a } in the pattern would end ${...}.
_vigil_json_pat_str='[\\"]'
_vigil_json_pat_box='[]"{}[]'

_vigil_json_ws() {
    while [ "$_vjp" -lt "$_vjn" ]; do
        case ${_vj:_vjp:1} in
            ' ' | $'\t' | $'\n' | $'\r') _vjp=$((_vjp + 1)) ;;
            *) return 0 ;;
        esac
    done
}

# Four hex digits at _vjp, into _vjh.
_vigil_json_hex4() {
    local h=${_vj:_vjp:4}
    case $h in
        [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) return 1 ;;
    esac
    _vjh=$((16#$h))
    _vjp=$((_vjp + 4))
}

# Appends code point $1 to _vjs as UTF-8.
_vigil_json_utf8() {
    local cp=$1 b o ch
    local -a bytes
    if [ "$cp" -lt 128 ]; then
        bytes=("$cp")
    elif [ "$cp" -lt 2048 ]; then
        bytes=($((192 | cp >> 6)) $((128 | cp & 63)))
    elif [ "$cp" -lt 65536 ]; then
        bytes=($((224 | cp >> 12)) $((128 | cp >> 6 & 63)) $((128 | cp & 63)))
    else
        bytes=($((240 | cp >> 18)) $((128 | cp >> 12 & 63)) $((128 | cp >> 6 & 63)) $((128 | cp & 63)))
    fi
    for b in "${bytes[@]}"; do
        printf -v o '%03o' "$b"
        # shellcheck disable=SC2059
        printf -v ch "\\$o"
        _vjs=$_vjs$ch
    done
}

# The string at _vjp, decoded into _vjs. Returns 1 when it is not valid.
_vigil_json_string() {
    local rest run c cp lo
    _vjs=''
    _vjp=$((_vjp + 1))
    while :; do
        rest=${_vj:_vjp}
        run=${rest%%$_vigil_json_pat_str*}
        _vjs=$_vjs$run
        _vjp=$((_vjp + ${#run}))
        [ "$_vjp" -lt "$_vjn" ] || return 1
        c=${_vj:_vjp:1}
        _vjp=$((_vjp + 1))
        [ "$c" = '"' ] && return 0
        c=${_vj:_vjp:1}
        _vjp=$((_vjp + 1))
        case $c in
            '"' | '\' | /) _vjs=$_vjs$c ;;
            b) _vjs=$_vjs$'\b' ;;
            f) _vjs=$_vjs$'\f' ;;
            n) _vjs=$_vjs$'\n' ;;
            r) _vjs=$_vjs$'\r' ;;
            t) _vjs=$_vjs$'\t' ;;
            u)
                _vigil_json_hex4 || return 1
                cp=$_vjh
                # A surrogate pair is one code point; a lone surrogate, or
                # NUL, which no value can hold, is not valid.
                if [ "$cp" -ge 55296 ] && [ "$cp" -le 56319 ]; then
                    [ "${_vj:_vjp:2}" = '\u' ] || return 1
                    _vjp=$((_vjp + 2))
                    _vigil_json_hex4 || return 1
                    lo=$_vjh
                    { [ "$lo" -ge 56320 ] && [ "$lo" -le 57343 ]; } || return 1
                    cp=$((65536 + ((cp - 55296) << 10) + lo - 56320))
                elif [ "$cp" -ge 56320 ] && [ "$cp" -le 57343 ]; then
                    return 1
                elif [ "$cp" -eq 0 ]; then
                    return 1
                fi
                _vigil_json_utf8 "$cp"
                ;;
            *) return 1 ;;
        esac
    done
}

# Skips the value at _vjp. Containers are only matched for brackets.
_vigil_json_skip() {
    local c depth=0 rest run start=$_vjp
    c=${_vj:_vjp:1}
    case $c in
        '"') _vigil_json_string; return ;;
        '{' | '[') ;;
        *)
            while [ "$_vjp" -lt "$_vjn" ]; do
                case ${_vj:_vjp:1} in
                    ',' | '}' | ']' | ' ' | $'\t' | $'\n' | $'\r') break ;;
                esac
                _vjp=$((_vjp + 1))
            done
            run=${_vj:start:_vjp-start}
            case $run in true | false | null) return 0 ;; esac
            [[ $run =~ $_vigil_json_re_num ]]
            return
            ;;
    esac
    while [ "$_vjp" -lt "$_vjn" ]; do
        rest=${_vj:_vjp}
        run=${rest%%$_vigil_json_pat_box*}
        _vjp=$((_vjp + ${#run}))
        [ "$_vjp" -lt "$_vjn" ] || return 1
        case ${_vj:_vjp:1} in
            '"') _vigil_json_string || return 1; continue ;;
            '{' | '[') depth=$((depth + 1)) ;;
            *) depth=$((depth - 1)) ;;
        esac
        _vjp=$((_vjp + 1))
        [ "$depth" -eq 0 ] && return 0
    done
    return 1
}

_vigil_json_follow() {
    local path='' k key c
    for k in "$@"; do path=${path:+$path.}$k; done
    _vigil_json_ws
    if [ "${_vj:_vjp:1}" != '{' ]; then
        VIGIL_JSON_WHY='not a JSON object'
        return 1
    fi
    for k in "$@"; do
        if [ "${_vj:_vjp:1}" != '{' ]; then
            VIGIL_JSON_WHY="no $path"
            return 1
        fi
        _vjp=$((_vjp + 1))
        while :; do
            _vigil_json_ws
            c=${_vj:_vjp:1}
            if [ "$c" = '}' ]; then
                VIGIL_JSON_WHY="no $path"
                return 1
            fi
            [ "$c" = '"' ] || return 2
            _vigil_json_string || return 2
            key=$_vjs
            _vigil_json_ws
            [ "${_vj:_vjp:1}" = : ] || return 2
            _vjp=$((_vjp + 1))
            _vigil_json_ws
            # The first of repeated keys counts.
            [ "$key" = "$k" ] && break
            _vigil_json_skip || return 2
            _vigil_json_ws
            case ${_vj:_vjp:1} in
                ,) _vjp=$((_vjp + 1)) ;;
                '}')
                    VIGIL_JSON_WHY="no $path"
                    return 1
                    ;;
                *) return 2 ;;
            esac
        done
    done
    if [ "${_vj:_vjp:1}" = '"' ]; then
        _vigil_json_string || return 2
        VIGIL_JSON_VALUE=$_vjs
        return 0
    fi
    _vigil_json_skip || return 2
    VIGIL_JSON_WHY="$path is not a string"
    return 1
}

vigil_json_get() {
    local LC_ALL=C
    local rc
    _vj=$1
    _vjn=${#_vj}
    _vjp=0
    shift
    VIGIL_JSON_VALUE=''
    VIGIL_JSON_WHY=''
    _vigil_json_follow "$@"
    rc=$?
    [ "$rc" -eq 2 ] && VIGIL_JSON_WHY='not valid JSON'
    _vj=''
    _vjs=''
    [ "$rc" -eq 0 ]
}

# --- HTTP --------------------------------------------------------------------

# Percent-encodes $1 into _vh_enc, keeping A-Z a-z 0-9 - . _ ~ and, when $2
# is 1, /.
_vigil_http_encode() {
    local LC_ALL=C
    local s=$1 c n i=0
    _vh_enc=''
    while [ "$i" -lt "${#s}" ]; do
        c=${s:i:1}
        case $c in
            [A-Za-z0-9._~-]) _vh_enc=$_vh_enc$c ;;
            /)
                if [ "$2" = 1 ]; then _vh_enc=$_vh_enc/; else _vh_enc=$_vh_enc%2F; fi
                ;;
            *)
                # bash 3.2 gives bytes over 127 as negative numbers.
                printf -v n '%d' "'$c"
                printf -v n '%%%02X' $((n & 255))
                _vh_enc=$_vh_enc$n
                ;;
        esac
        i=$((i + 1))
    done
}

# $1 with a backslash before every \ and ", into _vh_esc. A loop, since
# bash versions treat backslashes in ${v//x/y} replacements differently.
_vigil_http_escape() {
    local v=$1 run
    _vh_esc=''
    while :; do
        run=${v%%$_vigil_json_pat_str*}
        if [ "$run" = "$v" ]; then
            _vh_esc=$_vh_esc$v
            return 0
        fi
        _vh_esc=$_vh_esc$run'\'${v:${#run}:1}
        v=${v:${#run}+1}
    done
}

# $1 as a JSON string, into _vh_enc. Control characters never get here.
_vigil_json_quote() {
    _vigil_http_escape "$1"
    _vh_enc="\"$_vh_esc\""
    _vh_esc=''
}

# One line of a curl configuration, the value quoted as curl reads it.
_vigil_curl_opt() {
    _vigil_http_escape "$2"
    printf '%s = "%s"\n' "$1" "$_vh_esc"
    _vh_esc=''
}

# _vigil_http_send <timeout> <method> <url> <ca_file> <metadata>
# One request with curl, with the headers in _vh_headers ("Name: value"
# each) and, for POST, the body in _vh_body. Sets _vh_status and _vh_resp and
# returns 0, or returns 1 with _vh_fail set: nocurl, cafile, resolve,
# connect, timeout, untrusted, tls or other. Only https, except metadata (1): the
# instance metadata endpoint, plain http and never through a proxy.
_vigil_http_send() {
    local out rc h ca
    local -a opts
    _vh_status=''
    _vh_resp=''
    _vh_fail=''
    if ! command -v curl > /dev/null 2>&1; then
        _vh_fail=nocurl
        return 1
    fi
    if [ -n "$4" ] && [ ! -r "$4" ]; then
        _vh_fail=cafile
        return 1
    fi
    # -q first: no .curlrc may change how Vigil connects.
    if [ "$5" = 1 ]; then
        opts=(-q --proto =http --noproxy '*')
    else
        opts=(-q --proto =https)
    fi
    # Under Git Bash and Cygwin, curl is a Windows program: Windows' TLS
    # (Schannel) cannot check the revocation of a private CA's certificates,
    # and a path it reads from its input is not converted for it.
    ca=$4
    case $(uname -s) in
        MINGW* | MSYS* | CYGWIN*)
            opts[${#opts[@]}]=--ssl-revoke-best-effort
            [ -n "$ca" ] && ca=$(cygpath -m "$ca")
            ;;
    esac
    out=$(
        {
            _vigil_curl_opt url "$3"
            [ -n "$ca" ] && _vigil_curl_opt cacert "$ca"
            [ "$2" = POST ] && _vigil_curl_opt data-raw "$_vh_body"
            for h in ${_vh_headers[@]+"${_vh_headers[@]}"}; do _vigil_curl_opt header "$h"; done
        } | curl "${opts[@]}" -sS --max-time "$1" -w '\n%{http_code}' -K - 2> /dev/null
        printf '\n%s' "$?"
    )
    rc=${out##*$'\n'}
    out=${out%$'\n'*}
    case $rc in
        0) ;;
        6) _vh_fail=resolve ;;
        7) _vh_fail=connect ;;
        28) _vh_fail=timeout ;;
        60) _vh_fail=untrusted ;;
        35 | 51 | 53 | 54 | 58 | 59 | 66 | 77 | 80 | 82 | 83 | 90 | 91) _vh_fail=tls ;;
        *) _vh_fail=other ;;
    esac
    [ "$rc" = 0 ] || return 1
    _vh_status=${out##*$'\n'}
    _vh_resp=${out%$'\n'*}
}

# --- Stores --------------------------------------------------------------------

# A store section's keys, as _vs_<key>.
_vigil_store_keys() {
    local root=$1 sec=$2 i end
    _vs_url='' _vs_vault='' _vs_mount=secret _vs_field=value _vs_auth=''
    _vs_token='' _vs_role_id='' _vs_secret_id=''
    _vs_tenant_id='' _vs_client_id='' _vs_client_secret=''
    _vs_authority=https://login.microsoftonline.com _vs_ca_file='' _vs_timeout=10
    i=${VIGIL_CFG_SEC_FIRST[$sec]}
    end=$((i + VIGIL_CFG_SEC_COUNT[sec]))
    while [ "$i" -lt "$end" ]; do
        case ${VIGIL_CFG_KEY[$i]} in
            url) _vs_url=${VIGIL_CFG_VALUE[$i]} ;;
            vault) _vs_vault=${VIGIL_CFG_VALUE[$i]} ;;
            mount) _vs_mount=${VIGIL_CFG_VALUE[$i]} ;;
            field) _vs_field=${VIGIL_CFG_VALUE[$i]} ;;
            auth) _vs_auth=${VIGIL_CFG_VALUE[$i]} ;;
            token) _vs_token=${VIGIL_CFG_VALUE[$i]} ;;
            role_id) _vs_role_id=${VIGIL_CFG_VALUE[$i]} ;;
            secret_id) _vs_secret_id=${VIGIL_CFG_VALUE[$i]} ;;
            tenant_id) _vs_tenant_id=${VIGIL_CFG_VALUE[$i]} ;;
            client_id) _vs_client_id=${VIGIL_CFG_VALUE[$i]} ;;
            client_secret) _vs_client_secret=${VIGIL_CFG_VALUE[$i]} ;;
            authority) _vs_authority=${VIGIL_CFG_VALUE[$i]} ;;
            ca_file) _vs_ca_file=${VIGIL_CFG_VALUE[$i]} ;;
            timeout) _vigil_wk_secs "${VIGIL_CFG_VALUE[$i]}"; _vs_timeout=$_vw_secs ;;
        esac
        i=$((i + 1))
    done
    case $_vs_ca_file in
        '' | /*) ;;
        *) _vs_ca_file=$root/$_vs_ca_file ;;
    esac
}

# The store's own credential, key $2 with reference $3, into _vs_cred.
_vigil_store_cred() {
    if [ -z "$3" ]; then
        VIGIL_SECRET_WHY="the store needs '$2'"
        return 1
    fi
    if ! vigil_secret_resolve "$1" "$3"; then
        VIGIL_SECRET_WHY="$2 $3: $VIGIL_SECRET_WHY"
        return 1
    fi
    _vs_cred=$VIGIL_SECRET_VALUE
    VIGIL_SECRET_VALUE=''
    case $_vs_cred in
        *[[:cntrl:]]*)
            _vs_cred=''
            VIGIL_SECRET_WHY="$2 $3: contains a control character"
            return 1
            ;;
    esac
}

# _vigil_store_request <prefix> <method> <url> <metadata>
# Sends _vh_headers and _vh_body. Returns 0 on HTTP 200, with the answer in
# _vh_resp, or 1 with VIGIL_SECRET_WHY set and starting with <prefix>.
_vigil_store_request() {
    local host why ca=$_vs_ca_file
    [ "$4" = 1 ] && ca=''
    host=${3#*://}
    host=${host%%/*}
    host=${host%%\?*}
    if ! _vigil_http_send "$_vs_timeout" "$2" "$3" "$ca" "$4"; then
        case $_vh_fail in
            nocurl) why='curl is not installed' ;;
            cafile) why="cannot read ca_file $_vs_ca_file" ;;
            resolve) why="cannot resolve $host" ;;
            connect) why="cannot connect to $host" ;;
            timeout) why="no answer from $host within ${_vs_timeout}s" ;;
            untrusted) why="the certificate of $host is not trusted" ;;
            tls) why="no secure connection to $host" ;;
            *) why="the request to $host failed" ;;
        esac
    else
        case $_vh_status in
            200) _vh_body=''; return 0 ;;
            404) why='not found (HTTP 404)' ;;
            401 | 403) why="permission denied (HTTP $_vh_status)" ;;
            *) why="HTTP $_vh_status from $host" ;;
        esac
    fi
    _vh_body=''
    _vh_resp=''
    VIGIL_SECRET_WHY=$1$why
    return 1
}

# The string at a path of the last answer, into _vs_got.
_vigil_store_answer() {
    local prefix=$1
    shift
    if ! vigil_json_get "$_vh_resp" "$@"; then
        _vh_resp=''
        VIGIL_SECRET_WHY="${prefix}unexpected answer: $VIGIL_JSON_WHY"
        return 1
    fi
    _vh_resp=''
    _vs_got=$VIGIL_JSON_VALUE
    VIGIL_JSON_VALUE=''
}

# HashiCorp Vault, KV version 2.
_vigil_store_hashicorp_vault() {
    local root=$1 name=$2 url=${_vs_url%/} mount
    case /$name/ in
        *//* | */./* | */../*)
            VIGIL_SECRET_WHY='not a valid secret path'
            return 1
            ;;
    esac
    case $_vs_auth in
        token)
            _vigil_store_cred "$root" token "$_vs_token" || return 1
            ;;
        approle)
            _vigil_store_cred "$root" secret_id "$_vs_secret_id" || return 1
            _vigil_json_quote "$_vs_role_id"
            _vh_body="{\"role_id\":$_vh_enc"
            _vigil_json_quote "$_vs_cred"
            _vh_body="$_vh_body,\"secret_id\":$_vh_enc}"
            _vh_enc=''
            _vs_cred=''
            _vh_headers=('Content-Type: application/json')
            _vigil_store_request 'sign-in failed: ' POST "$url/v1/auth/approle/login" 0 || return 1
            _vigil_store_answer 'sign-in failed: ' auth client_token || return 1
            _vs_cred=$_vs_got
            _vs_got=''
            ;;
        *)
            VIGIL_SECRET_WHY="the store needs 'auth'"
            return 1
            ;;
    esac
    _vigil_http_encode "$_vs_mount" 1
    mount=$_vh_enc
    _vigil_http_encode "$name" 1
    _vh_headers=("X-Vault-Token: $_vs_cred")
    _vs_cred=''
    _vigil_store_request '' GET "$url/v1/$mount/data/$_vh_enc" 0 || return 1
    _vigil_store_answer '' data data "$_vs_field" || return 1
    VIGIL_SECRET_VALUE=$_vs_got
}

# Azure Key Vault.
_vigil_store_azure_keyvault() {
    local root=$1 name=$2 vault=${_vs_vault%/} host resource imds q
    local re='^[0-9A-Za-z-]+(/[0-9A-Za-z]+)?$' re_imds='^http://127\.0\.0\.1:[0-9]+$'
    if ! [[ $name =~ $re ]]; then
        VIGIL_SECRET_WHY='not a valid Key Vault secret name'
        return 1
    fi
    # Tokens are for the vault's cloud: ops-kv.vault.azure.net is in
    # vault.azure.net.
    host=${vault#https://}
    host=${host%%/*}
    host=${host%%:*}
    case $host in
        *.*.*) resource=${host#*.} ;;
        *) resource=$host ;;
    esac
    case $_vs_auth in
        managed_identity)
            imds=http://169.254.169.254
            if [ -n "${VIGIL_TEST_IMDS:-}" ] && [[ $VIGIL_TEST_IMDS =~ $re_imds ]]; then
                imds=$VIGIL_TEST_IMDS
            fi
            _vigil_http_encode "https://$resource" 0
            q="api-version=2018-02-01&resource=$_vh_enc"
            if [ -n "$_vs_client_id" ]; then
                _vigil_http_encode "$_vs_client_id" 0
                q="$q&client_id=$_vh_enc"
            fi
            _vh_headers=('Metadata: true')
            _vigil_store_request 'sign-in failed: ' GET "$imds/metadata/identity/oauth2/token?$q" 1 || return 1
            ;;
        service_principal)
            _vigil_store_cred "$root" client_secret "$_vs_client_secret" || return 1
            _vigil_http_encode "$_vs_client_id" 0
            _vh_body="grant_type=client_credentials&client_id=$_vh_enc"
            _vigil_http_encode "$_vs_cred" 0
            _vh_body="$_vh_body&client_secret=$_vh_enc"
            _vigil_http_encode "https://$resource/.default" 0
            _vh_body="$_vh_body&scope=$_vh_enc"
            _vs_cred=''
            _vigil_http_encode "$_vs_tenant_id" 0
            _vh_headers=('Content-Type: application/x-www-form-urlencoded')
            _vigil_store_request 'sign-in failed: ' POST "${_vs_authority%/}/$_vh_enc/oauth2/v2.0/token" 0 || return 1
            ;;
        *)
            VIGIL_SECRET_WHY="the store needs 'auth'"
            return 1
            ;;
    esac
    _vigil_store_answer 'sign-in failed: ' access_token || return 1
    _vh_headers=("Authorization: Bearer $_vs_got")
    _vs_got=''
    _vigil_store_request '' GET "$vault/secrets/$name?api-version=7.4" 0 || return 1
    _vigil_store_answer '' value || return 1
    VIGIL_SECRET_VALUE=$_vs_got
}

vigil_store_fetch() {
    local rc
    _vigil_store_keys "$1" "$2"
    VIGIL_SECRET_VALUE=''
    VIGIL_SECRET_WHY=''
    _vh_headers=()
    _vh_body=''
    "_vigil_store_$3" "$1" "$4"
    rc=$?
    _vh_headers=()
    _vh_body=''
    _vh_resp=''
    _vh_enc=''
    _vs_cred=''
    _vs_got=''
    return "$rc"
}
