#!/usr/bin/env bash
#
# peers.sh - WireGuard: each interface's peers, how long since each last
# completed a handshake, and the bytes each sent and received
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
# Reports the WireGuard interfaces on this machine, their peers, and for each
# peer how long since its last handshake and the bytes it sent and received.
# A peer that is talking completes a handshake at least every two minutes;
# one whose last handshake is older than WG_STALE_SECONDS (180 by default)
# is stale: it stopped talking, or cannot. One that never completed one has
# never connected.
#
# It never reads a key: it runs only "wg show interfaces", "wg show all
# latest-handshakes" and "wg show all transfer", none of which prints a
# private or preshared key. A peer is named by its public key, which is not
# secret (every peer of it has it). Those commands need root: as another
# account (Vigil's, on Linux) it runs them with sudo -n, which a sudoers
# rule allows for exactly those three (packs/wireguard/README.md).
#
# Metrics:
#   interfaces           WireGuard interfaces on this machine
#   peers                their peers, all together
#   peers_stale          of them, those whose last handshake is older than
#                        WG_STALE_SECONDS
#   peers_never          those that never completed a handshake
#   interface_peers      one interface's peers, tagged interface=<its name>
#   handshake_seconds    since a peer's last handshake (-1: never), tagged
#                        interface= and peer=<its public key>, the 20 that
#                        have been quiet longest (never first)
#   rx_bytes_count       bytes received from that peer (a running total,
#                        since the interface came up)
#   tx_bytes_count       bytes sent to that peer (a running total)
#   peers_not_shown      peers past the 20 shown
#
# Example output (the rest are in the same form):
#   metric interfaces 2
#   metric peers 3
#   metric peers_stale 1
#   metric peers_never 1
#   metric interface_peers 3 interface=wg0
#   metric interface_peers 0 interface=wg1
#   metric handshake_seconds -1 interface=wg0 peer=EcNI0FIB9H+Bywnzgiuofm6zINvEaqLn53mfVx8LxiA_
#   metric handshake_seconds 183 interface=wg0 peer=QzJ87q6To1z9+J1R/IGGXhQ2XzqFx8gBqucMerPInnk_
#   metric rx_bytes_count 564 interface=wg0 peer=QzJ87q6To1z9+J1R/IGGXhQ2XzqFx8gBqucMerPInnk_
#   metric tx_bytes_count 3436 interface=wg0 peer=QzJ87q6To1z9+J1R/IGGXhQ2XzqFx8gBqucMerPInnk_
#   metric peers_not_shown 0
#
# Reading the results (starting points: tune them to your peers):
#   Healthy  peers_stale 0 for peers that should always be up (with
#            PersistentKeepalive, they handshake every two minutes even when
#            idle); peers_never 0.
#   Watch    a peer's handshake_seconds above WG_STALE_SECONDS when it
#            should be talking: it is down, or something between drops its
#            packets; peers_never above 0 for a peer just added.
#   Act      peers_stale for a peer that carries traffic (a site link, a
#            server's tunnel): the tunnel is down; interfaces lower than
#            expected: an interface is gone.
#
# Requires: bash, awk, wg (wireguard-tools); as an account that is not root,
#   sudo and the rule in packs/wireguard/README.md
# Exit code: 0, whatever the peers; 1 when wg is missing, or may not be run
#   as root (it says which)
#
# Example (vigil.config):
#   [job.wireguard_peers]
#   file        = packs/wireguard/peers.sh
#   metric_name = wireguard
#   run_every   = 1m
#   env         = WG_STALE_SECONDS=180

set -u

job=peers
stale=${WG_STALE_SECONDS:-180}
case $stale in '' | *[!0-9]*) stale=180 ;; esac
wg=$(command -v wg) || { echo "$job: wg not found: install wireguard-tools" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-wireguard.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
now=$(date +%s)

# show <args>: wg show, as root: itself when it is root, else with sudo -n
# (no password asked: the sudoers rule allows exactly these).
if [ "$(id -u)" = 0 ]; then
    show() { "$wg" show "$@"; }
else
    show() { sudo -n "$wg" show "$@"; }
fi
for a in interfaces 'all latest-handshakes' 'all transfer'; do
    # shellcheck disable=SC2086
    if ! show $a > "$work/${a##* }" 2> "$work/err"; then
        if [ "$(id -u)" != 0 ] && grep -qi 'sudo\|password\|not allowed\|permission' "$work/err"; then
            echo "$job: may not run \"wg show $a\" as root: add the sudoers rule in packs/wireguard/README.md" >&2
        else
            echo "$job: wg show $a: $(head -n 1 "$work/err")" >&2
        fi
        exit 1
    fi
done

# The interfaces, one a line; then each peer: interface, public key, last
# handshake (0: never), received, sent.
tr ' \t' '\n\n' < "$work/interfaces" | grep -v '^$' > "$work/ifs"
awk -F'\t' 'NR == FNR { rx[$1 FS $2] = $3; tx[$1 FS $2] = $4; next } { print $1, $2, $3, rx[$1 FS $2] + 0, tx[$1 FS $2] + 0 }' \
    "$work/transfer" "$work/latest-handshakes" > "$work/peers"

awk -v now="$now" -v stale="$stale" -v ifs="$work/ifs" '
    function tag(s) { gsub(/[^A-Za-z0-9@._:\/+-]/, "_", s); return substr(s, 1, 120) }
    BEGIN { while ((getline i < ifs) > 0) { order[++ni] = i; count[i] = 0 } }
    {
        n++
        count[$1]++
        age = ($3 == 0) ? -1 : now - $3
        if (age < 0 && $3 != 0) age = 0
        if ($3 == 0) never++
        else if (age > stale) old++
        # Never first, then the longest quiet.
        key[n] = ($3 == 0) ? 1e18 : age
        line[n] = sprintf("metric handshake_seconds %d interface=%s peer=%s\nmetric rx_bytes_count %d interface=%s peer=%s\nmetric tx_bytes_count %d interface=%s peer=%s",
            age, tag($1), tag($2), $4, tag($1), tag($2), $5, tag($1), tag($2))
    }
    END {
        printf "metric interfaces %d\n", ni
        printf "metric peers %d\n", n
        printf "metric peers_stale %d\n", old
        printf "metric peers_never %d\n", never
        for (i = 1; i <= ni; i++) printf "metric interface_peers %d interface=%s\n", count[order[i]], tag(order[i])
        for (k = 1; k <= 20 && k <= n; k++) {
            best = 0
            for (j = 1; j <= n; j++) if (!(j in done) && (best == 0 || key[j] > key[best])) best = j
            done[best] = 1
            print line[best]
        }
        printf "metric peers_not_shown %d\n", (n > 20 ? n - 20 : 0)
    }' "$work/peers"
exit 0
