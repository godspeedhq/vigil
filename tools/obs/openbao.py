# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
"""The openbao pack's jobs (tools/obs/DESIGN.md): OpenBao, and HashiCorp
Vault, which answer the same paths and publish the same metrics."""
from jobs import job, page, table, code

PACK = dict(
    P='OpenBao', E='OPENBAO', url='http://localhost:8200', version='1.0.0',
    description='OpenBao and HashiCorp Vault: sealed or not, initialized, active or standby, the unseal progress, '
                'HA and the Raft cluster (autopilot, failure tolerance, nodes unhealthy, followers behind), storage '
                'latency, leases and irrevocable ones, logins that failed and users locked out, responses refused, '
                'audit devices that failed',
    works='OpenBao 2.x and HashiCorp Vault 1.15 and later, one node or an HA cluster (tested: OpenBao 2.7.3 and '
          'Vault 2.2.2, each a Raft cluster of three)',
    head=['openbao - an OpenBao or HashiCorp Vault node, from what it says about',
          'itself: is it sealed, initialized, active or standby, is its Raft',
          'cluster healthy and how many nodes may it lose, how many leases does it',
          'hold, and do logins fail.'],
    needs=['its address, where it is not http://localhost:8200: env = OPENBAO_URL=... on each job (https, and '
           'OPENBAO_CACERT when its CA is not one the system trusts)',
           'for the storage, leases and requests jobs, its metrics: telemetry { prometheus_retention_time = "24h" } '
           'in its configuration, and a token that may read sys/metrics (secret = OPENBAO_TOKEN=secret:OPENBAO_TOKEN; '
           'packs/openbao/README.md has the policy), or unauthenticated_metrics_access = true on the listener',
           'on a Vault standby, unauthenticated_metrics_access = true: Vault sends a standby\'s sys/metrics to the '
           'active node (HTTP 307) otherwise. The status job needs neither',
           "on each node: each reports itself; for its CPU and memory: the base pack's processes job"])

READS = "Reads @E@_URL (default @URL@): /v1/sys/metrics?format=prometheus, with @E@_TOKEN"

HEALTH = ('/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&standbycode=200'
          '&performancestandbycode=200&drsecondarycode=200&removedcode=200')

STATUS_SH = r'''# Three pages that answer with no token, and in every state: health (asked
# to answer 200 whatever the state, so its answer can be read), the seal's
# status, and, unsealed, the leader.
# jf <file> <key>: a key's value in flat JSON: true, false, a number or a string.
jf() { tr -d '\n' < "$1" | sed -n 's/.*[{,] *"'"$2"'" *: *"\{0,1\}\([^",}]*\)"\{0,1\} *[,}].*/\1/p' | head -n 1; }
yes1() { [ "$1" = true ] && echo 1 || echo 0; }
get '@HEALTH@' health
case $? in
    0) echo "metric up 1" ;;
    2 | 5) echo "metric up 0"; exit 0 ;;
    3) echo "metric up 0"; echo "$job: $url/v1/sys/health: no such page (HTTP 404): is @E@_URL @P@'s address?" >&2; exit 0 ;;
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
'''.replace('@HEALTH@', HEALTH)

STATUS_PS = r'''# Three pages that answer with no token, and in every state: health (asked
# to answer 200 whatever the state, so its answer can be read), the seal's
# status, and, unsealed, the leader.
$r = Get-Answer '@HEALTH@'
switch ($r.State) {
    'ok' { Write-Output 'metric up 1' }
    'down' { Write-Output 'metric up 0'; exit 0 }
    'notready' { Write-Output 'metric up 0'; exit 0 }
    'missing' { Write-Output 'metric up 0'; [Console]::Error.WriteLine("${Job}: $($script:Url)/v1/sys/health: no such page (HTTP 404): is @E@_URL @P@'s address?"); exit 0 }
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
'''.replace('@HEALTH@', HEALTH)

job(pack='openbao', job='status', metric='', when='run_every   = 1m', runtime='30s',
    title='is this OpenBao or Vault node sealed, and active or standby',
    what="Reports whether the node answers, whether it is initialized and sealed, how far an unseal has got, "
         "whether it is active, a standby or a performance standby, whether it knows its cluster's leader, and "
         "how far its Raft log is applied. It needs no token: these pages answer anyone, sealed or not.",
    reads="Reads @E@_URL (default @URL@): /v1/sys/health, /v1/sys/seal-status and /v1/sys/leader, with no token.",
    needs_sh=['curl'],
    exit_sh="0, whatever it reads, and when @P@ does not answer (up 0 is the reading); 1 when it answers wrong "
            "(not HTTP), said on stderr, or curl is missing",
    steps=[code(STATUS_SH, STATUS_PS, [
        ('up', '1 when the node answered, else 0'),
        ('info', 'always 1, tagged product=<openbao or vault>, version=, seal=<shamir, awskms, transit ...> and storage=<raft, consul, file ...>'),
        ('initialized', '1 when it is initialized'),
        ('sealed', '1 when it is sealed: it serves nothing until it is unsealed'),
        ('standby', '1 for a standby: it sends requests to the active node'),
        ('performance_standby', '1 for a performance standby (Vault Enterprise)'),
        ('unseal_threshold', 'keys needed to unseal it'),
        ('unseal_shares', 'keys there are'),
        ('unseal_progress', 'keys given so far toward an unseal'),
        ('ha_enabled', '1 when high availability is on (unsealed only, as the rest)'),
        ('active', '1 for the active node'),
        ('leader_known', '1 when it knows the active node'),
        ('raft_apply_lag', 'Raft entries committed and not yet applied'),
    ])],
    healthy='up 1; initialized 1; sealed 0; one node of the cluster active 1, the others standby 1; leader_known 1.',
    watch='unseal_progress above 0 for long: an unseal started and not finished; raft_apply_lag growing.',
    act='sealed 1: the node serves nothing (after a restart, a Shamir seal needs its keys again); no node active 1: '
        'the cluster has no active node; leader_known 0 on an unsealed standby; initialized 0 on a node that should '
        'have data.')

job(pack='openbao', job='storage', metric='storage', when='run_every   = 1m', runtime='30s', secrets=['@E@_TOKEN'],
    title="an OpenBao or Vault node's Raft cluster and storage",
    what="Reports, from the node's metrics, whether it is active, its Raft cluster's health as autopilot sees it "
         "(on the active node): healthy or not, how many nodes it may lose, the nodes and those unhealthy, named; "
         "the peers, the followers' lag, the time since a follower last heard from the leader, leadership lost; and "
         "how long Raft commits and storage reads and writes take.",
    reads=READS + ".",
    steps=[
        page('/v1/sys/metrics?format=prometheus'),
        table(
            ('active|max?|vault_core_active', '1 for the active node'),
            ('autopilot_healthy|max?|vault_autopilot_healthy', "1 when autopilot finds every node healthy (the active node reports it)"),
            ('failure_tolerance|max?|vault_autopilot_failure_tolerance', 'nodes the cluster may lose and keep quorum'),
            ('nodes|count?|vault_autopilot_node_healthy', 'nodes autopilot knows'),
            ('nodes_unhealthy|count?|vault_autopilot_node_healthy||=0', 'of them, unhealthy (sealed, stopped or behind)'),
            ('node_unhealthy|countby?|vault_autopilot_node_healthy||node_id:node =0', 'each node: 1 when unhealthy, tagged node=<its node_id>'),
            ('raft_peers|max?|vault_raft_peers', "the Raft cluster's peers"),
            ('follower_lag_max|max?|vault_raft_storage_follower_applied_index_delta', 'the follower furthest behind the leader, in log entries (the active node reports it)'),
            ('_lc_s|sum?|vault_raft_leader_lastContact_sum', None),
            ('_lc_n|sum?|vault_raft_leader_lastContact_count', None),
            ('leader_contact_avg_ms|div|_lc_s|_lc_n', 'how long since a follower last heard from the leader, on average (on a standby)'),
            ('_ct_s|sum?|vault_raft_commitTime_sum', None),
            ('_ct_n|sum?|vault_raft_commitTime_count', None),
            ('commit_avg_ms|div|_ct_s|_ct_n', 'a Raft commit, on average, in milliseconds (on the active node)'),
            ('leadership_lost_count|sum?|vault_core_leadership_lost_count', 'times this node lost leadership (a running total)'),
            ('leadership_setup_failed_count|sum?|vault_core_leadership_setup_failed_count', 'times it failed to take leadership (a running total)'),
            ('storage_reads_count|sum|vault_barrier_get_count', 'storage reads (a running total)'),
            ('_bg_s|sum|vault_barrier_get_sum', None),
            ('storage_read_avg_ms|div|_bg_s|storage_reads_count', 'a storage read, on average, in milliseconds'),
            ('storage_writes_count|sum|vault_barrier_put_count', 'storage writes (a running total)'),
            ('_bp_s|sum|vault_barrier_put_sum', None),
            ('storage_write_avg_ms|div|_bp_s|storage_writes_count', 'a storage write, on average, in milliseconds'),
        ),
    ],
    healthy='autopilot_healthy 1; nodes_unhealthy 0; failure_tolerance 1 or more (a cluster of three or five).',
    watch='failure_tolerance 0: one more node lost and the cluster stops; follower_lag_max growing; storage_write_avg_ms '
          'or commit_avg_ms rising: slow disks.',
    act='autopilot_healthy 0: node_unhealthy names the node (sealed after a restart, stopped, or cut off); '
        'leadership_lost_count moving with no one stepping it down.')

job(pack='openbao', job='leases', metric='leases', when='run_every   = 5m', runtime='30s', secrets=['@E@_TOKEN'],
    title='the leases and tokens an OpenBao or Vault node holds',
    what="Reports the leases the node holds and those it could not revoke, the tokens created and by which auth "
         "method, and the mounts. Leases that grow without end make every restart and every failover slower; "
         "irrevocable ones are secrets that should have been revoked and were not. The active node holds them: on "
         "a standby these read 0.",
    reads=READS + ".",
    steps=[
        page('/v1/sys/metrics?format=prometheus'),
        table(
            ('leases|max|vault_expire_num_leases', 'leases held, tokens\' included'),
            ('irrevocable_leases|max?|vault_expire_num_irrevocable_leases', 'leases it tried to revoke and could not'),
            ('tokens_created_count|sum?|vault_token_creation', 'tokens created (a running total)'),
            ('tokens_created|by|vault_token_creation||auth_method:method', 'the same, for each auth method, tagged method=<token, userpass, approle, kubernetes ...>'),
            ('tokens|max?|vault_token_count', 'tokens (Vault, every usage_gauge_period: 10 minutes by default)'),
            ('mounts|sum?|vault_core_mount_table_num_entries', 'mounts: secrets engines and auth methods'),
        ),
    ],
    healthy='leases steady with the workload; irrevocable_leases 0.',
    watch='leases growing day after day: long TTLs, or clients that log in again and again without reusing their '
          'token (tokens_created says by which method).',
    act='irrevocable_leases above 0: credentials it could not revoke, in a database or a cloud account, still work: '
        'find them (sys/leases) and revoke them where they live; leases in the hundreds of thousands: restarts and '
        'failovers slow down, and storage grows.')

job(pack='openbao', job='requests', metric='requests', when='run_every   = 1m', runtime='30s', secrets=['@E@_TOKEN'],
    title='the requests and logins an OpenBao or Vault node handled, and those that failed',
    what="Reports the requests the node handled and those in flight, the logins and those that failed (a login "
         "that created no token), the users locked out after too many failures, the responses refused for each "
         "class of status (Vault), and requests its audit devices failed to log: when every audit device fails, it "
         "refuses requests.",
    reads=READS + ".",
    steps=[
        page('/v1/sys/metrics?format=prometheus'),
        table(
            ('requests_count|sum?|vault_core_handle_request_count', 'requests handled (a running total)'),
            ('in_flight|max?|vault_core_in_flight_requests', 'requests being handled now'),
            ('logins_count|sum|vault_core_handle_login_request_count', 'login requests (a running total)'),
            ('logins_ok_count|sum|vault_token_creation|auth_method!=token', 'of them, those that created a token (a running total)'),
            ('logins_failed_count|sub|logins_count|logins_ok_count', 'those that did not: a wrong password, a role unknown, a user locked out (a running total)'),
            ('locked_users|max?|vault_core_locked_users', 'users locked out after too many failed logins (updated every few minutes)'),
            ('responses_4xx_count|sum?|vault_core_response_status_code|type=4xx', 'responses refused, 4xx (Vault; a running total)'),
            ('permission_denied_count|sum?|vault_core_response_status_code|code=403', 'of them, 403: a token without the policy, or a user locked out (Vault)'),
            ('responses_5xx_count|sum?|vault_core_response_status_code|type=5xx', 'responses that failed, 5xx (Vault; a running total)'),
            ('audit_request_failures_count|sum?|vault_audit_log_request_failure', 'requests an audit device failed to log (a running total)'),
            ('audit_response_failures_count|sum?|vault_audit_log_response_failure', 'responses an audit device failed to log (a running total)'),
        ),
    ],
    healthy='logins_failed_count rising slowly, if at all; locked_users 0; the audit failure counts flat.',
    watch='logins_failed_count rising: a client with a stale secret, or someone guessing; permission_denied_count '
          'rising: a token without the policy it needs.',
    act='locked_users above 0: a user locked out (an application that cannot log in); the audit failure counts '
        'moving: with every audit device failing, it refuses every request; responses_5xx_count moving.')
