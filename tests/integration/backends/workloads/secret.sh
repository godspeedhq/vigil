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
# Proves a secret reached the job, without ever showing it: the SHA-256 of
# BK_SECRET, which Vigil sets from a store, must be BK_SECRET_SHA256.
if [ -z "${BK_SECRET-}" ]; then
    echo 'no secret in BK_SECRET'
    exit 2
fi
if command -v sha256sum > /dev/null 2>&1; then
    got=$(printf '%s' "$BK_SECRET" | sha256sum)
else
    got=$(printf '%s' "$BK_SECRET" | shasum -a 256)
fi
if [ "${got%% *}" = "${BK_SECRET_SHA256-}" ]; then
    echo 'secret matched'
    echo 'metric secret_matched 1'
    exit 0
fi
echo 'secret did not match'
exit 1
