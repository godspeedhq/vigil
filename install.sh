#!/bin/sh
#
# install.sh - installs or upgrades Vigil on Linux and macOS
# (SPECIFICATION.md 18.7). POSIX sh, so it runs as
#
#   curl -fsSL https://github.com/godspeedhq/vigil/releases/latest/download/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --system --backend datadog
#
# or, the reviewed way: download the release archive and SHA256SUMS,
# check them, read this file, and run it with --archive.
#
# Options:
#   --user | --system      the install mode (default: system as root, user
#                          otherwise): ~/.local/share/vigil or /opt/vigil
#   --prefix <dir>         another install root
#   --version <version>    a release (default: the latest)
#   --archive <file>       install this vigil-<version>.tar.gz instead of
#                          downloading it; SHA256SUMS must be beside it
#   --account <name>       system mode: the service account
#   --instance <name>      passed to vigil init
#   --backend <list>       passed to vigil init (file, datadog, otel)
#   --no-init              do not write a starting configuration
#   --no-service           do not register the service
#   --upgrade              only replace an installed Vigil, as vigil self
#                          update does: no vigil init, no link, and the
#                          service is left as it was found
#
# Steps: check the prerequisites, download the archive and verify its
# SHA-256 before using it, unpack it into the root (on upgrade only app/ is
# replaced; config/ and scripts/ are never touched), link the vigil
# command, run vigil init on a fresh install, register the service.

set -u

repo_url=https://github.com/godspeedhq/vigil
mode=''
prefix=''
version=''
archive=''
account=''
instance=''
backend=''
do_init=1
do_service=1
only_upgrade=0

say() { printf '%s\n' "$*"; }
die() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --user) mode=user ;;
        --system) mode=system ;;
        --no-init) do_init=0 ;;
        --no-service) do_service=0 ;;
        --upgrade)
            only_upgrade=1
            do_init=0
            ;;
        --prefix | --version | --archive | --account | --instance | --backend)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            case $1 in
                --prefix) prefix=$2 ;;
                --version) version=${2#v} ;;
                --archive) archive=$2 ;;
                --account) account=$2 ;;
                --instance) instance=$2 ;;
                --backend) backend=$2 ;;
            esac
            shift
            ;;
        -h | --help)
            sed -n '2,/^$/s/^# \{0,1\}//p' "$0" 2> /dev/null || say "see $repo_url"
            exit 0
            ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

# Tests only (22.4.4): releases from a local server, never over the network.
curl_proto="--proto =https --proto-redir =https"
if [ -n "${VIGIL_TEST_RELEASE_URL-}" ]; then
    case $VIGIL_TEST_RELEASE_URL in
        http://127.0.0.1:*)
            repo_url=$VIGIL_TEST_RELEASE_URL
            curl_proto="--proto =http --proto-redir =http --noproxy *"
            ;;
        *) die 'VIGIL_TEST_RELEASE_URL must be http://127.0.0.1:<port>' ;;
    esac
fi

uid=$(id -u)
if [ -z "$mode" ]; then
    if [ "$uid" -eq 0 ]; then mode=system; else mode=user; fi
fi
[ "$mode" = system ] && [ "$uid" -ne 0 ] && die 'system mode needs root: run it with sudo, or use --user'
[ "$mode" = user ] && [ "$uid" -eq 0 ] && die 'user mode installs for the account that runs it, not root: use --system'
if [ -n "$prefix" ]; then
    root=$prefix
elif [ "$mode" = system ]; then
    root=/opt/vigil
else
    root=$HOME/.local/share/vigil
fi
case $root in
    /*) ;;
    *) root=$(pwd)/$root ;;
esac

# --- 1. Prerequisites (5.1), before anything changes ---------------------

missing=''
for t in bash tar gzip; do
    command -v "$t" > /dev/null 2>&1 || missing="$missing $t"
done
if command -v sha256sum > /dev/null 2>&1; then
    sha='sha256sum'
elif command -v shasum > /dev/null 2>&1; then
    sha='shasum -a 256'
else
    missing="$missing sha256sum"
fi
[ -n "$archive" ] || command -v curl > /dev/null 2>&1 || missing="$missing curl"
if [ "$do_service" = 1 ] && [ "$only_upgrade" = 0 ]; then
    case $(uname -s) in
        Linux) command -v systemctl > /dev/null 2>&1 || missing="$missing systemd" ;;
        Darwin) ;;
        *) die "Vigil runs on Linux and macOS here; on Windows use install.ps1" ;;
    esac
fi
[ -z "$missing" ] || die "missing prerequisites:$missing"

# --- 2. The archive, verified ----------------------------------------------

work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-install.XXXXXX") || die 'cannot make a temporary folder'
trap 'rm -rf "$work"' EXIT

if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "no archive at $archive"
    dir=$(cd "$(dirname "$archive")" && pwd)
    file=$(basename "$archive")
    [ -f "$dir/SHA256SUMS" ] || die "no SHA256SUMS beside $archive: the archive cannot be verified"
    cp "$dir/$file" "$work/$file" && cp "$dir/SHA256SUMS" "$work/SHA256SUMS" || die 'cannot copy the archive'
else
    if [ -z "$version" ]; then
        # The latest release, from where GitHub redirects /releases/latest.
        set -f
        # shellcheck disable=SC2086
        tag=$(curl $curl_proto -fsSLI -o /dev/null -w '%{url_effective}' "$repo_url/releases/latest") || die 'cannot reach GitHub to find the latest release'
        set +f
        version=${tag##*/v}
        case $version in '' | */*) die "cannot tell the latest release from $tag" ;; esac
    fi
    file=vigil-$version.tar.gz
    say "downloading Vigil $version"
    set -f
    # shellcheck disable=SC2086
    curl $curl_proto -fsSL -o "$work/$file" "$repo_url/releases/download/v$version/$file" || die "cannot download $file"
    # shellcheck disable=SC2086
    curl $curl_proto -fsSL -o "$work/SHA256SUMS" "$repo_url/releases/download/v$version/SHA256SUMS" || die 'cannot download SHA256SUMS'
    set +f
fi
want=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
[ -n "$want" ] || die "SHA256SUMS has no entry for $file"
got=$(cd "$work" && $sha "$file" | awk '{ print $1 }')
[ "$got" = "$want" ] || die "SHA-256 mismatch for $file: expected $want, got $got; nothing was changed"
say "verified $file (SHA-256 $got)"

mkdir "$work/x" && tar -xzf "$work/$file" -C "$work/x" || die "cannot unpack $file"
src=$(find "$work/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -f "$src/app/vigil" ] || die "$file does not hold a Vigil release"
version=$(cat "$src/app/VERSION" 2> /dev/null || printf '%s' "${version:-unknown}")

# --- 3. Unpack into the root -------------------------------------------------

upgrade=0
[ -f "$root/app/vigil" ] && upgrade=1
[ "$only_upgrade" = 0 ] || [ "$upgrade" = 1 ] || die "no Vigil in $root to upgrade"
mkdir -p "$root" || die "cannot create $root"
# Copied before anything is stopped: a full disk changes nothing.
rm -rf "$root/app.new" "$root/app.old"
cp -R "$src/app" "$root/app.new" || { rm -rf "$root/app.new"; die "cannot copy into $root; nothing was changed"; }
chmod 755 "$root/app.new/vigil"
running=0
if [ "$upgrade" = 1 ] && [ "$do_service" = 1 ] &&
    bash "$root/app/vigil" --root "$root" status 2> /dev/null | head -n 1 | grep -q '^service: active'; then
    running=1
    bash "$root/app/vigil" --root "$root" stop > /dev/null || { rm -rf "$root/app.new"; die 'cannot stop the running service for the upgrade; nothing was changed'; }
fi
vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
# Back to the version that was running, and its service.
rollback() {
    rm -rf "$root/app"
    mv "$root/app.old" "$root/app"
    if [ "$running" = 1 ]; then vigil start > /dev/null; fi
    die "$1; went back to the version that was installed"
}
# app/ is swapped whole, so a process still running the old one keeps
# reading files that stay intact.
if [ -d "$root/app" ] && ! mv "$root/app" "$root/app.old"; then
    rm -rf "$root/app.new"
    [ "$running" = 1 ] && vigil start > /dev/null
    die "cannot replace $root/app; nothing was changed"
fi
if ! mv "$root/app.new" "$root/app"; then
    [ -d "$root/app.old" ] && mv "$root/app.old" "$root/app"
    [ "$running" = 1 ] && vigil start > /dev/null
    die "cannot replace $root/app; nothing was changed"
fi
if [ "$mode" = system ]; then
    chown -R 0:0 "$root/app" 2> /dev/null
    chmod 755 "$root"
fi
# The old version goes only once the new one has proved it runs.
if [ "$upgrade" = 1 ]; then
    [ "$(vigil version 2> /dev/null)" = "Vigil $version" ] || rollback "the new version ($version) does not run"
    if [ "$running" = 1 ]; then
        vigil start > /dev/null || rollback "the new version ($version) did not start"
        sleep 3
        vigil status 2> /dev/null | head -n 1 | grep -q '^service: active' || rollback "the new version ($version) did not stay up"
    fi
    rm -rf "$root/app.old"
    say "upgraded $root to Vigil $version"
else
    say "installed Vigil $version in $root"
fi
if [ "$only_upgrade" = 1 ]; then
    say "done: Vigil $version"
    exit 0
fi

# --- 4. The vigil command ------------------------------------------------------

if [ "$mode" = system ]; then bindir=/usr/local/bin; else bindir=$HOME/.local/bin; fi
mkdir -p "$bindir" && ln -sf "$root/app/vigil" "$bindir/vigil" || die "cannot link $bindir/vigil"
say "linked $bindir/vigil"
case :$PATH: in
    *:"$bindir":*) ;;
    *) say "note: $bindir is not on your PATH; add it, or run $root/app/vigil" ;;
esac

# --- 5. vigil init, on a fresh install --------------------------------------------

if [ "$do_init" = 1 ] && [ ! -f "$root/config/vigil.config" ]; then
    set --
    [ -n "$instance" ] && set -- "$@" --instance "$instance"
    [ -n "$backend" ] && set -- "$@" --backend "$backend"
    say ''
    # Piped into sh, standard input is this script: questions go to the terminal.
    if [ ! -t 0 ] && (: < /dev/tty) 2> /dev/null; then
        vigil init "$@" < /dev/tty || die 'vigil init failed'
    else
        vigil init "$@" || die 'vigil init failed'
    fi
fi

# --- 6. The service ------------------------------------------------------------------

if [ "$do_service" = 1 ]; then
    say ''
    if [ "$upgrade" = 1 ] && bash "$root/app/vigil" --root "$root" status 2> /dev/null | head -n 1 | grep -q '^service: not registered'; then
        : # registered nowhere yet: install it below
    elif [ "$upgrade" = 1 ]; then
        say "done: Vigil $version"
        exit 0
    fi
    set -- service install "--$mode"
    [ -n "$account" ] && set -- "$@" --account "$account"
    if ! vigil "$@"; then
        say ''
        say "Vigil is installed but not running: fix what the checks above report"
        say "(edit $root/config/vigil.config, set the environment), then run: vigil service install --$mode"
        exit 1
    fi
fi
say ''
say "done: Vigil $version. vigil status shows what it is doing."
