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
# Vigil self-update - bash 3.2 compatible.
#
# vigil version and vigil self update (SPECIFICATION.md 18.7). An update is
# the installer of the release being installed, run with --upgrade: there is
# one path that replaces Vigil, and it verifies, swaps and goes back if the
# new version does not run. This only finds the release and starts it.
#
#   vigil_packaged <app dir>
#     Whether a package manager installed this program (app/PACKAGED): sets
#     _vp_manager, _vp_upgrade (its update command) and _vp_root.
#   vigil_version <app dir>
#     Prints "Vigil <version>", or says this is a copy from the repository.
#   vigil_about <root> <app dir>
#     What this is, who made it and where it runs.
#   vigil_self_update <root> <app dir> <check: 0|1> <version, or empty> [wait]
#     Returns 0, or 1 with the reason on stderr; nothing is changed then.
#     Without wait this process becomes the installer. With wait (the
#     vigil_update worker) the installer runs as a child and this returns
#     when it has finished. Either way _vu_kind says what went wrong: refused
#     (nothing to retry: ownership, signature, a repository copy), download
#     (the release could not be fetched: worth trying again) or install (the
#     installer ran and went back to what was installed).
#   vigil_config_version <root>
#     The release [vigil] version asks for, in _vu_want, its release_url, in
#     _vu_source, its release_path, in _vu_path, and its release_header_name
#     and release_header_value, in _vu_hname and _vu_hvalue: the active
#     configuration's when it is fetched, else the file's. Empty when unset.
#   vigil_release_source
#     Where releases come from, from _vu_source and _vu_path: _vu_base,
#     _vu_mirror (0 GitHub, 1 a release_url, 2 a release_path), _vu_from (how
#     messages name it), _vu_curl (curl's options) and _vu_hline (the
#     release_url's header, its secret resolved). Returns 1 with the reason
#     on stderr.
#   vigil_latest_version <base> <mirror: 0|1|2> <curl options...>
#     Prints the latest release's version.
#   vigil_release_get <base> <mirror> <path in the release tree> <out file> <curl options...>
#     Downloads, or for a release_path copies, one file of the releases.
#   vigil_update
#     The body of the vigil_update worker (18.11): moves this install to the
#     configuration's version and records the outcome in state/update.state.
#   vigil_supervisor_version <root>
#     Prints the version the supervisor last started as; returns 1 if none.
#   vigil_update_notice <root> <app dir>
#     Says on stderr when a newer release is known, at a terminal only. Reads
#     a per-user cache, and refreshes it in the background once a day, so it
#     never slows a command and a host with no way out never notices.
#   vigil_update_refresh <root>
#     That refresh, as a detached process.
#
# Linux and macOS only; SelfUpdate.ps1 is the Windows twin.

# Everything Vigil downloads about itself comes from here, unless [vigil]
# release_url or release_path names a copy of the releases of its own (18.7). Redirecting
# updates there gains nothing: whatever is downloaded must be signed by the
# release key installed here, and a release that is not newer is never taken
# as the latest.
VIGIL_RELEASES=https://github.com/godspeedhq/vigil

# app/PACKAGED is written by a package's build (18.6), never by Vigil: the
# package manager owns this program, so self update leaves it to that, and the
# root is elsewhere. Lines of key = value: manager, upgrade and root, and
# service when the package runs the service itself: how to start it.
vigil_packaged() {
    _vp_manager='' _vp_upgrade='' _vp_root='' _vp_service=''
    [ -f "$1/PACKAGED" ] || return 1
    _vp_manager=$(sed -n 's/^manager *= *//p' "$1/PACKAGED" | head -n 1 | sed 's/[[:space:]]*$//')
    _vp_upgrade=$(sed -n 's/^upgrade *= *//p' "$1/PACKAGED" | head -n 1 | sed 's/[[:space:]]*$//')
    _vp_root=$(sed -n 's/^root *= *//p' "$1/PACKAGED" | head -n 1 | sed 's/[[:space:]]*$//')
    _vp_service=$(sed -n 's/^service *= *//p' "$1/PACKAGED" | head -n 1 | sed 's/[[:space:]]*$//')
    [ -n "$_vp_manager" ] || _vp_manager='a package manager'
    [ -n "$_vp_upgrade" ] || _vp_upgrade='its package manager'
    return 0
}

# How this install is updated, into _vu_how: vigil self update, or the
# package manager's command.
_vigil_update_how() {
    if vigil_packaged "$1"; then _vu_how=$_vp_upgrade; else _vu_how='vigil self update'; fi
}

vigil_version() {
    if [ -f "$1/VERSION" ]; then
        printf 'Vigil %s\n' "$(cat "$1/VERSION")"
    else
        printf 'Vigil, from the repository (no release)\n'
    fi
}

vigil_about() {
    local os
    case $(uname -s) in
        Darwin) os=macOS ;;
        Linux) os=Linux ;;
        *) os=$(uname -s) ;;
    esac
    vigil_version "$2"
    printf 'A job scheduler, supervisor and metrics forwarder for Windows, Linux and macOS,\n'
    printf 'written only in the shells that ship with each one.\n\n'
    printf '%-11s %s\n' 'Created by' 'Bankole Ogundero and the Vigil contributors'
    printf '%-11s %s\n' Licence Apache-2.0
    printf '%-11s %s\n' Source "$VIGIL_RELEASES"
    vigil_config_version "$1"
    [ -z "$_vu_source$_vu_path" ] || printf '%-11s %s\n' Releases "$_vu_source$_vu_path"
    printf '%-11s %s\n' Docs https://godspeedhq.github.io/vigil/
    printf '%-11s %s\n' Installed "$1"
    if vigil_packaged "$2"; then
        printf '%-11s %s, by %s\n' Program "${2%/app}" "$_vp_manager"
    fi
    printf '%-11s %s, bash %s\n' Platform "$os" "${BASH_VERSION%%(*}"
}

# The SHA-256 of file $1, as 64 hex digits, on standard output.
_vigil_self_sha() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -c1-64
    else
        shasum -a 256 "$1" | cut -c1-64
    fi
}

# The version the running supervisor wrote when it started, which is not always
# what is on disk: after an upgrade the two differ until it has reloaded. The
# installer relies on this to know when a reload has happened.
vigil_supervisor_version() {
    local v=''
    _vw_root=$1
    vigil_config_parse "$1/config/vigil.config" 2>/dev/null
    _vigil_wk_dir vigil state_dir state
    [ -f "$_vw_dir/supervisor.version" ] && read -r v < "$_vw_dir/supervisor.version"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# Whether version $1 is newer than $2, comparing the numbers of x.y.z.
_vigil_self_newer() {
    local x=$1 y=$2 p q i=0
    while [ "$i" -lt 3 ]; do
        p=${x%%[.-]*}
        q=${y%%[.-]*}
        case $x in *[.-]*) x=${x#*[.-]} ;; *) x=0 ;; esac
        case $y in *[.-]*) y=${y#*[.-]} ;; *) y=0 ;; esac
        case $p$q in '' | *[!0-9]*) return 1 ;; esac
        # 10# forces base 10, or a part such as 08 is read as bad octal.
        p=$((10#$p))
        q=$((10#$q))
        [ "$p" -gt "$q" ] && return 0
        [ "$p" -lt "$q" ] && return 1
        i=$((i + 1))
    done
    return 1
}

# Per user and outside the install, because a read-only system install has to
# be able to show the notice too.
_vigil_update_cache() {
    _vu_cache=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/vigil/update-check
}

# Called on the way out of a command, so it must never fail one, block one or
# add to the output a script is reading: anything that is not a person at a
# terminal gets nothing. It only ever reads the cache, so it works offline.
vigil_update_notice() {
    local at=0 latest='' current
    [ -z "${VIGIL_NO_UPDATE_CHECK-}" ] || return 0
    [ -f "$2/VERSION" ] || return 0
    if [ -z "${VIGIL_TEST_RELEASE_URL-}" ]; then
        { [ -t 1 ] && [ -t 2 ] && [ -z "${CI-}" ]; } || return 0
    fi
    _vigil_update_cache
    [ -f "$_vu_cache" ] && read -r at latest < "$_vu_cache"
    current=$(cat "$2/VERSION")
    if [ -n "$latest" ] && _vigil_self_newer "$latest" "$current"; then
        _vigil_update_how "$2"
        printf '\nVigil %s is available (this is %s). To update: %s\n' "$latest" "$current" "$_vu_how" >&2
    fi
    case $at in '' | *[!0-9]*) at=0 ;; esac
    if [ $(($(date '+%s') - at)) -ge 86400 ]; then
        # Detached from the terminal, so closing it does not stop the check.
        ( trap '' HUP; exec "$BASH" "$2/vigil" --root "$1" self refresh-check ) < /dev/null > /dev/null 2>&1 &
    fi
    return 0
}

# Where releases come from (18.7). A release_url is https, or plain http to
# this machine only, as for a log destination: checked here too, since the
# configuration is read here without being validated.
vigil_release_source() {
    _vu_base=$VIGIL_RELEASES _vu_mirror=0 _vu_from=GitHub
    _vu_curl=(-q --proto =https --proto-redir =https)
    # Tests only (22.4.4): releases from a local server, never over the
    # network. It stands for GitHub, so a release_url still wins.
    if [ -n "${VIGIL_TEST_RELEASE_URL-}" ]; then
        case $VIGIL_TEST_RELEASE_URL in
            http://127.0.0.1:*)
                _vu_base=$VIGIL_TEST_RELEASE_URL
                _vu_curl=(-q --proto =http --proto-redir =http --noproxy '*')
                ;;
            *)
                printf 'vigil: VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>\n' >&2
                return 1
                ;;
        esac
    fi
    if [ -n "${_vu_denied-}" ]; then
        printf 'vigil: cannot read %s from this account, which says where releases come from: run this as the account that installed Vigil (sudo for a system install)\n' "$_vu_denied" >&2
        return 1
    fi
    if [ -n "${_vu_source-}" ] && [ -n "${_vu_path-}" ]; then
        printf "vigil: [vigil] sets both 'release_url' and 'release_path': use one\n" >&2
        return 1
    fi
    # A login for a release_url: a header, as for a source (6.9), whose value
    # is a secret reference resolved below. Only ever sent to a release_url.
    _vu_hline=''
    if [ -n "${_vu_hname-}${_vu_hvalue-}" ]; then
        if [ -z "${_vu_hname-}" ] || [ -z "${_vu_hvalue-}" ]; then
            printf "vigil: [vigil] needs both 'release_header_name' and 'release_header_value'\n" >&2
            return 1
        fi
        if [ -z "${_vu_source-}" ]; then
            printf "vigil: [vigil] sets 'release_header_name' without 'release_url': the header is sent only to a release_url\n" >&2
            return 1
        fi
        case $_vu_hname in
            *[!A-Za-z0-9-]*)
                printf "vigil: 'release_header_name' must be a header name (letters, digits and -): %s\n" "$_vu_hname" >&2
                return 1
                ;;
        esac
    fi
    # A folder: copied from, not downloaded. Absolute, so it does not depend
    # on where Vigil was started.
    if [ -n "${_vu_path-}" ]; then
        case $_vu_path in
            /*) ;;
            *)
                printf "vigil: 'release_path' must be an absolute path here: %s\n" "$_vu_path" >&2
                return 1
                ;;
        esac
        _vu_base=${_vu_path%/} _vu_mirror=2 _vu_from=${_vu_path%/}
        return 0
    fi
    [ -n "${_vu_source-}" ] || return 0
    _vu_base=${_vu_source%/} _vu_mirror=1 _vu_from=${_vu_source%/}
    case $_vu_base in
        https://*) _vu_curl=(-q --proto =https --proto-redir =https) ;;
        http://localhost | http://localhost[:/]* | http://127.0.0.1 | http://127.0.0.1[:/]* | 'http://[::1]' | 'http://[::1]'[:/]*)
            _vu_curl=(-q --proto =http --proto-redir =http --noproxy '*')
            ;;
        *)
            printf "vigil: 'release_url' must start with https://\n" >&2
            return 1
            ;;
    esac
    [ -n "${_vu_hname-}" ] || return 0
    # Resolved once, held in memory for this command only. A secret that
    # cannot be had now may be there later: worth trying again (18.11).
    if ! vigil_secret_resolve "$_vw_root" "$_vu_hvalue"; then
        _vu_kind=download
        printf 'vigil: release_header_value %s unavailable: %s\n' "$_vu_hvalue" "$VIGIL_SECRET_WHY" >&2
        return 1
    fi
    case $VIGIL_SECRET_VALUE in
        *[[:cntrl:]]*)
            VIGIL_SECRET_VALUE=''
            printf 'vigil: release_header_value %s holds a control character\n' "$_vu_hvalue" >&2
            return 1
            ;;
    esac
    _vu_hline="$_vu_hname: $VIGIL_SECRET_VALUE"
    VIGIL_SECRET_VALUE=''
    # No redirect is followed while there is a header: curl would send it to
    # whatever host a redirect names.
    _vu_curl[${#_vu_curl[@]}]=--max-redirs
    _vu_curl[${#_vu_curl[@]}]=0
}

# The latest release's version, printed. From a release_url or a
# release_path, the one line of <base>/releases/latest/VERSION. From GitHub, where it redirects
# /releases/latest, or the GitHub API when that page fails (it has answered
# 504 for half an hour while the downloads worked). The redirect comes first:
# the API allows an address 60 requests an hour, too few for a fleet behind
# one. Tests serve the API's answer at <base>/api/releases/latest.
vigil_latest_version() {
    local base=$1 mirror=$2 api tag
    shift 2
    if [ "$mirror" != 0 ]; then
        if [ "$mirror" = 2 ]; then
            tag=$(head -n 1 "$base/releases/latest/VERSION" 2> /dev/null | tr -d '[:space:]')
        else
            tag=$(_vigil_release_curl "$@" -fsSL "$base/releases/latest/VERSION" 2> /dev/null | head -n 1 | tr -d '[:space:]')
        fi
        case $tag in '' | *[!0-9A-Za-z.-]*) return 1 ;; esac
        printf '%s\n' "${tag#v}"
        return 0
    fi
    if tag=$(curl "$@" -fsSLI -o /dev/null -w '%{url_effective}' "$base/releases/latest" 2> /dev/null); then
        tag=${tag##*/v}
        case $tag in '' | */*) ;; *) printf '%s\n' "$tag"; return 0 ;; esac
    fi
    case $base in
        https://github.com/*) api=https://api.github.com/repos/${base#https://github.com/}/releases/latest ;;
        *) api=$base/api/releases/latest ;;
    esac
    tag=$(curl "$@" -fsSL -H 'Accept: application/vnd.github+json' "$api" 2> /dev/null |
        grep -o '"tag_name": *"v[^"/]*"' | sed -n '1s/.*"v\([^"]*\)"$/\1/p')
    [ -n "$tag" ] || return 1
    printf '%s\n' "$tag"
}

# One file of the releases, <rel> under <base>, into <out>: copied from a
# release_path, downloaded otherwise. Returns 1 when it is not there.
vigil_release_get() {
    local base=$1 mirror=$2 rel=$3 out=$4
    shift 4
    if [ "$mirror" = 2 ]; then
        [ -f "$base/$rel" ] && cp "$base/$rel" "$out" 2> /dev/null
        return
    fi
    _vigil_release_curl "$@" -fsSL -o "$out" "$base/$rel"
}

# curl, with the release_url's header when there is one. The header goes on
# stdin (curl -K -), so it is never on a command line.
_vigil_release_curl() {
    if [ -n "${_vu_hline-}" ]; then
        _vigil_curl_opt header "$_vu_hline" | curl "$@" -K -
    else
        curl "$@"
    fi
}

# Why a release_url refused <path in the release tree>, when the answer was
# about the login or a redirect; nothing otherwise. Asked again, only after
# a failure, since curl -f does not say why.
_vigil_release_refused() {
    local status
    [ "$_vu_mirror" = 1 ] || return 0
    status=$(_vigil_release_curl "${_vu_curl[@]}" --max-time 10 -sS -o /dev/null -w '%{http_code}' "$_vu_base/$1" 2> /dev/null)
    case $status in
        401 | 403)
            if [ -n "${_vu_hline-}" ]; then
                printf '%s refused the login (HTTP %s): check release_header_value' "$_vu_from" "$status"
            else
                printf '%s asks for a login (HTTP %s): set release_header_name and release_header_value' "$_vu_from" "$status"
            fi
            ;;
        3??)
            [ -z "${_vu_hline-}" ] ||
                printf '%s redirected the request (HTTP %s): Vigil follows no redirect while release_header_name is set' "$_vu_from" "$status"
            ;;
    esac
}

# How a source whose latest release could not be found is named. For a
# release_path, with the account, since a share the service's account cannot
# read is the usual reason.
_vigil_release_unreadable() {
    local why
    if [ "$_vu_mirror" = 2 ]; then
        printf 'cannot read the latest release from %s (as %s): is it there, and readable by this account?' "$_vu_from" "$(id -un 2> /dev/null || echo this account)"
        return
    fi
    why=$(_vigil_release_refused releases/latest/VERSION)
    if [ -n "$why" ]; then
        printf 'cannot read the latest release: %s' "$why"
    else
        printf 'cannot reach %s to find the latest release' "$_vu_from"
    fi
}

vigil_update_refresh() {
    local at latest='' tag
    vigil_config_version "$1"
    _vigil_update_cache
    mkdir -p "${_vu_cache%/*}" 2>/dev/null || return 0
    [ -f "$_vu_cache" ] && read -r at latest < "$_vu_cache"
    # A source that cannot be used (a secret this account cannot read, say)
    # counts as no answer.
    if vigil_release_source 2> /dev/null && { [ "$_vu_mirror" = 2 ] || command -v curl > /dev/null 2>&1; } && tag=$(vigil_latest_version "$_vu_base" "$_vu_mirror" "${_vu_curl[@]}" --max-time 10); then
        latest=$tag
    fi
    # Written whether or not it worked: a host with no way out tries once a
    # day, not on every command.
    printf '%s %s\n' "$(date '+%s')" "$latest" > "$_vu_cache.tmp.$$" && mv -f "$_vu_cache.tmp.$$" "$_vu_cache"
}

_vigil_self_die() {
    printf 'vigil: %s\n' "$*" >&2
    return 1
}

# The order matters: everything that can be refused is refused before anything
# is downloaded, and everything downloaded is verified before anything runs.
# This function never changes the install itself. pinned remembers that a
# version was asked for, since want is filled in with the latest one below.
# The caller sets _vu_source and _vu_path, the release_url and release_path
# (vigil_config_version).
vigil_self_update() {
    local root=$1 app=$2 check=$3 want=$4 pinned=$4 wait=${5-} base current tag work sum got file f key rc why
    local -a curlopts
    _vu_kind=refused
    # Root reads the configuration itself through the --update-by rule (18.7),
    # and with it where releases come from.
    if [ -n "${_vu_denied-}" ] && [ "$check" = 0 ] && [ -z "$pinned" ] && [ ! -O "$app" ] &&
        command -v sudo > /dev/null 2>&1 && sudo -n -l "$app/vigil" self update > /dev/null 2>&1; then
        exec sudo -n "$app/vigil" self update
    fi
    vigil_release_source || return 1
    base=$_vu_base
    curlopts=("${_vu_curl[@]}" --max-time 60)
    if [ ! -f "$app/VERSION" ]; then
        _vigil_self_die 'this copy comes from the repository, not a release: update it with git'
        return 1
    fi
    current=$(cat "$app/VERSION")
    # A package manager's program is its to replace: refused before anything is
    # downloaded. --check still says what is available.
    if [ "$check" = 0 ] && vigil_packaged "$app"; then
        _vigil_self_die "Vigil was installed by $_vp_manager: update it with $_vp_upgrade"
        return 1
    fi
    [ "$_vu_mirror" = 2 ] || command -v curl > /dev/null 2>&1 || { _vigil_self_die 'curl not found'; return 1; }

    if [ -z "$want" ]; then
        want=$(vigil_latest_version "$base" "$_vu_mirror" "${curlopts[@]}") ||
            { _vu_kind=download; _vigil_self_die "$(_vigil_release_unreadable)"; return 1; }
        # The latest is never older than what runs here: a source that names
        # an older release cannot move this back. Going back is asked for by
        # number (--version, or the configuration's version).
        if _vigil_self_newer "$current" "$want"; then
            printf 'Vigil %s is installed, newer than the latest release from %s (%s): nothing to do\n' "$current" "$_vu_from" "$want"
            return 0
        fi
    fi
    if [ "$want" = "$current" ]; then
        printf 'Vigil %s is installed: nothing to do\n' "$current"
        return 0
    fi
    if [ "$check" = 1 ]; then
        _vigil_update_how "$app"
        printf 'Vigil %s is installed; %s is available: %s\n' "$current" "$want" "$_vu_how"
        return 0
    fi

    # Whoever installed it updates it: the installer leaves app/ owned as a
    # system install needs it, so a user's own must not go through root.
    # Refused rather than attempted, so a failed update cannot leave a partial one.
    if [ ! -O "$app" ]; then
        # A sudo rule from install --update-by (18.7) allows two commands: the
        # latest release, or the release the configuration asks for, which
        # root reads from the configuration itself (18.11).
        if [ -z "$pinned" ] && command -v sudo > /dev/null 2>&1 && sudo -n -l "$app/vigil" self update > /dev/null 2>&1; then
            # sudo checks the rule again here. -n means it fails rather than prompts.
            exec sudo -n "$app/vigil" self update
        fi
        if [ -n "$wait" ] && command -v sudo > /dev/null 2>&1 && sudo -n -l "$app/vigil" self update --from-config > /dev/null 2>&1; then
            sudo -n "$app/vigil" self update --from-config
            rc=$?
            case $rc in
                0) return 0 ;;
                2) _vu_kind=download ;;
                3) _vu_kind=install ;;
            esac
            return 1
        fi
        _vigil_self_die "$root was installed by another account: run this as that account (sudo for a system install)"
        return 1
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-update.XXXXXX") || { _vigil_self_die 'cannot make a temporary folder'; return 1; }
    file=vigil-$want.tar.gz
    for f in install.sh "$file" SHA256SUMS; do
        if ! vigil_release_get "$base" "$_vu_mirror" "releases/download/v$want/$f" "$work/$f" "${curlopts[@]}"; then
            rm -rf "$work"
            _vu_kind=download
            why=$(_vigil_release_refused "releases/download/v$want/$f")
            if [ -n "$why" ]; then
                _vigil_self_die "cannot download Vigil $want: $why"
            elif [ "$_vu_mirror" = 2 ]; then
                # A folder names itself and the account, as for the latest (45).
                _vigil_self_die "cannot read Vigil $want from $_vu_from (as $(id -un 2> /dev/null || echo this account)): is it there, and readable by this account?"
            else
                _vigil_self_die "cannot download Vigil $want: is there such a release?"
            fi
            return 1
        fi
    done
    # The signature (17): whatever else was replaced on the server, the key
    # that checks it is the one already installed here. The archive is
    # handed to the installer, so what is verified is what is installed.
    key=$app/release-key.pem
    [ -n "${VIGIL_TEST_RELEASE_URL-}" ] && [ -n "${VIGIL_TEST_RELEASE_KEY-}" ] && key=$VIGIL_TEST_RELEASE_KEY
    # No key means nothing to check with, and that is refused like a bad
    # signature: every release since 0.2.1 carries the key, so a missing one
    # means this install has been changed.
    if [ ! -f "$key" ]; then
        rm -rf "$work"
        _vigil_self_die "the release key $key is missing: Vigil $want cannot be verified; nothing was changed"
        return 1
    fi
    if ! command -v openssl > /dev/null 2>&1; then
        rm -rf "$work"
        _vigil_self_die 'openssl not found: the release cannot be verified; nothing was changed'
        return 1
    fi
    if ! vigil_release_get "$base" "$_vu_mirror" "releases/download/v$want/SHA256SUMS.sig" "$work/SHA256SUMS.sig" "${curlopts[@]}" ||
        ! openssl dgst -sha256 -verify "$key" -signature "$work/SHA256SUMS.sig" "$work/SHA256SUMS" > /dev/null 2>&1; then
        rm -rf "$work"
        _vigil_self_die "Vigil $want is not signed by the Vigil release key; nothing was changed"
        return 1
    fi
    # SHA256SUMS is what the signature covers, so this is what ties the installer
    # to the signature. The installer checks the archive against the same file.
    sum=$(awk '$2 == "install.sh" || $2 == "*install.sh" { print $1 }' "$work/SHA256SUMS")
    got=$(_vigil_self_sha "$work/install.sh")
    if [ -z "$sum" ] || [ "$got" != "$sum" ]; then
        rm -rf "$work"
        _vigil_self_die "the installer of $want does not match its SHA256SUMS; nothing was changed"
        return 1
    fi
    printf 'updating Vigil %s to %s\n' "$current" "$want"
    if [ -n "$wait" ]; then
        # The worker stays, to record how it went. It runs from memory, so app/
        # moving under it does not matter.
        sh "$work/install.sh" --upgrade --reload --prefix "$root" --archive "$work/$file"
        rc=$?
        rm -rf "$work"
        [ "$rc" -eq 0 ] && return 0
        _vu_kind=install
        return 1
    fi
    # This process goes: its own file is about to be moved.
    # shellcheck disable=SC2016
    exec sh -c 'sh "$1/install.sh" --upgrade --prefix "$2" --archive "$1/$3"; rc=$?; rm -rf "$1"; exit "$rc"' sh "$work" "$root" "$file"
}

vigil_config_version() {
    _vu_want='' _vu_source='' _vu_path='' _vu_hname='' _vu_hvalue='' _vu_denied=''
    _vw_root=$1
    if ! vigil_config_parse "$1/config/vigil.config" 2> /dev/null; then
        # One this account may not read may name a copy of the releases: GitHub
        # is not the answer then (45).
        _vu_denied=$(vigil_denied "$1/config/vigil.config")
        return 0
    fi
    if vigil_fetch_mode; then
        _vigil_wk_dir vigil state_dir state
        vigil_active_read "$_vw_dir" && vigil_config_parse "$VIGIL_ACT_CONFIG" 2> /dev/null || return 0
    fi
    _vigil_wk_get vigil version ''
    _vu_want=$_vw_value
    _vigil_wk_get vigil release_url ''
    _vu_source=$_vw_value
    _vigil_wk_get vigil release_path ''
    _vu_path=$_vw_value
    _vigil_wk_get vigil release_header_name ''
    _vu_hname=$_vw_value
    _vigil_wk_get vigil release_header_value ''
    _vu_hvalue=$_vw_value
}

# How long a release that could not be downloaded waits before it is tried
# again (18.11). One that installed and failed is not tried again until the
# configuration names another.
VIGIL_UPDATE_RETRY=300

vigil_update() {
    local want current='' out result line reason=''
    _vigil_wk_get vigil version ''
    want=$_vw_value
    if [ -z "$want" ]; then
        _vw_reason='the configuration names no version'
        return 1
    fi
    [ -f "$app/VERSION" ] && read -r current < "$app/VERSION"
    _vigil_wk_get vigil release_url ''
    _vu_source=$_vw_value
    _vigil_wk_get vigil release_path ''
    _vu_path=$_vw_value
    _vigil_wk_get vigil release_header_name ''
    _vu_hname=$_vw_value
    _vigil_wk_get vigil release_header_value ''
    _vu_hvalue=$_vw_value
    out="$_vw_statedir/update.out.$$"
    vigil_self_update "$_vw_root" "$app" 0 "$want" wait > "$out" 2>&1
    if [ "$?" -eq 0 ]; then
        result=succeeded
    elif [ "$_vu_kind" = download ]; then
        result=unavailable
    else
        result=failed
    fi
    _vigil_wk_now
    # Everything the update and its installer said, in the worker's log.
    while IFS= read -r line || [ -n "$line" ]; do
        _vigil_wk_log "${_vw_run-} out $line"
        case $line in
            '') ;;
            *) reason=${line#vigil: } ;;
        esac
    done < "$out"
    rm -f "$out"
    {
        printf '[update]\n'
        printf 'version = %s\n' "$want"
        printf 'from    = %s\n' "$current"
        printf 'result  = %s\n' "$result"
        printf 'epoch   = %s\n' "$(date '+%s')"
        printf 'reason  = %s\n' "$reason"
    } > "$_vw_statedir/update.state.tmp.$$" && mv -f "$_vw_statedir/update.state.tmp.$$" "$_vw_statedir/update.state"
    [ "$result" = succeeded ] && return 0
    _vw_reason=$reason
    return 1
}
