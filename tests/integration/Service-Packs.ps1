#Requires -Version 5.1

# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

<#
.SYNOPSIS
    Integration test: the postgres and redis service packs against real
    servers, on Windows. The twin of service-packs.sh (nginx has no Windows
    script).
.DESCRIPTION
    Tested only when a server is given, and SKIPped otherwise:
        VIGIL_IT_PG_HOST, VIGIL_IT_PG_PORT   a PostgreSQL server (port 5432 by default)
        VIGIL_IT_PG_PASSWORD                 its vigil_monitor role's password; the
                                             role has pg_monitor and nothing more
        VIGIL_IT_REDIS_HOST, _PORT           a Redis or Valkey server (port 6379
                                             by default)
        VIGIL_IT_REDIS_PASSWORD              its vigil_monitor user's password; the
                                             user may run INFO and PING only
        VIGIL_IT_REDIS_ADMIN_PASSWORD        optional: its admin user's, to make
                                             keys, lookups, a blocked client,
                                             evictions and a snapshot
        VIGIL_IT_REDIS_REPLICA_HOST, _PORT   optional: a replica of it
        VIGIL_IT_REDIS_TLS_HOST, _PORT       optional: a server that speaks TLS
                                             only, its default user open, with
        VIGIL_IT_REDIS_CACERT                the CA its certificate is from, which
                                             names the TLS host as given
    psql is found as the pack finds it: on the PATH, or in PostgreSQL's own
    folders under Program Files. The redis pack needs no client.

    The pack is off until enabled; vigil pack enable puts its jobs in the
    configuration; each job runs and reports what the server says; a long
    query and transaction are seen; a wrong password fails the run and says
    why; a server that is down reads as up 0; its metrics reach a backend;
    and the password is written nowhere. For redis, as service-packs.sh tests
    it: keys, lookups, a blocked client, evictions and a snapshot; a replica
    from both sides; TLS against a CA, refused when the certificate cannot be
    trusted, names another host, or is asked for without TLS; a server with
    no password; a wrong password, even where the default user is open; a
    user that may not run INFO; and a server that is down.

    Exit code: 0 all passed or skipped, 1 any failed.
#>

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent $here)
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil svcpack.$PID"
$root = Join-Path $work 'root'
$script:pass = 0
$script:fail = 0
$hold = $null
$script:blocked = $null

function Test-Equal {
    param([string]$Name, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) { $script:pass++; Write-Host "  PASS  $Name" }
    else { $script:fail++; Write-Host "  FAIL  ${Name}: expected [$Expected] actual [$Actual]" }
}

function Invoke-Vigil {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'app\vigil.ps1'), '-Root', $root) + $args
    $out = & $shell @a 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}

# vigil secret set <Name> --stdin, the value on its standard input.
function Set-VigilSecret {
    param([string]$Name, [string]$Value)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'app\vigil.ps1'), '-Root', $root, 'secret', 'set', $Name, '--stdin')
    [void]($Value | & $shell @a 2>&1)
}

# The value job $Job's last run printed for metric $Name (with $Tag, if given).
function Get-Printed {
    param([string]$Job, [string]$Name, [string]$Tag = '')
    $v = ''
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root "logs\jobs\$Job") -Filter '*.log' -ErrorAction SilentlyContinue) {
        foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
            if ($l -match " out metric $Name (\S+)(.*)$" -and $Matches[2].Contains($Tag)) { $v = $Matches[1] }
        }
    }
    return $v
}

# Sets env NAME=value in every line of the configuration that sets NAME.
function Set-Env {
    param([string]$Name, [string]$Value)
    $cfg = Join-Path $root 'config\vigil.config'
    $text = [System.IO.File]::ReadAllText($cfg) -replace "(?m)^(env\s*=\s*)$Name=.*$", "`${1}$Name=$Value"
    [System.IO.File]::WriteAllText($cfg, $text)
}

function Find-Psql {
    $c = @(Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($c.Count -gt 0) { return $c[0].Source }
    $found = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'PostgreSQL') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\psql.exe') } |
            Sort-Object { [int]($_.Name -replace '\D.*$', '') } -Descending)
    if ($found.Count -gt 0) { return Join-Path $found[0].FullName 'bin\psql.exe' }
    return $null
}

# The test's own commands to a Redis server, as admin, in the server's
# protocol: no client is needed. Each command's reply is read, unless
# -NoReply leaves the connection waiting (a blocked client).
function Send-RedisCommand {
    param($Conn, [string[]]$Words, [switch]$NoReply)
    $text = "*$($Words.Count)`r`n"
    foreach ($w in $Words) { $text += "`$$([System.Text.Encoding]::UTF8.GetByteCount($w))`r`n$w`r`n" }
    $b = [System.Text.Encoding]::UTF8.GetBytes($text)
    $Conn.Stream.Write($b, 0, $b.Length)
    if (-not $NoReply) { return Read-RedisReply $Conn.Reader }
}
function Read-RedisReply {
    param($Reader)
    $l = $Reader.ReadLine()
    switch ($l[0]) {
        '*' {
            $a = @()
            for ($i = 0; $i -lt [int]$l.Substring(1); $i++) { $a += , (Read-RedisReply $Reader) }
            return , $a
        }
        '$' {
            $n = [int]$l.Substring(1)
            if ($n -lt 0) { return $null }
            $buf = New-Object char[] ($n + 2)
            $got = 0
            while ($got -lt $n + 2) { $got += $Reader.Read($buf, $got, $n + 2 - $got) }
            return (New-Object string($buf, 0, $n))
        }
    }
    return $l
}
function Connect-RedisAdmin {
    $port = if ($env:VIGIL_IT_REDIS_PORT) { [int]$env:VIGIL_IT_REDIS_PORT } else { 6379 }
    $tcp = New-Object System.Net.Sockets.TcpClient($env:VIGIL_IT_REDIS_HOST, $port)
    $s = $tcp.GetStream()
    $s.ReadTimeout = 60000
    $c = @{ Tcp = $tcp; Stream = $s; Reader = (New-Object System.IO.StreamReader($s, [System.Text.Encoding]::ASCII)) }
    [void](Send-RedisCommand $c @('AUTH', 'admin', $env:VIGIL_IT_REDIS_ADMIN_PASSWORD))
    return $c
}
# The metric lines of job $Job's last run.
function Show-LastRun {
    param([string]$Job)
    $f = @(Get-ChildItem -LiteralPath (Join-Path $root "logs\jobs\$Job") -Filter '*.log' | Sort-Object Name)[-1]
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $rid = ($lines[-1] -split ' ')[1]
    foreach ($l in $lines) { if ($l -match "^\S+ $([regex]::Escape($rid)) out (metric .*)$") { Write-Host "        $($Matches[1])" } }
}
# Whether job $Job's last run said $Text.
function Test-Said {
    param([string]$Job, [string]$Text)
    $f = @(Get-ChildItem -LiteralPath (Join-Path $root "logs\jobs\$Job") -Filter '*.log' | Sort-Object Name)[-1]
    $lines = [System.IO.File]::ReadAllLines($f.FullName)
    $rid = ($lines[-1] -split ' ')[1]
    return [string][bool](@($lines | Where-Object { $_ -match "^\S+ $([regex]::Escape($rid)) " -and $_.Contains($Text) }).Count)
}
# Whether the last value job $Job printed for $Name (with $Tag) is a number
# from $Low to $High.
function Test-Between {
    param([string]$Job, [string]$Name, [string]$Tag, [double]$Low, [double]$High)
    $v = Get-Printed $Job $Name $Tag
    if ($v -match '^-?[0-9]+(\.[0-9]+)?$' -and [double]$v -ge $Low -and [double]$v -le $High) { return 'yes' }
    return "no [$v]"
}
# The redis jobs' TLS lines, REDIS_TLS and REDIS_CACERT, each left out when
# empty, as an operator adds them under REDIS_PORT.
function Set-RedisTls {
    param([string]$Tls, [string]$Ca)
    $cfg = Join-Path $root 'config\vigil.config'
    $out = foreach ($l in [System.IO.File]::ReadAllLines($cfg)) {
        if ($l -match '^env\s*=\s*REDIS_(TLS|CACERT)=') { continue }
        $l
        if ($l -match '^env\s*=\s*REDIS_PORT=') {
            if ($Tls) { "env         = REDIS_TLS=$Tls" }
            if ($Ca) { "env         = REDIS_CACERT=$Ca" }
        }
    }
    [System.IO.File]::WriteAllLines($cfg, [string[]]$out)
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"
try {
    [void](New-Item -ItemType Directory -Force -Path $root)
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'app'), (Join-Path $repo 'vendor') -Destination $root
    $r = Invoke-Vigil init --instance svcpack --backend file --no-pack
    Test-Equal 'init' '0' ([string]$r.Code)
    $pk = Join-Path $root 'packs\postgres'
    [void](New-Item -ItemType Directory -Force -Path $pk)
    Copy-Item -LiteralPath (Join-Path $repo 'packs\postgres\pack.config') -Destination $pk
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\postgres\windows') | Copy-Item -Destination $pk
    $rk = Join-Path $root 'packs\redis'
    [void](New-Item -ItemType Directory -Force -Path $rk)
    Copy-Item -LiteralPath (Join-Path $repo 'packs\redis\pack.config') -Destination $rk
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\redis\windows') | Copy-Item -Destination $rk
    $list = (Invoke-Vigil pack list).Text
    # pack list indents each job under its pack.
    Test-Equal 'the pack is off until enabled' 'off off' ((@($list.Split("`n") | Where-Object { $_ -match '^\s*postgres_(status|size)\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })) -join ' ')

    $psql = Find-Psql
    if (-not $env:VIGIL_IT_PG_HOST -or -not $env:VIGIL_IT_PG_PASSWORD) { Write-Host '  SKIP  postgres: set VIGIL_IT_PG_HOST and VIGIL_IT_PG_PASSWORD' }
    elseif (-not $psql) { Write-Host '  SKIP  postgres: psql is not installed here' }
    else {
        $port = if ($env:VIGIL_IT_PG_PORT) { $env:VIGIL_IT_PG_PORT } else { '5432' }
        Write-Host "postgres at $($env:VIGIL_IT_PG_HOST):$port, psql $psql"
        Set-VigilSecret POSTGRES_MONITOR_PASSWORD $env:VIGIL_IT_PG_PASSWORD
        $r = Invoke-Vigil pack enable postgres
        Test-Equal 'postgres: enabled' '0' ([string]$r.Code)
        $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" }
        Set-Env 'PGHOST' $env:VIGIL_IT_PG_HOST
        Set-Env 'PGPORT' $port
        $r = Invoke-Vigil precheck
        Test-Equal 'postgres: precheck is happy' '0' ([string]$r.Code)
        if ($r.Code -ne 0) { $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" } }

        # A transaction held open for the status job to see, by the same role.
        $env:PGPASSWORD = $env:VIGIL_IT_PG_PASSWORD
        $hold = Start-Process -FilePath $psql -PassThru -WindowStyle Hidden -ArgumentList @(
            '-X', '-q', '-h', $env:VIGIL_IT_PG_HOST, '-p', $port, '-U', 'vigil_monitor', '-d', 'postgres', '-c', '"BEGIN; SELECT pg_sleep(30); COMMIT;"')
        Remove-Item Env:\PGPASSWORD
        Start-Sleep -Seconds 4
        $r = Invoke-Vigil run postgres_status
        Test-Equal 'postgres: status runs' '0' ([string]$r.Code)
        foreach ($m in 'up', 'connections', 'max_connections', 'connections_pct', 'longest_query_seconds', 'longest_transaction_seconds', 'commits_count', 'cache_hit_pct') {
            Write-Host "        metric $m $(Get-Printed postgres_status $m)"
        }
        Test-Equal 'postgres: up' '1' (Get-Printed postgres_status up)
        Test-Equal 'postgres: connections seen' 'True' ([string]([long]("0" + (Get-Printed postgres_status connections)) -ge 1))
        Test-Equal 'postgres: a percentage of the limit' 'True' ([string]((Get-Printed postgres_status connections_pct) -ne ''))
        Test-Equal 'postgres: the long query seen' 'True' ([string]([long]("0" + (Get-Printed postgres_status longest_query_seconds)) -ge 2))
        Test-Equal 'postgres: the long transaction seen' 'True' ([string]([long]("0" + (Get-Printed postgres_status longest_transaction_seconds)) -ge 2))
        Test-Equal 'postgres: commits counted' 'True' ([string]([long]("0" + (Get-Printed postgres_status commits_count)) -ge 1))
        if (-not $hold.HasExited) { Stop-Process -Id $hold.Id -Force -ErrorAction SilentlyContinue }

        $r = Invoke-Vigil run postgres_size
        Test-Equal 'postgres: size runs' '0' ([string]$r.Code)
        Test-Equal 'postgres: the postgres database sized' 'True' ([string]([long]("0" + (Get-Printed postgres_size size_bytes 'database=postgres')) -gt 0))

        Set-VigilSecret POSTGRES_MONITOR_PASSWORD 'not-the-password'
        $r = Invoke-Vigil run postgres_status
        Test-Equal 'postgres: a wrong password fails the run' '2' ([string]$r.Code)
        $log = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\postgres_status') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
        Test-Equal 'postgres: and says why' 'True' ([string]$log.Contains('refused the login'))
        Set-VigilSecret POSTGRES_MONITOR_PASSWORD $env:VIGIL_IT_PG_PASSWORD

        Set-Env 'PGPORT' '1'
        $r = Invoke-Vigil run postgres_status
        Test-Equal 'postgres: a server that is down still runs' '0' ([string]$r.Code)
        Test-Equal 'postgres: and reads as up 0' '0' (Get-Printed postgres_status up)
        Set-Env 'PGPORT' $port

        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
        [void](Invoke-Vigil supervise --once)
        $prom = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
        Test-Equal 'postgres: metrics reach the backend' 'True' ([string]($prom -match '(?m)^postgres_connections\{'))
        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'spool'), (Join-Path $root 'metrics') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains($env:VIGIL_IT_PG_PASSWORD) })
        Test-Equal 'postgres: the password is written nowhere' '0' ([string]$leaks.Count)
    }

    # --- redis --------------------------------------------------------------
    if (-not $env:VIGIL_IT_REDIS_HOST -or -not $env:VIGIL_IT_REDIS_PASSWORD) { Write-Host '  SKIP  redis: set VIGIL_IT_REDIS_HOST and VIGIL_IT_REDIS_PASSWORD' }
    else {
        # The jobs have their password from Vigil, or none: never from this
        # test's own environment.
        Remove-Item Env:\REDISCLI_AUTH -ErrorAction SilentlyContinue
        $rport = if ($env:VIGIL_IT_REDIS_PORT) { $env:VIGIL_IT_REDIS_PORT } else { '6379' }
        Write-Host "redis at $($env:VIGIL_IT_REDIS_HOST):$rport"
        $jobs = 'status', 'memory', 'replication', 'persistence', 'keyspace'
        function Get-RedisJobsOn {
            $list = (Invoke-Vigil pack list).Text
            return (@($list.Split("`n") | Where-Object { $_ -match '^\s*redis_\w+\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })) -join ' '
        }
        function Invoke-Job { param([string]$Job) return [string](Invoke-Vigil run $Job).Code }
        Test-Equal 'redis: off until enabled' 'off off off off off' (Get-RedisJobsOn)
        $r = Invoke-Vigil pack enable redis
        Test-Equal 'redis: enabled' '0' ([string]$r.Code)
        $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" }
        Test-Equal 'redis: its jobs are on' 'on on on on on' (Get-RedisJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal 'redis: the password is a secret reference' 'True' ([string]([System.IO.File]::ReadAllText($cfg) -match '(?m)^secret\s*=\s*REDISCLI_AUTH=secret:REDIS_MONITOR_PASSWORD'))
        Set-VigilSecret REDIS_MONITOR_PASSWORD $env:VIGIL_IT_REDIS_PASSWORD
        Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_HOST
        Set-Env 'REDIS_PORT' $rport
        $r = Invoke-Vigil precheck
        Test-Equal 'redis: precheck is happy' '0' ([string]$r.Code)

        # With admin: more data than maxmemory allows, when there is a limit,
        # so the server evicts; keys in two databases, some expiring; a
        # lookup that hits and one that misses; a client blocked on a list
        # no one writes; and a snapshot.
        $maxmem = 0
        if ($env:VIGIL_IT_REDIS_ADMIN_PASSWORD) {
            $a = Connect-RedisAdmin
            $maxmem = [long](Send-RedisCommand $a @('CONFIG', 'GET', 'maxmemory'))[1]
            if ($maxmem -gt 0) {
                $n = [long][Math]::Floor($maxmem / 4096 / 2000) + 1
                for ($i = 1; $i -le $n * 2; $i++) {
                    [void](Send-RedisCommand $a @('EVAL', "for i = 1, 2000 do redis.call('SET', 'vigil_it:fill:' .. ARGV[1] .. ':' .. i, string.rep('x', 4096)) end", '0', "w$i"))
                }
            }
            for ($i = 1; $i -le 5; $i++) { [void](Send-RedisCommand $a @('SET', "vigil_it:key:$i", "$i")) }
            [void](Send-RedisCommand $a @('SELECT', '3'))
            [void](Send-RedisCommand $a @('SET', 'vigil_it:expiring', '1', 'EX', '600'))
            [void](Send-RedisCommand $a @('SELECT', '0'))
            [void](Send-RedisCommand $a @('GET', 'vigil_it:key:1'))
            [void](Send-RedisCommand $a @('GET', 'vigil_it:no-such-key'))
            $script:blocked = Connect-RedisAdmin
            Send-RedisCommand $script:blocked @('BLPOP', 'vigil_it:never', '60') -NoReply
            [void](Send-RedisCommand $a @('BGSAVE'))
            for ($i = 0; $i -lt 30; $i++) {
                if ((Send-RedisCommand $a @('INFO', 'persistence')) -match 'rdb_bgsave_in_progress:0') { break }
                Start-Sleep -Seconds 1
            }
            $a.Tcp.Close()
            Start-Sleep -Seconds 2
        } else { Write-Host '  SKIP  redis: keys, lookups, a blocked client, evictions and a snapshot: set VIGIL_IT_REDIS_ADMIN_PASSWORD' }
        foreach ($j in $jobs) {
            Test-Equal "redis: $j runs" '0' (Invoke-Job "redis_$j")
            Show-LastRun "redis_$j"
        }
        Test-Equal 'redis: up' '1' (Get-Printed redis_status up)
        $log = (Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\redis_status') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join ''
        Test-Equal 'redis: what it is' 'True' ([string]($log -match ' out metric info 1 server=(redis|valkey) version=[0-9][0-9.]* mode=standalone\r?\n'))
        Test-Equal 'redis: not loading' '0' (Get-Printed redis_status loading)
        Test-Equal 'redis: clients seen' 'yes' (Test-Between redis_status clients '' 1 100000)
        Test-Equal 'redis: the limit' 'yes' (Test-Between redis_status max_clients '' 1 1e7)
        Test-Equal 'redis: clients against it' 'yes' (Test-Between redis_status clients_pct '' 0 100)
        Test-Equal 'redis: commands counted' 'yes' (Test-Between redis_status commands_count '' 1 1e18)
        Test-Equal 'redis: memory used' 'yes' (Test-Between redis_memory used_bytes '' 1 1e15)
        Test-Equal 'redis: memory from the system' 'yes' (Test-Between redis_memory rss_bytes '' 1 1e15)
        Test-Equal 'redis: the limit and its policy' 'True' ([string]((Get-Printed redis_memory max_bytes 'policy=') -ne ''))
        Test-Equal 'redis: fragmentation' 'yes' (Test-Between redis_memory fragmentation_ratio '' 0 100000)
        Test-Equal 'redis: a primary' '0' (Get-Printed redis_replication is_replica)
        Test-Equal 'redis: the last snapshot worked' '1' (Get-Printed redis_persistence last_save_ok)
        Test-Equal 'redis: its age' 'yes' (Test-Between redis_persistence last_save_age_seconds '' 0 1e9)
        Test-Equal 'redis: the append-only file is fine' '1' (Get-Printed redis_persistence aof_last_write_ok)
        Test-Equal 'redis: keys in db0' 'yes' (Test-Between redis_keyspace keys 'db=db0' 0 1e12)
        $bad = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs') -Directory -Filter 'redis_*' | Get-ChildItem -Filter '*.log' |
                ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } |
                Where-Object { $_ -match ' out metric ' -and $_ -notmatch ' out metric [a-z_]+ -?[0-9]+(\.[0-9]+)?( [a-z]+=[A-Za-z0-9_.-]+)*$' })
        Test-Equal 'redis: nothing but numbers taken for data' '0' ([string]$bad.Count)
        if ($env:VIGIL_IT_REDIS_ADMIN_PASSWORD) {
            Test-Equal 'redis: a lookup that hit' 'yes' (Test-Between redis_status hits_count '' 1 1e18)
            Test-Equal 'redis: one that missed' 'yes' (Test-Between redis_status misses_count '' 1 1e18)
            Test-Equal 'redis: the hit rate' 'yes' (Test-Between redis_status hit_pct '' 0 100)
            Test-Equal 'redis: the blocked client' 'yes' (Test-Between redis_status blocked_clients '' 1 100000)
            Test-Equal 'redis: keys in db3' 'yes' (Test-Between redis_keyspace keys 'db=db3' 1 1e12)
            Test-Equal 'redis: expiring in db3' 'yes' (Test-Between redis_keyspace expires 'db=db3' 1 1e12)
            Test-Equal 'redis: the snapshot just written' 'yes' (Test-Between redis_persistence last_save_age_seconds '' 0 60)
            Test-Equal 'redis: its fork timed' 'yes' (Test-Between redis_persistence last_fork_usec '' 1 1e9)
            if ($maxmem -gt 0) {
                Test-Equal 'redis: keys evicted at maxmemory' 'yes' (Test-Between redis_status evicted_keys_count '' 1 1e18)
                Test-Equal 'redis: memory against the limit' 'yes' (Test-Between redis_memory used_pct '' 50 150)
                Test-Equal 'redis: the policy that evicts' 'True' ([string]((Get-Printed redis_memory max_bytes 'policy=allkeys-lru') -ne ''))
            }
            $script:blocked.Tcp.Close()
            $script:blocked = $null
        }

        # With a replica: the primary sees it in step; the replica says it is
        # one, linked and up to date.
        if ($env:VIGIL_IT_REDIS_REPLICA_HOST) {
            Test-Equal 'redis: the replica seen from the primary' 'yes' (Test-Between redis_replication replicas '' 1 1000)
            Test-Equal 'redis: in step' '1' (Get-Printed redis_replication online 'replica=')
            Test-Equal 'redis: its lag in bytes' 'yes' (Test-Between redis_replication lag_bytes 'replica=' 0 1e15)
            Test-Equal 'redis: its lag in seconds' 'yes' (Test-Between redis_replication lag_seconds 'replica=' 0 1e9)
            Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_REPLICA_HOST
            Set-Env 'REDIS_PORT' $(if ($env:VIGIL_IT_REDIS_REPLICA_PORT) { $env:VIGIL_IT_REDIS_REPLICA_PORT } else { '6379' })
            Test-Equal 'redis: replication runs on the replica' '0' (Invoke-Job redis_replication)
            Show-LastRun redis_replication
            Test-Equal 'redis: a replica' '1' (Get-Printed redis_replication is_replica)
            Test-Equal 'redis: its link up' '1' (Get-Printed redis_replication link_up)
            Test-Equal 'redis: heard from the primary' 'yes' (Test-Between redis_replication last_io_seconds '' 0 60)
            Test-Equal 'redis: no copy under way' '0' (Get-Printed redis_replication sync_in_progress)
            if ($env:VIGIL_IT_REDIS_ADMIN_PASSWORD) {
                Test-Equal 'redis: keyspace runs on the replica' '0' (Invoke-Job redis_keyspace)
                Test-Equal 'redis: the keys copied over' 'yes' (Test-Between redis_keyspace keys 'db=db3' 1 1e12)
            }
            Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_HOST
            Set-Env 'REDIS_PORT' $rport
        } else { Write-Host '  SKIP  redis: a replica: set VIGIL_IT_REDIS_REPLICA_HOST' }

        # TLS: checked against the CA given, with the server's name; a
        # certificate that cannot be trusted, one that names another host,
        # and plain TCP to a TLS port, fail the run. This server's default
        # user is open: with no password the jobs read it as that user, and a
        # wrong password must still fail.
        if ($env:VIGIL_IT_REDIS_TLS_HOST -and $env:VIGIL_IT_REDIS_CACERT) {
            Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_TLS_HOST
            Set-Env 'REDIS_PORT' $(if ($env:VIGIL_IT_REDIS_TLS_PORT) { $env:VIGIL_IT_REDIS_TLS_PORT } else { '6379' })
            Set-RedisTls '1' $env:VIGIL_IT_REDIS_CACERT
            Test-Equal 'redis: TLS, against its CA' '0' (Invoke-Job redis_status)
            Test-Equal 'redis: TLS: up' '1' (Get-Printed redis_status up)
            Test-Equal 'redis: TLS: the other jobs too' '0 0 0 0' ((@('memory', 'replication', 'persistence', 'keyspace') | ForEach-Object { Invoke-Job "redis_$_" }) -join ' ')
            Set-RedisTls '1' ''
            Test-Equal 'redis: TLS: a certificate it cannot trust fails the run' '2' (Invoke-Job redis_status)
            Test-Equal 'redis: and says why' 'True' (Test-Said redis_status 'TLS handshake failed')
            Set-RedisTls '1' $env:VIGIL_IT_REDIS_CACERT
            Set-Env 'REDIS_HOST' 'localhost'
            Test-Equal 'redis: TLS: a certificate that names another host fails the run' '2' (Invoke-Job redis_status)
            Test-Equal 'redis: and says why' 'True' (Test-Said redis_status 'TLS handshake failed')
            Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_TLS_HOST
            Set-RedisTls '0' ''
            Test-Equal 'redis: plain TCP to a TLS port fails the run' '2' (Invoke-Job redis_status)
            Set-RedisTls '1' $env:VIGIL_IT_REDIS_CACERT
            Set-VigilSecret REDIS_MONITOR_PASSWORD 'not-the-password'
            Test-Equal 'redis: a wrong password fails, though the default user is open' '2' (Invoke-Job redis_status)
            Test-Equal 'redis: and says why' 'True' (Test-Said redis_status 'refused the login')
            Set-VigilSecret REDIS_MONITOR_PASSWORD $env:VIGIL_IT_REDIS_PASSWORD
            # No password at all, as on a server with none: the secret lines go.
            $keep = [System.IO.File]::ReadAllText($cfg)
            [System.IO.File]::WriteAllText($cfg, ($keep -replace '(?m)^secret\s*=\s*REDISCLI_AUTH=.*\r?\n', ''))
            Test-Equal 'redis: with no password, as the default user' '0' (Invoke-Job redis_status)
            Test-Equal 'redis: up' '1' (Get-Printed redis_status up)
            [System.IO.File]::WriteAllText($cfg, $keep)
            Set-RedisTls '' ''
            Set-Env 'REDIS_HOST' $env:VIGIL_IT_REDIS_HOST
            Set-Env 'REDIS_PORT' $rport
        } else { Write-Host '  SKIP  redis: TLS: set VIGIL_IT_REDIS_TLS_HOST and VIGIL_IT_REDIS_CACERT' }

        # A wrong password fails the run and says why; it is not "down".
        Set-VigilSecret REDIS_MONITOR_PASSWORD 'not-the-password'
        Test-Equal 'redis: a wrong password fails the run' '2' (Invoke-Job redis_status)
        Test-Equal 'redis: and says why' 'True' (Test-Said redis_status 'refused the login')
        Set-VigilSecret REDIS_MONITOR_PASSWORD $env:VIGIL_IT_REDIS_PASSWORD
        Set-Env 'REDIS_USER' 'vigil_noinfo'
        Test-Equal 'redis: a user that may not run INFO fails the run' '2' (Invoke-Job redis_memory)
        Test-Equal 'redis: and says why' 'True' (Test-Said redis_memory 'NOPERM')
        Set-Env 'REDIS_USER' 'vigil_monitor'

        # A server that does not answer is a reading; the others say nothing.
        Set-Env 'REDIS_PORT' '1'
        Test-Equal 'redis: a server that is down still runs' '0' (Invoke-Job redis_status)
        Test-Equal 'redis: and reads as up 0' '0' (Get-Printed redis_status up)
        $count = { @(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\redis_memory') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match ' out metric ' }).Count }
        $before = & $count
        Test-Equal 'redis: the other jobs succeed when it is down' '0' (Invoke-Job redis_memory)
        Test-Equal 'redis: and say nothing' ([string]$before) ([string](& $count))
        Set-Env 'REDIS_PORT' $rport
        [void](Invoke-Job redis_status)

        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
        [void](Invoke-Vigil supervise --once)
        $prom = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
        Test-Equal 'redis: metrics reach the backend' 'True' ([string](($prom -match '(?m)^redis_up\{') -and ($prom -match '(?m)^redis_memory_used_bytes\{') -and ($prom -match '(?m)^redis_keyspace_keys\{.*db="db0"')))
        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'spool'), (Join-Path $root 'metrics') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains($env:VIGIL_IT_REDIS_PASSWORD) })
        Test-Equal 'redis: the password is written nowhere' '0' ([string]$leaks.Count)
    }
}
finally {
    if ($script:blocked) { $script:blocked.Tcp.Close() }
    if ($hold -and -not $hold.HasExited) { Stop-Process -Id $hold.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
