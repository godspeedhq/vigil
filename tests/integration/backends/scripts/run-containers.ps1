# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.

# run-containers.ps1 - the docker pack on Windows, against the real engine
# of this machine holding containers in every state the pack reads, with its
# evidence kept like the other runs'. The twin of run-containers.sh.
#
#   scripts\run-containers.ps1 [-Shell <a PowerShell>]
#
# It makes small containers and two volumes, all labelled
# vigil.it=containers and named vigilit_*, runs every job under -Shell
# (default: the PowerShell this runs in) and checks what each read; stops
# and starts a container, watches the restart loop rising, cuts the number
# of containers named, and asks a pipe nothing listens on. Then
# tests\integration\Service-Packs.ps1 runs the pack through Vigil. At the
# end only what this script made is removed: no other container, volume or
# image is touched, and nothing is pruned.
#
# The engine may run Linux containers (Docker Desktop: the same eleven
# containers as run-containers.sh, and each job is also compared with what
# the Linux script prints, run in a container against the same engine) or
# Windows containers (Docker's engine on Windows Server: eight containers,
# since a Windows container in process isolation cannot be paused, is not
# killed for memory, and has no layer size to read).
param([string]$Shell = (Get-Process -Id $PID).Path)
$ErrorActionPreference = 'Continue'
$bk = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bk))
. (Join-Path $PSScriptRoot 'evidence.ps1')
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vigil-containers-it.$PID"
$root = Join-Path $work 'none'
[void](New-Item -ItemType Directory -Force -Path $work)
# Windows PowerShell 5.1 started from PowerShell 7 must not load 7's modules.
if ($Shell -like '*\powershell.exe') {
    $env:PSModulePath = (@($env:PSModulePath -split ';' | Where-Object { $_ -and $_ -notlike '*\PowerShell\7*' -and $_ -notlike '*\Documents\PowerShell\*' -and $_ -notlike '*\Program Files\PowerShell\Modules*' }) -join ';')
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Output 'docker not found'; exit 1 }
$engineOs = "$(docker info --format '{{.OSType}}' 2> $null)"
if ($LASTEXITCODE -ne 0 -or -not $engineOs) { Write-Output "the Docker engine does not answer on this machine, as $env:USERNAME"; exit 1 }
$win = ($engineOs -ceq 'windows')
$psv = & $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
$name = 'pack-docker-windows' + $(if ($psv -like '5.*') { '' } else { '-powershell7' })
Start-Evidence $name $bk '' "$($MyInvocation.MyCommand.Path) -Shell $Shell"
Write-Output "engine   Docker $(docker version --format '{{.Server.Version}}'), $engineOs containers, $(docker info --format '{{.OperatingSystem}}'), as an account that $(if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'is an administrator' } else { 'is not an administrator' })"
Write-Output "jobs     run under PowerShell $psv"

$script:pass = 0; $script:fail = 0
function Check([string]$what, [string]$want, [string]$got) {
    if ($want -ceq $got) { $script:pass++; Write-Output "  PASS  $what" } else { $script:fail++; Write-Output "  FAIL  ${what}: expected [$want] actual [$got]" }
}
function Say([string]$t) { Write-Output ''; Write-Output "# $t" }
$out = @{}
function Quiet([string]$j) {
    $lines = @(& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo "packs\docker\windows\$j.ps1") 2>&1 | ForEach-Object { "$_" })
    $script:code = $LASTEXITCODE
    $out[$j] = $lines
    [System.IO.File]::WriteAllLines((Join-Path $work "$j.out"), @($lines | Where-Object { $_ -notmatch ' name=' -or $_ -match ' name=vigilit_' }))
}
# Run-Job <job> [<label>] [<only lines matching>]: other containers on the
# engine are read like any, and left out of what is shown.
function Run-Job([string]$j, [string]$label = '', [string]$only = '') {
    Write-Output ''
    Write-Output "PS> powershell -File packs\docker\windows\$j.ps1$(if ($label) { "   ($label)" })"
    Quiet $j
    $mine = @($out[$j] | Where-Object { $_ -notmatch ' name=' -or $_ -match ' name=vigilit_' })
    if ($only) { $mine = @($mine | Where-Object { $_ -match $only }) }
    $mine | Write-Output
    $others = @($out[$j] | Where-Object { $_ -match ' name=' -and $_ -notmatch ' name=vigilit_' }).Count
    if ($others -gt 0 -and -not $only) { Write-Output "  (and $others lines for the engine's other containers and volumes, not shown)" }
}
function Val([string]$j, [string]$metric, [string]$tags = '') {
    foreach ($l in $out[$j]) {
        if ($l -cmatch "^metric $metric (\S+)( .*)?$") {
            $v = $Matches[1]; $rest = [string]$Matches[2]
            if (-not $tags -or "$rest " -match "$tags( |$)") { return $v }
        }
    }
    return ''
}
function Has([string]$j, [string]$metric, [string]$tags = '') { if ((Val $j $metric $tags) -ne '') { 'yes' } else { 'no' } }
function Least([string]$j, [string]$metric, [string]$tags, [double]$n) {
    $v = Val $j $metric $tags
    $d = [double]0
    if ($v -and [double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge $n) { return 'yes' }
    return "no [$v]"
}
function Clean {
    $ids = @(docker ps -aq --filter label=vigil.it=containers 2> $null)
    if ($ids.Count -gt 0) { docker rm -f @ids > $null 2>&1 }
    docker volume rm vigilit_data vigilit_unused > $null 2>&1
}
function Mk {
    $r = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Output "cannot make a container: docker $($args -join ' ')"; Write-Output "$r"; throw 'docker failed' }
}
$jobs = @([IO.File]::ReadAllLines((Join-Path $repo 'packs\docker\pack.config')) | Where-Object { $_ -match '^\[job\.(\w+)\]' } | ForEach-Object { $Matches[1] })
$lab = @('--label', 'vigil.it=containers')

try {
    Clean
    if ($win) {
        $img = if ($env:VIGIL_IT_CONTAINERS_IMAGE) { $env:VIGIL_IT_CONTAINERS_IMAGE } else { 'mcr.microsoft.com/windows/nanoserver:ltsc2025' }
        Say 'Eight Windows containers and two volumes, each in a state the pack reads.'
        docker pull -q $img > $null 2>&1
        Mk volume create --label vigil.it=containers vigilit_data
        Mk volume create --label vigil.it=containers vigilit_unused
        Mk run -d @lab --name vigilit_ok --memory 512m -v 'vigilit_data:C:\data' $img cmd /c 'ping -t localhost > nul'
        Mk run -d @lab --name vigilit_healthy --health-cmd 'cmd /c exit 0' --health-interval 3s $img cmd /c 'ping -t localhost > nul'
        Mk run -d @lab --name vigilit_unhealthy --health-cmd 'cmd /c exit 1' --health-interval 3s --health-retries 2 $img cmd /c 'ping -t localhost > nul'
        Mk run -d @lab --name vigilit_loop --restart always $img cmd /c 'ping -n 2 localhost > nul & exit 3'
        Mk run -d @lab --name vigilit_exit7 $img cmd /c 'exit 7'
        Mk run -d @lab --name vigilit_exit0 $img cmd /c 'exit 0'
        Mk create @lab --name vigilit_created $img cmd /c 'exit 0'
        Mk run -d @lab --name vigilit_busy --cpus 0.3 $img cmd /c 'for /l %i in () do @rem'
        $made = 8
    } else {
        $img = if ($env:VIGIL_IT_CONTAINERS_IMAGE) { $env:VIGIL_IT_CONTAINERS_IMAGE } else { 'busybox:1.37' }
        Say 'Eleven containers and two volumes, each in a state the pack reads.'
        docker pull -q $img > $null 2>&1
        Mk volume create --label vigil.it=containers vigilit_data
        Mk volume create --label vigil.it=containers vigilit_unused
        Mk run -d @lab --name vigilit_ok --memory 64m --cpus 0.5 -v vigilit_data:/data $img sh -c 'while :; do dd if=/dev/zero of=/data/f bs=1k count=100 conv=fsync 2>/dev/null; sleep 1; done'
        Mk run -d @lab --name vigilit_healthy --health-cmd true --health-interval 2s $img sleep 36000
        Mk run -d @lab --name vigilit_unhealthy --health-cmd false --health-interval 2s --health-retries 2 $img sleep 36000
        Mk run -d @lab --name vigilit_loop --restart always $img sh -c 'sleep 1; exit 3'
        Mk run -d @lab --name vigilit_exit7 $img sh -c 'exit 7'
        Mk run -d @lab --name vigilit_exit0 $img true
        Mk run -d @lab --name vigilit_oom --memory 16m --memory-swap 16m $img sh -c 'a=x; while :; do a=$a$a; done'
        Mk run -d @lab --name vigilit_paused $img sleep 36000
        Mk pause vigilit_paused
        Mk create @lab --name vigilit_created $img sleep 1
        Mk run -d @lab --name vigilit_busy --cpus 0.3 $img sh -c 'while :; do :; done'
        Mk run -d @lab --name vigilit_writes $img sh -c 'dd if=/dev/zero of=/big bs=1M count=20 2>/dev/null; sleep 36000'
        $made = 11
    }
    @(docker ps -a --filter label=vigil.it=containers --format '{{.Names}}: {{.Status}}' | Sort-Object) | ForEach-Object { Write-Output "  $_" }
    # The faults take a moment to show.
    foreach ($i in 1..60) {
        Quiet 'containers'
        if ((Val 'containers' 'healthy' 'name=vigilit_healthy') -ceq '1' -and (Val 'containers' 'healthy' 'name=vigilit_unhealthy') -ceq '0' -and (Least 'containers' 'restarts_count' 'name=vigilit_loop' 2) -ceq 'yes') { break }
        Start-Sleep -Seconds 3
    }
    # A Windows container uses several seconds of CPU just to start: the busy
    # one is told apart once it has used twice what an idle one has.
    function Busier { return ([double](Val 'resources' 'cpu_seconds_count' 'name=vigilit_busy') -gt 2 * [double](Val 'resources' 'cpu_seconds_count' 'name=vigilit_healthy')) }
    foreach ($i in 1..60) { Quiet 'resources'; if ((Least 'resources' 'cpu_seconds_count' 'name=vigilit_busy' 3) -ceq 'yes' -and (Busier)) { break }; Start-Sleep -Seconds 3 }

    Say 'Every job, as the Windows scripts print it.'
    foreach ($j in $jobs) {
        Run-Job $j
        Check "docker ${j}: runs, and the engine answers" '0 1' "$script:code $(Val $j 'up')"
    }

    if (-not $win) {
        Say 'The same engine, read by the Linux scripts from a container: the same readings, by name and tag.'
        $src = (Join-Path $repo 'packs\docker\linux')
        $all = @(docker run --rm --name vigilit_reader @lab -v /var/run/docker.sock:/var/run/docker.sock -v "${src}:/p:ro" alpine:3.22 sh -c 'apk add -q --no-progress bash curl jq > /dev/null 2>&1; for j in status containers resources disk; do echo ==$j; bash /p/$j.sh; done' 2>&1 | ForEach-Object { "$_" })
        $linux = @{}; $at = ''
        foreach ($l in $all) { if ($l -match '^==(\w+)$') { $at = $Matches[1]; $linux[$at] = @() } elseif ($at) { $linux[$at] += $l } }
        # A reading's name and tags, for this run's containers and for those with no tag.
        # Not the loop's: from one moment to the next it is running, or between two
        # starts, and so has an uptime or not.
        function Keys($lines) { @($lines | Where-Object { $_ -cmatch '^metric ' -and $_ -notmatch 'name=vigilit_(reader|loop)( |$)' -and ($_ -notmatch ' name=' -or $_ -match ' name=vigilit_') } | ForEach-Object { $f = $_ -split ' '; (@($f[1]) + @($f | Select-Object -Skip 3 | Where-Object { $_ -notmatch '^state=' })) -join ' ' } | Sort-Object -CaseSensitive -Unique) }
        foreach ($j in $jobs) {
            Quiet $j
            $mine = @(Keys $out[$j]); $theirs = @(Keys $linux[$j])
            $diff = @(if ($theirs.Count -eq 0) { 'the Linux script printed nothing' } else { Compare-Object -ReferenceObject $theirs -DifferenceObject $mine -CaseSensitive | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" } })
            Check "docker ${j}: the same readings as the Linux script printed ($($theirs.Count) of them)" '' (($diff | Select-Object -First 4) -join '; ')
        }
    }

    Say 'What each job must have read.'
    Check 'status: the unhealthy one, the one never started, and one that ended with an error are counted' 'yes yes yes' "$(Least 'status' 'unhealthy' '' 1) $(Least 'status' 'created' '' 1) $(Least 'status' 'exited_nonzero' '' 1)"
    Check 'status: every container is counted, whatever its state, and the kind of containers is said' "yes $engineOs" "$(Least 'status' 'containers' '' $made) $(if ((($out['status'] | Where-Object { $_ -match '^metric version ' }) -join '') -match ' os=(\S+)') { $Matches[1] })"
    Check 'containers: the one that runs, runs; the one never started does not, and its state is said' '1 0' "$(Val 'containers' 'running' 'name=vigilit_ok state=running') $(Val 'containers' 'running' 'name=vigilit_created state=created')"
    Check 'containers: healthy and unhealthy are told apart; one with no health check has no such reading' '1 0 no' "$(Val 'containers' 'healthy' 'name=vigilit_healthy') $(Val 'containers' 'healthy' 'name=vigilit_unhealthy') $(Has 'containers' 'healthy' 'name=vigilit_ok')"
    Check 'containers: exit codes, as they ended: 7 and 0' '7 0' "$(Val 'containers' 'exit_code' 'name=vigilit_exit7') $(Val 'containers' 'exit_code' 'name=vigilit_exit0')"
    Check 'containers: the loop has restarted, the others have not' 'yes 0' "$(Least 'containers' 'restarts_count' 'name=vigilit_loop' 2) $(Val 'containers' 'restarts_count' 'name=vigilit_ok')"
    Check 'containers: uptime for one that runs, none for one that stopped' 'yes no' "$(Least 'containers' 'uptime_seconds' 'name=vigilit_ok' 5) $(Has 'containers' 'uptime_seconds' 'name=vigilit_exit7')"
    Check 'resources: the busy one has used CPU, more than twice what an idle one has' 'yes True' "$(Least 'resources' 'cpu_seconds_count' 'name=vigilit_busy' 3) $(Busier)"
    Check 'resources: memory and processes for each; only running containers are measured' 'yes yes no no' "$(Least 'resources' 'memory_bytes' 'name=vigilit_ok' 1) $(Least 'resources' 'pids' 'name=vigilit_ok' 1) $(Has 'resources' 'memory_bytes' 'name=vigilit_exit7') $(Has 'resources' 'memory_bytes' 'name=vigilit_created')"
    Check 'disk: both volumes counted, and the one no container uses; images and what they take' 'yes yes yes yes' "$(Least 'disk' 'volumes' '' 2) $(Least 'disk' 'volumes_unused' '' 1) $(Least 'disk' 'images' '' 1) $(Least 'disk' 'images_bytes' '' 1000000)"
    if (-not $win) {
        Check 'containers: the paused one does not run, and its state is said' '0' (Val 'containers' 'running' 'name=vigilit_paused state=paused')
        Check 'containers: the one killed for memory is named, with its exit code, and only that one' '1 137 0' "$(Val 'containers' 'oom_killed' 'name=vigilit_oom') $(Val 'containers' 'exit_code' 'name=vigilit_oom') $(Val 'containers' 'oom_killed' 'name=vigilit_ok')"
        Check 'resources: the limit of the one that has one (64 MB), and its memory as a share of it; none for one without' '67108864 yes 0 no' "$(Val 'resources' 'memory_limit_bytes' 'name=vigilit_ok') $(Has 'resources' 'memory_pct' 'name=vigilit_ok') $(Val 'resources' 'memory_limit_bytes' 'name=vigilit_busy') $(Has 'resources' 'memory_pct' 'name=vigilit_busy')"
        Check 'resources: the busy one is held back at its CPU limit, and that is counted' 'yes yes' "$(Least 'resources' 'cpu_throttled_seconds_count' 'name=vigilit_busy' 1) $(Least 'resources' 'cpu_throttled_containers' '' 1)"
        Check 'disk: the 20 MB one container wrote in its own layer' 'yes' (Least 'disk' 'container_bytes' 'name=vigilit_writes' 20000000)
    }

    Say 'A restart loop, watched: the count rises from one run to the next.'
    Quiet 'containers'
    $before = [double](Val 'containers' 'restarts_count' 'name=vigilit_loop')
    Write-Output "  before: restarts_count $before"
    # Docker waits longer before each new start, up to a minute.
    foreach ($i in 1..24) { Start-Sleep -Seconds 5; Quiet 'containers'; if ([double](Val 'containers' 'restarts_count' 'name=vigilit_loop') -gt $before) { break } }
    Run-Job 'containers' 'a little later' 'name=vigilit_loop'
    Check 'the loop: restarts_count has risen' 'True' ([string]([double](Val 'containers' 'restarts_count' 'name=vigilit_loop') -gt $before))

    Say 'A container stops, and is started again.'
    docker stop -t 1 vigilit_ok > $null 2>&1
    Run-Job 'containers' 'vigilit_ok stopped' 'name=vigilit_ok( |$)'
    Check 'stopped: running 0, its state and its exit code said' '0 yes' "$(Val 'containers' 'running' 'name=vigilit_ok state=exited') $(Has 'containers' 'exit_code' 'name=vigilit_ok')"
    Quiet 'resources'
    Check 'stopped: no longer measured' 'no' (Has 'resources' 'memory_bytes' 'name=vigilit_ok')
    docker start vigilit_ok > $null 2>&1
    Start-Sleep -Seconds 3
    Run-Job 'containers' 'vigilit_ok started again' 'name=vigilit_ok( |$)'
    Check 'started again: running 1, and a new uptime' '1 True' "$(Val 'containers' 'running' 'name=vigilit_ok state=running') $([double](Val 'containers' 'uptime_seconds' 'name=vigilit_ok') -lt 120)"

    Say 'More containers than a job names: the first few by name, the rest counted.'
    $total = [int](Val 'containers' 'containers')
    $env:DOCKER_MOST = '3'
    Quiet 'containers'
    $env:DOCKER_MOST = $null
    Check 'DOCKER_MOST=3: three are named, and the rest are counted' "3 $($total - 3)" "$(@($out['containers'] | Where-Object { $_ -cmatch '^metric running ' }).Count) $(Val 'containers' 'containers_not_shown')"

    Say 'Nothing answering.'
    $env:DOCKER_HOST = 'npipe:////./pipe/vigilit_nothing_here'
    foreach ($j in $jobs) {
        Quiet $j
        Check "${j}: nothing answers: the job still runs, and reads up 0" '0 metric up 0' "$script:code $($out[$j] -join ' ')"
    }
    $env:DOCKER_HOST = 'tcp://127.0.0.1:2375'
    Quiet 'status'
    Check 'an address that is not a pipe on this machine: refused, and said' '1 True' "$script:code $([string](($out['status'] -join ' ') -match 'DOCKER_HOST is tcp://127.0.0.1:2375'))"
    $env:DOCKER_HOST = $null
    Write-Output ''
    Write-Output "$($script:pass) passed, $($script:fail) failed"

    Say 'The pack through Vigil.'
    $env:VIGIL_IT_DOCKER = 'DOCKER_HOST=npipe:////./pipe/docker_engine'
    $env:VIGIL_IT_DOCKER_DOWN = 'DOCKER_HOST=npipe:////./pipe/vigilit_nothing_here'
    & $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\integration\Service-Packs.ps1') 2>&1 | ForEach-Object { Write-Output "$_" }
    $rc = $LASTEXITCODE

    Say 'Only what this run made is removed.'
    $before = @(docker ps -aq).Count
    Clean
    Check "this run's $made containers are gone, and no other was touched" "0 $($before - $made)" "$(@(docker ps -aq --filter label=vigil.it=containers).Count) $(@(docker ps -aq).Count)"
}
finally {
    Clean
    Save-Evidence $work $root @()
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
}
if ($script:fail -eq 0 -and $rc -eq 0) { exit 0 }
exit 1
