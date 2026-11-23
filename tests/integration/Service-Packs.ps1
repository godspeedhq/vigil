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
    Integration test: the postgres, redis, mssql, kafka and jvm service packs against
    real servers, on Windows. The twin of service-packs.sh (nginx has no
    Windows script).
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
        VIGIL_IT_MSSQL_HOST, _PORT           a SQL Server (port 1433 by default), by
                                             a name on its certificate, from a CA
                                             this machine trusts
        VIGIL_IT_MSSQL_PASSWORD              its vigil_monitor login's password; the
                                             login has what packs/README.md says
                                             to grant
        VIGIL_IT_MSSQL_SA_PASSWORD           optional: sa's, to make a database,
                                             backups, an integrity check and
                                             blocking
        VIGIL_IT_KAFKA_BOOTSTRAP             a Kafka cluster's SASL_SSL listener
                                             (host:port, comma-separated), SCRAM
        VIGIL_IT_KAFKA_PASSWORD              its vigil_monitor user's password; the
                                             user has the ACLs packs/README.md lists
        VIGIL_IT_KAFKA_CACERT                the CA its certificates are from
        VIGIL_IT_KAFKA_HOME                  Kafka's command-line tools (3.9 on);
                                             Java on the PATH or in JAVA_HOME
        VIGIL_IT_KAFKA_JMX                   optional: its brokers' JMX, jmxs=host:port; ...
        VIGIL_IT_KAFKA_JMX_PASSWORD          JMX's password, for its user monitor
        VIGIL_IT_KAFKA_RELEASE               a folder of packs.sh's archives: the
                                             kafka pack, with its jars
        VIGIL_IT_KAFKA_LIBS2                 optional: a second Kafka library, to
                                             run every job again with
        VIGIL_IT_KAFKA_JRE                   optional: a JRE to run those on
        VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP       optional: a PLAINTEXT listener that may
                                             do anything, to make a topic, messages
                                             and a group with lag
        VIGIL_IT_JVM_TARGETS                 JVMs with JMX (JVM_TARGETS' form), as
                                             scripts/run-jvm.sh runs them, by
                                             tunnels; the test adds a JVM of its
                                             own here, without JMX
        VIGIL_IT_JVM_PASSWORD                their JMX operator user's password
        VIGIL_IT_JVM_CACERT                  the CA their certificates are from
        VIGIL_IT_JVM_RELEASE                 a folder of packs.sh's archives, the
                                             jvm pack's among them (its jars)
        VIGIL_IT_JVM_JRE                     optional: a JRE 11 or later, to run
                                             every job on from the jars too
    psql is found as the pack finds it: on the PATH, or in PostgreSQL's own
    folders under Program Files. The redis and mssql packs need no client;
    the kafka pack needs Kafka's tools and Java, the jvm pack Java 11 or
    later and its release zip (and to test it on a JRE, a JRE too).

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
$script:jvmProc = $null
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
    $mk = Join-Path $root 'packs\mssql'
    [void](New-Item -ItemType Directory -Force -Path $mk)
    Copy-Item -LiteralPath (Join-Path $repo 'packs\mssql\pack.config') -Destination $mk
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\mssql\windows') | Copy-Item -Destination $mk
    $kk = Join-Path $root 'packs\kafka'
    [void](New-Item -ItemType Directory -Force -Path $kk)
    Copy-Item -LiteralPath (Join-Path $repo 'packs\kafka\pack.config') -Destination $kk
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\kafka\windows') | Copy-Item -Destination $kk
    $bk = Join-Path $root 'packs\beam'
    [void](New-Item -ItemType Directory -Force -Path $bk)
    Copy-Item -LiteralPath (Join-Path $repo 'packs\beam\pack.config') -Destination $bk
    Get-ChildItem -LiteralPath (Join-Path $repo 'packs\beam\windows') | Copy-Item -Destination $bk
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

        # With admin: a lookup that hits and one that misses; more data than
        # maxmemory allows, when there is a limit, so the server evicts; keys
        # in two databases, some expiring; a client blocked on a list no one
        # writes; and a snapshot. The lookups come first, and the keys two
        # seconds after the fill: the server's LRU clock ticks once a second,
        # and a key written in the same second as the fill may be evicted
        # with it.
        $maxmem = 0
        if ($env:VIGIL_IT_REDIS_ADMIN_PASSWORD) {
            $a = Connect-RedisAdmin
            [void](Send-RedisCommand $a @('SET', 'vigil_it:key:1', '1'))
            [void](Send-RedisCommand $a @('GET', 'vigil_it:key:1'))
            [void](Send-RedisCommand $a @('GET', 'vigil_it:no-such-key'))
            $maxmem = [long](Send-RedisCommand $a @('CONFIG', 'GET', 'maxmemory'))[1]
            if ($maxmem -gt 0) {
                $n = [long][Math]::Floor($maxmem / 4096 / 2000) + 1
                for ($i = 1; $i -le $n * 2; $i++) {
                    [void](Send-RedisCommand $a @('EVAL', "for i = 1, 2000 do redis.call('SET', 'vigil_it:fill:' .. ARGV[1] .. ':' .. i, string.rep('x', 4096)) end", '0', "w$i"))
                }
                Start-Sleep -Seconds 2
            }
            for ($i = 1; $i -le 5; $i++) { [void](Send-RedisCommand $a @('SET', "vigil_it:key:$i", "$i")) }
            [void](Send-RedisCommand $a @('SELECT', '3'))
            [void](Send-RedisCommand $a @('SET', 'vigil_it:expiring', '1', 'EX', '600'))
            [void](Send-RedisCommand $a @('SELECT', '0'))
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

    # --- mssql --------------------------------------------------------------
    if (-not $env:VIGIL_IT_MSSQL_HOST -or -not $env:VIGIL_IT_MSSQL_PASSWORD) { Write-Host '  SKIP  mssql: set VIGIL_IT_MSSQL_HOST and VIGIL_IT_MSSQL_PASSWORD' }
    else {
        # The jobs have their password and server from Vigil: never from
        # this test's own environment.
        foreach ($v in 'SQLCMDPASSWORD', 'MSSQL_HOST', 'MSSQL_PORT', 'MSSQL_USER', 'MSSQL_AUTH', 'MSSQL_CACERT', 'MSSQL_CERT_NAME') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
        $mport = if ($env:VIGIL_IT_MSSQL_PORT) { $env:VIGIL_IT_MSSQL_PORT } else { '1433' }
        Write-Host "mssql at $($env:VIGIL_IT_MSSQL_HOST):$mport"
        # activity first, while the waiter waits.
        $mjobs = 'activity', 'status', 'performance', 'cpu', 'replication', 'waits', 'io', 'memory', 'tempdb', 'connections', 'databases', 'health', 'config', 'backups', 'agent'
        function Get-MssqlJobsOn {
            $list = (Invoke-Vigil pack list).Text
            $s = @($list.Split("`n") | Where-Object { $_ -match '^\s*mssql_\w+\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
            return (@($s | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ' '
        }
        function Invoke-Job { param([string]$Job) return [string](Invoke-Vigil run $Job).Code }
        # The test's own connections, as sa, encrypted and checked like the
        # pack's.
        function New-MssqlSa {
            $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
            $b['Data Source'] = "tcp:$($env:VIGIL_IT_MSSQL_HOST),$mport"
            $b['Encrypt'] = $true; $b['TrustServerCertificate'] = $false; $b['Pooling'] = $false
            $b['User ID'] = 'sa'; $b['Password'] = $env:VIGIL_IT_MSSQL_SA_PASSWORD
            $c = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
            $c.Open()
            return $c
        }
        function Invoke-MssqlSa {
            param($Conn, [string]$Sql)
            $cmd = $Conn.CreateCommand(); $cmd.CommandTimeout = 120; $cmd.CommandText = $Sql
            [void]$cmd.ExecuteNonQuery()
        }
        Test-Equal 'mssql: off until enabled' 'off=15' (Get-MssqlJobsOn)
        $r = Invoke-Vigil pack enable mssql
        Test-Equal 'mssql: enabled' '0' ([string]$r.Code)
        $r.Text.Split("`n") | ForEach-Object { Write-Host "        $_" }
        Test-Equal 'mssql: its jobs are on' 'on=15' (Get-MssqlJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal 'mssql: the password is a secret reference' '15' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*SQLCMDPASSWORD=secret:MSSQL_MONITOR_PASSWORD')).Count)
        Set-VigilSecret MSSQL_MONITOR_PASSWORD $env:VIGIL_IT_MSSQL_PASSWORD
        Set-Env 'MSSQL_HOST' $env:VIGIL_IT_MSSQL_HOST
        Set-Env 'MSSQL_PORT' $mport
        $r = Invoke-Vigil precheck
        Test-Equal 'mssql: precheck is happy' '0' ([string]$r.Code)

        # As sa: a database, a full and a log backup, an integrity check, a
        # session asleep with its transaction open holding a row lock, and
        # another blocked behind it.
        $sa = $null; $holder = $null; $waiter = $null; $wait = $null
        if ($env:VIGIL_IT_MSSQL_SA_PASSWORD) {
            $db = if ($env:VIGIL_IT_MSSQL_DATABASE) { $env:VIGIL_IT_MSSQL_DATABASE } else { 'vigil_it' }
            $sa = New-MssqlSa
            Invoke-MssqlSa $sa "IF DB_ID('$db') IS NULL BEGIN CREATE DATABASE [$db]; ALTER DATABASE [$db] SET RECOVERY FULL; END"
            Invoke-MssqlSa $sa "USE [$db]; IF OBJECT_ID('dbo.t') IS NULL CREATE TABLE dbo.t (id int PRIMARY KEY, v int); IF NOT EXISTS (SELECT 1 FROM dbo.t) INSERT dbo.t VALUES (1, 0), (2, 0);"
            Invoke-MssqlSa $sa "BACKUP DATABASE [$db] TO DISK = N'/var/opt/mssql/data/$db.bak' WITH INIT; BACKUP LOG [$db] TO DISK = N'/var/opt/mssql/data/$db.trn' WITH INIT;"
            Invoke-MssqlSa $sa "DBCC CHECKDB([$db]) WITH NO_INFOMSGS;"
            $holder = New-MssqlSa
            Invoke-MssqlSa $holder "USE [$db]; BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1;"
            $waiter = New-MssqlSa
            $wc = $waiter.CreateCommand(); $wc.CommandTimeout = 200
            $wc.CommandText = "SET LOCK_TIMEOUT 150000; USE [$db]; UPDATE dbo.t SET v = v + 1 WHERE id = 1;"
            $wait = $wc.ExecuteNonQueryAsync()
            Start-Sleep -Seconds 8
        }
        else { Write-Host '  SKIP  mssql: a database, backups, CHECKDB and blocking: set VIGIL_IT_MSSQL_SA_PASSWORD' }
        foreach ($j in $mjobs) {
            Test-Equal "mssql: $j runs" '0' (Invoke-Job "mssql_$j")
            Show-LastRun "mssql_$j"
        }
        Test-Equal 'mssql: up' '1' (Get-Printed mssql_status up)
        Test-Equal 'mssql: what it is' 'True' ([string](@(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\mssql_status') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } |
                    Where-Object { $_ -match ' out metric info 1 release=20(19|22|25) version=1[5-7]\.[0-9.]+ update=[A-Za-z0-9]+ edition=[a-z]+ os=(linux|windows)$' }).Count -gt 0))
        Test-Equal 'mssql: connections' 'yes' (Test-Between mssql_status connections '' 1 100000)
        Test-Equal 'mssql: requests counted' 'yes' (Test-Between mssql_performance batch_requests_count '' 1 1e18)
        Test-Equal 'mssql: workers against the most' 'yes' (Test-Between mssql_cpu workers_pct '' 0.01 100)
        # SQL Server records its CPU once a minute: none yet on a server just
        # started.
        for ($i = 0; $i -lt 12 -and -not (Get-Printed mssql_cpu sql_pct); $i++) { Start-Sleep -Seconds 10; [void](Invoke-Job mssql_cpu) }
        Test-Equal 'mssql: SQL Server CPU' 'yes' (Test-Between mssql_cpu sql_pct '' 0 100)
        Test-Equal 'mssql: reads, file by file' 'yes' (Test-Between mssql_io reads_count 'database=master file=master kind=data' 1 1e18)
        Test-Equal 'mssql: memory it aims for' 'yes' (Test-Between mssql_memory target_bytes '' 1 1e15)
        Test-Equal 'mssql: tempdb free' 'yes' (Test-Between mssql_tempdb free_pct '' 0 100)
        Test-Equal 'mssql: our connections encrypted' 'yes' (Test-Between mssql_connections connections 'encrypted=yes' 1 100000)
        Test-Equal 'mssql: master online' '1' (Get-Printed mssql_databases online 'database=master')
        Test-Equal 'mssql: disk space' 'yes' (Test-Between mssql_health volume_free_pct 'volume=' 0 100)
        Test-Equal 'mssql: xp_cmdshell off' '0' (Get-Printed mssql_config xp_cmdshell)
        Test-Equal 'mssql: Agent jobs not readable without their grants' '0' (Get-Printed mssql_agent readable)
        if ($sa) {
            Test-Equal 'mssql: a request blocked' 'yes' (Test-Between mssql_activity requests_blocked '' 1 1000)
            Test-Equal 'mssql: and its head blocker' 'yes' (Test-Between mssql_activity head_blockers '' 1 1000)
            Test-Equal 'mssql: asleep with a transaction open' 'yes' (Test-Between mssql_activity idle_in_transaction '' 1 1000)
            Test-Equal 'mssql: the open transaction' 'yes' (Test-Between mssql_activity oldest_transaction_seconds '' 3 300)
            Test-Equal 'mssql: checked today' '0' (Get-Printed mssql_health checkdb_age_days "database=$db")
            Test-Equal 'mssql: its full backup just taken' 'yes' (Test-Between mssql_backups full_age_seconds "database=$db" 0 3600)
            Test-Equal 'mssql: and its log backup' 'yes' (Test-Between mssql_backups log_age_seconds "database=$db" 0 3600)
            Invoke-MssqlSa $sa "USE msdb; IF USER_ID('vigil_monitor') IS NULL CREATE USER vigil_monitor FOR LOGIN vigil_monitor; GRANT SELECT ON dbo.sysjobs TO vigil_monitor; GRANT SELECT ON dbo.sysjobhistory TO vigil_monitor; GRANT SELECT ON dbo.sysjobactivity TO vigil_monitor; GRANT SELECT ON dbo.syssessions TO vigil_monitor;"
            Test-Equal 'mssql: agent runs with its grants' '0' (Invoke-Job mssql_agent)
            Test-Equal 'mssql: Agent jobs readable' '1' (Get-Printed mssql_agent readable)
            Invoke-MssqlSa $sa 'USE msdb; DROP USER vigil_monitor;'
            $holder.Dispose(); $holder = $null
            try { [void]$wait.Wait(60000) } catch { }
            $waiter.Dispose(); $waiter = $null
            $sa.Dispose(); $sa = $null
        }

        Set-VigilSecret MSSQL_MONITOR_PASSWORD 'not-the-Password1'
        Test-Equal 'mssql: a wrong password fails the run' '2' (Invoke-Job mssql_status)
        Test-Equal 'mssql: and says why' 'True' (Test-Said mssql_status 'Login failed')
        Set-VigilSecret MSSQL_MONITOR_PASSWORD $env:VIGIL_IT_MSSQL_PASSWORD

        # A server that does not answer is a reading; the others say nothing.
        Set-Env 'MSSQL_PORT' '1'
        Test-Equal 'mssql: a server that is down still runs' '0' (Invoke-Job mssql_status)
        Test-Equal 'mssql: and reads as up 0' '0' (Get-Printed mssql_status up)
        $count = { @(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\mssql_databases') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match ' out metric ' }).Count }
        $before = & $count
        Test-Equal 'mssql: the other jobs succeed when it is down' '0' (Invoke-Job mssql_databases)
        Test-Equal 'mssql: and say nothing' ([string]$before) ([string](& $count))
        Set-Env 'MSSQL_PORT' $mport
        [void](Invoke-Job mssql_status)

        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
        [void](Invoke-Vigil supervise --once)
        $prom = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
        Test-Equal 'mssql: metrics reach the backend' 'True' ([string](($prom -match '(?m)^mssql_up\{') -and ($prom -match '(?m)^mssql_database_online\{.*database="master"') -and ($prom -match '(?m)^mssql_waits_wait_ms')))
        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'spool'), (Join-Path $root 'metrics') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains($env:VIGIL_IT_MSSQL_PASSWORD) })
        Test-Equal 'mssql: the password is written nowhere' '' ((@($leaks | ForEach-Object { $_.FullName.Substring($root.Length + 1) })) -join ' ')
    }

    # --- kafka --------------------------------------------------------------
    if (-not $env:VIGIL_IT_KAFKA_BOOTSTRAP -or -not $env:VIGIL_IT_KAFKA_PASSWORD -or -not $env:VIGIL_IT_KAFKA_HOME) { Write-Host '  SKIP  kafka: set VIGIL_IT_KAFKA_BOOTSTRAP, VIGIL_IT_KAFKA_PASSWORD and VIGIL_IT_KAFKA_HOME' }
    elseif (-not $env:JAVA_HOME -and -not (Get-Command java.exe -ErrorAction SilentlyContinue)) { Write-Host '  SKIP  kafka: java is not installed here' }
    elseif (-not $env:VIGIL_IT_KAFKA_RELEASE) { Write-Host '  SKIP  kafka: set VIGIL_IT_KAFKA_RELEASE to a folder of packs.sh''s archives, the kafka pack''s among them' }
    else {
        # The jobs have their cluster, passwords and CA from Vigil: never from
        # this test's own environment.
        foreach ($v in 'KAFKA_BOOTSTRAP', 'KAFKA_SECURITY', 'KAFKA_SASL_MECHANISM', 'KAFKA_USER', 'KAFKA_PASSWORD', 'KAFKA_CACERT', 'KAFKA_CERT', 'KAFKA_KEY', 'KAFKA_CLIENT_CONFIG',
            'KAFKA_JMX', 'KAFKA_JMX_USER', 'KAFKA_JMX_PASSWORD', 'KAFKA_HOME', 'KAFKA_LIBS') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
        Write-Host "kafka at $($env:VIGIL_IT_KAFKA_BOOTSTRAP)"
        # The pack as a release builds it, with its jars: from packs.sh's zip.
        $kzip = @(Get-ChildItem -LiteralPath $env:VIGIL_IT_KAFKA_RELEASE -Filter 'vigil-pack-kafka-*-windows.zip' | Sort-Object Name)[-1]
        $kx = Join-Path $work 'kafka-pack'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($kzip.FullName, $kx)
        $kdir = Join-Path $root 'packs\kafka'
        Remove-Item -LiteralPath $kdir -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $kx 'kafka') -Destination $kdir -Recurse
        $kjobs = 'status', 'quorum', 'brokers', 'replication', 'reassignment', 'consumers', 'groups', 'topics', 'logdirs', 'transactions', 'config', 'security', 'features', 'throughput', 'requests', 'controller', 'connections', 'tls'
        function Get-KafkaJobsOn {
            $list = (Invoke-Vigil pack list).Text
            $s = @($list.Split("`n") | Where-Object { $_ -match '^\s*kafka_\w+\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
            return (@($s | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ' '
        }
        function Invoke-KJob { param([string]$Job) return [string](Invoke-Vigil run $Job).Code }
        $kroot = Join-Path $root 'logs\jobs'
        Test-Equal 'kafka: off until enabled' 'off=18' (Get-KafkaJobsOn)
        Test-Equal 'kafka: its JVM is the jvm pack''s: no kafka_jvm' '0' ([string]@((Invoke-Vigil pack list).Text.Split("`n") | Where-Object { $_ -match '^\s*kafka_jvm\s' }).Count)
        $r = Invoke-Vigil pack enable kafka
        Test-Equal 'kafka: enabled' '0' ([string]$r.Code)
        Write-Host ($r.Text -replace '(?m)^', '        ')
        Test-Equal 'kafka: and it says so' 'True' ([string]($r.Text -match "needs for the brokers' JVMs .*the jvm pack"))
        Test-Equal 'kafka: its jobs are on' 'on=18' (Get-KafkaJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal 'kafka: the password is a secret reference, in the jobs that log in' '14' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*KAFKA_PASSWORD=secret:KAFKA_MONITOR_PASSWORD')).Count)
        # JMX with a password: a secret line on the jobs that read JMX.
        if ($env:VIGIL_IT_KAFKA_JMX) {
            [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(env\s*=\s*KAFKA_JMX_USER=[^\r\n]*)(\r?\n)', '$1$2secret      = KAFKA_JMX_PASSWORD=secret:KAFKA_JMX_PASSWORD$2'))
            Test-Equal 'kafka: the JMX password is a secret reference, in the jobs that read JMX' '5' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*KAFKA_JMX_PASSWORD=secret:KAFKA_JMX_PASSWORD')).Count)
        }
        # A logon with no password (SSH with a key) cannot use Vigil's secret
        # store: Windows refuses it its data protection, and Vigil says so.
        # Then the jobs take the passwords from this test's environment, by
        # env: references, as such a logon would.
        $kenv = $false
        Set-VigilSecret 'KAFKA_MONITOR_PASSWORD' $env:VIGIL_IT_KAFKA_PASSWORD
        if ((Invoke-Vigil secret list).Text -notmatch 'KAFKA_MONITOR_PASSWORD') {
            $kenv = $true
            Write-Host '  note  kafka: this logon cannot use the secret store (it has no password): the jobs take them by env:VIGIL_IT_KAFKA_PASSWORD and env:VIGIL_IT_KAFKA_JMX_PASSWORD'
            [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(secret\s*=\s*KAFKA_PASSWORD=)secret:KAFKA_MONITOR_PASSWORD', '${1}env:VIGIL_IT_KAFKA_PASSWORD' -replace '(?m)^(secret\s*=\s*KAFKA_JMX_PASSWORD=)secret:KAFKA_JMX_PASSWORD', '${1}env:VIGIL_IT_KAFKA_JMX_PASSWORD'))
        }
        elseif ($env:VIGIL_IT_KAFKA_JMX) { Set-VigilSecret 'KAFKA_JMX_PASSWORD' $env:VIGIL_IT_KAFKA_JMX_PASSWORD }
        Set-Env 'KAFKA_BOOTSTRAP' $env:VIGIL_IT_KAFKA_BOOTSTRAP
        Set-Env 'KAFKA_HOME' $env:VIGIL_IT_KAFKA_HOME
        Set-Env 'KAFKA_CACERT' ([string]$env:VIGIL_IT_KAFKA_CACERT)
        if ($env:VIGIL_IT_KAFKA_JMX) { Set-Env 'KAFKA_JMX' $env:VIGIL_IT_KAFKA_JMX; Set-Env 'KAFKA_JMX_USER' 'monitor' }
        $r = Invoke-Vigil precheck
        Test-Equal 'kafka: precheck is happy' '0' ([string]$r.Code)

        # Through the admin listener: a topic with messages, part of them read
        # by a group that then stops (lag), and a topic with a single replica.
        # The tools run as Java, each tool's class read from its .bat. Names
        # of this run's own.
        $kid = $PID
        $kworkload = $false
        if ($env:VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP) {
            function Invoke-KafkaAdmin {
                param([string]$Tool, [string[]]$Arguments)
                $bat = Join-Path $env:VIGIL_IT_KAFKA_HOME "bin\windows\$Tool.bat"
                if ([System.IO.File]::ReadAllText($bat) -cnotmatch 'kafka-run-class\.bat"?\s+([\w.$]+)') { return }
                $java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { (Get-Command java.exe).Source }
                [void](& $java -Xmx256m -cp (Join-Path $env:VIGIL_IT_KAFKA_HOME 'libs\*') $Matches[1] @Arguments 2>&1)
            }
            $ab = $env:VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP
            Invoke-KafkaAdmin 'kafka-topics' @('--bootstrap-server', $ab, '--create', '--if-not-exists', '--topic', "vigil_it_orders_$kid", '--partitions', '6')
            Invoke-KafkaAdmin 'kafka-topics' @('--bootstrap-server', $ab, '--create', '--if-not-exists', '--topic', "vigil_it_single_$kid", '--partitions', '1', '--replication-factor', '1')
            Invoke-KafkaAdmin 'kafka-producer-perf-test' @('--topic', "vigil_it_orders_$kid", '--num-records', '1000', '--record-size', '100', '--throughput', '-1', '--producer-props', "bootstrap.servers=$ab", 'acks=all')
            Invoke-KafkaAdmin 'kafka-console-consumer' @('--bootstrap-server', $ab, '--topic', "vigil_it_orders_$kid", '--group', "vigil_it_billing_$kid", '--from-beginning', '--max-messages', '300')
            $kworkload = $true
        }
        else { Write-Host '  SKIP  kafka: a topic, messages and a group with lag: set VIGIL_IT_KAFKA_ADMIN_BOOTSTRAP' }
        foreach ($j in $kjobs) {
            Test-Equal "kafka: $j runs" '0' (Invoke-KJob "kafka_$j")
            Show-LastRun "kafka_$j"
        }
        Test-Equal 'kafka: up' '1' (Get-Printed kafka_status up)
        Test-Equal 'kafka: what it is' 'True' ([string](@(Get-ChildItem -LiteralPath (Join-Path $kroot 'kafka_status') -Filter '*.log' | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } |
                        Where-Object { $_ -cmatch ' out metric info 1 cluster_id=[A-Za-z0-9_-]+ kraft=(yes|no)$' }).Count -gt 0))
        Test-Equal 'kafka: its brokers' 'yes' (Test-Between kafka_status brokers '' 1 10000)
        Test-Equal 'kafka: every partition has a leader' '0' (Get-Printed kafka_replication offline)
        Test-Equal 'kafka: the topics it sees' 'yes' (Test-Between kafka_replication topics '' 1 1e9)
        Test-Equal 'kafka: data on disk' 'yes' (Test-Between kafka_logdirs broker_size_bytes '' 1 1e18)
        Test-Equal 'kafka: ACLs are checked' '1' (Get-Printed kafka_security authorizer)
        Test-Equal 'kafka: unclean leader election off' '0' (Get-Printed kafka_config unclean_leader_election)
        Test-Equal 'kafka: TLS on its listener' '1' (Get-Printed kafka_tls tls)
        Test-Equal 'kafka: its certificate trusted' '1' (Get-Printed kafka_tls trusted)
        if ($kworkload) {
            Test-Equal 'kafka: a group behind on a topic' '700' (Get-Printed kafka_consumers lag "group=vigil_it_billing_$kid topic=vigil_it_orders_$kid")
            Test-Equal 'kafka: messages written, counted' '1000' (Get-Printed kafka_topics messages_count "topic=vigil_it_orders_$kid")
            Test-Equal 'kafka: the topic has 6 partitions' '6' (Get-Printed kafka_topics partitions "topic=vigil_it_orders_$kid")
        }
        if ($env:VIGIL_IT_KAFKA_JMX) {
            Test-Equal 'kafka: JMX over TLS with a password answers' '1' (Get-Printed kafka_throughput jmx_up)
            Test-Equal 'kafka: messages in, counted' 'yes' (Test-Between kafka_throughput messages_in_count '' 1 1e18)
            Test-Equal 'kafka: the log cleaner, read from JMX' 'yes' (Test-Between kafka_logdirs cleaner_dead_threads '' 0 1e9)
            $jvmish = @(Get-ChildItem -LiteralPath $kroot -Directory -Filter 'kafka_*' | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.log' } |
                    ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -cmatch ' out metric (heap_|gc_|threads |cpu_pct |open_files )' }).Count
            Test-Equal 'kafka: no heap, GC or threads: the jvm pack''s' '0' ([string]$jvmish)
            # JMX's failures: a wrong password and a certificate it cannot
            # trust fail the run, and say why.
            $kjpw = $env:VIGIL_IT_KAFKA_JMX_PASSWORD
            if ($kenv) { $env:VIGIL_IT_KAFKA_JMX_PASSWORD = 'not-the-password' } else { Set-VigilSecret 'KAFKA_JMX_PASSWORD' 'not-the-password' }
            Test-Equal 'kafka: a wrong JMX password fails the run' '2' (Invoke-KJob kafka_throughput)
            Test-Equal 'kafka: and says why' 'True' (Test-Said kafka_throughput 'refused the login')
            if ($kenv) { $env:VIGIL_IT_KAFKA_JMX_PASSWORD = $kjpw } else { Set-VigilSecret 'KAFKA_JMX_PASSWORD' $kjpw }
            if ($env:VIGIL_IT_KAFKA_CACERT) {
                Set-Env 'KAFKA_CACERT' ''
                Test-Equal 'kafka: a JMX certificate it cannot trust fails the run' '2' (Invoke-KJob kafka_controller)
                Test-Equal 'kafka: and says why' 'True' (Test-Said kafka_controller 'certificate is not trusted')
                Set-Env 'KAFKA_CACERT' $env:VIGIL_IT_KAFKA_CACERT
            }
        }

        # The jars: one changed by a byte is not run.
        $kpj = Join-Path $kdir '_probe.jar'
        Copy-Item -LiteralPath $kpj -Destination (Join-Path $work 'probe.keep')
        $b = [System.IO.File]::ReadAllBytes($kpj); $b[900] = $b[900] -bxor 0xFF; [System.IO.File]::WriteAllBytes($kpj, $b)
        Test-Equal 'kafka: a jar changed by one byte is not run' '2' (Invoke-KJob kafka_throughput)
        Test-Equal 'kafka: and says why' 'True' (Test-Said kafka_throughput 'does not match the digest')
        Copy-Item -LiteralPath (Join-Path $work 'probe.keep') -Destination $kpj -Force

        # Failures: a certificate it cannot trust and a wrong password fail the
        # run and say why; a cluster that is down reads as up 0.
        if ($env:VIGIL_IT_KAFKA_CACERT) {
            Set-Env 'KAFKA_CACERT' ''
            Test-Equal 'kafka: a certificate it cannot trust fails the run' '2' (Invoke-KJob kafka_status)
            Test-Equal 'kafka: and says why' 'True' (Test-Said kafka_status 'certificate')
            Test-Equal 'kafka: the certificate is still read' '0' (Invoke-KJob kafka_tls)
            Test-Equal 'kafka: and reported untrusted' 'True' (Test-Said kafka_tls ' trusted 0 ')
            Set-Env 'KAFKA_CACERT' $env:VIGIL_IT_KAFKA_CACERT
        }
        $kpw = $env:VIGIL_IT_KAFKA_PASSWORD
        if ($kenv) { $env:VIGIL_IT_KAFKA_PASSWORD = 'not-the-password' } else { Set-VigilSecret 'KAFKA_MONITOR_PASSWORD' 'not-the-password' }
        Test-Equal 'kafka: a wrong password fails the run' '2' (Invoke-KJob kafka_status)
        Test-Equal 'kafka: and says why' 'True' (Test-Said kafka_status 'refused the login')
        if ($kenv) { $env:VIGIL_IT_KAFKA_PASSWORD = $kpw } else { Set-VigilSecret 'KAFKA_MONITOR_PASSWORD' $kpw }
        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'spool'), (Join-Path $root 'metrics') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $t = [System.IO.File]::ReadAllText($_.FullName); $t.Contains($env:VIGIL_IT_KAFKA_PASSWORD) -or ($env:VIGIL_IT_KAFKA_JMX_PASSWORD -and $t.Contains($env:VIGIL_IT_KAFKA_JMX_PASSWORD)) })
        Test-Equal 'kafka: the passwords are written nowhere' '' ((@($leaks | ForEach-Object { $_.FullName.Substring($root.Length + 1) })) -join ' ')
        Test-Equal 'kafka: nothing is left behind' '0' ([string]@(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'vigil-kafka.*' -ErrorAction SilentlyContinue).Count)
        Set-Env 'KAFKA_BOOTSTRAP' 'localhost:1'
        Test-Equal 'kafka: a cluster that is down still runs' '0' (Invoke-KJob kafka_status)
        Test-Equal 'kafka: and reads as up 0' '0' (Get-Printed kafka_status up)
        Set-Env 'KAFKA_BOOTSTRAP' $env:VIGIL_IT_KAFKA_BOOTSTRAP
        [void](Invoke-KJob kafka_status)

        # Every job again, with a second Kafka library (VIGIL_IT_KAFKA_LIBS2),
        # on a JRE when one is given (VIGIL_IT_KAFKA_JRE): run directly, as the
        # jobs run them.
        if (-not $env:VIGIL_IT_KAFKA_LIBS2) { Write-Host '  SKIP  kafka with a second library: set VIGIL_IT_KAFKA_LIBS2' }
        else {
            $k2java = if ($env:VIGIL_IT_KAFKA_JRE) { $env:VIGIL_IT_KAFKA_JRE } else { $env:JAVA_HOME }
            Write-Host "kafka with the library $(@(Get-ChildItem -LiteralPath $env:VIGIL_IT_KAFKA_LIBS2 -Filter 'kafka-clients-*.jar')[0].Name), on $([string](& (Join-Path $k2java 'bin\java.exe') -version 2>&1 | Select-Object -First 1))"
            function Invoke-KDirect {
                param([string]$Job)
                $was = $env:JAVA_HOME
                $set = @{ JAVA_HOME = $k2java; KAFKA_LIBS = $env:VIGIL_IT_KAFKA_LIBS2; KAFKA_BOOTSTRAP = $env:VIGIL_IT_KAFKA_BOOTSTRAP; KAFKA_SECURITY = 'SASL_SSL'
                    KAFKA_SASL_MECHANISM = 'SCRAM-SHA-512'; KAFKA_USER = 'vigil_monitor'; KAFKA_PASSWORD = $env:VIGIL_IT_KAFKA_PASSWORD; KAFKA_CACERT = [string]$env:VIGIL_IT_KAFKA_CACERT
                    KAFKA_JMX = [string]$env:VIGIL_IT_KAFKA_JMX; KAFKA_JMX_USER = 'monitor'; KAFKA_JMX_PASSWORD = [string]$env:VIGIL_IT_KAFKA_JMX_PASSWORD }
                foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $set[$k]) }
                try {
                    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kdir "$Job.ps1") 2>&1
                    $code = $LASTEXITCODE
                }
                finally {
                    foreach ($k in $set.Keys) { if ($k -ne 'JAVA_HOME') { [Environment]::SetEnvironmentVariable($k, $null) } }
                    $env:JAVA_HOME = $was
                }
                [System.IO.File]::WriteAllText((Join-Path $work "k2.$Job"), ((@($out | ForEach-Object { "$_" })) -join "`n"))
                return [string]$code
            }
            $failed = @()
            foreach ($j in $kjobs) { if ((Invoke-KDirect $j) -ne '0') { $failed += $j } }
            Test-Equal 'kafka: every job runs with the second library' '' ($failed -join ' ')
            foreach ($j in $failed) { Get-Content -LiteralPath (Join-Path $work "k2.$j") -Tail 3 | ForEach-Object { Write-Host "        $_" } }
        }

        [void](Invoke-Vigil supervise --once)
        Start-Sleep -Seconds 3
        [void](Invoke-Vigil supervise --once)
        $prom = [System.IO.File]::ReadAllText((Join-Path $root 'metrics\vigil.prom'))
        Test-Equal 'kafka: metrics reach the backend' 'True' ([string](($prom -match '(?m)^kafka_up\{') -and ($prom -match '(?m)^kafka_replication_partitions\{')))
    }

    # --- jvm ----------------------------------------------------------------
    # A JVM of the test's own on this machine, as this account, without JMX:
    # the process and its counters, as Windows has them. And JMX to JVMs
    # elsewhere (VIGIL_IT_JVM_TARGETS, by tunnels to scripts/run-jvm.sh's).
    $jjava = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { [string](Get-Command java.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source) }
    if (-not $env:VIGIL_IT_JVM_TARGETS -or -not $env:VIGIL_IT_JVM_PASSWORD) { Write-Host '  SKIP  jvm: set VIGIL_IT_JVM_TARGETS and VIGIL_IT_JVM_PASSWORD (scripts/run-jvm.sh sets them up)' }
    elseif (-not $jjava -or -not (Test-Path -LiteralPath $jjava)) { Write-Host '  SKIP  jvm: java is not installed here' }
    elseif (-not $env:VIGIL_IT_JVM_RELEASE) { Write-Host '  SKIP  jvm: set VIGIL_IT_JVM_RELEASE to a folder of packs.sh''s archives, the jvm pack''s among them' }
    else {
        # The jobs have their JVMs, password and CA from Vigil: never from
        # this test's own environment.
        foreach ($v in 'JVM_TARGETS', 'JVM_JMX_USER', 'JVM_JMX_PASSWORD', 'JVM_CACERT', 'JVM_MBEANS', 'JVM_DUMP_DIRS') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
        $jtargets = "$($env:VIGIL_IT_JVM_TARGETS); win: main=-Dvigil.it=winplain"
        Write-Host "jvm: $jtargets"
        $script:jvmProc = Start-Process -FilePath $jjava -PassThru -NoNewWindow -WorkingDirectory $work `
            -RedirectStandardOutput (Join-Path $work 'winplain.out') -RedirectStandardError (Join-Path $work 'winplain.err') `
            -ArgumentList @('-Dvigil.it=winplain', '-Xmx128m', '-XX:+UseSerialGC', "`"$(Join-Path $repo 'tests\integration\backends\workloads\jvm\Trouble.java')`"", 'busy', 'leak', 'threadleak')
        # The pack as a release builds it, with its jars: from packs.sh's zip.
        $jzip = @(Get-ChildItem -LiteralPath $env:VIGIL_IT_JVM_RELEASE -Filter 'vigil-pack-jvm-*-windows.zip' | Sort-Object Name)[-1]
        $jkx = Join-Path $work 'jvm-pack'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($jzip.FullName, $jkx)
        $jk = Join-Path $root 'packs\jvm'
        Remove-Item -LiteralPath $jk -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $jkx 'jvm') -Destination $jk -Recurse
        function Get-JvmJobsOn {
            $list = (Invoke-Vigil pack list).Text
            $s = @($list.Split("`n") | Where-Object { $_ -match '^\s*jvm_\w+\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
            return (@($s | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ' '
        }
        function Invoke-JJob { param([string]$Job) return [string](Invoke-Vigil run "jvm_$Job").Code }
        Test-Equal 'jvm: off until enabled' 'off=41' (Get-JvmJobsOn)
        $r = Invoke-Vigil pack enable jvm
        Test-Equal 'jvm: enabled' '0' ([string]$r.Code)
        Write-Host ($r.Text -replace '(?m)^', '        ')
        Test-Equal 'jvm: its jobs are on' 'on=41' (Get-JvmJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal 'jvm: no secret line until JMX asks for one' '0' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*JVM_JMX_PASSWORD=')).Count)
        # JMX with a password: a secret line on each job, as packs/README.md
        # says. A logon with no password (SSH with a key) cannot use the
        # secret store: then the jobs take it by an env: reference, as such a
        # logon would.
        [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(env\s*=\s*JVM_CACERT=[^\r\n]*)(\r?\n)', '$1$2secret      = JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD$2'))
        Test-Equal 'jvm: the password is a secret reference, on every job' '41' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*JVM_JMX_PASSWORD=secret:JVM_JMX_PASSWORD')).Count)
        $jenv = $false
        Set-VigilSecret 'JVM_JMX_PASSWORD' $env:VIGIL_IT_JVM_PASSWORD
        if ((Invoke-Vigil secret list).Text -notmatch 'JVM_JMX_PASSWORD') {
            $jenv = $true
            Write-Host '  note  jvm: this logon cannot use the secret store (it has no password): the jobs take it by env:VIGIL_IT_JVM_PASSWORD'
            [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(secret\s*=\s*JVM_JMX_PASSWORD=)secret:JVM_JMX_PASSWORD', '${1}env:VIGIL_IT_JVM_PASSWORD'))
        }
        Set-Env 'JVM_TARGETS' $jtargets
        Set-Env 'JVM_JMX_USER' 'operator'
        Set-Env 'JVM_CACERT' ([string]$env:VIGIL_IT_JVM_CACERT)
        $r = Invoke-Vigil precheck
        Test-Equal 'jvm: precheck is happy' '0' ([string]$r.Code)
        # A while of trouble: threads leaked, the heap filling.
        Start-Sleep -Seconds 45
        $jlist = @(([System.IO.File]::ReadAllLines($cfg) | Where-Object { $_ -match '^\[job\.jvm_(\w+)\]' } | ForEach-Object { $Matches[1] }))
        foreach ($j in $jlist) {
            Test-Equal "jvm: $j runs" '0' (Invoke-JJob $j)
            Show-LastRun "jvm_$j"
        }
        # This machine's JVM: its process and counters, no JMX.
        Test-Equal 'jvm: found here' '1' (Get-Printed jvm_process running ' jvm=win')
        Test-Equal 'jvm: its memory' 'yes' (Test-Between jvm_process rss_bytes ' jvm=win' 1e6 1e11)
        Test-Equal 'jvm: its CPU time' 'yes' (Test-Between jvm_process cpu_seconds ' jvm=win' 0.1 1e9)
        Test-Equal 'jvm: its handles' 'yes' (Test-Between jvm_process open_files ' jvm=win' 1 1e7)
        Test-Equal 'jvm: from the process' '1' (Get-Printed jvm_status tier_os ' jvm=win')
        Test-Equal 'jvm: and its counters' '1' (Get-Printed jvm_status tier_counters ' jvm=win')
        Test-Equal 'jvm: and no JMX' '0' (Get-Printed jvm_status tier_jmx ' jvm=win')
        Test-Equal 'jvm: the heap, from the counters' 'yes' (Test-Between jvm_heap used_bytes ' jvm=win' 1 1e11)
        Test-Equal 'jvm: collections, counted' 'yes' (Test-Between jvm_gc collections_total ' jvm=win' 1 1e12)
        Test-Equal 'jvm: leaked threads' 'yes' (Test-Between jvm_threads live ' jvm=win' 30 1e6)
        Test-Equal 'jvm: the JIT' 'yes' (Test-Between jvm_jit compile_seconds ' jvm=win' 0.001 1e6)
        Test-Equal 'jvm: safepoints, a share of its time' 'yes' (Test-Between jvm_safepoints stopped_percent_lifetime ' jvm=win' 0 100)
        Test-Equal 'jvm: every JVM here, found' 'yes' (Test-Between jvm_discovery jvms '' 1 1000)
        # JMX elsewhere, by its address.
        if ($env:VIGIL_IT_JVM_TARGETS -match '(^|;)\s*j21:') {
            Test-Equal 'jvm: JMX with TLS and a password' '1' (Get-Printed jvm_status tier_jmx ' jvm=j21')
            Test-Equal 'jvm: a deadlock, named' '2' (Get-Printed jvm_deadlocks deadlocked ' jvm=j21')
            Test-Equal 'jvm: the heap, over JMX' 'yes' (Test-Between jvm_heap used_bytes ' jvm=j21' 1 1e11)
        }

        # Failures: a wrong password and a certificate it cannot trust fail
        # the run and say why; JMX that does not answer reads as jmx_up 0, a
        # JVM not running as running 0.
        $jpw = $env:VIGIL_IT_JVM_PASSWORD
        if ($jenv) { $env:VIGIL_IT_JVM_PASSWORD = 'not-the-password' } else { Set-VigilSecret 'JVM_JMX_PASSWORD' 'not-the-password' }
        Test-Equal 'jvm: a wrong password fails the run' '2' (Invoke-JJob heap)
        Test-Equal 'jvm: and says why' 'True' (Test-Said jvm_heap 'refused the login')
        if ($jenv) { $env:VIGIL_IT_JVM_PASSWORD = $jpw } else { Set-VigilSecret 'JVM_JMX_PASSWORD' $jpw }
        if ($env:VIGIL_IT_JVM_CACERT -and $env:VIGIL_IT_JVM_TARGETS -match 'jmxs=') {
            Set-Env 'JVM_CACERT' ''
            Test-Equal 'jvm: a certificate it cannot trust fails the run' '2' (Invoke-JJob heap)
            Test-Equal 'jvm: and says why' 'True' (Test-Said jvm_heap 'certificate is not trusted')
            Set-Env 'JVM_CACERT' $env:VIGIL_IT_JVM_CACERT
        }
        Set-Env 'JVM_TARGETS' 'gone: jmx=127.0.0.1:1; absent: main=-Dvigil.it=nowhere'
        Test-Equal 'jvm: JMX that does not answer still runs' '0' (Invoke-JJob status)
        Test-Equal 'jvm: and reads as jmx_up 0' '0' (Get-Printed jvm_status jmx_up ' jvm=gone')
        [void](Invoke-JJob process)
        Test-Equal 'jvm: a JVM not running reads as running 0' '0' (Get-Printed jvm_process running ' jvm=absent')
        Set-Env 'JVM_TARGETS' $jtargets
        [void](Invoke-JJob heap)
        [void](Invoke-JJob deadlocks)
        $leaks = @(Get-ChildItem -LiteralPath (Join-Path $root 'logs'), (Join-Path $root 'state'), (Join-Path $root 'spool'), (Join-Path $root 'metrics'), $cfg -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains($env:VIGIL_IT_JVM_PASSWORD) })
        Test-Equal 'jvm: the password is written nowhere' '' ((@($leaks | ForEach-Object { $_.FullName.Substring($root.Length + 1) })) -join ' ')

        # On a JRE: the client compiled, from a packs release that
        # tools/release/packs.sh built (VIGIL_IT_JVM_RELEASE, its folder), and
        # checked before it runs. Each script run directly, as the jobs run
        # them.
        if (-not $env:VIGIL_IT_JVM_JRE) { Write-Host '  SKIP  jvm on a JRE: set VIGIL_IT_JVM_JRE (a JRE 11 or later)' }
        else {
            $jreHome = $env:VIGIL_IT_JVM_JRE
            $jdkHome = Split-Path -Parent (Split-Path -Parent $jjava)
            Write-Host "jvm on a JRE: $([string](& (Join-Path $jreHome 'bin\java.exe') -version 2>&1 | Select-Object -First 1))"
            $jx = Join-Path $work 'jvm-jar'
            $zip = @(Get-ChildItem -LiteralPath $env:VIGIL_IT_JVM_RELEASE -Filter 'vigil-pack-jvm-*-windows.zip' | Sort-Object Name)[-1]
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $jx)
            $jp = Join-Path $jx 'jvm'
            $jar = Join-Path $jp '_client.jar'
            $pjar = Join-Path $jp '_probe.jar'
            function Get-JarSum {
                param([string]$Path)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $f = [System.IO.File]::OpenRead($Path)
                try { return -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) } finally { $f.Dispose(); $sha.Dispose() }
            }
            Test-Equal 'jvm: the release has its client and the probe compiled' 'True' ([string]((Test-Path -LiteralPath $jar) -and (Test-Path -LiteralPath $pjar)))
            $sum = Get-JarSum $jar
            $psum = Get-JarSum $pjar
            Test-Equal "jvm: the client's digest is in every script" '41' ([string]@(Get-ChildItem -LiteralPath $jp -Filter '*.ps1' | Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains("`$clientSha256 = '$sum'") }).Count)
            Test-Equal "jvm: and the probe's" '41' ([string]@(Get-ChildItem -LiteralPath $jp -Filter '*.ps1' | Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains("`$probeSha256 = '$psum'") }).Count)
            Test-Equal 'jvm: its probe is the shared one' 'True' ([string]([System.IO.File]::ReadAllText((Join-Path $jp '_probe.java')) -ceq [System.IO.File]::ReadAllText((Join-Path $repo 'tools\probe\_probe.java'))))
            Test-Equal 'jvm: the JRE has no compiler' 'False' ([string](Test-Path -LiteralPath (Join-Path $jreHome 'bin\javac.exe')))
            # $JavaHome's Java runs job $Job, its output in jre.<job>; the exit code.
            function Invoke-Direct {
                param([string]$JavaHome, [string]$Job, [string]$Dir = $jp)
                $was = $env:JAVA_HOME
                $env:JAVA_HOME = $JavaHome; $env:JVM_TARGETS = $jtargets; $env:JVM_JMX_USER = 'operator'
                $env:JVM_JMX_PASSWORD = $env:VIGIL_IT_JVM_PASSWORD; $env:JVM_CACERT = [string]$env:VIGIL_IT_JVM_CACERT
                try {
                    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir "$Job.ps1") 2>&1
                    $code = $LASTEXITCODE
                }
                finally {
                    $env:JAVA_HOME = $was
                    foreach ($v in 'JVM_TARGETS', 'JVM_JMX_USER', 'JVM_JMX_PASSWORD', 'JVM_CACERT') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
                }
                [System.IO.File]::WriteAllText((Join-Path $work "jre.$Job"), ((@($out | ForEach-Object { "$_" })) -join "`n"))
                return [string]$code
            }
            function Get-Names { param([string]$Job) return ((@([System.IO.File]::ReadAllLines((Join-Path $work "jre.$Job")) | ForEach-Object { $w = $_ -split ' '; if ($w.Count -gt 2) { $w[2] = '' }; $w -join ' ' } | Sort-Object)) -join "`n") }
            $failed = @()
            $t = [System.Diagnostics.Stopwatch]::StartNew()
            foreach ($j in $jlist) { if ((Invoke-Direct $jreHome $j) -ne '0') { $failed += $j } }
            Test-Equal 'jvm: every job runs on the JRE, from the jar' '' ($failed -join ' ')
            foreach ($j in $failed) { Get-Content -LiteralPath (Join-Path $work "jre.$j") -Tail 3 | ForEach-Object { Write-Host "        $_" } }
            Write-Host ('        41 jobs from the jar in {0} s' -f [int]$t.Elapsed.TotalSeconds)
            Test-Equal 'jvm: and every JVM is up' ([string]@($jtargets.Split(';') | Where-Object { $_.Trim() }).Count) ([string]@([System.IO.File]::ReadAllLines((Join-Path $work 'jre.status')) | Where-Object { $_ -like 'metric up 1 *' }).Count)
            # The same lines as the same jars give on a JDK, values apart.
            $differ = @()
            foreach ($j in 'status', 'heap', 'gc', 'threads', 'classes', 'jit', 'metaspace', 'codecache', 'flags', 'security') {
                $a = Get-Names $j
                [void](Invoke-Direct $jdkHome $j)
                if ((Get-Names $j) -cne $a) { $differ += $j }
            }
            Test-Equal 'jvm: the same lines as on a JDK' '' ($differ -join ' ')
            # A jar changed by one byte is not run, by any Java.
            Copy-Item -LiteralPath $jar -Destination (Join-Path $work 'keep.jar')
            $b = [System.IO.File]::ReadAllBytes($jar); $b[1000] = $b[1000] -bxor 0xFF; [System.IO.File]::WriteAllBytes($jar, $b)
            Test-Equal 'jvm: a jar changed by one byte is not run' '1' (Invoke-Direct $jreHome heap)
            Test-Equal 'jvm: and says why' 'True' ([string]([System.IO.File]::ReadAllText((Join-Path $work 'jre.heap')).Contains('does not match the digest in this script')))
            Test-Equal 'jvm: nor by a JDK' '1' (Invoke-Direct $jdkHome heap)
            Copy-Item -LiteralPath (Join-Path $work 'keep.jar') -Destination $jar -Force
            # The probe too: the client runs on its engine.
            Copy-Item -LiteralPath $pjar -Destination (Join-Path $work 'keep.jar') -Force
            $b = [System.IO.File]::ReadAllBytes($pjar); $b[1000] = $b[1000] -bxor 0xFF; [System.IO.File]::WriteAllBytes($pjar, $b)
            Test-Equal 'jvm: a probe changed by one byte is not run' '1' (Invoke-Direct $jreHome heap)
            Test-Equal 'jvm: and says which' 'True' ([string]([System.IO.File]::ReadAllText((Join-Path $work 'jre.heap')).Contains('_probe.jar does not match the digest in this script')))
            Copy-Item -LiteralPath (Join-Path $work 'keep.jar') -Destination $pjar -Force
            Copy-Item -LiteralPath (Join-Path $repo 'packs\jvm\windows\heap.ps1') -Destination (Join-Path $jp 'heap.ps1') -Force
            Test-Equal 'jvm: a script with no digest runs no jar' '1' (Invoke-Direct $jreHome heap)
            Remove-Item -LiteralPath $pjar
            Test-Equal 'jvm: no probe, and nothing runs' '1' (Invoke-Direct $jreHome status)
            Test-Equal 'jvm: and says so' 'True' ([string]([System.IO.File]::ReadAllText((Join-Path $work 'jre.status')).Contains('_probe.jar not found')))
        }

        # Forty-one jobs are a lot of events: the sender merges them in the
        # background.
        $prom = ''
        foreach ($i in 1..40) {
            [void](Invoke-Vigil supervise --once)
            $pf = Join-Path $root 'metrics\vigil.prom'
            if (Test-Path -LiteralPath $pf) { $prom = [System.IO.File]::ReadAllText($pf) }
            if ($prom -match '(?m)^jvm_heap_used_bytes\{.*jvm="win"') { break }
            Start-Sleep -Seconds 3
        }
        Test-Equal 'jvm: metrics reach the backend' 'True' ([string](($prom -match '(?m)^jvm_heap_used_bytes\{.*jvm="win"') -and ($prom -match '(?m)^jvm_threads_live\{')))
    }

    # --- a pack on the probe: tomcat, jetty, activemq, artemis -------------
    # One of the packs that are only tables for the probe, through Vigil, as
    # its scripts/run-<pack>.sh sets it up: VIGIL_IT_PROBE_PACK its name,
    # VIGIL_IT_PROBE_RELEASE a folder of packs.sh's archives (its own among
    # them), VIGIL_IT_PROBE_TARGETS its servers, VIGIL_IT_PROBE_USER and
    # VIGIL_IT_PROBE_PASSWORD their JMX login, VIGIL_IT_PROBE_CACERT their CA,
    # VIGIL_IT_PROBE_EXPECT a metric that must reach the backend.
    $pjava = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { [string](Get-Command java.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source) }
    if (-not $env:VIGIL_IT_PROBE_PACK) { Write-Host '  SKIP  a pack on the probe: set VIGIL_IT_PROBE_PACK (scripts/run-tomcat.sh and the like set it up)' }
    elseif (-not $pjava -or -not (Test-Path -LiteralPath $pjava)) { Write-Host "  SKIP  $($env:VIGIL_IT_PROBE_PACK): java is not installed here" }
    elseif (-not $env:VIGIL_IT_PROBE_RELEASE) { Write-Host "  SKIP  $($env:VIGIL_IT_PROBE_PACK): set VIGIL_IT_PROBE_RELEASE to a folder of packs.sh's archives" }
    else {
        $pp = $env:VIGIL_IT_PROBE_PACK
        $PU = $pp.ToUpperInvariant()
        foreach ($v in "${PU}_JMX", "${PU}_JMX_USER", "${PU}_JMX_PASSWORD", "${PU}_CACERT") { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
        Write-Host "${pp}: $($env:VIGIL_IT_PROBE_TARGETS)"
        $pzip = @(Get-ChildItem -LiteralPath $env:VIGIL_IT_PROBE_RELEASE -Filter "vigil-pack-$pp-*-windows.zip" | Sort-Object Name)[-1]
        $pkx = Join-Path $work "$pp-pack"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($pzip.FullName, $pkx)
        $pk = Join-Path $root "packs\$pp"
        Remove-Item -LiteralPath $pk -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $pkx $pp) -Destination $pk -Recurse
        $pjobs = @(([System.IO.File]::ReadAllLines((Join-Path $pk 'pack.config')) | Where-Object { $_ -match '^\[job\.(\w+)\]' } | ForEach-Object { $Matches[1] }))
        $pn = $pjobs.Count
        function Get-ProbeJobsOn {
            $list = (Invoke-Vigil pack list).Text
            $s = @($list.Split("`n") | Where-Object { $_ -match "^\s*${pp}_\w+\s" } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
            return (@($s | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ' '
        }
        function Invoke-PJob { param([string]$Job) return [string](Invoke-Vigil run "${pp}_$Job").Code }
        Test-Equal "${pp}: off until enabled" "off=$pn" (Get-ProbeJobsOn)
        $r = Invoke-Vigil pack enable $pp
        Test-Equal "${pp}: enabled" '0' ([string]$r.Code)
        Write-Host ($r.Text -replace '(?m)^', '        ')
        Test-Equal "${pp}: it says its JVM is the jvm pack's" 'True' ([string]$r.Text.Contains('the jvm pack, not this one'))
        Test-Equal "${pp}: its jobs are on" "on=$pn" (Get-ProbeJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal "${pp}: no secret line until JMX asks for one" '0' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), "(?m)^secret\s*=\s*${PU}_JMX_PASSWORD=")).Count)
        [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace "(?m)^(env\s*=\s*${PU}_CACERT=[^\r\n]*)(\r?\n)", "`$1`$2secret      = ${PU}_JMX_PASSWORD=secret:${PU}_JMX_PASSWORD`$2"))
        Test-Equal "${pp}: the password is a secret reference, on every job" "$pn" ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), "(?m)^secret\s*=\s*${PU}_JMX_PASSWORD=secret:${PU}_JMX_PASSWORD")).Count)
        # A logon with no password (SSH with a key) cannot use the secret
        # store: then the jobs take it by an env: reference, as such a logon
        # would.
        $penv = $false
        Set-VigilSecret "${PU}_JMX_PASSWORD" $env:VIGIL_IT_PROBE_PASSWORD
        if ((Invoke-Vigil secret list).Text -notmatch "${PU}_JMX_PASSWORD") {
            $penv = $true
            Write-Host "  note  ${pp}: this logon cannot use the secret store (it has no password): the jobs take it by env:VIGIL_IT_PROBE_PASSWORD"
            [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace "(?m)^(secret\s*=\s*${PU}_JMX_PASSWORD=)secret:${PU}_JMX_PASSWORD", '${1}env:VIGIL_IT_PROBE_PASSWORD'))
        }
        Set-Env "${PU}_JMX" $env:VIGIL_IT_PROBE_TARGETS
        Set-Env "${PU}_JMX_USER" $env:VIGIL_IT_PROBE_USER
        Set-Env "${PU}_CACERT" ([string]$env:VIGIL_IT_PROBE_CACERT)
        $r = Invoke-Vigil precheck
        Test-Equal "${pp}: precheck is happy" '0' ([string]$r.Code)
        $failed = @()
        foreach ($j in $pjobs) { if ((Invoke-PJob $j) -ne '0') { $failed += $j } }
        Test-Equal "${pp}: every job runs" '' ($failed -join ' ')
        foreach ($j in $failed) { Show-LastRun "${pp}_$j" }
        foreach ($t in $env:VIGIL_IT_PROBE_TARGETS.Split(';')) {
            if ($t -match '^\s*([A-Za-z0-9_.-]+):\s') { Test-Equal "${pp}: $($Matches[1]) answers over JMX" '1' (Get-Printed "${pp}_status" jmx_up "=$($Matches[1]) ") }
        }
        Show-LastRun "${pp}_status"
        # What fails the run, saying why; a server that does not answer is a reading.
        if ($penv) { $keep = $env:VIGIL_IT_PROBE_PASSWORD; $env:VIGIL_IT_PROBE_PASSWORD = 'not-the-password' }
        else { Set-VigilSecret "${PU}_JMX_PASSWORD" 'not-the-password' }
        Test-Equal "${pp}: a wrong password fails the run" '2' (Invoke-PJob status)
        Test-Equal "${pp}: and says why" 'True' (Test-Said "${pp}_status" 'refused the login')
        if ($penv) { $env:VIGIL_IT_PROBE_PASSWORD = $keep } else { Set-VigilSecret "${PU}_JMX_PASSWORD" $env:VIGIL_IT_PROBE_PASSWORD }
        if ($env:VIGIL_IT_PROBE_CACERT) {
            Set-Env "${PU}_CACERT" ''
            Test-Equal "${pp}: a certificate it cannot trust fails the run" '2' (Invoke-PJob status)
            Test-Equal "${pp}: and says why" 'True' (Test-Said "${pp}_status" 'certificate is not trusted')
            Set-Env "${PU}_CACERT" $env:VIGIL_IT_PROBE_CACERT
        }
        Set-Env "${PU}_JMX" 'gone: jmx=127.0.0.1:1'
        Test-Equal "${pp}: a server that does not answer still runs" '0' (Invoke-PJob status)
        Test-Equal "${pp}: and reads as jmx_up 0" '0' (Get-Printed "${pp}_status" jmx_up '=gone ')
        Set-Env "${PU}_JMX" $env:VIGIL_IT_PROBE_TARGETS
        [void](Invoke-PJob status)
        $leaks = @()
        foreach ($d in 'logs', 'state', 'spool', 'metrics') {
            foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue) {
                if ([System.IO.File]::ReadAllText($f.FullName).Contains($env:VIGIL_IT_PROBE_PASSWORD)) { $leaks += $f.Name }
            }
        }
        if ([System.IO.File]::ReadAllText($cfg).Contains($env:VIGIL_IT_PROBE_PASSWORD)) { $leaks += 'vigil.config' }
        Test-Equal "${pp}: the password is written nowhere" '' ($leaks -join ' ')
        $prom = ''
        foreach ($i in 1..20) {
            [void](Invoke-Vigil supervise --once)
            $pf = Join-Path $root 'metrics\vigil.prom'
            if (Test-Path -LiteralPath $pf) { $prom = [System.IO.File]::ReadAllText($pf) }
            if ($prom -match "(?m)^$($env:VIGIL_IT_PROBE_EXPECT)\{") { break }
            Start-Sleep -Seconds 3
        }
        Test-Equal "${pp}: metrics reach the backend" 'True' ([string](($prom -match "(?m)^$($env:VIGIL_IT_PROBE_EXPECT)\{") -and ($prom -match "(?m)^${pp}_jmx_up\{")))
    }

    # --- beam --------------------------------------------------------------
    # Erlang VMs, through Vigil: VIGIL_IT_BEAM_DIST the nodes (name=node;...),
    # VIGIL_IT_BEAM_COOKIE their cookie, VIGIL_IT_BEAM_ERLANG where Erlang is,
    # VIGIL_IT_BEAM_PROMETHEUS Prometheus pages (name=url;...),
    # VIGIL_IT_BEAM_DUMPS a folder of crash dumps, VIGIL_IT_BEAM_TROUBLE the
    # node running workloads/beam/trouble.erl.
    if (-not $env:VIGIL_IT_BEAM_DIST -or -not $env:VIGIL_IT_BEAM_COOKIE) { Write-Host '  SKIP  beam: set VIGIL_IT_BEAM_DIST and VIGIL_IT_BEAM_COOKIE' }
    else {
        foreach ($v in 'BEAM_DIST', 'BEAM_COOKIE', 'BEAM_PROMETHEUS', 'BEAM_ERLANG', 'BEAM_EPMD', 'BEAM_CRASH_DUMPS') { Remove-Item "Env:\$v" -ErrorAction SilentlyContinue }
        Write-Host "beam: $($env:VIGIL_IT_BEAM_DIST); $($env:VIGIL_IT_BEAM_PROMETHEUS)"
        $profileCookie = Join-Path $env:USERPROFILE '.erlang.cookie'
        $cookieBefore = [string](Test-Path -LiteralPath $profileCookie)
        $bjobs = @(([System.IO.File]::ReadAllLines((Join-Path $bk 'pack.config')) | Where-Object { $_ -match '^\[job\.(\w+)\]' } | ForEach-Object { $Matches[1] }))
        $bn = $bjobs.Count
        function Get-BeamJobsOn {
            $list = (Invoke-Vigil pack list).Text
            $s = @($list.Split("`n") | Where-Object { $_ -match '^\s*beam_\w+\s' } | ForEach-Object { ($_.Trim() -split '\s+')[1] })
            return (@($s | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join ' '
        }
        function Invoke-BJob { param([string]$Job) return [string](Invoke-Vigil run "beam_$Job").Code }
        function Test-AtLeast { param([string]$Job, [string]$Name, [string]$Tag, [double]$Low) return (Test-Between "beam_$Job" $Name $Tag $Low 1e18) }
        Test-Equal 'beam: off until enabled' "off=$bn" (Get-BeamJobsOn)
        $r = Invoke-Vigil pack enable beam
        Test-Equal 'beam: enabled' '0' ([string]$r.Code)
        Write-Host ($r.Text -replace '(?m)^', '        ')
        Test-Equal 'beam: it warns what the cookie allows' 'True' ([string](($r.Text -replace '\s+', ' ').Contains('WARNING: the cookie lets whoever holds it run anything on the node; this pack only reads')))
        Test-Equal 'beam: its jobs are on' "on=$bn" (Get-BeamJobsOn)
        $cfg = Join-Path $root 'config\vigil.config'
        Test-Equal 'beam: no secret line until the cookie is asked for' '0' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*BEAM_COOKIE=')).Count)
        [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(env\s*=\s*BEAM_ERLANG=[^\r\n]*)(\r?\n)', "`$1`$2secret      = BEAM_COOKIE=secret:BEAM_COOKIE`$2"))
        Test-Equal 'beam: the cookie is a secret reference, on the five jobs that read it' '5' ([string]([regex]::Matches([System.IO.File]::ReadAllText($cfg), '(?m)^secret\s*=\s*BEAM_COOKIE=secret:BEAM_COOKIE')).Count)
        # A logon with no password (SSH with a key) cannot use the secret
        # store: then the jobs take it by an env: reference.
        $benv = $false
        Set-VigilSecret BEAM_COOKIE $env:VIGIL_IT_BEAM_COOKIE
        if ((Invoke-Vigil secret list).Text -notmatch 'BEAM_COOKIE') {
            $benv = $true
            Write-Host '  note  beam: this logon cannot use the secret store (it has no password): the jobs take the cookie by env:VIGIL_IT_BEAM_COOKIE'
            [System.IO.File]::WriteAllText($cfg, ([System.IO.File]::ReadAllText($cfg) -replace '(?m)^(secret\s*=\s*BEAM_COOKIE=)secret:BEAM_COOKIE', '${1}env:VIGIL_IT_BEAM_COOKIE'))
        }
        Set-Env BEAM_DIST $env:VIGIL_IT_BEAM_DIST
        Set-Env BEAM_ERLANG ([string]$env:VIGIL_IT_BEAM_ERLANG)
        Set-Env BEAM_PROMETHEUS ([string]$env:VIGIL_IT_BEAM_PROMETHEUS)
        Set-Env BEAM_CRASH_DUMPS ([string]$env:VIGIL_IT_BEAM_DUMPS)
        $r = Invoke-Vigil precheck
        Test-Equal 'beam: precheck is happy' '0' ([string]$r.Code)
        $failed = @()
        foreach ($j in $bjobs) { if ((Invoke-BJob $j) -ne '0') { $failed += $j } }
        Test-Equal 'beam: every job runs' '' ($failed -join ' ')
        foreach ($j in $failed) { Show-LastRun "beam_$j" }
        Test-Equal 'beam: process: the VMs are seen' 'yes' (Test-AtLeast process beams '' 1)
        Test-Equal 'beam: epmd answers' '1' (Get-Printed beam_epmd epmd_up)
        foreach ($t in $env:VIGIL_IT_BEAM_DIST.Split(';')) {
            if ($t -match '^\s*([^=]+)=') {
                $n = $Matches[1].Trim()
                Test-Equal "beam: $n answers with the cookie" '1' (Get-Printed beam_vm up "node=$n source=dist")
                Test-Equal "beam: $n says its version" '1' (Get-Printed beam_vm version "node=$n source=dist")
            }
        }
        foreach ($t in ([string]$env:VIGIL_IT_BEAM_PROMETHEUS).Split(';')) {
            if ($t -match '^\s*([^=]+)=') {
                $n = $Matches[1].Trim()
                Test-Equal "beam: $n answers on Prometheus" '1' (Get-Printed beam_vm up "node=$n source=prometheus")
                Test-Equal "beam: ${n}'s atoms are counted" 'yes' (Test-AtLeast vm atoms "node=$n source=prometheus" 1000)
            }
        }
        if ($env:VIGIL_IT_BEAM_TROUBLE) {
            $tr = $env:VIGIL_IT_BEAM_TROUBLE
            Test-Equal 'beam: the mailbox nobody reads is the longest' 'yes' (Test-AtLeast processes mailbox "node=$tr source=dist process=slow_consumer" 100)
            Test-Equal 'beam: the cache that never evicts is the largest table' 'True' ([string](@(Get-ChildItem -LiteralPath (Join-Path $root 'logs\jobs\beam_tables') -Filter *.log | ForEach-Object { [System.IO.File]::ReadAllLines($_.FullName) } | Where-Object { $_ -match " out metric table_memory_bytes \S+ node=$tr " })[0] -match 'table=leaky_cache owner=trouble:cache/1'))
            Test-Equal 'beam: its applications are listed' '1' (Get-Printed beam_apps app "node=$tr source=dist app=kernel ")
        }
        if ($env:VIGIL_IT_BEAM_DUMPS) {
            Test-Equal 'beam: the crash dumps are found' 'yes' (Test-AtLeast crashdumps dumps '' 1)
            Test-Equal 'beam: and why the VM died' 'True' ([string]((Get-Printed beam_crashdumps dump 'slogan=no_more_index_entries_in_atom_tab') -eq '1'))
        }
        Show-LastRun beam_vm
        if ($benv) { $keep = $env:VIGIL_IT_BEAM_COOKIE; $env:VIGIL_IT_BEAM_COOKIE = 'not-the-cookie' }
        else { Set-VigilSecret BEAM_COOKIE 'not-the-cookie' }
        Test-Equal 'beam: a wrong cookie fails the run' '2' (Invoke-BJob vm)
        Test-Equal "beam: and says the cookie, or the name, is not the node's" 'True' (Test-Said beam_vm 'is not its cookie, or')
        if ($benv) { $env:VIGIL_IT_BEAM_COOKIE = $keep } else { Set-VigilSecret BEAM_COOKIE $env:VIGIL_IT_BEAM_COOKIE }
        Set-Env BEAM_DIST 'gone=vigil_gone@127.0.0.1'
        Test-Equal 'beam: a node that is down still runs' '0' (Invoke-BJob dist)
        Test-Equal 'beam: and reads as up 0' '0' (Get-Printed beam_dist up 'node=gone ')
        Set-Env BEAM_DIST $env:VIGIL_IT_BEAM_DIST
        [void](Invoke-BJob vm)
        $leaks = @()
        foreach ($d in 'logs', 'state', 'spool', 'metrics') {
            foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -ErrorAction SilentlyContinue) {
                if ([System.IO.File]::ReadAllText($f.FullName).Contains($env:VIGIL_IT_BEAM_COOKIE)) { $leaks += $f.Name }
            }
        }
        if ([System.IO.File]::ReadAllText($cfg).Contains($env:VIGIL_IT_BEAM_COOKIE)) { $leaks += 'vigil.config' }
        Test-Equal 'beam: the cookie is written nowhere' '' ($leaks -join ' ')
        Test-Equal 'beam: and Erlang wrote no cookie file into this profile' $cookieBefore ([string](Test-Path -LiteralPath $profileCookie))
        Test-Equal 'beam: no home of a run is left behind' '0' ([string]@(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'vigil-beam.*' -ErrorAction SilentlyContinue).Count)
        $prom = ''
        foreach ($i in 1..20) {
            [void](Invoke-Vigil supervise --once)
            $pf = Join-Path $root 'metrics\vigil.prom'
            if (Test-Path -LiteralPath $pf) { $prom = [System.IO.File]::ReadAllText($pf) }
            if ($prom -match '(?m)^beam_vm_up\{') { break }
            Start-Sleep -Seconds 3
        }
        Test-Equal 'beam: metrics reach the backend' 'True' ([string](($prom -match '(?m)^beam_vm_up\{') -and ($prom -match '(?m)^beam_processes_mailbox_messages\{')))
    }
}
finally {
    # The mssql test's own connections, holding a lock or waiting on one.
    foreach ($c in $holder, $waiter, $sa) { if ($c) { try { $c.Dispose() } catch { } } }
    if ($script:blocked) { $script:blocked.Tcp.Close() }
    if ($hold -and -not $hold.HasExited) { Stop-Process -Id $hold.Id -Force -ErrorAction SilentlyContinue }
    # The jvm test's JVM: the one it started, by its process.
    if ($script:jvmProc -and -not $script:jvmProc.HasExited) { Stop-Process -Id $script:jvmProc.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
