#Requires -Version 5.1

<#
.SYNOPSIS
    ingest.ps1 - the ingest pipelines of a cluster, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the documents the cluster's ingest pipelines have taken, failed and
    taken time over, every node together, and each pipeline that has run, those
    that failed most first: its documents, its failures and their share, and its
    average time. It only reads: it changes nothing in the cluster.

    Reads OpenSearch at OPENSEARCH_URL (default https://localhost:9200), as
    OPENSEARCH_USER with the password in OPENSEARCH_PASSWORD (a secret). The
    login goes in a header made here, never on a command line.
    It speaks HTTP itself, with .NET: nothing to install. Over https, the
    certificate is checked against Windows' trusted CAs, or OPENSEARCH_CACERT, a
    CA file, and against the server's name. What the scripts share is in
    _opensearch.ps1, beside this one.

    Metrics:
      up                   1 when OpenSearch answers, else 0
      count                documents through any pipeline, every node (a
                           counter)
      failed               of those, failed (a counter)
      time_ms              time spent in pipelines (a counter)
      current              documents in a pipeline now
      failed_pct           failed, as a percentage of count
      pipelines            pipelines that have run
      pipeline_count       a pipeline's documents, tagged pipeline=<its name> (a
                           counter)
      pipeline_failed      its failures (a counter)
      pipeline_failed_pct  its failures, as a percentage of its documents
      pipeline_time_ms     its time (a counter)
      pipeline_avg_ms      its average time a document
      pipelines_not_shown  pipelines past the first 100, left out

    Example output (the rest are in the same form):
      metric up 1
      metric count 6
      metric failed 3
      metric failed_pct 50
      metric pipeline_count 6 pipeline=parse
      metric pipeline_failed 3 pipeline=parse

    Reading the results (starting points: tune them to the cluster):
      Healthy  failed flat.
      Watch    pipeline_avg_ms rising: a pipeline slows every write through it.
      Act      pipeline_failed rising: documents refused, or indexed with an
               error (a grok pattern that no longer matches, a field of a type
               the pipeline did not expect).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, OpenSearch up or down; 1 if a setting is wrong, the
      login is refused, this user may not read what the job needs, or the
      address is not OpenSearch
#>

$Job = 'ingest'
. (Join-Path $PSScriptRoot '_opensearch.ps1')

Read-First
$s = Need-Page '/_nodes/stats/ingest?filter_path=nodes.*.ingest.total,nodes.*.ingest.pipelines.*.count,nodes.*.ingest.pipelines.*.failed,nodes.*.ingest.pipelines.*.time_in_millis,nodes.*.ingest.pipelines.*.current'
$ing = @(Values $s.nodes | ForEach-Object { $_.ingest })
$c = 0; $f = 0; $tm = 0; $cur = 0
$by = @{}
foreach ($i in $ing) {
    $c += N $i.total.count; $f += N $i.total.failed; $tm += N $i.total.time_in_millis; $cur += N $i.total.current
    foreach ($p in (Props $i.pipelines)) {
        if (-not $by.ContainsKey($p.Name)) { $by[$p.Name] = [pscustomobject]@{ name = $p.Name; count = 0.0; failed = 0.0; time = 0.0 } }
        $e = $by[$p.Name]; $e.count += N $p.Value.count; $e.failed += N $p.Value.failed; $e.time += N $p.Value.time_in_millis
    }
}
M 'count' $c
M 'failed' $f
M 'time_ms' $tm
M 'current' $cur
M 'failed_pct' (Pct $f $c)
$pl = @($by.Values | Where-Object { $_.count -gt 0 -or $_.failed -gt 0 } | Sort-Object @{ Expression = { $_.failed }; Descending = $true }, @{ Expression = { $_.count }; Descending = $true }, @{ Expression = { $_.name } })
M 'pipelines' $pl.Count
foreach ($x in @($pl | Select-Object -First 100)) {
    $t = "pipeline=$(Safe $x.name)"
    M 'pipeline_count' $x.count $t
    M 'pipeline_failed' $x.failed $t
    M 'pipeline_failed_pct' (Pct $x.failed $x.count) $t
    M 'pipeline_time_ms' $x.time $t
    M 'pipeline_avg_ms' $(if ($x.count -gt 0) { R2 ($x.time / $x.count) } else { 0 }) $t
}
M 'pipelines_not_shown' ([Math]::Max($pl.Count - 100, 0))
exit 0
