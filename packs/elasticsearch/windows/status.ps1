#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - a cluster's health, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports whether Elasticsearch answers, its version, the cluster's health
    (green, yellow or red), its nodes, its shards (active, relocating,
    initializing, unassigned, and unassigned primaries), the cluster tasks
    waiting and for how long, and which node is the elected master. It only
    reads: it changes nothing in the cluster.

    Reads Elasticsearch at ELASTICSEARCH_URL (default https://localhost:9200),
    as ELASTICSEARCH_USER with the password in ELASTICSEARCH_PASSWORD (a
    secret), or with an API key in ELASTICSEARCH_API_KEY (a secret: the encoded
    form Elasticsearch gives). The login goes in a header made here, never on a
    command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or
    ELASTICSEARCH_CACERT, a CA file, and against the server's name. What the
    scripts share is in _elasticsearch.ps1, beside this one.

    Metrics:
      up                         1 when Elasticsearch answers, else 0
      version                    always 1, tagged version=<its version> and
                                 cluster=<its name>
      status                     the cluster's health: 0 green, 1 yellow (a
                                 replica unassigned), 2 red (a primary
                                 unassigned: data missing), 3 when there is no
                                 elected master; tagged status=<it>
      timed_out                  1 when the health check timed out
      nodes                      nodes in the cluster
      data_nodes                 of those, nodes that hold data
      active_primary_shards      primary shards active
      active_shards              shards active, primaries and replicas
      active_shards_pct          shards active, as a percentage of all
      relocating_shards          shards moving between nodes
      initializing_shards        shards being created or recovered
      unassigned_shards          shards on no node
      unassigned_primary_shards  of those, primaries (when Elasticsearch says)
      delayed_unassigned_shards  unassigned shards whose allocation waits, on
                                 purpose, for a node to come back
      pending_tasks              cluster tasks waiting for the master
      task_max_wait_ms           how long the oldest of those has waited
      in_flight_fetch            shard information being fetched from the nodes
      master                     1 when a node is the elected master, tagged
                                 node=<its name>; 0 when none is

    Example output (the rest are in the same form):
      metric up 1
      metric version 1 version=9.5.5 cluster=vigil95
      metric status 2 status=red
      metric nodes 3
      metric active_shards_pct 86.21
      metric unassigned_shards 4
      metric unassigned_primary_shards 2
      metric master 1 node=es95b

    Reading the results (starting points: tune them to the cluster):
      Healthy  up 1; status 0; unassigned_shards 0; pending_tasks 0.
      Watch    status 1 for long: replicas unassigned, one node from losing
               data; relocating_shards or initializing_shards for long;
               task_max_wait_ms in seconds.
      Act      up 0; status 2: primaries unassigned, data unreachable (the
               shards job says which, and why); master 0 or status 3: no elected
               master, the cluster changes nothing.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
Write-Output "metric version 1 version=$(Safe $script:Root.version.number) cluster=$(Safe $script:Root.cluster_name)"
$health = '/_cluster/health?timeout=10s&master_timeout=10s'
$p = Get-Page $health
if ($p.State -eq 'nomaster') { Write-Output 'metric status 3 status=no_master'; Write-Output 'metric master 0'; exit 0 }
if ($p.State -ne 'ok') { Stop-Why $p.State $health }
$h = $p.Data
M 'status' (Code $h.status) "status=$(Safe $h.status)"
M 'timed_out' $h.timed_out
M 'nodes' $h.number_of_nodes
M 'data_nodes' $h.number_of_data_nodes
M 'active_primary_shards' $h.active_primary_shards
M 'active_shards' $h.active_shards
M 'active_shards_pct' (R2 $h.active_shards_percent_as_number)
M 'relocating_shards' $h.relocating_shards
M 'initializing_shards' $h.initializing_shards
M 'unassigned_shards' $h.unassigned_shards
if ($null -ne $h.unassigned_primary_shards) { M 'unassigned_primary_shards' $h.unassigned_primary_shards }
M 'delayed_unassigned_shards' $h.delayed_unassigned_shards
M 'pending_tasks' $h.number_of_pending_tasks
M 'task_max_wait_ms' $h.task_max_waiting_in_queue_millis
M 'in_flight_fetch' $h.number_of_in_flight_fetch
$m = @(Need-Page '/_cat/master?format=json&h=id,node')
if ($m.Count -gt 0 -and $m[0].node -and $m[0].node -ne '-') { M 'master' 1 "node=$(Safe $m[0].node)" } else { M 'master' 0 }
exit 0
