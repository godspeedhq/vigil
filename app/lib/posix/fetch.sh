# shellcheck shell=bash
#
# Vigil fetcher - bash 3.2 compatible.
#
# Sources and reconciliation (SPECIFICATION.md 6.8, 6.9, 16.5): the body of
# the vigil_fetch worker, and the activation record the supervisor, workers
# and pre-flight read.
#
#   vigil_fetch
#     Called by the worker after its claim, with the local configuration
#     parsed and _vw_root, _vw_statedir, _vw_spooldir, _vw_host and _vw_os
#     set. Fetches what the candidate configuration needs, verifies it, and
#     activates it by writing state/config.active. Returns 0, or 1 with
#     _vw_reason set; on failure nothing that is active changes.
#   vigil_fetch_mode
#     Whether the parsed configuration needs the fetcher: it is a pointer
#     file (6.8) or defines a source (6.9).
#   vigil_active_read <state dir>
#     Reads the activation record. Returns 1 when there is none, or its
#     configuration file is missing. Sets VIGIL_ACT_CONFIG (the
#     configuration file), VIGIL_ACT_REVISION, VIGIL_ACT_ORIGIN and, for
#     each script, VIGIL_ACT_SRC[i], VIGIL_ACT_FILE[i], VIGIL_ACT_ENTRY[i]
#     and VIGIL_ACT_SHA[i]. Needs _vw_root.
#   vigil_active_script <source> <file>
#     The cached copy of a script named by the record read last, in
#     _va_path. Returns 1 when the record does not name it.
#
# Each configuration activated is kept as state/configs/<sha256>.config, so
# deleting the cache never loses the last valid one. The cache is
# <root>/cache, with cache/<source>/<entry>/ for each source, where the
# entry is a git commit, the digest of a local directory's contents, or the
# digest of a file fetched over https or sftp. Entries are assembled under
# cache/staging/ and renamed into place, so each is complete or absent.
#
# Requires config.sh, validate.sh, worker.sh, secrets.sh, stores.sh and
# precheck.sh.

VIGIL_FETCH_CONFIG_MAX=1048576
VIGIL_FETCH_SCRIPT_MAX=16777216

vigil_fetch_mode() {
    local s=0
    while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
        case ${VIGIL_CFG_SEC_NAME[$s]} in source.*) return 0 ;; esac
        s=$((s + 1))
    done
    _vigil_wk_get vigil config_source ''
    [ -n "$_vw_value" ]
}

vigil_active_read() {
    local line key value rest
    VIGIL_ACT_CONFIG='' VIGIL_ACT_REVISION='' VIGIL_ACT_ORIGIN=''
    VIGIL_ACT_SRC=() VIGIL_ACT_FILE=() VIGIL_ACT_ENTRY=() VIGIL_ACT_SHA=()
    [ -f "$1/config.active" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in *' = '*) ;; *) continue ;; esac
        key=${line%%=*}
        key=${key%"${key##*[! ]}"}
        value=${line#*= }
        case $key in
            revision) VIGIL_ACT_REVISION=$value ;;
            origin) VIGIL_ACT_ORIGIN=$value ;;
            config) VIGIL_ACT_CONFIG="$1/configs/$value.config" ;;
            script)
                # <source> <entry> <sha256> <file>: the file last, since it
                # may hold spaces.
                VIGIL_ACT_SRC[${#VIGIL_ACT_SRC[@]}]=${value%% *}
                rest=${value#* }
                VIGIL_ACT_ENTRY[${#VIGIL_ACT_ENTRY[@]}]=${rest%% *}
                rest=${rest#* }
                VIGIL_ACT_SHA[${#VIGIL_ACT_SHA[@]}]=${rest%% *}
                VIGIL_ACT_FILE[${#VIGIL_ACT_FILE[@]}]=${rest#* }
                ;;
        esac
    done < "$1/config.active"
    [ -n "$VIGIL_ACT_CONFIG" ] && [ -f "$VIGIL_ACT_CONFIG" ]
}

vigil_active_script() {
    local i=0
    _va_path=''
    while [ "$i" -lt "${#VIGIL_ACT_SRC[@]}" ]; do
        if [ "${VIGIL_ACT_SRC[$i]}" = "$1" ] && [ "${VIGIL_ACT_FILE[$i]}" = "$2" ]; then
            _va_path="$_vw_root/cache/$1/${VIGIL_ACT_ENTRY[$i]}/$2"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# The SHA-256 of standard input, as 64 lower-case hex digits.
_vigil_fetch_digest() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum | cut -c1-64
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 | cut -c1-64
    else
        openssl dgst -sha256 -r | cut -c1-64
    fi
}

# The size of file $1 in bytes. Result in _vf_size.
_vigil_fetch_size() {
    _vf_size=$(wc -c < "$1" 2>/dev/null)
    _vf_size=$((_vf_size + 0))
}

# Runs a command with a time limit of $1 seconds, its output to files $2 and
# $3. Returns its exit status, or 124 when it was stopped at the limit; it
# is stopped with its process group, so a child it started goes too.
_vigil_fetch_exec() {
    local secs=$1 out=$2 err=$3 pid n=0
    shift 3
    set -m
    "$@" > "$out" 2> "$err" < /dev/null &
    pid=$!
    set +m
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$n" -ge $((secs * 5)) ]; then
            kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.2
        n=$((n + 1))
    done
    wait "$pid"
}

# The first line of file $1, for a failure reason. Result in _vf_line.
_vigil_fetch_first() {
    _vf_line=''
    IFS= read -r _vf_line < "$1" 2>/dev/null
    _vf_line=${_vf_line%$'\r'}
    _vf_line=${_vf_line:0:200}
}

# Source $1's settings from the parsed configuration, as _vfs_<key>.
_vigil_fetch_source() {
    local sec="source.$1"
    _vigil_wk_get "$sec" type ''
    _vfs_type=$_vw_value
    _vigil_wk_get "$sec" url ''
    _vfs_url=$_vw_value
    _vigil_wk_get "$sec" path ''
    _vfs_path=$_vw_value
    _vigil_wk_get "$sec" host ''
    _vfs_host=$_vw_value
    _vigil_wk_get "$sec" port 22
    _vfs_port=$_vw_value
    _vigil_wk_get "$sec" user ''
    _vfs_user=$_vw_value
    _vigil_wk_get "$sec" ref ''
    _vfs_ref=$_vw_value
    _vigil_wk_get "$sec" header_name ''
    _vfs_hname=$_vw_value
    _vigil_wk_get "$sec" header_value ''
    _vfs_hvalue=$_vw_value
    _vigil_wk_get "$sec" check_every 5m
    _vfs_check=$_vw_value
    _vigil_wk_secs "$_vw_value"
    _vfs_every=$_vw_secs
    _vigil_wk_get "$sec" timeout 60s
    _vfs_timeout=$_vw_value
    _vigil_wk_secs "$_vw_value"
    _vfs_secs=$_vw_secs
    # What the source's content depends on: a change refetches it.
    _vfs_identity="$_vfs_type $_vfs_url$_vfs_path $_vfs_host:$_vfs_port $_vfs_user $_vfs_ref"
}

# Source $1's fetch state: _vft_identity, _vft_checked, _vft_ok (the last
# successful check), _vft_entry, _vft_kind and _vft_failures.
_vigil_fetch_state_read() {
    local line key value
    _vft_identity='' _vft_checked=0 _vft_ok='' _vft_entry='' _vft_kind='' _vft_failures=0
    [ -f "$_vw_statedir/sources/$1.state" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in *' = '* | *' =') ;; *) continue ;; esac
        key=${line%%=*}
        key=${key%"${key##*[! ]}"}
        value=${line#*=}
        value=${value# }
        case $key in
            identity) _vft_identity=$value ;;
            checked_epoch) _vft_checked=$value ;;
            ok_epoch) _vft_ok=$value ;;
            entry) _vft_entry=$value ;;
            kind) _vft_kind=$value ;;
            failures) _vft_failures=$value ;;
        esac
    done < "$_vw_statedir/sources/$1.state"
}

# Writes source $1's fetch state from the _vft_ variables, with error $2.
_vigil_fetch_state_write() {
    local f="$_vw_statedir/sources/$1.state"
    mkdir -p "$_vw_statedir/sources"
    {
        printf '[source]\n'
        printf 'identity      = %s\n' "$_vft_identity"
        printf 'checked_epoch = %s\n' "$_vft_checked"
        printf 'ok_epoch      = %s\n' "$_vft_ok"
        printf 'entry         = %s\n' "$_vft_entry"
        printf 'kind          = %s\n' "$_vft_kind"
        printf 'failures      = %s\n' "$_vft_failures"
        printf 'error         = %s\n' "$2"
    } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# Records a failure of source $1, with reason _vf_why, once per run. The
# event's reason tag sorts it (14.5).
_vigil_fetch_failed() {
    local reason=unreachable
    case " $_vf_failed_names " in *" $1 "*) return 0 ;; esac
    _vf_failed_names="$_vf_failed_names $1"
    _vf_failed="$_vf_failed${_vf_failed:+; }source.$1: $_vf_why"
    case $_vf_why in
        *'timed out'*) reason=timeout ;;
        *'permission denied'* | *'Permission denied'* | *'Host key verification failed'* | *'Authentication failed'* | *'could not read Username'*) reason=auth ;;
        *'does not match its sha256'*) reason=digest ;;
        *'has errors' | *' not found' | *'not found (HTTP 404)' | *'symbolic link'* | *'larger than'*) reason=invalid ;;
    esac
    _vf_events[${#_vf_events[@]}]="$_vf_now vigil.source.failures 1 count $_vf_tags source=$1 reason=$reason"
    _vigil_wk_log "$_vw_run run source.$1: $_vf_why"
}

# Remembers when source $1 is next checked: _vf_next is the earliest.
_vigil_fetch_next() {
    local n=$(($2 + $3))
    if [ -z "$_vf_next" ] || [ "$n" -lt "$_vf_next" ]; then _vf_next=$n; fi
}

# Whether link path $1 with target $2 stays inside the tree it is in: the
# link's directory, then the target from there, never above the top.
_vigil_fetch_inside() {
    local depth=0 seg path=$2 IFS=/
    case $2 in /* | *\\* | [A-Za-z]:*) return 1 ;; esac
    case $1 in */*) path="${1%/*}/$2" ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $path
    set +f
    for seg in "$@"; do
        case $seg in
            '' | .) ;;
            ..)
                depth=$((depth - 1))
                [ "$depth" -ge 0 ] || return 1
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
    return 0
}

# A symbolic link in commit $2 of mirror $1 that points outside the tree.
# Result in _vf_link (empty when there is none).
_vigil_fetch_links() {
    local rec oid path target found=''
    while IFS= read -r -d '' rec; do
        case $rec in 120000\ *) ;; *) continue ;; esac
        oid=${rec#* blob }
        oid=${oid%%	*}
        path=${rec#*	}
        target=$(git --git-dir="$1" cat-file blob "$oid" 2>/dev/null)
        if ! _vigil_fetch_inside "$path" "$target"; then
            found=$path
            break
        fi
    done < <(git --git-dir="$1" ls-tree -r -z "$2" 2>/dev/null)
    _vf_link=$found
}

# git: fetch into the bare mirror, resolve the ref and unpack its tree.
_vigil_fetch_git() {
    local name=$1 mirror="$_vw_root/cache/$1/repo.git" commit rc tree="$_vf_st/tree"
    _vf_kind=''
    if ! command -v git > /dev/null 2>&1; then
        _vf_why='git not found'
        return 1
    fi
    mkdir -p "$_vw_root/cache/$name"
    if [ ! -d "$mirror" ] && ! git init -q --bare "$mirror" > /dev/null 2>&1; then
        _vf_why="cannot create $mirror"
        return 1
    fi
    # Nothing is checked out, so no hook, filter or submodule ever runs.
    # Credentials come from the account's credential helper or SSH key;
    # nothing may stop to ask for one.
    _vigil_fetch_exec "$_vfs_secs" "$_vf_st/out" "$_vf_st/err" env GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
        git --git-dir="$mirror" -c core.hooksPath=/dev/null fetch -q --no-tags --no-recurse-submodules --force \
        "$_vfs_url" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
    rc=$?
    if [ "$rc" -eq 124 ]; then
        _vf_why="timed out after $_vfs_timeout"
        return 1
    elif [ "$rc" -ne 0 ]; then
        _vigil_fetch_first "$_vf_st/err"
        _vf_why="git fetch failed: ${_vf_line:-exit code $rc}"
        return 1
    fi
    if commit=$(git --git-dir="$mirror" rev-parse -q --verify "refs/tags/$_vfs_ref^{commit}" 2>/dev/null); then
        _vf_kind=tag
    elif commit=$(git --git-dir="$mirror" rev-parse -q --verify "refs/heads/$_vfs_ref^{commit}" 2>/dev/null); then
        _vf_kind=branch
    elif [[ $_vfs_ref =~ ^[0-9a-f]{7,64}$ ]] && commit=$(git --git-dir="$mirror" rev-parse -q --verify "$_vfs_ref^{commit}" 2>/dev/null); then
        _vf_kind=commit
    else
        _vf_why="ref '$_vfs_ref' not found"
        return 1
    fi
    _vf_entry=$commit
    [ -d "$_vw_root/cache/$name/$commit" ] && return 0
    _vigil_fetch_links "$mirror" "$commit"
    if [ -n "$_vf_link" ]; then
        _vf_why="'$_vf_link' at $_vfs_ref is a symbolic link pointing outside the repository"
        return 1
    fi
    rm -rf "$tree" "$_vf_st/tree.tar"
    mkdir -p "$tree"
    if ! git --git-dir="$mirror" -c core.autocrlf=false archive --format=tar -o "$_vf_st/tree.tar" "$commit" 2> "$_vf_st/err" ||
        ! tar -xf "$_vf_st/tree.tar" -C "$tree" 2> "$_vf_st/err"; then
        _vigil_fetch_first "$_vf_st/err"
        _vf_why="cannot unpack $commit: $_vf_line"
        return 1
    fi
    rm -f "$_vf_st/tree.tar"
    mv "$tree" "$_vw_root/cache/$name/$commit" 2>/dev/null || [ -d "$_vw_root/cache/$name/$commit" ]
}

# local: a copy of the directory, so a job never runs a file from a share
# that may change under it. The entry is named by the copy's contents.
_vigil_fetch_local() {
    local dir=$_vfs_path tree="$_vf_st/tree" rc digest
    case $dir in /*) ;; *) dir="$_vw_root/$dir" ;; esac
    if [ ! -d "$dir" ]; then
        _vf_why="not a directory: $dir"
        return 1
    fi
    rm -rf "$tree"
    _vigil_fetch_exec "$_vfs_secs" "$_vf_st/out" "$_vf_st/err" cp -R "$dir" "$tree"
    rc=$?
    if [ "$rc" -eq 124 ]; then
        _vf_why="timed out after $_vfs_timeout"
        return 1
    elif [ "$rc" -ne 0 ]; then
        _vigil_fetch_first "$_vf_st/err"
        _vf_why="cannot copy $dir: $_vf_line"
        return 1
    fi
    digest=$(
        cd "$tree" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s %s\n' "$(_vigil_fetch_digest < "$f")" "$f"
        done | _vigil_fetch_digest
    )
    _vf_entry=$digest
    if [ -d "$_vw_root/cache/$1/$digest" ]; then
        rm -rf "$tree"
        return 0
    fi
    mkdir -p "$_vw_root/cache/$1"
    mv "$tree" "$_vw_root/cache/$1/$digest" 2>/dev/null || [ -d "$_vw_root/cache/$1/$digest" ]
}

# https: GET <url>/<file> into $2, with the source's header. Plain http
# only to this host (as for a metrics backend, 15.3); redirects are not
# followed.
_vigil_fetch_https() {
    local url=$_vfs_url out=$2 rc status host
    local -a opts
    if ! command -v curl > /dev/null 2>&1; then
        _vf_why='curl not found'
        return 1
    fi
    case $url in */) ;; *) url="$url/" ;; esac
    _vigil_http_encode "$1" 1
    url=$url$_vh_enc
    host=${_vfs_url#*://}
    host=${host%%/*}
    case $_vfs_url in
        http://localhost | http://localhost[:/]* | http://127.0.0.1 | http://127.0.0.1[:/]* | 'http://[::1]' | 'http://[::1]'[:/]*)
            opts=(-q --proto =http --noproxy '*') ;;
        *) opts=(-q --proto =https) ;;
    esac
    case $(uname -s) in
        MINGW* | MSYS* | CYGWIN*)
            opts[${#opts[@]}]=--ssl-revoke-best-effort
            out=$(cygpath -m "$out")
            ;;
    esac
    VIGIL_SECRET_VALUE=''
    if [ -n "$_vfs_hname" ]; then
        if ! vigil_secret_resolve "$_vw_root" "$_vfs_hvalue"; then
            _vf_why="header_value $_vfs_hvalue unavailable: $VIGIL_SECRET_WHY"
            return 1
        fi
        case $VIGIL_SECRET_VALUE in
            *[[:cntrl:]]*)
                VIGIL_SECRET_VALUE=''
                _vf_why="header_value $_vfs_hvalue holds a control character"
                return 1
                ;;
        esac
    fi
    status=$(
        {
            _vigil_curl_opt url "$url"
            [ -n "$_vfs_hname" ] && _vigil_curl_opt header "$_vfs_hname: $VIGIL_SECRET_VALUE"
        } | curl "${opts[@]}" -sS --max-time "$_vfs_secs" --max-filesize "$3" -o "$out" -w '%{http_code}' -K - 2>/dev/null
    )
    rc=$?
    VIGIL_SECRET_VALUE=''
    case $rc in
        0) ;;
        6) _vf_why="cannot resolve $host" ;;
        7) _vf_why="cannot connect to $host" ;;
        28) _vf_why="timed out after $_vfs_timeout" ;;
        60) _vf_why="the certificate of $host is not trusted" ;;
        63) _vf_why="$1 is larger than $3 bytes" ;;
        *) _vf_why="request to $host failed (curl exit code $rc)" ;;
    esac
    [ "$rc" -eq 0 ] || return 1
    case $status in
        200) return 0 ;;
        401 | 403) _vf_why="permission denied (HTTP $status)" ;;
        404) _vf_why="$1 not found (HTTP 404)" ;;
        *) _vf_why="HTTP $status from $host" ;;
    esac
    return 1
}

# sftp: the OpenSSH client in batch mode; the server's host key must already
# be known. VIGIL_TEST_SSH_CONFIG gives tests their own ssh configuration;
# the options on the command line take precedence over it.
_vigil_fetch_sftp() {
    local dest=$_vfs_host rc
    local -a opts
    if ! command -v sftp > /dev/null 2>&1; then
        _vf_why='sftp not found'
        return 1
    fi
    case $1$_vfs_path in
        *'"'* | *\\*)
            _vf_why="cannot fetch a path containing \" or \\ over sftp"
            return 1
            ;;
    esac
    [ -n "$_vfs_user" ] && dest="$_vfs_user@$_vfs_host"
    opts=(-b batch -o BatchMode=yes -o StrictHostKeyChecking=yes -o "ConnectTimeout=$_vfs_secs" -P "$_vfs_port")
    [ -n "${VIGIL_TEST_SSH_CONFIG-}" ] && opts[${#opts[@]}]=-F && opts[${#opts[@]}]=$VIGIL_TEST_SSH_CONFIG
    printf 'get "%s" "%s"\n' "${_vfs_path%/}/$1" download > "$_vf_st/batch"
    rm -f "$_vf_st/download"
    (cd "$_vf_st" && _vigil_fetch_exec "$_vfs_secs" out err sftp "${opts[@]}" -- "$dest")
    rc=$?
    if [ "$rc" -eq 124 ]; then
        _vf_why="timed out after $_vfs_timeout"
        return 1
    elif [ "$rc" -ne 0 ] || [ ! -f "$_vf_st/download" ]; then
        _vigil_fetch_first "$_vf_st/err"
        _vf_why="sftp failed: ${_vf_line:-exit code $rc}"
        return 1
    fi
    mv -f "$_vf_st/download" "$2"
}

# Downloads file $1 of an https or sftp source into $2, at most $3 bytes.
_vigil_fetch_download() {
    rm -f "$2"
    if [ "$_vfs_type" = https ]; then
        _vigil_fetch_https "$1" "$2" "$3" || return 1
    else
        _vigil_fetch_sftp "$1" "$2" || return 1
    fi
    _vigil_fetch_size "$2"
    if [ "$_vf_size" -gt "$3" ]; then
        _vf_why="$1 is larger than $3 bytes"
        return 1
    fi
}

# Brings source $1 (its settings in _vfs_) up to date, once per run, when
# it is due: a git or local source, or the configuration file $2 of an
# https or sftp one. Sets _vf_entry, or returns 1 with _vf_why.
_vigil_fetch_sync() {
    local name=$1 i=0 sha
    while [ "$i" -lt "${#_vf_sn[@]}" ]; do
        if [ "${_vf_sn[$i]}" = "$name" ]; then
            _vf_entry=${_vf_se[$i]}
            _vf_why=${_vf_sw[$i]}
            [ -z "$_vf_why" ]
            return
        fi
        i=$((i + 1))
    done
    _vf_kind=""
    _vigil_fetch_state_read "$name"
    _vf_entry=$_vft_entry
    _vf_why=''
    if [ "$_vft_identity" != "$_vfs_identity" ] || [ -z "$_vft_entry" ] ||
        [ ! -d "$_vw_root/cache/$name/$_vft_entry" ] || [ $((_vft_checked + _vfs_every)) -le "$_vf_now" ]; then
        case $_vfs_type in
            git) _vigil_fetch_git "$name" ;;
            local) _vigil_fetch_local "$name" ;;
            *)
                if _vigil_fetch_download "$2" "$_vf_st/config" "$VIGIL_FETCH_CONFIG_MAX"; then
                    sha=$(_vigil_fetch_digest < "$_vf_st/config")
                    _vf_entry=$sha
                    mkdir -p "$_vw_root/cache/$name/$sha/$(dirname "$2")"
                    mv -f "$_vf_st/config" "$_vw_root/cache/$name/$sha/$2"
                else
                    false
                fi
                ;;
        esac
        if [ $? -eq 0 ]; then
            if [ "$_vf_kind" = branch ] && [ "$_vf_entry" != "$_vft_entry" ]; then
                _vigil_wk_log "$_vw_run run WARN source.$name: ref '$_vfs_ref' is a branch: its scripts follow it, and hosts may briefly differ (W_SCRIPT_UNPINNED)"
            fi
            _vft_identity=$_vfs_identity
            _vft_entry=$_vf_entry
            _vft_kind=$_vf_kind
            _vft_failures=0
            _vft_checked=$_vf_now
            _vft_ok=$_vf_now
            _vigil_fetch_state_write "$name" ''
        else
            _vft_failures=$((_vft_failures + 1))
            _vft_checked=$_vf_now
            _vigil_fetch_state_write "$name" "$_vf_why"
        fi
    fi
    _vigil_fetch_next "$name" "$_vft_checked" "$_vfs_every"
    _vf_sn[${#_vf_sn[@]}]=$name
    _vf_se[${#_vf_se[@]}]=$_vf_entry
    _vf_sw[${#_vf_sw[@]}]=$_vf_why
    [ -z "$_vf_why" ]
}

# The verified copy the active record has of file $2 of source $1 with
# digest $3, kept when the source's content no longer matches it.
_vigil_fetch_keep() {
    local i=0
    while [ "$i" -lt "${#VIGIL_ACT_SRC[@]}" ]; do
        if [ "${VIGIL_ACT_SRC[$i]}" = "$1" ] && [ "${VIGIL_ACT_FILE[$i]}" = "$2" ] &&
            [ "${VIGIL_ACT_SHA[$i]}" = "$3" ] && [ -f "$_vw_root/cache/$1/${VIGIL_ACT_ENTRY[$i]}/$2" ]; then
            _vf_entry=${VIGIL_ACT_ENTRY[$i]}
            _vf_sha=$3
            _vigil_wk_log "$_vw_run run WARN source.$1: $2 no longer matches its sha256; the last verified copy stays in use"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# One script reference: file $2 of source $1, with digest $3 if pinned.
# Sets _vf_entry and _vf_sha, or returns 1 with _vf_why.
_vigil_fetch_ref() {
    local src=$1 file=$2 want=$3 p
    _vigil_fetch_source "$src"
    case $_vfs_type in
        https | sftp)
            # Pinned by digest (6.9): a cached copy that verifies is final.
            p="$_vw_root/cache/$src/$want/$file"
            if [ -f "$p" ] && [ "$(_vigil_fetch_digest < "$p")" = "$want" ]; then
                _vf_entry=$want
                _vf_sha=$want
                return 0
            fi
            _vigil_fetch_download "$file" "$_vf_st/script" "$VIGIL_FETCH_SCRIPT_MAX" || return 1
            _vf_sha=$(_vigil_fetch_digest < "$_vf_st/script")
            if [ "$_vf_sha" != "$want" ]; then
                _vf_why="$file does not match its sha256"
                return 1
            fi
            mkdir -p "$(dirname "$p")"
            mv -f "$_vf_st/script" "$p"
            _vf_entry=$want
            ;;
        *)
            _vigil_fetch_sync "$src" || return 1
            p="$_vw_root/cache/$src/$_vf_entry/$file"
            if [ ! -f "$p" ]; then
                _vf_why="$file not found"
                return 1
            fi
            _vigil_fetch_size "$p"
            if [ "$_vf_size" -gt "$VIGIL_FETCH_SCRIPT_MAX" ]; then
                _vf_why="$file is larger than $VIGIL_FETCH_SCRIPT_MAX bytes"
                return 1
            fi
            _vf_sha=$(_vigil_fetch_digest < "$p")
            if [ -n "$want" ] && [ "$_vf_sha" != "$want" ]; then
                _vigil_fetch_keep "$src" "$file" "$want" && return 0
                _vf_why="$file does not match its sha256"
                return 1
            fi
            ;;
    esac
}

# Tags of the fetcher's events, from the parsed configuration.
_vigil_fetch_tags() {
    local i
    _vigil_wk_get vigil instance vigil
    _vf_tags="host=$_vw_host os=$_vw_os instance=$_vw_value"
    vigil_config_section tags
    [ "$VIGIL_CFG_SEC" -ge 0 ] || return 0
    i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
    while [ "$i" -lt $((VIGIL_CFG_SEC_FIRST[VIGIL_CFG_SEC] + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC])) ]; do
        _vf_tags="$_vf_tags ${VIGIL_CFG_KEY[$i]}=${VIGIL_CFG_VALUE[$i]}"
        i=$((i + 1))
    done
}

# Removes cache entries named by neither the active nor the previous record
# nor a source's current state, unless a run is in progress (16.5).
_vigil_fetch_gc() {
    local keep=' ' d e f line value
    for f in "$_vw_statedir"/locks/*.token "$_vw_statedir"/locks/*.launch; do
        [ -e "$f" ] || continue
        case ${f##*/} in vigil_fetch.* | vigil_sender.*) ;; *) return 0 ;; esac
    done
    for f in "$_vw_statedir/config.active" "$_vw_statedir/config.previous"; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            value=${line#*= }
            case $line in
                'config '*) keep="${keep}configs/$value.config " ;;
                'script '*)
                    e=${value#* }
                    keep="$keep${value%% *}/${e%% *} "
                    ;;
            esac
        done < "$f"
    done
    for f in "$_vw_statedir"/sources/*.state; do
        [ -f "$f" ] || continue
        e=${f##*/}
        while IFS= read -r line; do
            case $line in
                'entry '*)
                    value=${line#*= }
                    [ -n "$value" ] && keep="$keep${e%.state}/$value "
                    ;;
            esac
        done < "$f"
    done
    for d in "$_vw_root"/cache/*/* "$_vw_statedir"/configs/*.config; do
        [ -e "$d" ] || continue
        e=${d#"$_vw_root"/cache/}
        e=${e#"$_vw_statedir"/}
        case $e in staging/* | */repo.git) continue ;; esac
        case $keep in *" $e "*) continue ;; esac
        rm -rf "$d"
    done
}

vigil_fetch() {
    local cfile csrc origin cand sha i s name src file want body revision lines old line f
    local -a rsrc rfile rwant
    _vf_now=$(date '+%s')
    _vf_st="$_vw_root/cache/staging"
    rm -rf "$_vf_st"
    mkdir -p "$_vf_st" "$_vw_statedir/configs" || { _vw_reason="cannot write $_vf_st"; return 1; }
    _vf_events=() _vf_sn=() _vf_se=() _vf_sw=()
    _vf_failed='' _vf_failed_names='' _vf_next=''
    _vf_local=$(_vigil_fetch_digest < "$_vw_root/config/vigil.config")

    # Event tags come from the active configuration, else this file.
    if vigil_active_read "$_vw_statedir" && vigil_config_parse "$VIGIL_ACT_CONFIG"; then
        _vigil_fetch_tags
        vigil_config_parse "$_vw_root/config/vigil.config"
        vigil_config_validate
    else
        _vigil_fetch_tags
    fi

    # The candidate: the configuration from its source (6.8), or this file.
    _vigil_wk_get vigil config_source ''
    csrc=$_vw_value
    if [ -n "$csrc" ]; then
        _vigil_wk_get vigil config_file ''
        cfile=$_vw_value
        origin="source.$csrc $cfile"
        _vigil_fetch_source "$csrc"
        if ! _vigil_fetch_sync "$csrc" "$cfile"; then
            _vigil_fetch_failed "$csrc"
        elif [ ! -f "$_vw_root/cache/$csrc/$_vf_entry/$cfile" ]; then
            _vf_why="$cfile not found"
            _vigil_fetch_failed "$csrc"
        else
            cand="$_vw_root/cache/$csrc/$_vf_entry/$cfile"
            _vigil_fetch_size "$cand"
            if [ "$_vf_size" -gt "$VIGIL_FETCH_CONFIG_MAX" ]; then
                _vf_why="$cfile is larger than $VIGIL_FETCH_CONFIG_MAX bytes"
                _vigil_fetch_failed "$csrc"
            fi
        fi
    else
        origin=local
        cand="$_vw_root/config/vigil.config"
    fi

    if [ -z "$_vf_failed" ]; then
        sha=$(_vigil_fetch_digest < "$cand")
        if [ ! -f "$_vw_statedir/configs/$sha.config" ]; then
            cp "$cand" "$_vf_st/candidate" && mv -f "$_vf_st/candidate" "$_vw_statedir/configs/$sha.config"
        fi
        cand="$_vw_statedir/configs/$sha.config"
        vigil_config_parse "$cand"
        vigil_config_validate
        # Where configuration comes from, and where state is kept, are
        # decided on the host (6.8).
        if [ -n "$csrc" ]; then
            vigil_config_section vigil
            if [ "$VIGIL_CFG_SEC" -ge 0 ]; then
                i=${VIGIL_CFG_SEC_FIRST[$VIGIL_CFG_SEC]}
                while [ "$i" -lt $((VIGIL_CFG_SEC_FIRST[VIGIL_CFG_SEC] + VIGIL_CFG_SEC_COUNT[VIGIL_CFG_SEC])) ]; do
                    case ${VIGIL_CFG_KEY[$i]} in
                        config_source | config_file | state_dir)
                            _vigil_val_add ERROR '' "${VIGIL_CFG_LINE[$i]}" E_NOT_FROM_SOURCE "'${VIGIL_CFG_KEY[$i]}' cannot be set by a fetched configuration; it is set on the host"
                            ;;
                    esac
                    i=$((i + 1))
                done
            fi
        fi
        if _vigil_pc_rejected; then
            _vf_why="$cfile has errors"
            [ -n "$csrc" ] || _vf_why='the configuration has errors'
            while IFS= read -r line; do
                [ -n "$line" ] && _vigil_wk_log "$_vw_run run   $line"
            done <<EOF_REPORT
$(vigil_config_report)
EOF_REPORT
            if [ -n "$csrc" ]; then
                _vigil_fetch_failed "$csrc"
            else
                _vf_failed=$_vf_why
            fi
        fi
    fi

    if [ -z "$_vf_failed" ]; then
        # Every valid job's script, disabled jobs included (16.5), once each.
        rsrc=() rfile=() rwant=()
        s=0
        while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
            name=${VIGIL_CFG_SEC_NAME[$s]}
            s=$((s + 1))
            case $name in job.*) ;; *) continue ;; esac
            _vigil_pc_invalid "${name#job.}" && continue
            _vigil_wk_get "$name" source ''
            src=$_vw_value
            [ -n "$src" ] || continue
            _vigil_wk_get "$name" file ''
            file=$_vw_value
            _vigil_wk_get "$name" sha256 ''
            want=$(printf '%s' "$_vw_value" | tr ABCDEF abcdef)
            i=0
            while [ "$i" -lt "${#rsrc[@]}" ]; do
                [ "${rsrc[$i]}" = "$src" ] && [ "${rfile[$i]}" = "$file" ] && [ "${rwant[$i]}" = "$want" ] && continue 2
                i=$((i + 1))
            done
            rsrc[${#rsrc[@]}]=$src
            rfile[${#rfile[@]}]=$file
            rwant[${#rwant[@]}]=$want
        done
        lines="config $sha"$'\n'
        body=''
        i=0
        while [ "$i" -lt "${#rsrc[@]}" ]; do
            src=${rsrc[$i]}
            if _vigil_fetch_ref "$src" "${rfile[$i]}" "${rwant[$i]}"; then
                body="${body}script         = $src $_vf_entry $_vf_sha ${rfile[$i]}"$'\n'
                lines="${lines}script $src ${rfile[$i]} $_vf_sha"$'\n'
            else
                _vigil_fetch_failed "$src"
            fi
            i=$((i + 1))
        done
        # A source no job uses any more is still checked for the next
        # candidate.
        s=0
        while [ "$s" -lt "${#VIGIL_CFG_SEC_NAME[@]}" ]; do
            name=${VIGIL_CFG_SEC_NAME[$s]}
            s=$((s + 1))
            case $name in source.*) ;; *) continue ;; esac
            _vigil_fetch_source "${name#source.}"
            _vigil_fetch_next "${name#source.}" "$_vf_now" "$_vfs_every"
        done
    fi

    if [ -z "$_vf_failed" ]; then
        # The revision: the configuration and every script, by digest.
        revision=$(printf '%s' "$lines" | _vigil_fetch_digest)
        revision=${revision:0:12}
        body="[active]"$'\n'"schema_version = 1"$'\n'"revision       = $revision"$'\n'"config         = $sha"$'\n'"origin         = $origin"$'\n'"$body"
        old=''
        [ -f "$_vw_statedir/config.active" ] && old=$(grep -v '^activated_epoch' "$_vw_statedir/config.active")
        if [ "$old" != "${body%$'\n'}" ]; then
            [ -f "$_vw_statedir/config.active" ] && cp -f "$_vw_statedir/config.active" "$_vw_statedir/config.previous"
            printf '%sactivated_epoch = %s\n' "$body" "$_vf_now" > "$_vw_statedir/config.active.tmp.$$" &&
                mv -f "$_vw_statedir/config.active.tmp.$$" "$_vw_statedir/config.active"
            _vigil_wk_log "$_vw_run run configuration revision $revision activated ($origin)"
            _vf_events[${#_vf_events[@]}]="$_vf_now vigil.config.activated 1 count $_vf_tags revision=$revision"
        fi
        # Sources no longer named are forgotten, with their cache.
        for f in "$_vw_statedir"/sources/*.state; do
            [ -f "$f" ] || continue
            name=${f##*/}
            name=${name%.state}
            [ "$name" = "$csrc" ] && continue
            vigil_config_section "source.$name"
            [ "$VIGIL_CFG_SEC" -ge 0 ] && continue
            rm -f "$f"
            rm -rf "${_vw_root:?}/cache/$name"
        done
        _vigil_fetch_gc
    fi

    # When to come back: the earliest next check of any source used.
    [ -n "$_vf_next" ] || _vf_next=$((_vf_now + 300))
    printf 'next_epoch = %s\nlocal = %s\n' "$_vf_next" "$_vf_local" > "$_vw_statedir/fetch.next.tmp.$$" &&
        mv -f "$_vw_statedir/fetch.next.tmp.$$" "$_vw_statedir/fetch.next"
    if [ "${#_vf_events[@]}" -gt 0 ]; then
        mkdir -p "$_vw_spooldir/incoming"
        f="$_vw_spooldir/incoming/$_vf_now-vigil_fetch.events"
        printf '%s\n' "${_vf_events[@]}" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
    fi
    rm -rf "$_vf_st"
    if [ -n "$_vf_failed" ]; then
        _vw_reason=$_vf_failed
        return 1
    fi
    return 0
}
