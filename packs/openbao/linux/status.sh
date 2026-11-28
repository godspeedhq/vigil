#!/usr/bin/env bash
#
# status.sh - is this OpenBao or Vault node sealed, and active or standby
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
# Reports whether the node answers, whether it is initialized and sealed, how
# far an unseal has got, whether it is active, a standby or a performance
# standby, whether it knows its cluster's leader, and how far its Raft log is
# applied. It needs no token: these pages answer anyone, sealed or not. It
# only reads: every request is a GET, and it changes nothing.
#
# Reads OPENBAO_URL (default http://localhost:8200): /v1/sys/health,
# /v1/sys/seal-status and /v1/sys/leader, with no token.
# What the scripts share is in _openbao.sh, beside this one.
#
# Metrics:
#   up                   1 when the node answered, else 0
#   info                 always 1, tagged product=<openbao or vault>,
#                        version=, seal=<shamir, awskms, transit ...> and
#                        storage=<raft, consul, file ...>
#   initialized          1 when it is initialized
#   sealed               1 when it is sealed: it serves nothing until it is
#                        unsealed
#   standby              1 for a standby: it sends requests to the active node
#   performance_standby  1 for a performance standby (Vault Enterprise)
#   unseal_threshold     keys needed to unseal it
#   unseal_shares        keys there are
#   unseal_progress      keys given so far toward an unseal
#   ha_enabled           1 when high availability is on (unsealed only, as the
#                        rest)
#   active               1 for the active node
#   leader_known         1 when it knows the active node
#   raft_apply_lag       Raft entries committed and not yet applied
#
# Example output (the rest are in the same form):
#   metric up 1
#   metric info 1 product=openbao version=2.7.3 seal=shamir storage=raft
#   metric initialized 1
#   metric sealed 0
#   metric standby 0
#   metric performance_standby 0
#   metric unseal_threshold 2
#   metric unseal_shares 3
#   metric unseal_progress 0
#   metric ha_enabled 1
#   metric active 1
#   metric leader_known 1
#   metric raft_apply_lag 0
#
# Reading the results (starting points: tune them to your own):
#   Healthy  up 1; initialized 1; sealed 0; one node of the cluster active 1,
#            the others standby 1; leader_known 1.
#   Watch    unseal_progress above 0 for long: an unseal started and not
#            finished; raft_apply_lag growing.
#   Act      sealed 1: the node serves nothing (after a restart, a Shamir seal
#            needs its keys again); no node active 1: the cluster has no
#            active node; leader_known 0 on an unsealed standby; initialized 0
#            on a node that should have data.
#
# Requires: bash, curl
# Exit code: 0, whatever it reads, and when OpenBao does not answer (up 0 is
#   the reading); 1 when it answers wrong (not HTTP), said on stderr, or curl
#   is missing

set -u

job=status
# shellcheck source=/dev/null
. "$(dirname "$0")/_openbao.sh"
needs curl

# Three pages that answer with no token, and in every state: health (asked
# to answer 200 whatever the state, so its answer can be read), the seal's
# status, and, unsealed, the leader.
# jf <file> <key>: a key's value in flat JSON: true, false, a number or a string.
jf() { tr -d '\n' < "$1" | sed -n 's/.*[{,] *"'"$2"'" *: *"\{0,1\}\([^",}]*\)"\{0,1\} *[,}].*/\1/p' | head -n 1; }
yes1() { [ "$1" = true ] && echo 1 || echo 0; }
get '/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&standbycode=200&performancestandbycode=200&drsecondarycode=200&removedcode=200' health
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/v1/sys/health: no such page (HTTP 404): is OPENBAO_URL OpenBao's address?" >&2; exit 0 ;;
    *) echo "metric up 0"; exit 1 ;;
esac
h=$work/health
sealed=$(yes1 "$(jf "$h" sealed)")
product=openbao
grep -q '"enterprise"' "$h" && product=vault
seal_type='' storage=''
if get '/v1/sys/seal-status' seal; then
    seal_type=$(jf "$work/seal" type)
    storage=$(jf "$work/seal" storage_type)
fi
echo "metric info 1 product=$product version=$(tag "$(jf "$h" version)") seal=$(tag "$seal_type") storage=$(tag "$storage")"
echo "metric initialized $(yes1 "$(jf "$h" initialized)")"
echo "metric sealed $sealed"
echo "metric standby $(yes1 "$(jf "$h" standby)")"
echo "metric performance_standby $(yes1 "$(jf "$h" performance_standby)")"
if [ -s "$work/seal" ]; then
    echo "metric unseal_threshold $(jf "$work/seal" t)"
    echo "metric unseal_shares $(jf "$work/seal" n)"
    echo "metric unseal_progress $(jf "$work/seal" progress)"
fi
[ "$sealed" = 1 ] && exit 0
if get '/v1/sys/leader' leader; then
    l=$work/leader
    echo "metric ha_enabled $(yes1 "$(jf "$l" ha_enabled)")"
    echo "metric active $(yes1 "$(jf "$l" is_self)")"
    [ -n "$(jf "$l" leader_address)" ] && echo "metric leader_known 1" || echo "metric leader_known 0"
    c=$(jf "$l" raft_committed_index)
    a=$(jf "$l" raft_applied_index)
    [ -n "$c" ] && [ -n "$a" ] && echo "metric raft_apply_lag $((c - a))"
fi
exit 0
