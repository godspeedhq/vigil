# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# One instance of the fleet test: Alpine, bash, supervisord, and Vigil as a
# user of its own (vigil), installed from a release the reviewed way (its
# archive checked against SHA256SUMS and their signature, with the release
# key this repository holds). The fleet test's CA is trusted. At start
# (entrypoint.sh) it points Vigil at the fleet's configuration in Git, and
# supervisord keeps `vigil supervise` running. Built by node/fleet.sh, from
# the repository's root:
#   docker build -f tests/integration/fleet/node/Dockerfile -t vigil-fleet-node .
FROM alpine:3.24
ARG VIGIL_VERSION=1.5.3
RUN apk add --no-cache bash coreutils findutils gawk grep sed procps util-linux iproute2 \
        curl git openssl ca-certificates supervisor tzdata \
    && adduser -D -h /home/vigil vigil
COPY app/release-key.pem /tmp/release-key.pem
RUN set -eu; d=/tmp/rel; mkdir -p $d; cd $d; \
    for f in install.sh vigil-$VIGIL_VERSION.tar.gz SHA256SUMS SHA256SUMS.sig; do \
        curl -fsSL -o $f https://github.com/godspeedhq/vigil/releases/download/v$VIGIL_VERSION/$f; done; \
    chmod -R a+rX $d /tmp/release-key.pem; \
    su vigil -s /bin/sh -c "sh $d/install.sh --user --prefix /home/vigil/vigil --no-service --no-init \
        --archive $d/vigil-$VIGIL_VERSION.tar.gz --key /tmp/release-key.pem"; \
    rm -rf $d /tmp/release-key.pem; \
    ls /home/vigil/vigil/packs/base/cpu.sh
COPY tests/integration/fleet/tls/out/ca.crt /usr/local/share/ca-certificates/vigil-fleet-test-ca.crt
RUN update-ca-certificates > /dev/null 2>&1
COPY tests/integration/fleet/node/entrypoint.sh /usr/local/bin/fleet-entrypoint
COPY tests/integration/fleet/node/supervisord.conf /etc/supervisord.conf
RUN chmod 755 /usr/local/bin/fleet-entrypoint
ENTRYPOINT ["/usr/local/bin/fleet-entrypoint"]
