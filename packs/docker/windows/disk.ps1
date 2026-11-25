#Requires -Version 5.1

<#
.SYNOPSIS
    disk.ps1 - the disk the engine uses: images, containers, volumes and the build cache, and what could be given back
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    What the engine keeps on disk and how much of it is in use: images (unused
    ones, and those with no name left), what containers wrote in their own
    layers, volumes (and those no container uses), and the build cache. A full
    disk under the engine stops every container on the machine at once.

    How full the disk itself is, is the base pack's to say (its disk job):
    this job says what is on it.

    Reads the Docker engine's API at DOCKER_HOST
    (npipe:////./pipe/docker_engine by default) with .NET alone. Every request
    is a GET: nothing is started, stopped, removed or pruned.

    Metrics:
      up                              1 when the engine answers, else 0 (and
                                      nothing more is read)
      images                          images it holds
      images_unused                   of those, used by no container
      images_dangling                 with no name left: an older build of a
                                      tag that moved on
      images_bytes                    disk the images take
      images_reclaimable_bytes        of that, what removing the unused ones
                                      would give back
      containers                      containers it holds, running or not
      containers_bytes                disk the containers take: what each
                                      wrote in its own layer
      containers_stopped_bytes        of that, held by containers that are not
                                      running
      container_bytes                 what one container wrote in its own
                                      layer, the 20 largest, tagged name=<the
                                      container's name>
      container_bytes_not_shown       past those 20, how many were left out
      volumes                         volumes it holds
      volumes_unused                  of those, used by no container
      volumes_bytes                   disk the volumes take
      volumes_unused_bytes            of that, in volumes no container uses
      volume_bytes                    the size of one volume, the 20 largest,
                                      tagged name=<the volume's name>
      volume_bytes_not_shown          past those 20, how many were left out
      build_cache_bytes               disk the build cache takes
      build_cache_reclaimable_bytes   of that, not in use by a build

    Example output:
      metric up 1
      metric images 18
      metric images_unused 12
      metric images_dangling 0
      metric images_bytes 5246472839
      metric images_reclaimable_bytes 2175583090
      metric containers 16
      metric containers_bytes 140804096
      metric containers_stopped_bytes 0
      metric container_bytes 20971520 name=vigilit_writes
      metric container_bytes_not_shown 0
      metric volumes 27
      metric volumes_unused 21
      metric volumes_bytes 4387655092
      metric volumes_unused_bytes 3763947182
      metric volume_bytes 102400 name=vigilit_data
      metric volume_bytes_not_shown 7
      metric build_cache_bytes 0
      metric build_cache_reclaimable_bytes 0

    Reading the results (starting points: tune them to the machine):
      Healthy  images_bytes and volumes_bytes steady; images_reclaimable_bytes
               a small share.
      Watch    images_dangling or images_reclaimable_bytes growing: builds and
               pulls that nothing clears. container_bytes large and growing: a
               container writing into its own layer what belongs in a volume
               (or logs nobody rotates).
      Act      any of them growing run after run while the base pack shows the
               disk filling. volumes_unused with volumes_unused_bytes large:
               data left behind by containers that are gone, to keep or to
               remove on purpose.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, the engine up or down; 1 if DOCKER_HOST is wrong,
      this account may not use the engine, or what answers is not a Docker
      engine
#>

$Job = 'disk'
. (Join-Path $PSScriptRoot '_docker.ps1')

Test-Engine
$df = Get-Json '/system/df'
function Items([string]$Old, [string]$New) {
    if ($null -ne $df[$Old]) { return , @($df[$Old] | Where-Object { $null -ne $_ }) }
    if ($df[$New] -and $null -ne $df[$New].Items) { return , @($df[$New].Items | Where-Object { $null -ne $_ }) }
    return , @()
}
$im = Items 'Images' 'ImageUsage'
$c = Items 'Containers' 'ContainerUsage'
$v = Items 'Volumes' 'VolumeUsage'
$b = Items 'BuildCache' 'BuildCacheUsage'
function VSize($x) { if ($x.UsageData) { return [Math]::Max((N $x.UsageData.Size), 0) }; return [double]0 }
function VRefs($x) { if ($x.UsageData) { return (N $x.UsageData.RefCount) }; return [double]0 }
function Total($Items, [scriptblock]$Of) { $t = [double]0; foreach ($x in @($Items)) { $t += (& $Of $x) }; return $t }
# Largest first; the order kept among equals, as the Linux scripts do.
function Largest($Items, [scriptblock]$Of) {
    $rows = @(); $at = 0
    foreach ($x in @($Items)) { $rows += , @((& $Of $x), $at, $x); $at++ }
    return , @($rows | Sort-Object @{ Expression = { $_[0] }; Descending = $true }, @{ Expression = { $_[1] } } | ForEach-Object { , $_[2] })
}
$unused = @($im | Where-Object { (N $_.Containers) -eq 0 })
$bytes = $df.LayersSize; if ($null -eq $bytes -and $df.ImageUsage) { $bytes = $df.ImageUsage.TotalSize }
$reclaim = $null; if ($df.ImageUsage) { $reclaim = $df.ImageUsage.Reclaimable }
if ($null -eq $reclaim) { $reclaim = Total $unused { param($x) N $x.Size } }
"metric images $($im.Count)"
"metric images_unused $($unused.Count)"
"metric images_dangling $(@($im | Where-Object { $t = @($_.RepoTags | Where-Object { $null -ne $_ }); $t.Count -eq 0 -or ($t.Count -eq 1 -and $t[0] -ceq '<none>:<none>') }).Count)"
"metric images_bytes $(Num $bytes)"
"metric images_reclaimable_bytes $(Num $reclaim)"
"metric containers $($c.Count)"
"metric containers_bytes $(Num (Total $c { param($x) N $x.SizeRw }))"
"metric containers_stopped_bytes $(Num (Total @($c | Where-Object { $_.State -cne 'running' -and $_.State -cne 'paused' }) { param($x) N $x.SizeRw }))"
$big = Largest @($c | Where-Object { (N $_.SizeRw) -gt 0 }) { param($x) N $x.SizeRw }
foreach ($x in @($big | Select-Object -First 20)) { "metric container_bytes $(Num $x.SizeRw) name=$(Safe (Name-Of $x))" }
"metric container_bytes_not_shown $([Math]::Max($big.Count - 20, 0))"
$vu = @($v | Where-Object { (VRefs $_) -eq 0 })
"metric volumes $($v.Count)"
"metric volumes_unused $($vu.Count)"
"metric volumes_bytes $(Num (Total $v { param($x) VSize $x }))"
"metric volumes_unused_bytes $(Num (Total $vu { param($x) VSize $x }))"
foreach ($x in @((Largest $v { param($x) VSize $x }) | Select-Object -First 20)) { "metric volume_bytes $(Num (VSize $x)) name=$(Safe $x.Name)" }
"metric volume_bytes_not_shown $([Math]::Max($v.Count - 20, 0))"
"metric build_cache_bytes $(Num (Total $b { param($x) N $x.Size }))"
"metric build_cache_reclaimable_bytes $(Num (Total @($b | Where-Object { $_.InUse -ne $true }) { param($x) N $x.Size }))"
exit 0
