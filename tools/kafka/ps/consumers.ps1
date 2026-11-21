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

    # Every consumer group's committed offsets against the end of each
    # partition, one row a partition:
    #   GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG CONSUMER-ID HOST CLIENT-ID
    # A partition with no committed offset shows "-": its lag is not known.
    if ((Invoke-Kafka 'kafka-consumer-groups' ($conn + @('--describe', '--all-groups'))) -ne 0) { return }
    $pairs = New-Map; $groups = New-Map; $total = [double]0
    foreach ($l in ($script:out -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+')
        if ($f.Count -lt 6 -or $f[0] -ceq 'GROUP' -or $f[2] -cnotmatch '^\d+$') { continue }
        $k = $f[0] + "`n" + $f[1]
        if (-not $pairs.Contains($k)) { $pairs[$k] = @{ Group = $f[0]; Topic = $f[1]; Lag = [double]0; Max = [double]0; NoOffset = 0 } }
        if (-not $groups.Contains($f[0])) { $groups[$f[0]] = [double]0 }
        $p = $pairs[$k]
        if ($f[5] -cmatch '^\d+$') {
            $v = [double]$f[5]
            $p.Lag += $v; $groups[$f[0]] += $v; $total += $v
            if ($v -gt $p.Max) { $p.Max = $v }
        }
        else { $p.NoOffset++ }
    }
    Write-Output "metric groups $($groups.Count)"
    Write-Metric 'total_lag' $total
    $n = 0; $hidden = 0
    foreach ($p in $pairs.Values) {
        if (++$n -gt 150) { $hidden++; continue }
        $tags = "group=$(ConvertTo-Tag $p.Group) topic=$($p.Topic)"
        Write-Metric 'lag' $p.Lag $tags
        Write-Metric 'lag_max' $p.Max $tags
        if ($p.NoOffset) { Write-Output "metric no_offset_partitions $($p.NoOffset) $tags" }
    }
    Write-Output "metric pairs_not_shown $hidden"
    $n = 0
    foreach ($g in $groups.Keys) { if (++$n -le 150) { Write-Metric 'group_lag' $groups[$g] "group=$(ConvertTo-Tag $g)" } }
