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
# The MacPorts port (backlog 30, step 3), for real: installed from its
# Portfile, run by port load, upgraded with the service running, removed.
# As root, through sudo, on a Mac with MacPorts and no vigil port (the macOS
# CI runner):
#   sudo bash macports.sh <old dir> <new dir>
# where each dir holds package.sh's output for one version, the new one
# newer. The Portfiles are portfile.sh's, fetching from those dirs. A port
# from a folder is not in the ports tree, so the port commands here name
# the folder (-D) and not the port, and an upgrade is what port upgrade
# does: the new version installed over the old, its startup item loaded.

set -u
[ "$#" -eq 2 ] || { printf 'usage: sudo bash macports.sh <old dir> <new dir>\n' >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { printf 'macports.sh: run it with sudo\n' >&2; exit 64; }
user=${SUDO_USER:-}
[ -n "$user" ] && [ "$user" != root ] || { printf 'macports.sh: run it with sudo from an account\n' >&2; exit 64; }
old=$(cd "$1" && pwd) new=$(cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
v_old=$(ls "$old" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
v_new=$(ls "$new" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
export VIGIL_NO_UPDATE_CHECK=1
P=/opt/local/bin/port
V=/opt/local/bin/vigil
root=/opt/local/var/vigil
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
as_user() { sudo -u "$user" VIGIL_NO_UPDATE_CHECK=1 "$@"; }
sup_pid() { as_user "$V" status 2> /dev/null | sed -n 's/^service: active, pid \([0-9]*\).*/\1/p'; }
wait_for() { # <seconds> <command...>
    local i=0 n=$(($1 * 2))
    shift
    while ! "$@" > /dev/null 2>&1 && [ "$i" -lt "$n" ]; do sleep 0.5; i=$((i + 1)); done
}
diagnose() {
    printf '        --- port installed vigil\n'
    "$P" -q installed vigil 2>&1 | sed 's/^/        /'
    printf '        --- launchctl print system/org.macports.vigil\n'
    launchctl print system/org.macports.vigil 2>&1 | head -n 20 | sed 's/^/        /'
    printf '        --- the supervisor log\n'
    tail -n 20 "$root"/logs/supervisor/2*.log 2> /dev/null | sed 's/^/        /'
    tail -n 20 "$root/logs/supervisor/service.log" 2> /dev/null | sed 's/^/        /'
}
# The Portfile for the version in dir $1 into $2, fetching from $work/dist:
# MacPorts fetches as an account of its own, which has to read the archive.
portfile() {
    local v
    v=$(ls "$1" | sed -n 's/^vigil-\([0-9.]*\)\.tar\.gz$/\1/p')
    cp "$1/vigil-$v.tar.gz" "$work/dist/" && chmod 644 "$work/dist/vigil-$v.tar.gz" || exit 1
    bash "$repo/tools/release/portfile.sh" "$v" "$1/vigil-$v.tar.gz" "$1/SHA256SUMS" "$2" > /dev/null || exit 1
    sed -i '' "s|^github.tarball_from .*|&\\
master_sites            file://$work/dist|" "$2/sysutils/vigil/Portfile"
}
versions() { "$P" -q installed vigil 2> /dev/null | awk '$1 == "vigil" { print $2 }'; }

printf 'vigil port %s then %s, %s on %s\n' "$v_old" "$v_new" "$("$P" version 2> /dev/null)" "$(uname -sm)"
[ -z "$(versions)" ] || { printf 'macports.sh: a vigil port is already installed\n' >&2; exit 1; }
work=$(mktemp -d /tmp/vigil-macports.XXXXXX) && chmod 755 "$work" && mkdir -m 755 "$work/dist" || exit 1
portfile "$old" "$work/old"
portfile "$new" "$work/new"
d_old=$work/old/sysutils/vigil d_new=$work/new/sysutils/vigil

out=$(cd "$d_old" && "$P" lint --nitpick 2>&1)
check 'port lint --nitpick: no errors or warnings' yes "$(has '0 errors and 0 warnings found')"

# --- install --------------------------------------------------------------------

out=$("$P" -N -D "$d_old" install 2>&1)
check 'install: succeeds' 0 "$?"
check 'install: says how to start it' yes "$(has 'sudo port load vigil')"
check 'the command is in /opt/local/bin' "$V" "$(as_user sh -c 'PATH=/opt/local/bin:$PATH command -v vigil')"
check 'it runs the version installed' "Vigil $v_old" "$(as_user "$V" version)"
out=$(as_user "$V" about 2>&1)
check 'about: the root is /opt/local/var/vigil' yes "$(has "Installed   $root")"
check 'about: the program and its package manager' yes "$(has 'Program     /opt/local/libexec/vigil, by MacPorts')"
check 'a starting configuration was written' yes "$(yn test -f "$root/config/vigil.config")"
check 'the base pack is in the root' yes "$(yn test -f "$root/packs/base/cpu.sh")"
out=$("$V" run base_cpu 2>&1)
check 'a job runs' 0 "$?"

out=$(as_user "$V" self update 2>&1)
check 'self update: refused' 1 "$?"
check 'self update: says port upgrade' yes "$(has 'sudo port selfupdate && sudo port upgrade vigil')"
out=$("$V" uninstall --yes 2>&1)
check 'uninstall: refused' 1 "$?"
out=$("$V" service install 2>&1)
check 'service install: refused' 1 "$?"
check 'service install: says port load' yes "$(has 'MacPorts installed this service: start it with sudo port load vigil')"
out=$(as_user "$V" status 2>&1)
check 'status: the startup item, not loaded' yes "$(has 'service: inactive (not loaded) (launchd, system mode)')"

# --- the service ------------------------------------------------------------------

out=$("$P" -D "$d_old" load 2>&1)
check 'port load: succeeds' 0 "$?"
wait_for 30 test -n "$(sup_pid)"
out=$(as_user "$V" status 2>&1)
check 'status finds the startup item, running' yes "$(has 'service: active')"
out=$("$V" service remove 2>&1)
check 'service remove: refused' yes "$(has 'MacPorts installed this service: stop it with sudo port unload vigil')"
before=$(sup_pid)
out=$("$V" restart 2>&1)
check 'vigil restart: succeeds' 0 "$?"
wait_for 30 test -n "$(sup_pid)"
after=$(sup_pid)
check 'vigil restart: a new supervisor' yes "$([ -n "$after" ] && [ "$after" != "$before" ] && echo yes || echo no)"
[ "$fail" -eq 0 ] || diagnose

# --- upgrade ------------------------------------------------------------------------

printf '# a job of our own: kept\n' >> "$root/config/vigil.config"
printf '#!/bin/sh\necho mine\n' > "$root/scripts/mine.sh"
out=$("$P" -N -D "$d_new" install 2>&1)
check 'upgrade: succeeds' 0 "$?"
check 'upgrade: the running service was unloaded first' yes "$(has "Unloading startupitem 'vigil'")"
out=$("$P" -D "$d_new" load 2>&1)
check 'upgrade: loaded again' 0 "$?"
check 'upgrade: the new version' "Vigil $v_new" "$(as_user "$V" version)"
check 'upgrade: the configuration is kept' yes "$(yn grep -q 'a job of our own' "$root/config/vigil.config")"
check 'upgrade: scripts are kept' yes "$(yn test -f "$root/scripts/mine.sh")"
wait_for 30 test -n "$(sup_pid)"
out=$(as_user "$V" status 2>&1)
check 'upgrade: the service is active' yes "$(has 'service: active')"
check 'upgrade: the supervisor runs the new version' "$v_new" "$(cat "$root/state/supervisor.version" 2> /dev/null)"
[ "$fail" -eq 0 ] || diagnose

# --- remove ---------------------------------------------------------------------------

out=$("$P" -D "$d_new" unload 2>&1)
check 'port unload: succeeds' 0 "$?"
out=$(as_user "$V" status 2>&1)
check 'status: not loaded' yes "$(has 'service: inactive (not loaded)')"
for v in $(versions); do "$P" -N uninstall vigil "$v" > /dev/null 2>&1; done
check 'uninstall: no vigil port left' '' "$(versions)"
check 'uninstall: the command is gone' no "$(yn test -e "$V")"
check 'uninstall: the startup item is gone' no "$(yn test -e /Library/LaunchDaemons/org.macports.vigil.plist)"
check 'uninstall: the root is kept' yes "$(yn test -f "$root/config/vigil.config")"
out=$("$P" -N -D "$d_new" install 2>&1)
check 'reinstall: succeeds' 0 "$?"
check 'reinstall: the configuration is untouched' yes "$(yn grep -q 'a job of our own' "$root/config/vigil.config")"
for v in $(versions); do "$P" -N uninstall vigil "$v" > /dev/null 2>&1; done
"$P" -N -D "$d_old" clean --all > /dev/null 2>&1
"$P" -N -D "$d_new" clean --all > /dev/null 2>&1
rm -rf "$root" "$work"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
