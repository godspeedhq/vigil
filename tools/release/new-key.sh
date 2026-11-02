#!/usr/bin/env bash
#
# new-key.sh - creates the release signing key (SPECIFICATION.md 17).
#
#   bash tools/release/new-key.sh
#
# The private key goes straight into the GitHub Actions secret
# VIGIL_RELEASE_KEY, from memory: it is never written to disk or shown. The
# public key is written to app/release-key.pem, to commit.
#
# Run it once. Running it again replaces the key, and every installed Vigil
# then refuses new releases until it is updated by hand: it asks first.
#
# Needs openssl and gh, signed in with admin rights on the repository.

set -u

slug=godspeedhq/vigil
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
pub=$repo/app/release-key.pem

command -v openssl > /dev/null 2>&1 || { printf 'new-key: openssl is required\n' >&2; exit 1; }
command -v gh > /dev/null 2>&1 || { printf 'new-key: gh is required\n' >&2; exit 1; }
if [ -e "$pub" ]; then
    printf 'A release key exists. Replacing it stops installed copies accepting new releases.\nType replace to go on: '
    IFS= read -r answer
    [ "$answer" = replace ] || { printf 'nothing changed\n'; exit 1; }
fi

key=$(openssl genrsa 3072 2> /dev/null) || { printf 'new-key: openssl failed\n' >&2; exit 1; }
printf '%s\n' "$key" | openssl rsa -pubout -out "$pub.tmp" 2> /dev/null || { printf 'new-key: openssl failed\n' >&2; exit 1; }
if ! printf '%s\n' "$key" | gh secret set VIGIL_RELEASE_KEY --repo "$slug"; then
    rm -f "$pub.tmp"
    printf 'new-key: the secret was not set; nothing changed\n' >&2
    exit 1
fi
key=''
mv -f "$pub.tmp" "$pub"
printf 'The private key is in the secret VIGIL_RELEASE_KEY. Commit %s.\n' "${pub#"$repo"/}"
