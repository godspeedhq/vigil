# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Patch-FleetContainers.ps1 [-File <path>] [-Target <path in app/>] [-Sha256 <hex>] [-Undo]
# Puts one fixed Vigil file into every fleet test container on this
# machine's Docker Desktop (containers labelled vigil.fleet=node), to try a
# fix before it is released. The file defaults to backends.sh beside this
# script, the target to lib/posix/backends.sh. The original is kept as
# <target>.orig in the container, once; -Undo puts it back. A worker reads
# its libraries when it starts, so the next run of each job uses the file.
# Run it in PowerShell; as Administrator when Docker Desktop asks for it.
# Its log goes beside it: Patch-FleetContainers.log.
param([string]$File = (Join-Path $PSScriptRoot 'backends.sh'), [string]$Target = 'lib/posix/backends.sh',
      [string]$Sha256 = '', [switch]$Undo)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'Patch-FleetContainers.log') -Force | Out-Null
try {
    $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
    if (-not $docker) { $docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' }
    & $docker version --format 'Docker {{.Server.Version}} ({{.Server.Os}})'
    if ($LASTEXITCODE) { throw 'Docker does not answer: is Docker Desktop running (and this PowerShell elevated)?' }
    $dest = "/home/vigil/vigil/app/$Target"
    if (-not $Undo) {
        if (-not (Test-Path $File)) { throw "no file $File" }
        $have = (Get-FileHash -Algorithm SHA256 $File).Hash.ToLower()
        "file: $File, sha256 $have"
        if ($Sha256 -and $have -ne $Sha256.ToLower()) { throw "the file's sha256 is not $Sha256" }
    }
    $names = & $docker ps --filter label=vigil.fleet=node --format '{{.Names}}'
    if (-not $names) { throw 'no running container labelled vigil.fleet=node' }
    foreach ($n in $names) {
        if ($Undo) {
            & $docker exec $n sh -c "test -f '$dest.orig' && cat '$dest.orig' > '$dest' && rm -f '$dest.orig' && echo restored || echo 'nothing to restore'"
        } else {
            # docker cp, then cat into place: the installed file keeps its owner and mode.
            & $docker cp $File "${n}:/tmp/vigil-patch"
            if ($LASTEXITCODE) { throw "could not copy into $n" }
            & $docker exec $n sh -c "test -f '$dest' || { echo 'no such file in the container'; exit 3; }; test -f '$dest.orig' || cp -p '$dest' '$dest.orig'; cat /tmp/vigil-patch > '$dest' && rm -f /tmp/vigil-patch"
            if ($LASTEXITCODE) { throw "could not patch $n" }
        }
        $now = & $docker exec $n sha256sum $dest
        "$n  $($now.Split(' ')[0])"
    }
} catch {
    "FAILED: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
