# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# A fragment of the kafka pack: tools/kafka/gen.py writes packs/kafka from it.

    # Each topic's shape, from its description, and its offsets: the end of
    # each partition (every message ever written to it, a running total) and
    # its start (what retention has removed before it), as topic:partition:offset.
    if ((Invoke-Kafka 'kafka-topics' ($conn + @('--describe'))) -ne 0) { return }
    $d = Read-Describe $script:out
    if (-not $d.Topics.Count) { Write-NoTopics }
    $sum = @{}
    foreach ($w in 'latest', 'earliest') {
        if ((Invoke-Kafka 'kafka-get-offsets' ($conn + @('--time', $w))) -ne 0) { return }
        $m = New-Map
        foreach ($l in ($script:out -split "`r?`n")) {
            $f = @($l.Trim() -split ':')
            if ($f.Count -eq 3 -and $f[2] -cmatch '^\d+$') { $m[$f[0]] = [double]$m[$f[0]] + [double]$f[2] }
        }
        $sum[$w] = $m
    }
    $internal = 0; $rf1 = 0; $compacted = 0
    foreach ($t in $d.Topics) {
        if ($t.Name.StartsWith('__')) { $internal++ } elseif ($t.Rf -eq 1) { $rf1++ }
        if ($t.Configs -cmatch 'cleanup\.policy=[a-z,]*compact') { $compacted++ }
    }
    Write-Output "metric topics $($d.Topics.Count)"
    Write-Output "metric internal_topics $internal"
    Write-Output "metric rf1_topics $rf1"
    Write-Output "metric compacted_topics $compacted"
    $n = 0; $hidden = 0
    foreach ($t in $d.Topics) {
        if (++$n -gt 100) { $hidden++; continue }
        $tag = "topic=$($t.Name)"
        Write-Output "metric partitions $($t.Partitions) $tag"
        Write-Output "metric replication_factor $($t.Rf) $tag"
        $end = [double]$sum['latest'][$t.Name]; $start = [double]$sum['earliest'][$t.Name]
        Write-Metric 'messages_count' $end $tag
        Write-Metric 'retained_messages' ($end - $start) $tag
    }
    Write-Output "metric topics_not_shown $hidden"
