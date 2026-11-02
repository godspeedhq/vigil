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
# check-headers.sh - fails if a script in this repository is missing its
# copyright notice, licence identifier or disclaimer.
#
# Only what git tracks is checked, so run it after git add. vendor/ holds
# other people's work under its own licence, and tests/conformance/ holds
# fixtures compared byte for byte, so neither is looked at.

set -u

cd "$(dirname "$0")/.." || exit 1

# The notice sits in the header, and the longest header is a pack script's.
readonly HEADER_LINES=50

missing=0
checked=0

check_file() {
    local file=$1 phrase
    for phrase in \
        'Copyright (c) Bankole Ogundero and the Vigil contributors' \
        'SPDX-License-Identifier: Apache-2.0' \
        'WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND'; do
        if ! head -n "$HEADER_LINES" "$file" | grep -qF "$phrase"; then
            printf 'missing from %s: %s\n' "$file" "$phrase"
            missing=$((missing + 1))
        fi
    done
    checked=$((checked + 1))
}

while IFS= read -r file; do
    case $file in
        vendor/* | tests/conformance/*) ;;
        *.sh | *.ps1 | *.py | *.cmd | app/vigil | */pack.config) check_file "$file" ;;
    esac
done <<EOF
$(git ls-files)
EOF

if [ "$checked" -eq 0 ]; then
    echo 'no scripts found: is this a git checkout?'
    exit 1
fi
if [ "$missing" -ne 0 ]; then
    echo "$missing missing from $checked files: copy the header from any script beside it"
    exit 1
fi
echo "$checked files carry the notice"
