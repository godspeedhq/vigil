#Requires -Version 5.1

<#
.SYNOPSIS
    snapshots.ps1 - the snapshots in a cluster's repositories, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the cluster's snapshot repositories and, for each (the first 20, by
    name), its snapshots: how many, how many failed or partial, the last one's
    state, age, length and failed shards, and how long since the last that
    succeeded. Then the snapshots being taken now. A repository the cluster
    cannot read is reported so, not failed. It only reads: it changes nothing in
    the cluster.

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
      up                        1 when Elasticsearch answers, else 0
      repositories              snapshot repositories
      running                   snapshots being taken now
      readable                  1 when the cluster could list a repository,
                                tagged repository=<its name>
      snapshots                 its snapshots, tagged the same
      failed                    of those, failed
      partial                   partial: some shards missing
      last_status               the last one's state: 0 SUCCESS, 1 IN_PROGRESS,
                                2 PARTIAL, 3 FAILED, 4 other; tagged repository
                                and status=<it>
      last_age_seconds          since the last one ended (or started, while it
                                runs)
      last_duration_seconds     how long it took
      last_failed_shards        its shards that failed
      last_success_age_seconds  since the last that succeeded ended; absent when
                                none has
      repositories_not_shown    repositories past the first 20, left out

    Example output (the rest are in the same form):
      metric up 1
      metric repositories 2
      metric snapshots 1 repository=backups
      metric last_status 0 repository=backups status=SUCCESS
      metric last_duration_seconds 4 repository=backups
      metric last_success_age_seconds 157 repository=backups

    Reading the results (starting points: tune them to the cluster):
      Healthy  last_status 0; last_success_age_seconds within your snapshot
               schedule.
      Watch    partial above 0; last_duration_seconds growing.
      Act      last_success_age_seconds past your schedule, or absent: no good
               backup; last_status 3; readable 0: the repository is gone or
               broken.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, Elasticsearch up or down; 1 if a setting is wrong,
      the login is refused, this user may not read what the job needs, or the
      address is not Elasticsearch
#>

$Job = 'snapshots'
. (Join-Path $PSScriptRoot '_elasticsearch.ps1')

Read-First
$repos = Need-Page '/_snapshot?filter_path=*.type'
$p = Get-Page '/_snapshot/_status?filter_path=snapshots.snapshot'
if ($p.State -eq 'ok') { M 'running' (@(@($p.Data.snapshots) | Where-Object { $_ }).Count) }
elseif ($p.State -eq 'unsupported') { M 'running' 0 }
else { Stop-Why $p.State '/_snapshot/_status' }
$names = @(Props $repos | ForEach-Object { $_.Name } | Sort-Object)
M 'repositories' $names.Count
M 'repositories_not_shown' ([Math]::Max($names.Count - 20, 0))
$code = @{ 'SUCCESS' = 0; 'IN_PROGRESS' = 1; 'PARTIAL' = 2; 'FAILED' = 3 }
foreach ($repo in @($names | Select-Object -First 20)) {
    $t = "repository=$(Safe $repo)"
    $path = "/_cat/snapshots/$([Uri]::EscapeDataString($repo))?format=json&h=id,status,start_epoch,end_epoch,failed_shards,total_shards"
    $r = Get-Page $path
    if ($r.State -in 'down', 'forbidden', 'nomaster') { Stop-Why $r.State $path }
    if ($r.State -ne 'ok') { M 'readable' 0 $t; continue }
    $all = @(@($r.Data) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ status = [string]$_.status; s = (N $_.start_epoch); e = (N $_.end_epoch); failed = (N $_.failed_shards) } } | Sort-Object s)
    M 'readable' 1 $t
    M 'snapshots' $all.Count $t
    M 'failed' (@($all | Where-Object { $_.status -eq 'FAILED' }).Count) $t
    M 'partial' (@($all | Where-Object { $_.status -eq 'PARTIAL' }).Count) $t
    if ($all.Count) {
        $l = $all[-1]
        $c = if ($code.ContainsKey($l.status)) { $code[$l.status] } else { 4 }
        M 'last_status' $c "$t status=$(Safe $l.status)"
        $age = if ($l.e -gt 0) { $script:Now - $l.e } else { $script:Now - $l.s }
        M 'last_age_seconds' ([Math]::Max($age, 0)) $t
        if ($l.e -gt 0) { M 'last_duration_seconds' ($l.e - $l.s) $t }
        M 'last_failed_shards' $l.failed $t
    }
    $ok = @($all | Where-Object { $_.status -eq 'SUCCESS' })
    if ($ok.Count) { M 'last_success_age_seconds' ([Math]::Max($script:Now - $ok[-1].e, 0)) $t }
}
exit 0
