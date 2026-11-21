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

    # Every partition: its leader, replicas, in-sync replicas, eligible leader
    # replicas, and any move in progress, against its topic's
    # min.insync.replicas.
    if ((Invoke-Kafka 'kafka-topics' ($conn + @('--describe'))) -ne 0) { return }
    $d = Read-Describe $script:out
    if (-not $d.Topics.Count) { Write-NoTopics }
    $min = New-Map
    foreach ($t in $d.Topics) { $min[$t.Name] = $t.MinIsr }
    $urp = 0; $offline = 0; $under = 0; $atmin = 0; $notpref = 0; $elr = 0; $moves = 0
    $urpT = New-Map; $offT = New-Map; $underT = New-Map
    foreach ($p in $d.Parts) {
        $r = @($p.Replicas).Count; $s = @($p.Isr).Count
        $m = if ($min.Contains($p.Topic)) { $min[$p.Topic] } else { 1 }
        if (-not $p.Leader -or $p.Leader -ceq 'none' -or $p.Leader -ceq '-1') { $offline++; $offT[$p.Topic] = 1 + [int]$offT[$p.Topic] }
        elseif ($r -and $p.Leader -cne @($p.Replicas)[0]) { $notpref++ }
        if ($s -lt $r) { $urp++; $urpT[$p.Topic] = 1 + [int]$urpT[$p.Topic] }
        if ($s -lt $m) { $under++; $underT[$p.Topic] = 1 + [int]$underT[$p.Topic] }
        elseif ($s -eq $m -and $s -lt $r) { $atmin++ }
        if (@($p.Elr).Count) { $elr++ }
        if ($p.Moving) { $moves++ }
    }
    Write-Output "metric topics $($d.Topics.Count)"
    Write-Output "metric partitions $($d.Parts.Count)"
    Write-Output "metric under_replicated $urp"
    Write-Output "metric offline $offline"
    Write-Output "metric under_min_isr $under"
    Write-Output "metric at_min_isr $atmin"
    Write-Output "metric not_preferred_leader $notpref"
    Write-Output "metric with_eligible_leaders $elr"
    Write-Output "metric reassigning $moves"
    # The topics with a partition in trouble, by name (at most 100 of each).
    foreach ($x in @(@('topic_under_replicated', $urpT), @('topic_offline', $offT), @('topic_under_min_isr', $underT))) {
        $n = 0
        foreach ($t in $x[1].Keys) { if (++$n -le 100) { Write-Output "metric $($x[0]) $($x[1][$t]) topic=$t" } }
    }
