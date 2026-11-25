#Requires -Version 5.1

<#
.SYNOPSIS
    containers.ps1 - each container: running or not, restarts, health, exit code, killed for memory
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Each container by name (the first 100; DOCKER_MOST sets another number):
    whether it runs, how many times its restart policy has started it again,
    whether its health check passes, the exit code of one that stopped, and
    whether the kernel killed it for memory.

    Reads the Docker engine's API at DOCKER_HOST
    (npipe:////./pipe/docker_engine by default) with .NET alone. Every request
    is a GET: nothing is started, stopped, removed or pruned.

    Metrics:
      up                          1 when the engine answers, else 0 (and
                                  nothing more is read)
      containers                  containers it holds, running or not
      containers_restarting       of those named below, between two starts
      containers_unhealthy        of those named below, with a health check
                                  that fails
      containers_oom_killed       killed for memory: the kernel ended them at
                                  their limit
      containers_exited_nonzero   stopped with an exit code other than 0
      restarts_total_count        times a restart policy started them again (a
                                  running total, over those named below)
      running                     1 when the container runs, 0 when it does
                                  not (stopped, paused, created, between two
                                  starts), tagged name=<the container's name>
                                  and state=<its state>
      restarts_count              times its restart policy started it again (a
                                  running total), tagged name=<the container's
                                  name>
      oom_killed                  1 when it was killed for memory, tagged
                                  name=<the container's name>
      uptime_seconds              for one that runs: seconds since it last
                                  started, tagged name=<the container's name>
      healthy                     for one with a health check that has run: 1
                                  healthy, 0 unhealthy, tagged name=<the
                                  container's name>
      exit_code                   for one that stopped: its exit code, tagged
                                  name=<the container's name>
      containers_not_shown        past the first 100 by name (DOCKER_MOST),
                                  how many were not named

    Example output:
      metric up 1

    Reading the results (starting points: tune them to the machine):
      Healthy  running 1 for every container meant to run; restarts_count
               flat; healthy 1; oom_killed 0.
      Watch    restarts_count rising slowly: a container that falls over now
               and then. uptime_seconds small on a container nobody restarted.
      Act      running 0 on a container meant to run. restarts_count rising on
               every run: a restart loop. healthy 0. oom_killed 1: it needs
               more memory, or leaks it. exit_code other than 0 on a job that
               should have succeeded (137: killed; 139: it crashed; 143:
               stopped by a signal).

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, the engine up or down; 1 if DOCKER_HOST is wrong,
      this account may not use the engine, or what answers is not a Docker
      engine
#>

$Job = 'containers'
. (Join-Path $PSScriptRoot '_docker.ps1')

Test-Engine
$all = Get-Json '/containers/json?all=1'
$list = By-Name @($all)
$c = New-Object System.Collections.Generic.List[object]
foreach ($one in @($list | Select-Object -First $script:Most)) {
    # A container removed since the list was read is left out.
    $d = Get-Json "/containers/$($one.Id)/json" -Missing
    if ($null -ne $d) { $c.Add($d) }
}
function Health($d) { $h = $d.State.Health; if ($h -and $h.Status) { return "$($h.Status)" }; return 'none' }
function Up($d) { return ($d.State.Running -eq $true -and $d.State.Restarting -ne $true -and $d.State.Paused -ne $true) }
$restarts = [double]0
foreach ($d in $c) { $restarts += (N $d.RestartCount) }
"metric containers $($list.Length)"
"metric containers_restarting $(@($c | Where-Object { $_.State.Restarting -eq $true }).Count)"
"metric containers_unhealthy $(@($c | Where-Object { (Health $_) -ceq 'unhealthy' }).Count)"
"metric containers_oom_killed $(@($c | Where-Object { $_.State.OOMKilled -eq $true }).Count)"
"metric containers_exited_nonzero $(@($c | Where-Object { $_.State.Status -ceq 'exited' -and (N $_.State.ExitCode) -ne 0 }).Count)"
"metric restarts_total_count $(Num $restarts)"
foreach ($d in $c) {
    $n = Safe (Name-Of $d)
    $state = "$($d.State.Status)"; if (-not $state) { $state = 'none' }
    $up = Up $d
    "metric running $(if ($up) { 1 } else { 0 }) name=$n state=$(Safe $state)"
    "metric restarts_count $(Num $d.RestartCount) name=$n"
    "metric oom_killed $(if ($d.State.OOMKilled -eq $true) { 1 } else { 0 }) name=$n"
    if ($up) { "metric uptime_seconds $([Math]::Max($script:Now - (Epoch $d.State.StartedAt), 0)) name=$n" }
    $h = Health $d
    if ($h -ceq 'healthy' -or $h -ceq 'unhealthy') { "metric healthy $(if ($h -ceq 'healthy') { 1 } else { 0 }) name=$n" }
    if ($state -ceq 'exited' -or $state -ceq 'dead') { "metric exit_code $(Num $d.State.ExitCode) name=$n" }
}
"metric containers_not_shown $([Math]::Max($list.Length - $script:Most, 0))"
exit 0
