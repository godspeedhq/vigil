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
#     The release [vigil] version asks for, in _vu_want: the active
#     configuration's when it is fetched, else the file's. Empty when unset.
#   vigil_update
#     The body of the vigil_update worker (18.11): moves this install to the
#     configuration's version and records the outcome in state/update.state.
#   vigil_supervisor_version <root>
#     Prints the version the supervisor last started as; returns 1 if none.
#   vigil_update_notice <root> <app dir>
#     Says on stderr when a newer release is known, at a terminal only. Reads
#     a per-user cache, and refreshes it in the background once a day, so it
#     never slows a command and a host with no way out never notices.
#   vigil_update_refresh <app dir>
#     That refresh, as a detached process.
#
# Linux and macOS only; SelfUpdate.ps1 is the Windows twin.

# Everything Vigil downloads about itself comes from here. There is no setting
# to change it: an address in the configuration would be a way to redirect
# updates.
VIGIL_RELEASES=https://github.com/godspeedhq/vigil

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
    printf '%-11s %s\n' Docs https://godspeedhq.github.io/vigil/
    printf '%-11s %s\n' Installed "$1"
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
        printf '\nVigil %s is available (this is %s). To update: vigil self update\n' "$latest" "$current" >&2
    fi
    case $at in '' | *[!0-9]*) at=0 ;; esac
    if [ $(($(date '+%s') - at)) -ge 86400 ]; then
        # Detached from the terminal, so closing it does not stop the check.
        ( trap '' HUP; exec "$BASH" "$2/vigil" self refresh-check ) < /dev/null > /dev/null 2>&1 &
    fi
    return 0
}

# Asks only where /releases/latest redirects to. The GitHub API would be
# limited to 60 requests an hour per address, too few for a fleet behind one.
vigil_update_refresh() {
    local at latest='' tag base=$VIGIL_RELEASES
    local -a opts
    opts=(-q --proto =https --proto-redir =https --max-time 10)
    if [ -n "${VIGIL_TEST_RELEASE_URL-}" ]; then
        base=$VIGIL_TEST_RELEASE_URL
        opts=(-q --proto =http --proto-redir =http --noproxy '*' --max-time 10)
    fi
    _vigil_update_cache
    mkdir -p "${_vu_cache%/*}" 2>/dev/null || return 0
    [ -f "$_vu_cache" ] && read -r at latest < "$_vu_cache"
    if command -v curl > /dev/null 2>&1 && tag=$(curl "${opts[@]}" -fsSLI -o /dev/null -w '%{url_effective}' "$base/releases/latest" 2>/dev/null); then
        case ${tag##*/v} in '' | */*) ;; *) latest=${tag##*/v} ;; esac
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
vigil_self_update() {
    local root=$1 app=$2 check=$3 want=$4 pinned=$4 wait=${5-} base=$VIGIL_RELEASES current tag work sum got file f key rc
    local -a curlopts
    _vu_kind=refused
    curlopts=(-q --proto =https --proto-redir =https --max-time 60)
    # Tests only (22.4.4): releases from a local server, never over the
    # network.
    if [ -n "${VIGIL_TEST_RELEASE_URL-}" ]; then
        case $VIGIL_TEST_RELEASE_URL in
            http://127.0.0.1:*)
                base=$VIGIL_TEST_RELEASE_URL
                curlopts=(-q --proto =http --proto-redir =http --noproxy '*' --max-time 60)
                ;;
            *)
                _vigil_self_die 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>'
                return 1
                ;;
        esac
    fi
    if [ ! -f "$app/VERSION" ]; then
        _vigil_self_die 'this copy comes from the repository, not a release: update it with git'
        return 1
    fi
    current=$(cat "$app/VERSION")
    command -v curl > /dev/null 2>&1 || { _vigil_self_die 'curl not found'; return 1; }

    if [ -z "$want" ]; then
        # The latest release, from where GitHub redirects /releases/latest.
        tag=$(curl "${curlopts[@]}" -fsSLI -o /dev/null -w '%{url_effective}' "$base/releases/latest") ||
            { _vu_kind=download; _vigil_self_die 'cannot reach GitHub to find the latest release'; return 1; }
        want=${tag##*/v}
        case $want in
            '' | */*)
                _vigil_self_die "cannot tell the latest release from $tag"
                return 1
                ;;
        esac
    fi
    if [ "$want" = "$current" ]; then
        printf 'Vigil %s is installed: nothing to do\n' "$current"
        return 0
    fi
    if [ "$check" = 1 ]; then
        printf 'Vigil %s is installed; %s is available: vigil self update\n' "$current" "$want"
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
        if ! curl "${curlopts[@]}" -fsSL -o "$work/$f" "$base/releases/download/v$want/$f"; then
            rm -rf "$work"
            _vu_kind=download
            _vigil_self_die "cannot download Vigil $want: is there such a release?"
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
    if ! curl "${curlopts[@]}" -fsSL -o "$work/SHA256SUMS.sig" "$base/releases/download/v$want/SHA256SUMS.sig" ||
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
    _vu_want=''
    _vw_root=$1
    vigil_config_parse "$1/config/vigil.config" 2> /dev/null || return 0
    if vigil_fetch_mode; then
        _vigil_wk_dir vigil state_dir state
        vigil_active_read "$_vw_dir" && vigil_config_parse "$VIGIL_ACT_CONFIG" 2> /dev/null || return 0
    fi
    _vigil_wk_get vigil version ''
    _vu_want=$_vw_value
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
