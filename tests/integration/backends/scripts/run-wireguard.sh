#!/usr/bin/env bash
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# run-wireguard.sh - the wireguard pack against real kernel WireGuard
# tunnels, with its evidence kept like the other runs'.
#
#   scripts/run-wireguard.sh
#
# It starts compose.wireguard.yaml: a hub with wg0 (three peers: peer1, with
# a preshared key, peer2, and one that never connects) and wg1 (none), and
# peer1 and peer2 in containers of their own. The pack runs in the hub as
# the account vigil, through the sudoers rule its page gives, and what it
# reads is checked; as an account the rule does not cover, it fails and
# says why. Then peer2 stops, and once its last handshake is past 180
# seconds it reads stale. Then tests/integration/service-packs.sh runs the
# pack through Vigil, in the hub as vigil. Every key (private and preshared)
# is looked for in everything the pack and Vigil printed or wrote: none may
# be there. The keys are written to files only, never printed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$here/common.sh"

command -v docker > /dev/null 2>&1 || die 'docker not found: WireGuard runs in containers'
file=compose.wireguard.yaml
work=$(mktemp -d "${TMPDIR:-/tmp}/vigil-wireguard-it.XXXXXX") || exit 1
root=$work/none
export WG_CONF=$work/conf WG_REPO=$bk_repo
c=$WG_CONF
mkdir -p "$c"
dc() { docker compose -p vigil-wireguard --project-directory "$bk_dir" -f "$bk_dir/$file" "$@"; }
trap 'dc down -v > /dev/null 2>&1; evidence_save; rm -rf "$work"' EXIT

dc build -q > "$work/build.log" 2>&1 || { tail -n 20 "$work/build.log"; die 'the image would not build'; }
# The keys, made by wg in the image; written to files only.
for k in hub p1 p2 ghost; do
    docker run --rm vigil-it-wireguard:1 wg genkey > "$c/$k.key" || die 'wg genkey failed'
    docker run --rm -i vigil-it-wireguard:1 wg pubkey < "$c/$k.key" > "$c/$k.pub"
done
docker run --rm vigil-it-wireguard:1 wg genpsk > "$c/p1.psk"
cat "$c"/*.key "$c/p1.psk" > "$c/secrets"
cat > "$c/hub.sh" << EOF
ip link add wg0 type wireguard
wg set wg0 listen-port 51820 private-key /conf/hub.key \\
    peer $(cat "$c/p1.pub") preshared-key /conf/p1.psk allowed-ips 10.9.0.2/32 \\
    peer $(cat "$c/p2.pub") allowed-ips 10.9.0.3/32 \\
    peer $(cat "$c/ghost.pub") allowed-ips 10.9.0.4/32
ip addr add 10.9.0.1/24 dev wg0
ip link set wg0 up
ip link add wg1 type wireguard
wg set wg1 listen-port 51821 private-key /conf/hub.key
ip link set wg1 up
exec sleep infinity
EOF
for n in 1 2; do
    psk=''
    [ "$n" = 1 ] && psk='preshared-key /conf/p1.psk'
    cat > "$c/peer$n.sh" << EOF
ip link add wg0 type wireguard
wg set wg0 private-key /conf/p$n.key peer $(cat "$c/hub.pub") $psk endpoint hub:51820 allowed-ips 10.9.0.0/24 persistent-keepalive 5
ip addr add 10.9.0.$((n + 1))/24 dev wg0
ip link set wg0 up
exec sh -c 'while true; do ping -c 1 -W 1 10.9.0.1 > /dev/null 2>&1; sleep 5; done'
EOF
done
chmod 755 "$c"
chmod 644 "$c"/*
evidence_start pack-wireguard "$bk_dir/$file" "$0" "$@"

dc up -d > "$work/up.log" 2>&1 || { tail -n 20 "$work/up.log"; die 'the tunnels would not start'; }
# Until both peers have completed a handshake (read as root, outside the pack).
for _ in $(seq 1 60); do
    [ "$(dc exec -T hub wg show wg0 latest-handshakes 2> /dev/null | awk '$2 > 0' | wc -l)" -ge 2 ] && break
    sleep 1
done
printf 'wg       %s; %s\n' "$(dc exec -T hub wg --version | cut -d' ' -f1-2)" "$(dc exec -T hub uname -sr)"
echo 'tunnels  hub: wg0 with peer1 (a preshared key), peer2 and one that never connects; wg1 with no peer. peer1 and peer2 ping the hub every 5 s'
echo 'sudo     the hub'"'"'s account vigil may run exactly: wg show interfaces, wg show all latest-handshakes, wg show all transfer'

say() { printf '\n# %s\n' "$*"; }
pass=0
fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s: expected [%s] actual [%s]\n' "$1" "$2" "$3"; fi
}
tagof() { tr -c 'A-Za-z0-9@._:/+\n-' '_' < "$c/$1.pub"; }
# val <out> <metric> [<text>]: the first value whose line holds the text (a
# public key has + and /: matched as text, not a pattern).
val() { awk -v m="$2" -v t="${3-}" '$1 == "metric" && $2 == m && index($0, t) { print $3; exit }' "$work/$1.out"; }
run() {
    printf '\n$ sudo -u %s bash packs/wireguard/linux/peers.sh%s\n' "$2" "${3:+   ($3)}"
    dc exec -T -u "$2" hub bash /repo/packs/wireguard/linux/peers.sh > "$work/$1.out" 2> "$work/$1.err"
    printf 'exit %s\n' "$?" >> "$work/$1.err"
    cat "$work/$1.out"
    grep -v '^exit 0$' "$work/$1.err"
}
# No key, private or preshared, in a file: "none", or the files that hold one.
nokey() { local f; f=$(grep -lF -f "$c/secrets" "$@" 2> /dev/null | tr '\n' ' '); printf '%s' "${f:-none}"; }

say "Both peers up, one never connected, wg1 with none: the pack as vigil, through sudo."
run up vigil
check 'it runs as vigil, through the sudoers rule' 'exit 0' "$(tail -n 1 "$work/up.err")"
check 'two interfaces; three peers on wg0, none on wg1' '2 3 3 0' "$(val up interfaces) $(val up peers) $(val up interface_peers interface=wg0) $(val up interface_peers interface=wg1)"
check 'one never connected, named first; none stale' "1 0 -1 interface=wg0 peer=$(tagof ghost)" "$(val up peers_never) $(val up peers_stale) $(grep -m 1 '^metric handshake_seconds' "$work/up.out" | cut -d' ' -f3-)"
check 'peer1 and peer2: a handshake within the last two minutes' 'yes yes' "$(for p in p1 p2; do awk -v s="$(val up handshake_seconds "peer=$(tagof $p)")" 'BEGIN { print (s >= 0 && s <= 130) ? "yes" : "no [" s "]" }'; done | tr '\n' ' ' | sed 's/ $//')"
check 'peer1 and peer2: bytes each way' 'yes yes' "$(for p in p1 p2; do awk -v r="$(val up rx_bytes_count "peer=$(tagof $p)")" -v t="$(val up tx_bytes_count "peer=$(tagof $p)")" 'BEGIN { print (r > 0 && t > 0) ? "yes" : "no [" r " " t "]" }'; done | tr '\n' ' ' | sed 's/ $//')"
check 'no key in what it printed' none "$(nokey "$work/up.out" "$work/up.err")"

say "As an account the sudoers rule does not cover."
run other other
check 'it fails, and says which rule to add' 'exit 1 yes' "$(tail -n 1 "$work/other.err") $(grep -q 'add the sudoers rule in packs/wireguard/README.md' "$work/other.err" && echo yes || echo no)"

say "peer2 stops. A peer that talks completes a handshake every two minutes; once peer2's last is past 180 seconds, it is stale."
dc stop peer2 > /dev/null 2>&1
for _ in $(seq 1 80); do
    dc exec -T -u vigil hub bash /repo/packs/wireguard/linux/peers.sh > "$work/stale.out" 2> /dev/null
    [ "$(val stale peers_stale)" = 1 ] && break
    sleep 5
done
run stale vigil 'peer2 stopped'
check 'peer2 stale, past 180 seconds; peer1 not' "1 yes yes" "$(val stale peers_stale) $(awk -v s="$(val stale handshake_seconds "peer=$(tagof p2)")" 'BEGIN { print (s > 180) ? "yes" : "no [" s "]" }') $(awk -v s="$(val stale handshake_seconds "peer=$(tagof p1)")" 'BEGIN { print (s >= 0 && s <= 180) ? "yes" : "no [" s "]" }')"
check 'the order: never first, then the longest quiet (peer2), then peer1' "$(tagof ghost) $(tagof p2) $(tagof p1)" "$(grep '^metric handshake_seconds' "$work/stale.out" | sed 's/.*peer=//' | tr '\n' ' ' | sed 's/ $//')"
check 'no key in what it printed' none "$(nokey "$work/stale.out" "$work/stale.err")"

say "The pack through Vigil, in the hub as vigil."
dc exec -T -u vigil -e VIGIL_IT_WIREGUARD=1 -e VIGIL_IT_WIREGUARD_SECRETS=/conf/secrets hub bash /repo/tests/integration/service-packs.sh
rc=$?

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$rc" -eq 0 ]
