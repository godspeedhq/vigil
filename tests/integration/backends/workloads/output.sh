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
# Writes to standard output and standard error, carrying the run's tag so
# verify.sh can find these lines in a log backend.
echo "bk_output stdout ${BK_RUN:-untagged}"
echo "bk_output stderr ${BK_RUN:-untagged}" >&2
