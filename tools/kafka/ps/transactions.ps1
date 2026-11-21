    # Transactions by state, then those open longer than KAFKA_TXN_LONG
    # seconds (default 300). Counts only: a transactional id names an
    # application.
    #   TransactionalId Coordinator ProducerId TransactionState
    $long = if ($env:KAFKA_TXN_LONG) { $env:KAFKA_TXN_LONG } else { '300' }
    if ($long -cnotmatch '^\d+$') { Stop-Run "KAFKA_TXN_LONG is '$long': give it in seconds" }
    if ((Invoke-Kafka 'kafka-transactions' ($conn + @('list'))) -ne 0) { return }
    $by = New-Map; $n = 0
    foreach ($l in ($script:out -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+')
        if ($f.Count -lt 4 -or $f[0] -ceq 'TransactionalId') { continue }
        $st = $f[3].ToLowerInvariant(); $by[$st] = 1 + [int]$by[$st]; $n++
    }
    Write-Output "metric all_transactions $n"
    foreach ($s in $by.Keys) { Write-Output "metric transactions $($by[$s]) state=$s" }
    Write-Output "metric ongoing $([int]$by['ongoing'])"
    # The filter is by age, whatever the state: only those still ongoing count.
    if ((Invoke-Kafka 'kafka-transactions' ($conn + @('list', '--duration-filter', ([long]$long * 1000)))) -ne 0) { return }
    $n = 0
    foreach ($l in ($script:out -split "`r?`n")) {
        $f = @($l.Trim() -split '\s+')
        if ($f.Count -ge 4 -and $f[0] -cne 'TransactionalId' -and $f[3] -ceq 'Ongoing') { $n++ }
    }
    Write-Output "metric long_running $n"
