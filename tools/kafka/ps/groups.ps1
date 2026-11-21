    # Every group's state and members. Consumer groups, from
    # kafka-consumer-groups:
    #   GROUP COORDINATOR (ID) ASSIGNMENT-STRATEGY STATE #MEMBERS
    # and, with Kafka 4's tools, share and streams groups, each type named by
    # kafka-groups. A tool this Kafka does not have, or a group type the
    # cluster has not turned on, is left out.
    if ((Invoke-Kafka 'kafka-consumer-groups' ($conn + @('--describe', '--all-groups', '--state'))) -ne 0) { return }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in ($script:out -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+')
        if ($f.Count -ge 5 -and $f[0] -cne 'GROUP' -and $f[-1] -cmatch '^\d+$') { $rows.Add(@{ Group = $f[0]; State = $f[-2]; Members = [int]$f[-1]; Type = '' }) }
    }
    $types = New-Map
    if ((Find-Tool 'kafka-groups') -and (Invoke-Kafka 'kafka-groups' ($conn + @('--list')) -Soft) -eq 0) {
        foreach ($l in ($script:out -split "`r?`n")) {
            $f = @($l.Trim() -split '\s+')
            if ($f.Count -ge 2 -and $f[0] -cne 'GROUP') { $types[$f[0]] = $f[1].ToLowerInvariant() }
        }
    }
    foreach ($kind in 'share', 'streams') {
        if (-not (Find-Tool "kafka-$kind-groups")) { continue }
        if ((Invoke-Kafka "kafka-$kind-groups" ($conn + @('--describe', '--all-groups', '--state')) -Soft) -ne 0) { continue }
        foreach ($l in ($script:out -split "`r?`n")) {
            $f = @($l.Trim() -split '\s+')
            if ($f.Count -ge 4 -and $f[0] -cne 'GROUP' -and $f[-1] -cmatch '^\d+$') { $rows.Add(@{ Group = $f[0]; State = $f[-2]; Members = [int]$f[-1]; Type = $kind }) }
        }
    }
    $by = New-Map; $members = 0; $rebal = 0; $empty = 0; $dead = 0
    foreach ($r in $rows) {
        if (-not $r.Type) { $r.Type = if ($types.Contains($r.Group)) { $types[$r.Group] } else { 'classic' } }
        $st = $r.State.ToLowerInvariant()
        $k = "type=$($r.Type) state=$st"
        $by[$k] = 1 + [int]$by[$k]
        $members += $r.Members
        if ($st -match 'rebalance|assigning|reconciling') { $rebal++ }
        if ($st -ceq 'empty') { $empty++ }
        if ($st -ceq 'dead') { $dead++ }
    }
    Write-Output "metric all_groups $($rows.Count)"
    Write-Output "metric all_members $members"
    Write-Output "metric rebalancing $rebal"
    Write-Output "metric empty $empty"
    Write-Output "metric dead $dead"
    foreach ($k in $by.Keys) { Write-Output "metric groups $($by[$k]) $k" }
    $n = 0; $hidden = 0
    foreach ($r in $rows) {
        if (++$n -gt 150) { $hidden++; continue }
        Write-Output "metric members $($r.Members) group=$(ConvertTo-Tag $r.Group) type=$($r.Type)"
    }
    Write-Output "metric groups_not_shown $hidden"
