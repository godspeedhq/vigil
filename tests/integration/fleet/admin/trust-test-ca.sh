#!/bin/sh
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# trust-test-ca.sh <ca.crt> [--remove] - on a Linux or macOS machine of the
# fleet test, as root (sudo): adds the fleet test's CA to the system's
# trusted roots, so Vigil, curl and Git there trust the backend; --remove
# takes it out again, and nothing else.
#   Fedora, RHEL: /etc/pki/ca-trust/source/anchors/, update-ca-trust
#   Debian, Ubuntu, Alpine: /usr/local/share/ca-certificates/, update-ca-certificates
#   macOS: the System keychain, as a trusted root (security)
set -eu
[ "$(id -u)" = 0 ] || { echo "run it as root: sudo sh $0 $*" >&2; exit 1; }
ca=${1:?usage: trust-test-ca.sh <ca.crt> [--remove]}
remove=${2-}
subject=$(openssl x509 -in "$ca" -noout -subject 2> /dev/null | sed 's/^subject= *//')
case $subject in *'Vigil fleet test CA'*) ;; *) echo "$ca is not the fleet test CA: $subject" >&2; exit 1 ;; esac
echo "CA: $subject, $(openssl x509 -in "$ca" -noout -fingerprint -sha256)"
name=vigil-fleet-test-ca.crt
if [ "$(uname -s)" = Darwin ]; then
    sha=$(openssl x509 -in "$ca" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
    if [ "$remove" = --remove ]; then
        security delete-certificate -Z "$sha" /Library/Keychains/System.keychain && echo 'Removed from the System keychain.'
    else
        security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca" && echo 'Added to the System keychain, trusted.'
    fi
elif [ -d /etc/pki/ca-trust/source/anchors ]; then
    if [ "$remove" = --remove ]; then rm -f "/etc/pki/ca-trust/source/anchors/$name"; else cp "$ca" "/etc/pki/ca-trust/source/anchors/$name"; fi
    update-ca-trust && echo "Done: /etc/pki/ca-trust/source/anchors/$name ${remove:+removed}"
elif [ -d /usr/local/share/ca-certificates ]; then
    if [ "$remove" = --remove ]; then rm -f "/usr/local/share/ca-certificates/$name"; else cp "$ca" "/usr/local/share/ca-certificates/$name"; fi
    update-ca-certificates > /dev/null && echo "Done: /usr/local/share/ca-certificates/$name ${remove:+removed}"
else
    echo 'This system keeps its trusted roots somewhere this script does not know.' >&2; exit 1
fi
