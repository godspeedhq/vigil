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
# ca.sh - copies OpenSearch's demo root CA out of its running container, to
# .secrets/opensearch/root-ca.pem, so that everything talking to it can
# verify its certificate instead of skipping verification: the collector
# and Dashboards (mounted), verify.sh and run-checks.sh (curl --cacert).
# start.sh runs it once OpenSearch is healthy, before starting the rest.
#
# The demo certificate names node-0.example.com, localhost and 127.0.0.1:
# the container answers to node-0.example.com on the Compose network, and
# to 127.0.0.1:9201 on this host.

set -u
bk_dir=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$bk_dir/.secrets/opensearch
mkdir -p "$dir" || exit 1
docker cp vigil-backends-opensearch-1:/usr/share/opensearch/config/root-ca.pem "$dir/root-ca.pem.tmp" > /dev/null &&
    mv -f "$dir/root-ca.pem.tmp" "$dir/root-ca.pem" || exit 1
chmod 644 "$dir/root-ca.pem"
