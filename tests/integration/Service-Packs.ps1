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
    Integration test: the postgres service pack against a real server, on
    Windows. The twin of service-packs.sh (nginx has no Windows script).
.DESCRIPTION
    Tested only when a server is given, and SKIPped otherwise:
        VIGIL_IT_PG_HOST, VIGIL_IT_PG_PORT   a PostgreSQL server (port 5432 by default)
        VIGIL_IT_PG_PASSWORD                 its vigil_monitor role's password; the
                                             role has pg_monitor and nothing more
    psql is found as the pack finds it: on the PATH, or in PostgreSQL's own
    folders under Program Files.

    The pack is off until enabled; vigil pack enable puts its jobs in the
    configuration; each job runs and reports what the server says; a long
    query and transaction are seen; a wrong password fails the run and says
    why; a server that is down reads as up 0; its metrics reach a backend;
    and the password is written nowhere.

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
}
finally {
    if ($hold -and -not $hold.HasExited) { Stop-Process -Id $hold.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}

Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
