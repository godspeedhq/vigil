# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Start-FleetContainers.ps1 -Name <hp|lenovo|...> [-Count 5] [-Backend <address>] [-Stop]
# The fleet test's containers on this Windows machine's Docker Desktop
# (Linux containers), as node/fleet.sh makes them, without bash: from the
# kit beside this script (copied first to your own profile, so Docker
# Desktop can mount the token), the image vigil-fleet-node is built, and
# containers <Name>-c1..c<Count> started, each 64 MB and half a CPU at
# most. -Stop removes them (only containers labelled vigil.fleet=node).
# Run it in PowerShell; as Administrator when Docker Desktop asks for it.
# Its log goes beside it: Start-FleetContainers-<Name>.log.
param([Parameter(Mandatory)][string]$Name, [int]$Count = 5, [string]$Backend = '192.168.4.40', [switch]$Stop)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot "Start-FleetContainers-$Name.log") -Force | Out-Null
try {
    $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
    if (-not $docker) { $docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    & $docker version --format 'Docker {{.Server.Version}} ({{.Server.Os}})'
    if ($LASTEXITCODE) { throw 'Docker does not answer: is Docker Desktop running (and this PowerShell elevated)?' }
    if ($Stop) {
        $ids = & $docker ps -aq --filter label=vigil.fleet=node
        if ($ids) { & $docker rm -f $ids | Out-Null }
        "removed $(@($ids).Count) containers"
        return
    }
    $kit = Join-Path $env:USERPROFILE 'vigil-fleet-kit'
    if ($PSScriptRoot -ne $kit) {
        Remove-Item -Recurse -Force $kit -ErrorAction SilentlyContinue
        Copy-Item -Recurse $PSScriptRoot $kit
    }
    "kit: $kit"
    & $docker build -q -f "$kit\tests\integration\fleet\node\Dockerfile" -t vigil-fleet-node $kit
    if ($LASTEXITCODE) { throw 'the image did not build' }
    $token = (Join-Path $kit 'fleet-token') -replace '\\', '/'
    foreach ($i in 1..$Count) {
        $n = "$Name-c$i"
        # (ps, not inspect: under Windows PowerShell 5.1 with Stop, a native
        # command's message on stderr ends the script.)
        if (& $docker ps -aq --filter "name=^$n$") { "$n is there already"; continue }
        & $docker run -d --name $n --hostname $n --label vigil.fleet=node --memory 64m --cpus 0.5 `
            --restart unless-stopped -e "FLEET_ADDR=$Backend" -e FLEET_KIND=linux-container `
            -v "${token}:/run/secrets/fleet_git_token:ro" vigil-fleet-node | Out-Null
        if ($LASTEXITCODE) { throw "$n did not start" }
        "started $n"
    }
    & $docker ps --filter label=vigil.fleet=node --format '{{.Names}}  {{.Status}}'
} catch {
    "FAILED: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
