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
# Package test: the vigil .deb or .rpm installed, upgraded and removed on a
# clean machine (backlog 30, step 1). Run as root, in a container or a
# throwaway VM, never on a machine whose Vigil matters: it removes
# /opt/vigil.
#
#   sh tests/packages/linux.sh <old dir> <new dir>
#
# Each dir holds a release's .deb and .rpm (tools/release/package.sh with
# nfpm); apt or dnf picks its own. Where systemd runs, the service is checked
# too: started by the .deb, left off by the .rpm.
#
# Exit code: 0 all passed, 1 any failed.

set -u
old=$1
new=$2
root=/opt/vigil
pass=0
fail=0
VIGIL_NO_UPDATE_CHECK=1
export VIGIL_NO_UPDATE_CHECK

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
as_vigil() { out=$(runuser -u vigil -- "$@" < /dev/null 2>&1); }

if command -v apt-get > /dev/null 2>&1; then
    format=deb manager=apt
    pkg_old=$(ls "$old"/vigil_*_all.deb) pkg_new=$(ls "$new"/vigil_*_all.deb)
    pkg_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$1" 2>&1; }
    pkg_remove() { DEBIAN_FRONTEND=noninteractive apt-get remove -y -q vigil 2>&1; }
else
    format=rpm manager=dnf
    pkg_old=$(ls "$old"/vigil-*.noarch.rpm) pkg_new=$(ls "$new"/vigil-*.noarch.rpm)
    pkg_install() { dnf install -y -q "$1" 2>&1; }
    pkg_remove() { dnf remove -y -q vigil 2>&1; }
fi
systemd=no
[ -d /run/systemd/system ] && systemd=yes
printf 'vigil %s on %s, systemd %s\n' "$format" "$(. /etc/os-release && echo "$PRETTY_NAME")" "$systemd"

# --- install --------------------------------------------------------------------

out=$(pkg_install "$pkg_old")
check 'install: succeeds' 0 "$?"
check 'install: no advice to run vigil service install, which refuses' no "$(has 'vigil service install')"
check 'the command is on PATH' /usr/lib/vigil/app/vigil "$(readlink -f "$(command -v vigil)")"
out=$(vigil about 2>&1)
check 'about: the root is /opt/vigil' yes "$(has "Installed   $root")"
check 'about: the program and its package manager' yes "$(has "Program     /usr/lib/vigil, by $manager")"
check 'the account vigil exists' yes "$(yn id vigil)"
check 'a starting configuration was written' yes "$(yn test -f $root/config/vigil.config)"
check 'it belongs to the service account' vigil "$(stat -c %U $root/config/vigil.config)"
check 'the base pack is in the root, flat' yes "$(yn test -f $root/packs/base/cpu.sh)"
check 'and turned on' 1 "$(grep -c '^# pack base:' $root/config/vigil.config)"
check 'the program belongs to root' root "$(stat -c %U /usr/lib/vigil/app/vigil)"

as_vigil vigil precheck
check 'precheck passes as the service account' 0 "$?"
as_vigil vigil run base_cpu
check 'a pack job runs as the service account' 0 "$?"

out=$(vigil self update 2>&1)
check 'self update: refused' 1 "$?"
check 'self update: names the package manager' yes "$(has "Vigil was installed by $manager")"
out=$(vigil uninstall --yes 2>&1)
check 'uninstall: refused' 1 "$?"
check 'uninstall: the root is kept' yes "$(yn test -f $root/config/vigil.config)"

if [ "$systemd" = yes ]; then
    out=$(vigil status 2>&1)
    if [ "$format" = deb ]; then
        check 'the .deb starts the service' yes "$(has 'service: active')"
    else
        check 'the .rpm leaves the service off' no "$(yn systemctl is-active --quiet vigil)"
        systemctl enable --now vigil > /dev/null 2>&1
        out=$(vigil status 2>&1)
        check 'systemctl enable --now starts it' yes "$(has 'service: active')"
    fi
    check 'status: the package unit, system mode' yes "$(has '(systemd, system mode)')"
    check 'it runs as vigil' vigil "$(ps -o user= -p "$(systemctl show -p MainPID --value vigil)" | tr -d ' ')"
    out=$(vigil service install 2>&1)
    check 'service install: refused' 1 "$?"
    check 'service install: says to use systemctl' yes "$(has 'the vigil package installed this service')"
    out=$(vigil restart 2>&1)
    check 'vigil restart works on the package unit' 0 "$?"
    # A supervisor stopped while it sleeps leaves its sleep behind for a moment;
    # the one restarted must not mistake that for another supervisor.
    sleep 3
    check 'after a restart, the service stays up' yes "$(yn systemctl is-active --quiet vigil)"
fi

# --- upgrade --------------------------------------------------------------------

printf '# kept across the upgrade\n' >> $root/config/vigil.config
printf '#!/bin/sh\necho ok\n' > $root/scripts/mine.sh
before=$(vigil version)
out=$(pkg_install "$pkg_new")
check 'upgrade: succeeds' 0 "$?"
check 'upgrade: the new version runs' yes "$([ "$(vigil version)" != "$before" ] && echo yes || echo no)"
check 'upgrade: the configuration is kept' 1 "$(grep -c '^# kept across the upgrade' $root/config/vigil.config)"
check 'upgrade: scripts are kept' yes "$(yn test -f $root/scripts/mine.sh)"
if [ "$systemd" = yes ]; then
    out="$out
$(systemctl status vigil --no-pager 2>&1)
$(journalctl -u vigil --no-pager -n 40 2>&1)
$(tail -n 20 $root/logs/supervisor/2*.log 2>&1)"
    check 'upgrade: the service is running' yes "$(yn systemctl is-active --quiet vigil)"
    want=$(vigil version | sed 's/^Vigil //')
    i=0
    while [ "$(cat $root/state/supervisor.version 2> /dev/null)" != "$want" ] && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    check 'upgrade: the supervisor is on the new version' "$want" "$(cat $root/state/supervisor.version 2> /dev/null)"
fi

# --- remove ---------------------------------------------------------------------

out=$(pkg_remove)
check 'remove: succeeds' 0 "$?"
check 'remove: the command is gone' no "$(yn test -e /usr/bin/vigil)"
check 'remove: the program is gone' no "$(yn test -e /usr/lib/vigil/app/vigil)"
check 'remove: the configuration is kept' yes "$(yn test -f $root/config/vigil.config)"
check 'remove: scripts are kept' yes "$(yn test -f $root/scripts/mine.sh)"
if [ "$systemd" = yes ]; then
    check 'remove: the service is stopped' no "$(yn systemctl is-active --quiet vigil)"
fi

# Installing again picks up where it left off.
out=$(pkg_install "$pkg_new")
check 'reinstall: succeeds' 0 "$?"
check 'reinstall: the configuration is the one kept' 1 "$(grep -c '^# kept across the upgrade' $root/config/vigil.config)"

if [ "$format" = deb ]; then
    out=$(DEBIAN_FRONTEND=noninteractive apt-get purge -y -q vigil 2>&1)
    check 'purge: succeeds' 0 "$?"
    check 'purge: the root is gone' no "$(yn test -e $root)"
else
    out=$(pkg_remove)
    rm -rf $root
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
