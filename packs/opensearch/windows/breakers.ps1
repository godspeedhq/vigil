#Requires -Version 5.1

<#
.SYNOPSIS
    breakers.ps1 - the circuit breakers of a cluster's nodes, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each node's circuit breakers, the limits OpenSearch sets on the
    memory a request, field data, requests in flight and the node as a whole
    (the parent) may take: what each holds against its limit, and how often it
    tripped, refusing a request rather than running out of memory. It only
    reads: it changes nothing in the cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                  1 when OpenSearch answers, else 0
      tripped_total       trips of every breaker of every node, since each
                          started (a counter)
      max_used_pct        the fullest breaker, as a percentage of its limit
      estimated_bytes     what a breaker holds, tagged node=<its name> and
                          breaker=<the breaker>
      limit_bytes         its limit, tagged the same
      used_pct            estimated_bytes, as a percentage of the limit
      tripped             its trips, since the node started (a counter)
      breakers_not_shown  breakers past the first 600, left out

    Example output (the rest are in the same form):
      metric up 1
      metric tripped_total 12
      metric max_used_pct 78.3
      metric estimated_bytes 0 node=os310a breaker=fielddata
      metric limit_bytes 161061273 node=os310a breaker=fielddata
      metric used_pct 0 node=os310a breaker=fielddata
      metric tripped 0 node=os310a breaker=fielddata

    Reading the results (starting points: tune them to the cluster):
      Healthy  tripped_total flat; the parent breaker's used_pct below 85.
      Watch    the parent breaker's used_pct above 85: the node is short of
               memory for what it is asked.
      Act      tripped rising: requests refused (HTTP 429,
               circuit_breaking_exception); on parent, the node's memory is too
               small for its load; on fielddata, a text field aggregated.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'breakers'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
$s = Need-Page '/_nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers'
$all = @(foreach ($nd in (Values $s.nodes)) {
    foreach ($b in (Props $nd.breakers)) {
        [pscustomobject]@{ node = [string]$nd.name; breaker = $b.Name; est = (N $b.Value.estimated_size_in_bytes); lim = (N $b.Value.limit_size_in_bytes); tripped = (N $b.Value.tripped) }
    }
}) | Sort-Object node, breaker
$all = @($all)
M 'tripped_total' (($all | ForEach-Object { $_.tripped } | Measure-Object -Sum).Sum)
$max = 0
foreach ($x in $all) { $p = Pct $x.est $x.lim; if ($p -gt $max) { $max = $p } }
M 'max_used_pct' $max
foreach ($x in @($all | Select-Object -First 600)) {
    $t = "node=$(Safe $x.node) breaker=$(Safe $x.breaker)"
    M 'estimated_bytes' $x.est $t
    M 'limit_bytes' $x.lim $t
    M 'used_pct' (Pct $x.est $x.lim) $t
    M 'tripped' $x.tripped $t
}
M 'breakers_not_shown' ([Math]::Max($all.Count - 600, 0))
exit 0
