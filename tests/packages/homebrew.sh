#!/usr/bin/env bash
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
# The Homebrew formula (backlog 30, step 2), for real: installed from a tap
# of its own, run by brew services, upgraded, removed. On a machine with
# Homebrew that runs no Vigil of its own (the macOS CI runner):
#   homebrew.sh <old dir> <new dir>
# where each dir holds package.sh's output for one version, the new one
# newer.

set -u
[ "$#" -eq 2 ] || { printf 'usage: homebrew.sh <old dir> <new dir>\n' >&2; exit 64; }
old=$(cd "$1" && pwd) new=$(cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
v_old=$(ls "$old" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
v_new=$(ls "$new" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
export VIGIL_NO_UPDATE_CHECK=1
prefix=$(brew --prefix)
root=$prefix/var/vigil
tap=vigil-test/local
pass=0 fail=0

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "$1"
    else
        fail=$((fail + 1))
        printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"
        [ -z "${out-}" ] || printf '%s\n' "$out" | sed 's/^/        /'
    fi
}
has() { if printf '%s\n' "$out" | grep -F -e "$1" > /dev/null; then echo yes; else echo no; fi; }
yn() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }
sup_version() { cat "$root/state/supervisor.version" 2> /dev/null; }
wait_for() { # <seconds> <command...>
    local i=0 n=$(($1 * 2))
    shift
    while ! "$@" > /dev/null 2>&1 && [ "$i" -lt "$n" ]; do sleep 0.5; i=$((i + 1)); done
}
# The formula for the version in dir $1, into the tap.
formula() {
    local v
    v=$(ls "$1" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
    VIGIL_PACKAGE_URL="file://$1" bash "$repo/tools/release/tap-bucket.sh" "$v" "$1/SHA256SUMS" "$work" > /dev/null || exit 1
    cp "$work/Formula/vigil.rb" "$tapdir/Formula/vigil.rb"
}
diagnose() {
    printf '        --- brew services list\n'
    brew services list 2>&1 | sed 's/^/        /'
    printf '        --- vigil status\n'
    vigil status 2>&1 | sed 's/^/        /'
    printf '        --- the supervisor log\n'
    tail -n 20 "$root"/logs/supervisor/2*.log 2> /dev/null | sed 's/^/        /'
    tail -n 20 "$root"/logs/supervisor/service.log 2> /dev/null | sed 's/^/        /'
}

printf 'vigil formula %s then %s, Homebrew %s on %s\n' "$v_old" "$v_new" "$(brew --version | head -n 1 | cut -d' ' -f2)" "$(uname -sm)"
work=$(mktemp -d)
brew tap-new --no-git "$tap" > /dev/null || exit 1
tapdir=$(brew --repository)/Library/Taps/${tap%/*}/homebrew-${tap#*/}
mkdir -p "$tapdir/Formula"

# --- install --------------------------------------------------------------------

formula "$old"
out=$(brew install "$tap/vigil" 2>&1)
check 'install: succeeds' 0 "$?"
check 'install: says how to start it' yes "$(has 'brew services start vigil')"
check 'install: no advice to run vigil service install' no "$(has 'then vigil service install')"
check 'the command is on PATH' "$prefix/bin/vigil" "$(command -v vigil)"
check 'it runs the version installed' "Vigil $v_old" "$(vigil version)"
out=$(vigil about 2>&1)
check 'about: the root is var/vigil' yes "$(has "Installed   $root")"
check 'about: the program and its package manager' yes "$(has 'by brew')"
check 'a starting configuration was written' yes "$(yn test -f "$root/config/vigil.config")"
check 'the base pack is in the root' yes "$(yn test -f "$root/packs/base/cpu.sh")"
out=$(vigil run base_cpu 2>&1)
check 'a job runs' 0 "$?"
out=$(brew test "$tap/vigil" 2>&1)
check 'brew test passes' 0 "$?"

out=$(vigil self update 2>&1)
check 'self update: refused' 1 "$?"
check 'self update: says brew upgrade vigil' yes "$(has 'brew upgrade vigil')"
out=$(vigil uninstall --yes 2>&1)
check 'uninstall: refused' 1 "$?"
out=$(vigil service install 2>&1)
check 'service install: refused' 1 "$?"
check 'service install: says brew services start vigil' yes "$(has 'brew services start vigil')"

# --- the service ------------------------------------------------------------------

out=$(brew services start vigil 2>&1)
check 'brew services start: succeeds' 0 "$?"
wait_for 30 test "$(sup_version)" = "$v_old"
check 'the supervisor runs' "$v_old" "$(sup_version)"
out=$(vigil status 2>&1)
check 'status finds brew services'"'"' registration' yes "$(has 'service: active')"
out=$(vigil service install 2>&1)
check 'service install: refused once registered' yes "$(has 'Homebrew installed this service: start it with brew services start vigil')"
out=$(vigil service remove 2>&1)
check 'service remove: refused' yes "$(has 'Homebrew installed this service: stop it with brew services stop vigil')"
before=$(vigil status | sed -n 's/^service: active, pid \([0-9]*\).*/\1/p')
out=$(vigil restart 2>&1)
check 'vigil restart: succeeds' 0 "$?"
wait_for 30 sh -c "vigil status | grep -q '^service: active, pid'"
after=$(vigil status | sed -n 's/^service: active, pid \([0-9]*\).*/\1/p')
check 'vigil restart: a new supervisor' yes "$([ -n "$after" ] && [ "$after" != "$before" ] && echo yes || echo no)"
[ "$fail" -eq 0 ] || diagnose

# --- upgrade ------------------------------------------------------------------------

printf '# a job of our own: kept\n' >> "$root/config/vigil.config"
printf '#!/bin/sh\necho mine\n' > "$root/scripts/mine.sh"
pid=$(vigil status | sed -n 's/^service: active, pid \([0-9]*\).*/\1/p')
formula "$new"
out=$(brew upgrade "$tap/vigil" 2>&1)
check 'upgrade: succeeds' 0 "$?"
check 'upgrade: the new version' "Vigil $v_new" "$(vigil version)"
check 'upgrade: the configuration is kept' yes "$(yn grep -q 'a job of our own' "$root/config/vigil.config")"
check 'upgrade: scripts are kept' yes "$(yn test -f "$root/scripts/mine.sh")"
wait_for 60 test "$(sup_version)" = "$v_new"
check 'upgrade: the service runs the new version' "$v_new" "$(sup_version)"
out=$(vigil status 2>&1)
check 'upgrade: the service is active' yes "$(has 'service: active')"
check 'upgrade: the old version is gone' no "$(yn test -d "$prefix/Cellar/vigil/$v_old")"
printf '        (supervisor pid %s before, %s after: %s)\n' "$pid" "$(vigil status | sed -n 's/^service: active, pid \([0-9]*\).*/\1/p')" \
    "$(grep -c "reloading: Vigil $v_old to $v_new" "$root"/logs/supervisor/2*.log 2> /dev/null | tail -n 1) reload line(s)"
[ "$fail" -eq 0 ] || diagnose

# --- remove ---------------------------------------------------------------------------

out=$(brew services stop vigil 2>&1)
check 'brew services stop: succeeds' 0 "$?"
out=$(vigil status 2>&1)
check 'status: no longer registered' yes "$(has 'service: not registered')"
out=$(brew uninstall "$tap/vigil" 2>&1)
check 'uninstall: succeeds' 0 "$?"
check 'uninstall: the command is gone' no "$(yn command -v vigil)"
check 'uninstall: the root is kept' yes "$(yn test -f "$root/config/vigil.config")"
out=$(brew install "$tap/vigil" 2>&1)
check 'reinstall: succeeds' 0 "$?"
check 'reinstall: the configuration is untouched' yes "$(yn grep -q 'a job of our own' "$root/config/vigil.config")"
brew uninstall "$tap/vigil" > /dev/null 2>&1
rm -rf "$root" "$work"
brew untap "$tap" > /dev/null 2>&1

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
