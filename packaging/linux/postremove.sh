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
# After the vigil .deb or .rpm is removed. Removing keeps /opt/vigil, the
# configuration, scripts, state and logs, and the vigil account; purging the
# .deb (apt purge vigil) removes /opt/vigil too.
#   .deb  postrm remove | purge | upgrade ...
#   .rpm  %postun 0 (remove) or 1 (upgrade)

case ${1-} in
    remove | 0)
        [ -d /run/systemd/system ] && systemctl daemon-reload > /dev/null 2>&1
        echo 'Vigil was removed; its configuration, scripts and logs are kept in /opt/vigil'
        ;;
    purge)
        rm -rf /opt/vigil
        ;;
esac
exit 0
