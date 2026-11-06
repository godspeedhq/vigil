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
# Before the vigil .deb or .rpm is removed: the service is stopped and
# disabled. Running jobs carry on to their end (KillMode=process). An upgrade
# leaves the service alone: postinstall.sh restarts it.
#   .deb  prerm remove | upgrade ...
#   .rpm  %preun 0 (remove) or 1 (upgrade)

case ${1-} in
    remove | 0)
        if [ -d /run/systemd/system ]; then
            systemctl disable --now vigil > /dev/null 2>&1
        fi
        ;;
esac
exit 0
