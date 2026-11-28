#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - is this OpenBao or Vault node sealed, and active or standby, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether the node answers, whether it is initialized and sealed, how
    far an unseal has got, whether it is active, a standby or a performance
    standby, whether it knows its cluster's leader, and how far its Raft log is
    applied. It needs no token: these pages answer anyone, sealed or not. It
    only reads: every request is a GET, and it changes nothing.

    Reads OPENBAO_URL (default http://localhost:8200): /v1/sys/health,
    /v1/sys/seal-status and /v1/sys/leader, with no token.
    What the scripts share is in _openbao.ps1, beside this one.

    Metrics:
      up                   1 when the node answered, else 0
      info                 always 1, tagged product=<openbao or vault>,
                           version=, seal=<shamir, awskms, transit ...> and
                           storage=<raft, consul, file ...>
      initialized          1 when it is initialized
      sealed               1 when it is sealed: it serves nothing until it is
                           unsealed
      standby              1 for a standby: it sends requests to the active node
      performance_standby  1 for a performance standby (Vault Enterprise)
      unseal_threshold     keys needed to unseal it
      unseal_shares        keys there are
      unseal_progress      keys given so far toward an unseal
      ha_enabled           1 when high availability is on (unsealed only, as the
                           rest)
      active               1 for the active node
      leader_known         1 when it knows the active node
      raft_apply_lag       Raft entries committed and not yet applied

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your own):
      Healthy  up 1; initialized 1; sealed 0; one node of the cluster active 1,
               the others standby 1; leader_known 1.
      Watch    unseal_progress above 0 for long: an unseal started and not
               finished; raft_apply_lag growing.
      Act      sealed 1: the node serves nothing (after a restart, a Shamir seal
               needs its keys again); no node active 1: the cluster has no
               active node; leader_known 0 on an unsealed standby; initialized 0
               on a node that should have data.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0, whatever it reads, and when OpenBao does not answer (up 0 is
      the reading); 1 when it answers wrong (a login refused, not HTTP), said on
      stderr
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_openbao.ps1')

# Three pages that answer with no token, and in every state: health (asked
# to answer 200 whatever the state, so its answer can be read), the seal's
# status, and, unsealed, the leader.
$r = Get-Answer '/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&standbycode=200&performancestandbycode=200&drsecondarycode=200&removedcode=200'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/v1/sys/health: no such page (HTTP 404): is OPENBAO_URL OpenBao's address?"); exit 0 }
    default { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($r.Why)"); exit 1 }
}
function One($v) { if ($v -eq $true) { 1 } else { 0 } }
$h = $r.Body | ConvertFrom-Json
$product = if ($r.Body -match '"enterprise"') { 'vault' } else { 'openbao' }
$s = $null
$sr = Get-Answer '/v1/sys/seal-status'
if ($sr.State -eq 'ok') { $s = $sr.Body | ConvertFrom-Json }
Write-Output "metric info 1 product=$product version=$(Safe $h.version) seal=$(Safe $(if ($s) { $s.type })) storage=$(Safe $(if ($s) { $s.storage_type }))"
Write-Output "metric initialized $(One $h.initialized)"
Write-Output "metric sealed $(One $h.sealed)"
Write-Output "metric standby $(One $h.standby)"
Write-Output "metric performance_standby $(One $h.performance_standby)"
if ($s) {
    Write-Output "metric unseal_threshold $($s.t)"
    Write-Output "metric unseal_shares $($s.n)"
    Write-Output "metric unseal_progress $($s.progress)"
}
if ($h.sealed -eq $true) { exit 0 }
$lr = Get-Answer '/v1/sys/leader'
if ($lr.State -eq 'ok') {
    $l = $lr.Body | ConvertFrom-Json
    Write-Output "metric ha_enabled $(One $l.ha_enabled)"
    Write-Output "metric active $(One $l.is_self)"
    Write-Output "metric leader_known $(if ([string]$l.leader_address) { 1 } else { 0 })"
    if ($null -ne $l.raft_committed_index -and $null -ne $l.raft_applied_index) {
        Write-Output "metric raft_apply_lag $([long]$l.raft_committed_index - [long]$l.raft_applied_index)"
    }
}
exit 0
