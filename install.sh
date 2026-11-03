#!/bin/sh
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
#   --update-by <who>      system mode: let this user, or %group, run vigil
#                          self update without being root, through a sudo
#                          rule for that one command
#   --upgrade              only replace an installed Vigil, as vigil self
#                          update does: no vigil init, no link, and the
#                          service is left as it was found
#
# Steps: check the prerequisites, download the archive and verify its
# SHA-256 before using it, unpack it into the root (on upgrade only app/ is
# replaced; config/ and scripts/ are never touched), link the vigil
# command, run vigil init on a fresh install, register the service.

# Written for plain sh, not bash: this has to run before Vigil's own
# prerequisites are known to be there, so no arrays, no [[ ]] and no local.
# set -e is left off on purpose: each step decides what a failure means, and
# a failure after the swap must roll back rather than stop half way.
set -u

# The options, filled in below. Empty means "not given", and each default is
# worked out once the rest are known, because the install mode depends on who
# is running this.
repo_url=https://github.com/godspeedhq/vigil
mode=''
prefix=''
version=''
archive=''
account=''
instance=''
backend=''
update_by=''
do_init=1
do_service=1
only_upgrade=0

say() { printf '%s\n' "$*"; }
die() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

# Unknown options stop the install: a mistyped --no-service must not quietly
# register a service.
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
        --prefix | --version | --archive | --account | --instance | --backend | --update-by)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            case $1 in
                --prefix) prefix=$2 ;;
                --version) version=${2#v} ;;
                --archive) archive=$2 ;;
                --account) account=$2 ;;
                --instance) instance=$2 ;;
                --backend) backend=$2 ;;
                --update-by) update_by=$2 ;;
            esac
            shift
            ;;
        -h | --help)
            sed -n '/^# install\.sh - /,/^$/s/^# \{0,1\}//p' "$0" 2> /dev/null || say "see $repo_url"
            exit 0
            ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

# Tests only (22.4.4): releases from a local server, never over the network.
# https only, redirects included, so a redirect can never drop to http. The
# variable is deliberately expanded unquoted further down, which is why those
# curl calls sit between set -f and set +f: the * below must stay a literal.
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

# The mode decides where files go and who owns them, so a contradiction is
# refused here rather than discovered after files have been written. Root
# cannot use user mode, which is for the account that runs it.
uid=$(id -u)
if [ -z "$mode" ]; then
    if [ "$uid" -eq 0 ]; then mode=system; else mode=user; fi
fi
[ "$mode" = system ] && [ "$uid" -ne 0 ] && die 'system mode needs root: run it with sudo, or use --user'
[ "$mode" = user ] && [ "$uid" -eq 0 ] && die 'user mode installs for the account that runs it, not root: use --system'
if [ -n "$update_by" ]; then
    [ "$mode" = system ] || die '--update-by is for system mode: a user install updates itself'
    # This name is written into a sudoers file, so only the characters of a user
    # or %group get through. A % is allowed at the start only.
    case $update_by in
        '' | *[!A-Za-z0-9_.%-]* | ?*%*) die "--update-by needs a user or %group: $update_by" ;;
    esac
    command -v visudo > /dev/null 2>&1 || die '--update-by needs sudo'
fi
if [ -n "$prefix" ]; then
    root=$prefix
elif [ "$mode" = system ]; then
    root=/opt/vigil
else
    root=$HOME/.local/share/vigil
fi
# A relative prefix is made absolute: it ends up in the service definition and
# the command link, which do not run from this folder.
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
# --archive is how a machine with no way out installs, so curl is only needed
# when downloading.
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
# Removed on every way out, including die, which is why no failure below has
# to clean this folder up itself.
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
# The check that everything rests on. Nothing has been unpacked yet, and a
# missing entry fails just as a wrong hash does: "no entry" must never read
# as "nothing to check". sha256sum marks binary files with a leading *.
want=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
[ -n "$want" ] || die "SHA256SUMS has no entry for $file"
got=$(cd "$work" && $sha "$file" | awk '{ print $1 }')
[ "$got" = "$want" ] || die "SHA-256 mismatch for $file: expected $want, got $got; nothing was changed"
say "verified $file (SHA-256 $got)"
# Only the downloads above use it: pre-flight refuses it (22.4.4).
unset VIGIL_TEST_RELEASE_URL

mkdir "$work/x" && tar -xzf "$work/$file" -C "$work/x" || die "cannot unpack $file"
src=$(find "$work/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -f "$src/app/vigil" ] || die "$file does not hold a Vigil release"
# The archive's own VERSION wins over what was asked for: with --archive
# nothing else says which version this is, and the upgrade below compares the
# running version against it.
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
vigil() { bash "$root/app/vigil" --root "$root" "$@"; }
# Whether the running service is on version $1 within 30 seconds.
# Both must be true: the version is only what the supervisor last wrote down,
# so the service has to be active as well. It gets 30 seconds because a
# supervisor notices a change to app/ at its next tick, not at once.
on_version() {
    n=0
    while [ "$n" -lt 30 ]; do
        if [ "$(vigil version --supervisor 2> /dev/null)" = "$1" ] &&
            vigil status 2> /dev/null | head -n 1 | grep -q '^service: active'; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}
# What was found running decides how the service is treated, and rollback()
# puts back exactly that, so an upgrade never starts a service that was stopped.
running=0
reload=0
old_version=$(cat "$root/app/VERSION" 2> /dev/null)
if [ "$upgrade" = 1 ] && [ "$do_service" = 1 ] &&
    vigil status 2> /dev/null | head -n 1 | grep -q '^service: active'; then
    running=1
    # A supervisor that can hot reload replaces itself when app/ changes
    # (18.7): the service is not touched. An older one is stopped and started.
    if [ -n "$(vigil version --supervisor 2> /dev/null)" ]; then
        reload=1
    else
        vigil stop > /dev/null || { rm -rf "$root/app.new"; die 'cannot stop the running service for the upgrade; nothing was changed'; }
    fi
fi
# Back to the version that was running, and its service.
# Whoever is running this reads the reason from die, so that message has to be
# the last thing that happens. A supervisor that reloaded to the new version
# reloads back by itself when app/ changes again; if it does not get back in
# time, it is started.
rollback() {
    rm -rf "$root/app"
    mv "$root/app.old" "$root/app"
    if [ "$reload" = 1 ]; then
        on_version "$old_version" || vigil start > /dev/null
    elif [ "$running" = 1 ]; then
        vigil start > /dev/null
    fi
    die "$1; went back to the version that was installed"
}
# app/ is swapped whole, so a process still running the old one keeps
# reading files that stay intact.
if [ -d "$root/app" ] && ! mv "$root/app" "$root/app.old"; then
    rm -rf "$root/app.new"
    [ "$running" = 1 ] && vigil start > /dev/null
    die "cannot replace $root/app; nothing was changed"
fi
# Between these two moves there is no app/ at all. They are renames in one
# folder, so that gap is a moment, not the length of a copy.
if ! mv "$root/app.new" "$root/app"; then
    [ -d "$root/app.old" ] && mv "$root/app.old" "$root/app"
    [ "$running" = 1 ] && vigil start > /dev/null
    die "cannot replace $root/app; nothing was changed"
fi
if [ "$mode" = system ]; then
    # Root owns the code in system mode, so the account the service runs as cannot
    # rewrite what it will run next.
    chown -R 0:0 "$root/app" 2> /dev/null
    chmod 755 "$root"
fi
# The old version goes only once the new one has proved it runs.
if [ "$upgrade" = 1 ]; then
    # Three proofs in increasing order of cost: the new code runs at all, then the
    # supervisor is really on it, then it stays up.
    [ "$(vigil version 2> /dev/null)" = "Vigil $version" ] || rollback "the new version ($version) does not run"
    if [ "$reload" = 1 ]; then
        on_version "$version" || rollback "the supervisor did not come up as $version"
    elif [ "$running" = 1 ]; then
        vigil start > /dev/null || rollback "the new version ($version) did not start"
        on_version "$version" || rollback "the new version ($version) did not stay up"
    fi
    rm -rf "$root/app.old"
    say "upgraded $root to Vigil $version"
else
    say "installed Vigil $version in $root"
fi
# vigil self update stops here: an update replaces Vigil and nothing else, so
# it can never touch packs, the link, the configuration or the service.
if [ "$only_upgrade" = 1 ]; then
    say "done: Vigil $version"
    exit 0
fi

# The packs, on a fresh install: only this platform's scripts. vigil pack
# update replaces them later; an upgrade leaves them alone (18.10).
case $(uname -s) in Darwin) os=macos ;; *) os=linux ;; esac
for p in "$src"/packs/*/; do
    [ -f "$p/pack.config" ] || continue
    p=${p%/}
    # A pack that is already here stays as it is: reinstalling must not undo a
    # vigil pack update.
    [ ! -e "$root/packs/${p##*/}" ] || continue
    mkdir -p "$root/packs/${p##*/}" && cp "$p/pack.config" "$root/packs/${p##*/}/" || die "cannot write to $root/packs"
    [ ! -d "$p/$os" ] || cp "$p/$os"/* "$root/packs/${p##*/}/" || die "cannot write to $root/packs"
    # The service account has to read these, and this may be running under a
    # strict umask.
    chmod -R a+rX "$root/packs/${p##*/}"
done

# --- 4. The vigil command ------------------------------------------------------

if [ "$mode" = system ]; then bindir=/usr/local/bin; else bindir=$HOME/.local/bin; fi
# A link, not a copy, so an upgrade needs no change here. app/vigil finds the
# rest of Vigil by following it.
mkdir -p "$bindir" && ln -sf "$root/app/vigil" "$bindir/vigil" || die "cannot link $bindir/vigil"
say "linked $bindir/vigil"
case :$PATH: in
    *:"$bindir":*) ;;
    *) say "note: $bindir is not on your PATH; add it, or run $root/app/vigil" ;;
esac

# One command, with no arguments of its own: the latest release only, never
# a version of the caller's choosing (18.7).
if [ -n "$update_by" ]; then
    # Checked with visudo before it goes anywhere near /etc/sudoers.d: one bad file
    # in there stops sudo working for everyone on the machine.
    rule="$work/sudoers"
    printf '%s ALL=(root) NOPASSWD: %s/app/vigil self update\n' "$update_by" "$root" > "$rule"
    visudo -cf "$rule" > /dev/null 2>&1 || die "the sudo rule for $update_by is not valid"
    chmod 440 "$rule"
    cp "$rule" /etc/sudoers.d/vigil && chown 0:0 /etc/sudoers.d/vigil 2> /dev/null && chmod 440 /etc/sudoers.d/vigil ||
        die 'cannot write /etc/sudoers.d/vigil'
    say "$update_by can now run: vigil self update"
fi

# --- 5. vigil init, on a fresh install --------------------------------------------

# An existing configuration is never rewritten, whatever else was asked for.
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
    # The arguments are built in "$@" because that is the only safe list in sh: an
    # account name with a space survives it.
    set -- service install "--$mode"
    [ -n "$account" ] && set -- "$@" --account "$account"
    if ! vigil "$@"; then
        say ''
        say "Vigil is installed but not running: the reason is above (a failed check,"
        say "or no session to run it in). Once it is dealt with, run: vigil service install --$mode"
        exit 1
    fi
fi
say ''
say "done: Vigil $version. vigil status shows what it is doing."
