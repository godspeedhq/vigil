#Requires -Version 5.1

<#
.SYNOPSIS
    storage.ps1 - an OpenBao or Vault node's Raft cluster and storage, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports, from the node's metrics, whether it is active, its Raft cluster's
    health as autopilot sees it (on the active node): healthy or not, how many
    nodes it may lose, the nodes and those unhealthy, named; the peers, the
    followers' lag, the time since a follower last heard from the leader,
    leadership lost; and how long Raft commits and storage reads and writes
    take. It only reads: every request is a GET, and it changes nothing.

    Reads OPENBAO_URL (default http://localhost:8200):
    /v1/sys/metrics?format=prometheus, with OPENBAO_TOKEN.
    What the scripts share is in _openbao.ps1, beside this one.

    Metrics:
      up                             1 when OpenBao answered its metrics page,
                                     else 0 (and nothing more is read)
      active                         1 for the active node
      autopilot_healthy              1 when autopilot finds every node healthy
                                     (the active node reports it)
      failure_tolerance              nodes the cluster may lose and keep quorum
      nodes                          nodes autopilot knows
      nodes_unhealthy                of them, unhealthy (sealed, stopped or
                                     behind)
      node_unhealthy                 each node: 1 when unhealthy, tagged
                                     node=<its node_id>
      node_unhealthy_not_shown       how many more there were than the 20 shown
      raft_peers                     the Raft cluster's peers
      follower_lag_max               the follower furthest behind the leader, in
                                     log entries (the active node reports it)
      leader_contact_avg_ms          how long since a follower last heard from
                                     the leader, on average (on a standby)
      commit_avg_ms                  a Raft commit, on average, in milliseconds
                                     (on the active node)
      leadership_lost_count          times this node lost leadership (a running
                                     total)
      leadership_setup_failed_count  times it failed to take leadership (a
                                     running total)
      storage_reads_count            storage reads (a running total)
      storage_read_avg_ms            a storage read, on average, in milliseconds
      storage_writes_count           storage writes (a running total)
      storage_write_avg_ms           a storage write, on average, in
                                     milliseconds

    Example output (the rest are in the same form):
      metric up 1
      metric active 1
      metric autopilot_healthy 1
      metric failure_tolerance 1
      metric nodes 3
      metric nodes_unhealthy 0
      metric node_unhealthy 0 node=o1
      metric node_unhealthy 0 node=o2
      metric node_unhealthy 0 node=o3
      metric raft_peers 3
      metric follower_lag_max 0
      metric leader_contact_avg_ms 43.75
      metric commit_avg_ms 17.960183
      metric storage_reads_count 215
      metric storage_read_avg_ms 0.024136
      metric storage_writes_count 127
      metric storage_write_avg_ms 34.347212

    Reading the results (starting points: tune them to your own):
      Healthy  autopilot_healthy 1; nodes_unhealthy 0; failure_tolerance 1 or
               more (a cluster of three or five).
      Watch    failure_tolerance 0: one more node lost and the cluster stops;
               follower_lag_max growing; storage_write_avg_ms or commit_avg_ms
               rising: slow disks.
      Act      autopilot_healthy 0: node_unhealthy names the node (sealed after
               a restart, stopped, or cut off); leadership_lost_count moving
               with no one stepping it down.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when OpenBao does not answer (up 0 is
      the reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'storage'
. (Join-Path $PSScriptRoot '_openbao.ps1')

Read-Page '/v1/sys/metrics?format=prometheus'
Get-Readings @'
active|max?|vault_core_active
autopilot_healthy|max?|vault_autopilot_healthy
failure_tolerance|max?|vault_autopilot_failure_tolerance
nodes|count?|vault_autopilot_node_healthy
nodes_unhealthy|count?|vault_autopilot_node_healthy||=0
node_unhealthy|countby?|vault_autopilot_node_healthy||node_id:node =0
raft_peers|max?|vault_raft_peers
follower_lag_max|max?|vault_raft_storage_follower_applied_index_delta
_lc_s|sum?|vault_raft_leader_lastContact_sum
_lc_n|sum?|vault_raft_leader_lastContact_count
leader_contact_avg_ms|div|_lc_s|_lc_n
_ct_s|sum?|vault_raft_commitTime_sum
_ct_n|sum?|vault_raft_commitTime_count
commit_avg_ms|div|_ct_s|_ct_n
leadership_lost_count|sum?|vault_core_leadership_lost_count
leadership_setup_failed_count|sum?|vault_core_leadership_setup_failed_count
storage_reads_count|sum|vault_barrier_get_count
_bg_s|sum|vault_barrier_get_sum
storage_read_avg_ms|div|_bg_s|storage_reads_count
storage_writes_count|sum|vault_barrier_put_count
_bp_s|sum|vault_barrier_put_sum
storage_write_avg_ms|div|_bp_s|storage_writes_count
'@
exit 0
