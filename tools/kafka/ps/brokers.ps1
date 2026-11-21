    # Each broker as the cluster lists it, then what it holds, from every
    # partition's leader, replicas and in-sync replicas.
    if ((Invoke-BrokersList) -ne 0) { return }
    $known = New-Map
    foreach ($l in ($script:out -split "`r?`n")) {
        if ($l -cmatch '\(id: (\d+) rack: ([^ )]*)( isFenced: (\w+))?\)') {
            $known[$Matches[1]] = @{ Rack = $Matches[2]; Fenced = [int]($Matches[4] -ceq 'true'); Down = $false }
        }
    }
    if ((Invoke-Kafka 'kafka-topics' ($conn + @('--describe'))) -ne 0) { return }
    $d = Read-Describe $script:out
    $leaders = New-Map; $replicas = New-Map; $behind = New-Map; $preferred = New-Map
    foreach ($p in $d.Parts) {
        if ($p.Leader -cmatch '^\d+$') { $leaders[$p.Leader] = 1 + [int]$leaders[$p.Leader] }
        foreach ($r in @($p.Replicas)) {
            $replicas[$r] = 1 + [int]$replicas[$r]
            if (@($p.Isr) -notcontains $r) { $behind[$r] = 1 + [int]$behind[$r] }
            # A broker that holds replicas but is not listed is down: shown as
            # online 0, so its replicas still show where they are.
            if (-not $known.Contains($r)) { $known[$r] = @{ Rack = 'none'; Fenced = 0; Down = $true } }
        }
        if (@($p.Replicas).Count) { $f = @($p.Replicas)[0]; $preferred[$f] = 1 + [int]$preferred[$f] }
    }
    $shown = 0; $hidden = 0
    foreach ($id in $known.Keys) {
        if (++$shown -gt 150) { $hidden++; continue }
        $b = $known[$id]
        $rack = if (-not $b.Rack -or $b.Rack -ceq 'null') { 'none' } else { ConvertTo-Tag $b.Rack }
        Write-Output "metric online $([int](-not $b.Down)) broker=$id rack=$rack"
        if (-not $b.Down) { Write-Output "metric fenced $($b.Fenced) broker=$id" }
        Write-Output "metric leaders $([int]$leaders[$id]) broker=$id"
        Write-Output "metric replicas $([int]$replicas[$id]) broker=$id"
        Write-Output "metric out_of_sync_replicas $([int]$behind[$id]) broker=$id"
        Write-Output "metric preferred_leaders $([int]$preferred[$id]) broker=$id"
    }
    Write-Output "metric brokers_not_shown $hidden"
