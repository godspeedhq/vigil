    # Each broker's connections, per listener, from JMX: open now, and running
    # totals of those made and of logins that succeeded and failed. Each of a
    # listener's network processors counts its own: added up.
    $attrs = [ordered]@{
        'connection-count' = 'connections'; 'connection-creation-total' = 'created_count'; 'successful-authentication-total' = 'logins_count'
        'failed-authentication-total' = 'failed_logins_count'; 'failed-reauthentication-total' = 'failed_relogins_count'
    }
    Invoke-JmxEach {
        $sum = New-Map
        foreach ($r in $rows) {
            if ($r.Name -cnotmatch 'type=socket-server-metrics,' -or -not $attrs.Contains($r.Attr)) { continue }
            $l = Get-Key $r.Name 'listener'
            $v = ConvertTo-Num $r.Value
            if ($null -eq $v) { continue }
            if (-not $sum.Contains($l)) { $sum[$l] = @{} }
            $sum[$l][$r.Attr] = [double]$sum[$l][$r.Attr] + [double]$v
        }
        foreach ($l in $sum.Keys) {
            foreach ($a in $attrs.Keys) { Write-Metric $attrs[$a] ([double]$sum[$l][$a]) "broker=$broker listener=$(ConvertTo-Tag $l)" }
        }
    } @('kafka.server:type=socket-server-metrics,listener=*,networkProcessor=*') 'Version,connection-count,connection-creation-total,successful-authentication-total,failed-authentication-total,failed-reauthentication-total'
