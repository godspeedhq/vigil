#!/usr/bin/env bash
#
# tls.sh - the certificates Apache httpd serves
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
# Makes a TLS handshake with each of Apache httpd's https endpoints and
# reports the certificate it serves: the days until it expires, whether it is
# within its dates, and whether it checks against the trusted CAs and the name
# asked for. It reads what clients get, so it also catches a certificate
# renewed on disk that Apache httpd has not loaded yet. Nothing is sent but
# the handshake. It only reads: it changes nothing.
#
# HTTPD_TLS lists the endpoints, separated by spaces: host:port, or
# host:port/name to ask for a name (SNI) other than the host (default
# localhost:443). HTTPD_CACERT, a CA file, checks a private CA.
# What the scripts share is in _httpd.sh, beside this one.
#
# Metrics:
#   tls_up             1 when the endpoint finished a TLS handshake, else 0;
#                      tagged endpoint=<host:port, or host:port/name>
#   cert_expires_days  days until the certificate it served expires (below 0:
#                      expired), tagged endpoint
#   cert_valid         1 when today is within its dates, else 0, tagged
#                      endpoint
#   cert_verified      1 when it checks against the trusted CAs (or
#                      HTTPD_CACERT) and the name, else 0; tagged endpoint and
#                      reason=<openssl's, or Windows' word>
#   cert_info          always 1, tagged endpoint, issuer=<its CN> and
#                      protocol=<the TLS version agreed>
#   certs_not_shown    endpoints past the first 50, left out
#
# Example output (the rest are in the same form):
#   metric tls_up 1 endpoint=localhost:18243
#   metric cert_expires_days 299 endpoint=localhost:18243
#   metric cert_valid 1 endpoint=localhost:18243
#   metric cert_verified 0 endpoint=localhost:18243 reason=self-signed_certificate
#   metric cert_info 1 endpoint=localhost:18243 issuer=localhost protocol=TLSv1.3
#   metric tls_up 1 endpoint=localhost:18143
#   metric cert_expires_days 4 endpoint=localhost:18143
#   metric cert_valid 1 endpoint=localhost:18143
#   metric cert_verified 1 endpoint=localhost:18143 reason=ok
#   metric cert_info 1 endpoint=localhost:18143 issuer=vigil_web_test_CA protocol=TLSv1.3
#
# Reading the results (starting points: tune them to the server):
#   Healthy  tls_up 1; cert_expires_days above 30; cert_valid 1; cert_verified
#            1.
#   Watch    cert_expires_days below 30: renewal should have happened by now.
#   Act      cert_expires_days below 7, or cert_valid 0: clients will refuse
#            it; cert_verified 0: clients that check (all browsers) refuse it
#            now (reason says why); tls_up 0: nothing answers TLS there.
#
# Requires: bash, openssl
# Exit code: 0, whatever the certificates; 1 if openssl is missing

set -u

job=tls
# shellcheck source=/dev/null
. "$(dirname "$0")/_httpd.sh"
needs openssl

read -r -a list <<< "${HTTPD_TLS:-localhost:443}"
certs ${list[@]+"${list[@]}"}
exit 0
