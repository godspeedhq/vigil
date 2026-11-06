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
# After the vigil .deb or .rpm is installed or upgraded: the service account,
# the root and its folders, a starting configuration when there is none, and
# the service, started as each distribution does (backlog 30, step 1).
#   .deb  postinst configure [<old version>]
#   .rpm  %post 1 (install) or 2 (upgrade)
# Plain sh: dash runs it on Debian. Nothing here fails the install: a package
# that cannot be configured is worse than a note saying what to do.

set -u
root=/opt/vigil
prog=/usr/lib/vigil/app/vigil
# No update check from a package script: it would reach the network.
VIGIL_NO_UPDATE_CHECK=1
export VIGIL_NO_UPDATE_CHECK

case ${1-} in
    configure)
        format=deb
        if [ -n "${2-}" ]; then action=upgrade; else action=install; fi
        ;;
    1) format=rpm action=install ;;
    [0-9]*) format=rpm action=upgrade ;;
    *) exit 0 ;;
esac

# The account the service runs as, as vigil service install --system makes it.
if ! id vigil > /dev/null 2>&1; then
    nologin=$(command -v nologin 2> /dev/null)
    [ -n "$nologin" ] || nologin=/usr/sbin/nologin
    useradd --system --user-group --no-create-home --home-dir "$root" --shell "$nologin" vigil ||
        echo 'vigil: could not create the vigil account' >&2
fi

mkdir -p "$root"
chmod 755 "$root"

# A starting configuration only when there is none: the defaults vigil init
# takes on Enter (the host name, metrics to a file, the base pack). It also
# puts the package's packs in the root.
if [ ! -f "$root/config/vigil.config" ]; then
    "$prog" --root "$root" init --backend file < /dev/null || echo 'vigil: vigil init failed; run: sudo vigil init' >&2
fi

# The folders the supervisor writes, the service account's.
for d in config scripts state spool logs logs/supervisor cache metrics; do
    mkdir -p "$root/$d"
done
for d in config scripts state spool logs cache metrics; do
    chown -R vigil:vigil "$root/$d" 2> /dev/null
done

# An install-script service names /opt/vigil/app/vigil, and its unit in
# /etc/systemd/system takes the place of this package's.
legacy=0
if [ -f /etc/systemd/system/vigil.service ] && grep -qF "$root/app/vigil" /etc/systemd/system/vigil.service; then
    legacy=1
    echo ''
    echo 'Vigil was installed here before by its install script, whose service still runs it.'
    echo 'Your configuration, scripts and packs are already in place; to switch to the package:'
    echo "  sudo $root/app/vigil service remove"
    echo "  sudo rm -rf $root/app $root/vendor /usr/local/bin/vigil /etc/sudoers.d/vigil"
    echo '  sudo systemctl enable --now vigil'
fi

# No systemd running (a container, a chroot): the program is installed, and
# vigil supervise runs it.
[ -d /run/systemd/system ] || exit 0
systemctl daemon-reload > /dev/null 2>&1
[ "$legacy" = 1 ] && exit 0

if [ "$action" = upgrade ]; then
    # Running jobs carry on (KillMode=process); the supervisor comes back on
    # the new version.
    systemctl try-restart vigil > /dev/null 2>&1
    exit 0
fi

if [ "$format" = rpm ]; then
    # Fedora and RHEL leave a new service off unless a preset turns it on.
    systemctl preset vigil > /dev/null 2>&1
    if ! systemctl is-enabled --quiet vigil 2> /dev/null; then
        echo ''
        echo 'Vigil is installed. Start it with: sudo systemctl enable --now vigil'
        echo "Its configuration is $root/config/vigil.config: sudo vigil config edits it."
        exit 0
    fi
fi

# Debian starts what it installs, once pre-flight passes as the service
# account, as vigil service install does.
if runuser -u vigil -- /bin/bash "$prog" --root "$root" precheck > /dev/null 2>&1; then
    systemctl enable --now vigil > /dev/null 2>&1 && {
        echo ''
        echo 'Vigil is running: vigil status shows what it is doing.'
        echo "Its configuration is $root/config/vigil.config: sudo vigil config edits it."
        exit 0
    }
fi
echo ''
echo 'Vigil is installed but not started: see sudo -u vigil vigil precheck, then'
echo 'start it with: sudo systemctl enable --now vigil'
exit 0
