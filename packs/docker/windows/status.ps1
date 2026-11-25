#Requires -Version 5.1

<#
.SYNOPSIS
    status.ps1 - the engine: up, its version, and its containers by state
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Whether the engine answers, and what it holds: containers running, paused,
    stopped, restarting, those whose health check fails, those that ended with
    an error, and its images.

    Reads the Docker engine's API at DOCKER_HOST
    (npipe:////./pipe/docker_engine by default) with .NET alone. Every request
    is a GET: nothing is started, stopped, removed or pruned.

    Metrics:
      up                1 when the engine answers, else 0 (and nothing more is
                        read)
      version           always 1, tagged version=<the engine's version>,
                        api=<its API's version> and os=<linux or windows: the
                        containers it runs>
      containers        containers it holds, running or not
      running           of those, running
      paused            paused
      restarting        between two starts: the container stopped, and its
                        restart policy is starting it again. One that stays
                        here is in a loop
      exited            stopped: they ran, and ended
      created           created, and never started
      dead              that the engine could not remove
      unhealthy         running, with a health check that fails
      health_starting   running, with a health check that has not passed yet
      exited_nonzero    stopped with an exit code other than 0
      images            images it holds
      cpus              processors the engine sees
      memory_bytes      memory the engine sees
      warnings          what the engine warns about itself (docker info prints
                        them)

    Example output:
      metric up 1
      metric version 1 version=29.9.3 api=1.56 os=linux
      metric containers 16
      metric running 11
      metric paused 1
      metric restarting 0
      metric exited 3
      metric created 1
      metric dead 0
      metric unhealthy 1
      metric health_starting 0
      metric exited_nonzero 2
      metric images 18
      metric cpus 4
      metric memory_bytes 8188477440
      metric warnings 0

    Reading the results (starting points: tune them to the machine):
      Healthy  up 1; unhealthy 0; restarting 0; exited_nonzero steady (a job
               that failed once stays counted until its container is removed).
      Watch    health_starting above 0 for minutes: a health check that never
               passes. running lower than it was: something stopped and
               nothing started it again.
      Act      up 0: the engine is down, and so is every container without
               live restore. unhealthy above 0. restarting above 0 on two runs
               in a row: a container in a restart loop (docker_containers
               names it, by restarts_count rising).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, the engine up or down; 1 if DOCKER_HOST is wrong,
      this account may not use the engine, or what answers is not a Docker
      engine
#>

$Job = 'status'
. (Join-Path $PSScriptRoot '_docker.ps1')

Test-Engine
$v = $script:Version
$i = Get-Json '/info'
$all = Get-Json '/containers/json?all=1'
$c = @($all)
function Count([scriptblock]$Where) { return @($c | Where-Object $Where).Count }
$os = $i.OSType; if (-not $os) { $os = $v.Os }
"metric version 1 version=$(Safe $v.Version) api=$(Safe $v.ApiVersion) os=$(Safe $os)"
"metric containers $($c.Count)"
"metric running $(Count { $_.State -ceq 'running' })"
"metric paused $(Count { $_.State -ceq 'paused' })"
"metric restarting $(Count { $_.State -ceq 'restarting' })"
"metric exited $(Count { $_.State -ceq 'exited' })"
"metric created $(Count { $_.State -ceq 'created' })"
"metric dead $(Count { $_.State -ceq 'dead' })"
$unhealthy = Count { "$($_.Status)" -cmatch '\(unhealthy\)' }
"metric unhealthy $unhealthy"
$starting = Count { "$($_.Status)" -cmatch '\(health: starting\)' }
"metric health_starting $starting"
$nonzero = Count { $_.State -ceq 'exited' -and "$($_.Status)" -cmatch '^Exited \([1-9-]' }
"metric exited_nonzero $nonzero"
"metric images $(Num $i.Images)"
"metric cpus $(Num $i.NCPU)"
"metric memory_bytes $(Num $i.MemTotal)"
"metric warnings $(@($i.Warnings | Where-Object { $null -ne $_ }).Count)"
exit 0
