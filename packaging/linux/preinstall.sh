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
# Before the vigil .deb or .rpm replaces an installed version: a running
# service is stopped, and postinstall.sh starts it again on the new one. The
# package manager replaces the program a file at a time, and the supervisor,
# which reloads itself when it sees a new version, must never load half of
# one. Running jobs carry on (KillMode=process).
#   .deb  preinst install | upgrade <old version>
#   .rpm  %pre 1 (install) or 2 (upgrade)

case ${1-} in
    upgrade | [2-9]*)
        if [ -d /run/systemd/system ] && systemctl is-active --quiet vigil 2> /dev/null; then
            systemctl stop vigil > /dev/null 2>&1 && : > /run/vigil.package-restart
        fi
        ;;
esac
exit 0
