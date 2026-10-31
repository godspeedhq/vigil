# shellcheck shell=bash
#
# Vigil secrets - bash 3.2 compatible.
#
# Resolves secret references (SPECIFICATION.md 6.5) when a run starts, and
# manages Vigil's own secret store. Values only ever live in shell variables
# and the environment of the one process that needs them: never in a log,
# state, the spool, a temporary file or a command line.
#
#   vigil_secret_resolve <root> <reference>
#     env:NAME, secret:NAME or store:STORE/NAME. Sets VIGIL_SECRET_VALUE and
#     returns 0, or returns 1 with VIGIL_SECRET_WHY (never containing the
#     value) set. Store sections are read from the parsed configuration.
#   vigil_secret_set <root> <NAME> <value>
#   vigil_secret_delete <root> <NAME>
#   vigil_secret_list <root>
#
# The store is config/secrets/<NAME>, one file per secret: the folder 0700
# and every file 0600, owned by the account Vigil runs as. A secret is not
# read when anyone else could read or change it.
#
# Requires config.sh.

VIGIL_SECRET_RE_NAME='^[A-Za-z_][A-Za-z0-9_]*$'

# Strips one trailing newline (LF or CRLF) from _vsec_v.
_vigil_secret_chomp() {
    _vsec_v=${_vsec_v%$'\n'}
    _vsec_v=${_vsec_v%$'\r'}
}

# Whether path $1 is safe: owned by this account, with no access for group
# or others. Sets _vsec_why when it is not.
_vigil_secret_safe() {
    local listing perms uid
    # Git Bash and Cygwin cannot enforce Unix permissions. They are for
    # development only: Windows runs the PowerShell implementation, whose
    # store is encrypted with DPAPI.
    case $(uname -s) in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
    listing=$(ls -ldn -- "$1" 2>/dev/null) || { _vsec_why="cannot inspect $1"; return 1; }
    set -f
    # shellcheck disable=SC2086
    set -- $listing
    set +f
    perms=$1
    uid=$3
    if [ "$uid" != "$(id -u)" ]; then
        _vsec_why="its file is owned by another account; run vigil secret as the service account"
        return 1
    fi
    case $perms in
        ?????????? | ??????????[.+@]) ;;
        *) _vsec_why="cannot read its permissions"; return 1 ;;
    esac
    case ${perms:4:6} in
        ------) return 0 ;;
    esac
    _vsec_why="its file or folder is accessible to other accounts; run: chmod 700 config/secrets && chmod 600 config/secrets/*"
    return 1
}

_vigil_secret_read() {
    local dir="$1/config/secrets" f="$1/config/secrets/$2"
    if [ ! -f "$f" ]; then
        VIGIL_SECRET_WHY="not found in Vigil's secret store (vigil secret set $2)"
        return 1
    fi
    if ! _vigil_secret_safe "$dir" || ! _vigil_secret_safe "$f"; then
        VIGIL_SECRET_WHY="refused: $_vsec_why"
        return 1
    fi
    _vsec_v=''
    IFS= read -r -d '' _vsec_v < "$f"
    _vigil_secret_chomp
    VIGIL_SECRET_VALUE=$_vsec_v
}

# Runs a helper store: <command> <arg>... get <NAME>, never through a shell,
# within the store's timeout. Its stdout is the value.
_vigil_secret_helper() {
    local root=$3
    local sec=$1 name=$2 cmd='' t=10 i end rc
    local -a args
    args=()
    i=${VIGIL_CFG_SEC_FIRST[$sec]}
    end=$((i + VIGIL_CFG_SEC_COUNT[sec]))
    while [ "$i" -lt "$end" ]; do
        case ${VIGIL_CFG_KEY[$i]} in
            command) cmd=${VIGIL_CFG_VALUE[$i]} ;;
            arg) args[${#args[@]}]=${VIGIL_CFG_VALUE[$i]} ;;
            timeout) _vigil_wk_secs "${VIGIL_CFG_VALUE[$i]}"; t=$_vw_secs ;;
        esac
        i=$((i + 1))
    done
    # A relative command resolves against the install root, like every path.
    case $cmd in
        /*) ;;
        */*) cmd="$root/$cmd" ;;
    esac
    # The value is captured with a trailing marker, so only one trailing
    # newline is removed, as for a stored secret. The watchdog writes to
    # /dev/null so it never holds the capture open.
    _vsec_v=$(
        "$cmd" ${args[@]+"${args[@]}"} get "$name" 2>/dev/null < /dev/null &
        p=$!
        ( sleep "$t"; kill "$p" 2>/dev/null ) > /dev/null 2>&1 &
        w=$!
        wait "$p"
        rc=$?
        kill "$w" 2>/dev/null
        printf x
        exit "$rc"
    )
    rc=$?
    _vsec_v=${_vsec_v%x}
    if [ "$rc" -ne 0 ]; then
        _vsec_v=''
        if [ "$rc" -ge 128 ]; then
            VIGIL_SECRET_WHY="the helper was stopped after ${t}s"
        else
            VIGIL_SECRET_WHY="the helper failed (exit code $rc)"
        fi
        return 1
    fi
    _vigil_secret_chomp
    VIGIL_SECRET_VALUE=$_vsec_v
    _vsec_v=''
}

vigil_secret_resolve() {
    local root=$1 ref=$2 name store sec i end type=''
    VIGIL_SECRET_VALUE=''
    VIGIL_SECRET_WHY=''
    case $ref in
        env:*)
            name=${ref#env:}
            if eval "[ -n \"\${$name+set}\" ]"; then
                eval "VIGIL_SECRET_VALUE=\$$name"
                return 0
            fi
            VIGIL_SECRET_WHY='not set in the environment'
            return 1
            ;;
        secret:*)
            _vigil_secret_read "$root" "${ref#secret:}"
            return $?
            ;;
        store:*)
            store=${ref#store:}
            name=${store#*/}
            store=${store%%/*}
            vigil_config_section "secret_store.$store"
            sec=$VIGIL_CFG_SEC
            if [ "$sec" -lt 0 ]; then
                VIGIL_SECRET_WHY="no [secret_store.$store] section"
                return 1
            fi
            i=${VIGIL_CFG_SEC_FIRST[$sec]}
            end=$((i + VIGIL_CFG_SEC_COUNT[sec]))
            while [ "$i" -lt "$end" ]; do
                [ "${VIGIL_CFG_KEY[$i]}" = type ] && type=${VIGIL_CFG_VALUE[$i]}
                i=$((i + 1))
            done
            case $type in
                helper) _vigil_secret_helper "$sec" "$name" "$root"; return $? ;;
                hashicorp_vault | azure_keyvault) vigil_store_fetch "$root" "$sec" "$type" "$name"; return $? ;;
            esac
            VIGIL_SECRET_WHY="store type $type not implemented yet"
            return 1
            ;;
    esac
    VIGIL_SECRET_WHY='not a secret reference'
    return 1
}

vigil_secret_set() {
    local dir="$1/config/secrets" name=$2 tmp
    [[ $name =~ $VIGIL_SECRET_RE_NAME ]] || { printf 'vigil: not a valid secret name: %s\n' "$name" >&2; return 1; }
    (
        umask 077
        mkdir -p "$dir" && chmod 700 "$dir" || exit 1
        tmp="$dir/.$name.tmp.$$"
        printf '%s' "$3" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$dir/$name"
    )
}

vigil_secret_delete() {
    local f="$1/config/secrets/$2"
    [ -f "$f" ] || { printf 'vigil: no secret %s\n' "$2" >&2; return 1; }
    rm -f "$f"
}

vigil_secret_list() {
    local f name when
    for f in "$1/config/secrets/"*; do
        [ -f "$f" ] || continue
        name=${f##*/}
        [[ $name =~ $VIGIL_SECRET_RE_NAME ]] || continue
        # GNU date reads a file's time with -r; BSD date (macOS) takes
        # seconds, which BSD stat gives.
        when=$(date -u -r "$f" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
            when=$(date -u -r "$(stat -f %m "$f" 2>/dev/null)" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
            when='?'
        printf '%-32s changed %s\n' "$name" "$when"
    done
}
