# shellcheck shell=bash
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
#   vigil_self_update <root> <app dir> <check: 0|1> <version, or empty>
#     Returns 0, or 1 with the reason on stderr; nothing is changed then.
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

VIGIL_RELEASES=https://github.com/godspeedhq/vigil

vigil_version() {
    if [ -f "$1/VERSION" ]; then
        printf 'Vigil %s\n' "$(cat "$1/VERSION")"
    else
        printf 'Vigil, from the repository (no release)\n'
    fi
}

# The SHA-256 of file $1, as 64 hex digits, on standard output.
_vigil_self_sha() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -c1-64
    else
        shasum -a 256 "$1" | cut -c1-64
    fi
}

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
    local IFS=.- a b i=0
    set -f
    # shellcheck disable=SC2206
    a=($1)
    # shellcheck disable=SC2206
    b=($2)
    set +f
    while [ "$i" -lt 3 ]; do
        case ${a[$i]-0}${b[$i]-0} in *[!0-9]*) return 1 ;; esac
        [ "$((10#${a[$i]-0}))" -gt "$((10#${b[$i]-0}))" ] && return 0
        [ "$((10#${a[$i]-0}))" -lt "$((10#${b[$i]-0}))" ] && return 1
        i=$((i + 1))
    done
    return 1
}

_vigil_update_cache() {
    _vu_cache=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/vigil/update-check
}

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
        ( trap '' HUP; exec "$BASH" "$2/vigil" self refresh-check ) < /dev/null > /dev/null 2>&1 &
    fi
    return 0
}

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

vigil_self_update() {
    local root=$1 app=$2 check=$3 want=$4 base=$VIGIL_RELEASES current tag work sum got
    local -a curlopts
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
            { _vigil_self_die 'cannot reach GitHub to find the latest release'; return 1; }
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
    if [ ! -O "$app" ]; then
        _vigil_self_die "$root was installed by another account: run this as that account (sudo for a system install)"
        return 1
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-update.XXXXXX") || { _vigil_self_die 'cannot make a temporary folder'; return 1; }
    if ! curl "${curlopts[@]}" -fsSL -o "$work/install.sh" "$base/releases/download/v$want/install.sh" ||
        ! curl "${curlopts[@]}" -fsSL -o "$work/SHA256SUMS" "$base/releases/download/v$want/SHA256SUMS"; then
        rm -rf "$work"
        _vigil_self_die "cannot download Vigil $want: is there such a release?"
        return 1
    fi
    sum=$(awk '$2 == "install.sh" || $2 == "*install.sh" { print $1 }' "$work/SHA256SUMS")
    got=$(_vigil_self_sha "$work/install.sh")
    if [ -z "$sum" ] || [ "$got" != "$sum" ]; then
        rm -rf "$work"
        _vigil_self_die "the installer of $want does not match its SHA256SUMS; nothing was changed"
        return 1
    fi
    printf 'updating Vigil %s to %s\n' "$current" "$want"
    # This process goes: its own file is about to be moved.
    # shellcheck disable=SC2016
    exec sh -c 'sh "$1/install.sh" --upgrade --prefix "$2" --version "$3"; rc=$?; rm -rf "$1"; exit "$rc"' sh "$work" "$root" "$want"
}
