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
    Vigil packs - Windows PowerShell 5.1 compatible.
.DESCRIPTION
    A pack is a set of scripts and jobs (SPECIFICATION.md 18.10), published
    in the pack repository: packs releases, signed. A machine holds only the
    packs installed on it, in packs\<name>\, this platform's scripts,
    Vigil's to replace. The configuration is the operator's: Vigil runs only
    what it names, so installing or updating changes scripts and never the
    configuration, and a new script stays off until it is enabled. The twin
    of pack.sh.

    Get-VigilPackList -Root <dir>
        Each pack here and whether its jobs are on.
    Find-VigilPack -Root <dir> -App <app dir> -Words <word>... [-Available]
    Get-VigilPackInfo -Root <dir> -App <app dir> -Name <name>
        From the newest index; when the repository cannot be reached, the
        one saved here (packs\.index), saying so. With -Available, the
        repository's packs not installed here.
    Install-VigilPack -Root <dir> -App <app dir> -From <folder, or ''> -Specs <name[@version]>...
        From the repository, or a folder vigil pack download wrote.
    Remove-VigilPack -Root <dir> -Names <name>...
        Refused while a job runs one of its scripts.
    Save-VigilPack -Root <dir> -App <app dir> -Os <linux|macos|windows> -To <folder> -Specs <name[@version]>...
        vigil pack download.
    Enable-VigilPack -Root <dir> -What <pack, or pack_job>
    Disable-VigilPack -Root <dir> -What <pack, or pack_job>
        Change the configuration, or nothing when the result is not valid.
    Update-VigilPack -Root <dir> -App <app dir> -Check <bool>
        Updates the packs installed here to the repository's newest, never
        back a version.
    Test-VigilPack -Root <dir> -App <app dir> -From <folder, or ''> -Names <name>...
        vigil pack verify: the packs installed here, or those named, file by
        file against the release of the version installed. Changes nothing.
        Install of the version installed puts back what differs.
    Copy-VigilPackSeed -Root <dir> -App <app dir>
        A packaged program only: copies in the packs the package keeps beside
        app\, those not here yet.
    Each returns an exit code: 0, or 1 with the reason on stderr; nothing is
    changed then.

    Requires Config.ps1, Validate.ps1 and SelfUpdate.ps1.
#>

# While Open-VigilPackRepo -Saved tries the repository, the reasons it
# could not are held here, not printed: the index saved here may answer.
$script:VigilPackHeld = $null

function Stop-VigilPack {
    param([string]$Why)
    if ($null -ne $script:VigilPackHeld) { $script:VigilPackHeld.Add($Why); return }
    [Console]::Error.WriteLine("vigil: $Why")
}

function Get-VigilPackStart { param([string]$Name) "# pack ${Name}: vigil pack disable takes these out" }
function Get-VigilPackEnd { param([string]$Name) "# end of pack $Name" }

# Reads a pack's manifest: @{ Version; Vigil; About; Needs; Jobs; Sections },
# Needs its needs lines, and the jobs with a script here, in order, each with
# its section's lines; $null when it cannot be read.
function Read-VigilPack {
    param([string]$Dir, [string]$Name)
    $f = Join-Path $Dir 'pack.config'
    if (-not [System.IO.File]::Exists($f)) { return $null }
    $p = ConvertFrom-VigilConfig -Path $f
    if ($p.Errors.Count -gt 0) { return $null }
    $r = @{ Version = ''; Vigil = ''; About = ''; Needs = @(); Jobs = (New-Object 'System.Collections.Generic.List[string]'); Sections = @{} }
    foreach ($s in $p.Sections) {
        if ($s.Name -ceq 'pack') {
            $r.Version = Get-VigilConfigValue $p 'pack' 'version' ''
            $r.Vigil = Get-VigilConfigValue $p 'pack' 'vigil' ''
            $r.About = Get-VigilConfigValue $p 'pack' 'description' ''
            $r.Needs = @($p.Entries | Where-Object { $_.Section -ceq 'pack' -and $_.Key -ceq 'needs' } | ForEach-Object { $_.Value })
        }
        elseif ($s.Name.StartsWith('job.', [System.StringComparison]::Ordinal)) {
            $job = $s.Name.Substring(4)
            if (-not [System.IO.File]::Exists((Join-Path $Dir "$job.ps1"))) { continue }
            $text = New-Object 'System.Collections.Generic.List[string]'
            $text.Add("[job.${Name}_$job]")
            $text.Add("file = packs/$Name/$job.ps1")
            foreach ($e in $p.Entries) {
                if ($e.Section -ceq $s.Name -and $e.Key -cne 'metrics' -and $e.Key -cne 'file') { $text.Add("$($e.Key) = $($e.Value)") }
            }
            $r.Jobs.Add($job)
            $r.Sections[$job] = $text
        }
    }
    if (-not $r.Version) { return $null }
    return $r
}

# The pack repository (18.10). Packs releases are tagged packs-<date>, apart
# from Vigil's. Each carries packs.index, every version of every pack with
# the archive of each platform and its SHA-256, signed with the release key
# (packs.index.sig): one signature check vouches for every archive.

# Whether index $Path is signed by key $Key ($Path.sig its signature).
function Test-VigilPackSigned {
    param([string]$Key, [string]$Path)
    if (-not [System.IO.File]::Exists($Path) -or -not [System.IO.File]::Exists("$Path.sig")) { return $false }
    return [bool](Test-VigilSignature -KeyFile $Key -Data ([System.IO.File]::ReadAllBytes($Path)) -Signature ([System.IO.File]::ReadAllBytes("$Path.sig")))
}

# Index $Path: @{ Release; Packs; Files; Info }, each a list of records, or
# $null when it is not of format 1, the one this Vigil reads. A record of a
# kind this Vigil does not know is skipped.
function Read-VigilPackIndex {
    param([string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($lines.Count -eq 0 -or $lines[0] -cne "format`t1") { return $null }
    $r = @{ Release = ''; Packs = (New-Object 'System.Collections.Generic.List[object]'); Files = (New-Object 'System.Collections.Generic.List[object]'); Info = (New-Object 'System.Collections.Generic.List[object]') }
    foreach ($l in $lines) {
        $x = $l.Split("`t")
        if ($x[0] -ceq 'pack' -and $x.Count -ge 7) { $r.Packs.Add(@{ Name = $x[1]; Version = $x[2]; Vigil = $x[3]; Release = $x[4]; About = $x[6] }) }
        elseif ($x[0] -ceq 'file' -and $x.Count -ge 6) { $r.Files.Add(@{ Name = $x[1]; Version = $x[2]; Os = $x[3]; File = $x[4]; Sha = $x[5].ToLowerInvariant() }) }
        elseif ($x[0] -ceq 'info' -and $x.Count -ge 5) { $r.Info.Add(@{ Name = $x[1]; Version = $x[2]; Key = $x[3]; Value = $x[4] }) }
        elseif ($x[0] -ceq 'release' -and $x.Count -ge 2) { $r.Release = $x[1] }
    }
    return $r
}

# The newest packs release, or $null. From a release_url or a release_path,
# the one line of <base>/packs/latest/RELEASE. From GitHub, the first packs-
# tag in the API's list of releases: a packs release is never marked latest,
# so /releases/latest names Vigil's. Tests serve the list at
# <base>/api/releases/all.
function Get-VigilPackLatest {
    param($Src)
    $tag = ''
    try {
        if ($Src.Path) { $tag = @([System.IO.File]::ReadAllText([System.IO.Path]::Combine($Src.Base, 'packs\latest\RELEASE')).Split("`n"))[0].Trim() }
        elseif ($Src.Mirror) { $tag = @((Invoke-VigilReleaseGet -Uri "$($Src.Base)/packs/latest/RELEASE" -Header $Src.Header -TimeoutSec 60).Split("`n"))[0].Trim() }
        else {
            $api = if ($Src.Base -clike 'https://github.com/*') { "https://api.github.com/repos/$($Src.Base.Substring(19))/releases?per_page=100" } else { "$($Src.Base)/api/releases/all" }
            $list = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 -Headers @{ Accept = 'application/vnd.github+json' } -Uri $api
            foreach ($x in $list) {
                if ([string]$x.tag_name -clike 'packs-*') { $tag = [string]$x.tag_name; break }
            }
        }
    }
    catch { }
    if ($tag -cmatch '^packs-[0-9][0-9A-Za-z.-]*$') { return $tag }
    return $null
}

# File $Name of packs release $Rel into $OutFile: from the release, or the
# folder. Returns whether it is there.
function Get-VigilPackFile {
    param($Repo, [string]$Rel, [string]$Name, [string]$OutFile)
    if ($Repo.Folder) {
        $f = Join-Path $Repo.Folder $Name
        if ([System.IO.File]::Exists($f)) {
            try { [System.IO.File]::Copy($f, $OutFile, $true); return $true } catch { }
        }
        Stop-VigilPack "$Name is not in $($Repo.Folder)"
        return $false
    }
    try {
        Get-VigilReleaseFile -Src $Repo.Src -Rel "releases/download/$Rel/$Name" -OutFile $OutFile
        return $true
    }
    catch {
        $why = Get-VigilReleaseRefused $Repo.Src
        if ($why) { $why = ": $why" }
        Stop-VigilPack "cannot download $Name of $Rel$why"
        return $false
    }
}

# Opens the repository for a command: the source (or folder $From, which
# holds what vigil pack download wrote), the key, a temporary folder (Work,
# which the caller removes) and the index of the newest release, verified.
# One fetched from a release is kept as packs\.index, when packs\ is
# writable. With -Saved, when the repository cannot give it, that saved
# index, when it is there and signed, saying so: search, info and list
# --available still answer offline, and never from an old index when a new
# one can be had. @{ Ok; Work; Src; Folder; Key; Index; IndexPath; App }.
function Open-VigilPackRepo {
    param([string]$Root, [string]$App, [string]$From = '', [switch]$Saved)
    if ($Saved) {
        $script:VigilPackHeld = New-Object 'System.Collections.Generic.List[string]'
        try { $r = Open-VigilPackRepo -Root $Root -App $App -From $From }
        finally { $held = $script:VigilPackHeld; $script:VigilPackHeld = $null }
        if ($r.Ok) { return $r }
        # Not $saved: PowerShell's names ignore case, and that is -Saved.
        $kept = Join-Path $Root 'packs\.index'
        if ($r.Key -and (Test-VigilPackSigned -Key $r.Key -Path $kept)) {
            $idx = Read-VigilPackIndex -Path $kept
            if ($idx) {
                $why = if ($held.Count -gt 0) { $held[0] } else { 'cannot reach the pack repository' }
                [Console]::Error.WriteLine("vigil: $why; showing the index saved here, of $($idx.Release)")
                $r.Index = $idx; $r.IndexPath = $kept; $r.Ok = $true
                return $r
            }
        }
        foreach ($w in $held) { [Console]::Error.WriteLine("vigil: $w") }
        return $r
    }
    $r = @{ Ok = $false; Work = ''; Src = $null; Folder = ''; Key = ''; Index = $null; IndexPath = ''; App = $App }
    $key = Join-Path $App 'release-key.pem'
    if ($env:VIGIL_TEST_RELEASE_URL -and $env:VIGIL_TEST_RELEASE_KEY) { $key = $env:VIGIL_TEST_RELEASE_KEY }
    if (-not (Test-Path -LiteralPath $key)) { Stop-VigilPack 'no release key here: packs cannot be verified; nothing was changed'; return $r }
    $r.Key = $key
    if ($From) {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($From)
        if (-not [System.IO.Directory]::Exists($full)) { Stop-VigilPack "cannot read the folder $From"; return $r }
        $r.Folder = $full.TrimEnd('\')
    }
    else {
        $src = Get-VigilReleaseSource -Root $Root
        if ($src.Error) { Stop-VigilPack $src.Error; return $r }
        $r.Src = $src
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # A new folder of its own, never one that is already there.
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-pack.' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work)
    $r.Work = $work
    $cache = Join-Path $Root 'packs\.index'
    $rel = ''
    if (-not $r.Folder) {
        $rel = Get-VigilPackLatest -Src $r.Src
        if (-not $rel) {
            if ($r.Src.Path) { Stop-VigilPack "cannot read packs/latest/RELEASE from $($r.Src.From) (as $([Environment]::UserDomainName)\$([Environment]::UserName)): is it there, and readable by this account?" }
            elseif ($r.Src.Mirror) {
                $why = Get-VigilReleaseRefused $r.Src
                if ($why) { $why = ": $why" }
                Stop-VigilPack "cannot read packs/latest/RELEASE from $($r.Src.From)$why"
            }
            else { Stop-VigilPack "cannot find the latest packs release on $($r.Src.From): no network, or its API refused (it allows 60 requests an hour)" }
            return $r
        }
        # The newest release's index is the one saved here: no need to
        # download it again (backlog 65). Checked as one downloaded is; a
        # published release does not change.
        if ([System.IO.File]::Exists($cache) -and (Test-VigilPackSigned -Key $key -Path $cache)) {
            $here = Read-VigilPackIndex -Path $cache
            if ($here -and $here.Release -ceq $rel) {
                $idx = Join-Path $work 'packs.index'
                try {
                    [System.IO.File]::Copy($cache, $idx, $true)
                    [System.IO.File]::Copy("$cache.sig", "$idx.sig", $true)
                    $r.Index = $here; $r.IndexPath = $idx; $r.Ok = $true
                    return $r
                }
                catch { }
            }
        }
    }
    $idx = Join-Path $work 'packs.index'
    if (-not (Get-VigilPackFile -Repo $r -Rel $rel -Name 'packs.index' -OutFile $idx)) { return $r }
    if (-not (Get-VigilPackFile -Repo $r -Rel $rel -Name 'packs.index.sig' -OutFile "$idx.sig")) { return $r }
    if (-not (Test-VigilPackSigned -Key $key -Path $idx)) {
        $what = if ($rel) { $rel } else { $r.Folder }
        Stop-VigilPack "the pack index of $what is not signed by the Vigil release key; nothing was changed"
        return $r
    }
    $r.Index = Read-VigilPackIndex -Path $idx
    if (-not $r.Index) { Stop-VigilPack 'the pack index is of a format this Vigil cannot read: vigil self update'; return $r }
    $r.IndexPath = $idx
    $packs = Join-Path $Root 'packs'
    if (-not $r.Folder -and [System.IO.Directory]::Exists($packs)) {
        try {
            [System.IO.File]::Copy($idx, "$cache.new", $true)
            [System.IO.File]::Copy("$idx.sig", "$cache.sig.new", $true)
            Move-Item -LiteralPath "$cache.sig.new" -Destination "$cache.sig" -Force -ErrorAction Stop
            Move-Item -LiteralPath "$cache.new" -Destination $cache -Force -ErrorAction Stop
        }
        catch { }
        foreach ($f in @("$cache.new", "$cache.sig.new")) { if ([System.IO.File]::Exists($f)) { try { [System.IO.File]::Delete($f) } catch { } } }
    }
    $r.Ok = $true
    return $r
}

function Close-VigilPackRepo {
    param($Repo)
    if ($Repo.Work) { Remove-Item -LiteralPath $Repo.Work -Recurse -Force -ErrorAction SilentlyContinue }
}

# The version of pack $Name to take from the index: $Want when given, else
# the newest that Vigil $Mine runs (any, when $Mine is empty), with an
# archive for platform $Os, and from a folder, its archive there.
# @{ Version (empty when there is none, with the reason in Why); Release;
# File; Sha; Newer, a newer version Vigil $Mine cannot run; NewerVigil }.
function Select-VigilPackVersion {
    param($Repo, [string]$Name, [string]$Want, [string]$Os, [string]$Mine)
    $osName = @{ linux = 'Linux'; macos = 'macOS'; windows = 'Windows' }[$Os]
    $r = @{ Version = ''; Release = ''; File = ''; Sha = ''; Newer = ''; NewerVigil = ''; Why = "no pack called ${Name}: vigil pack search" }
    $all = @($Repo.Index.Packs | Where-Object { $_.Name -ceq $Name })
    if ($Want -and $all.Count -gt 0) { $r.Why = "pack $Name has no version ${Want}: vigil pack info $Name" }
    foreach ($p in $all) {
        if ($Want -and $p.Version -cne $Want) { continue }
        $f = $Repo.Index.Files | Where-Object { $_.Name -ceq $Name -and $_.Version -ceq $p.Version -and $_.Os -ceq $Os } | Select-Object -First 1
        if (-not $f) {
            $r.Why = if ($Want) { "pack $Name $Want has no scripts for $osName" } else { "pack $Name has no scripts for $osName" }
            continue
        }
        if ($Repo.Folder -and -not [System.IO.File]::Exists((Join-Path $Repo.Folder $f.File))) {
            $s = if ($Want) { "$Name@$Want" } else { $Name }
            $r.Why = "$($f.File) is not in $($Repo.Folder): vigil pack download $s there"
            continue
        }
        if ($Mine -and $p.Vigil -and (Test-VigilNewer $p.Vigil $Mine)) {
            if (-not $r.Newer -or (Test-VigilNewer $p.Version $r.Newer)) { $r.Newer = $p.Version; $r.NewerVigil = $p.Vigil }
            $r.Why = "pack $Name $($r.Newer) needs Vigil $($r.NewerVigil) or later: vigil self update"
            continue
        }
        if (-not $r.Version -or (Test-VigilNewer $p.Version $r.Version)) {
            $r.Version = $p.Version; $r.Release = $p.Release; $r.File = $f.File; $r.Sha = $f.Sha
        }
    }
    return $r
}

# This Vigil's version.
function Get-VigilPackMine {
    param([string]$App)
    $f = Join-Path $App 'VERSION'
    if ([System.IO.File]::Exists($f)) { return [System.IO.File]::ReadAllText($f).Trim() }
    return ''
}

# The picked archive of pack $Name, downloaded, checked against the index and
# unpacked: the pack's folder, or $null.
function Expand-VigilPackPick {
    param($Repo, [string]$Name, $Pick)
    $f = Join-Path $Repo.Work $Pick.File
    if (-not (Get-VigilPackFile -Repo $Repo -Rel $Pick.Release -Name $Pick.File -OutFile $f)) { return $null }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() -cne $Pick.Sha) {
        Stop-VigilPack "$($Pick.File) does not match the pack index; nothing was changed"
        return $null
    }
    $x = Join-Path $Repo.Work 'x'
    if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force }
    $saved = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Expand-Archive -LiteralPath $f -DestinationPath $x -ErrorAction Stop }
    catch { Stop-VigilPack "cannot unpack $($Pick.File)"; return $null }
    finally { $ProgressPreference = $saved }
    $src = Join-Path $x $Name
    if (-not [System.IO.File]::Exists((Join-Path $src 'pack.config'))) { Stop-VigilPack "$($Pick.File) holds no pack $Name"; return $null }
    # Verified: the downloaded-from-the-internet mark would make a
    # RemoteSigned policy refuse them.
    Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
    return $src
}

# Pack $Name's folder here, $Here, against its release's, $Rel, byte for
# byte: @{ Count, the release's files; Changed, those that differ here;
# Missing, those not here; Added, those here the release does not have;
# Kept }. A script the release does not have that a job of configuration
# $Cfg runs, kept by vigil pack update when the pack dropped it, is not
# Added: it is in Kept, as '<file>:<job>'.
function Compare-VigilPackFiles {
    param([string]$Cfg, [string]$Name, [string]$Here, [string]$Rel)
    $r = @{ Count = 0; Changed = @(); Missing = @(); Added = @(); Kept = @() }
    # Files in byte order, as pack.sh lists them.
    $theirs = [System.IO.Directory]::GetFiles($Rel)
    [Array]::Sort($theirs, [StringComparer]::Ordinal)
    foreach ($f in $theirs) {
        $b = [System.IO.Path]::GetFileName($f)
        $r.Count++
        $o = Join-Path $Here $b
        if (-not [System.IO.File]::Exists($o)) { $r.Missing += $b }
        elseif ((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash -cne (Get-FileHash -Algorithm SHA256 -LiteralPath $o).Hash) { $r.Changed += $b }
    }
    $runs = @{}
    if ([System.IO.File]::Exists($Cfg)) {
        foreach ($e in (ConvertFrom-VigilConfig -Path $Cfg).Entries) {
            if ($e.Key -cne 'file' -or -not $e.Section.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            $v = $e.Value.Replace('\', '/')
            if ($v.StartsWith("packs/$Name/", [System.StringComparison]::Ordinal)) { $runs[$v.Substring(7 + $Name.Length)] = $e.Section.Substring(4) }
        }
    }
    $ours = [System.IO.Directory]::GetFileSystemEntries($Here)
    [Array]::Sort($ours, [StringComparer]::Ordinal)
    foreach ($f in $ours) {
        $b = [System.IO.Path]::GetFileName($f)
        $t = Join-Path $Rel $b
        if ([System.IO.File]::Exists($t) -or [System.IO.Directory]::Exists($t)) { continue }
        if ($runs.ContainsKey($b)) { $r.Kept += "${b}:$($runs[$b])" } else { $r.Added += $b }
    }
    return $r
}

# What may stop an edit of the configuration.
function Test-VigilPackWritable {
    param([string]$Root)
    $cfg = Join-Path $Root 'config\vigil.config'
    $denied = Get-VigilDenied $cfg
    if ($denied) { Stop-VigilPack (Get-VigilDeniedMessage $denied); return $false }
    if (-not [System.IO.File]::Exists($cfg)) { Stop-VigilPack 'no configuration here: run vigil init first'; return $false }
    $p = ConvertFrom-VigilConfig -Path $cfg
    if ($p.Errors.Count -gt 0) { Stop-VigilPack "$cfg has errors: fix them first (vigil precheck)"; return $false }
    $src = Get-VigilConfigValue $p 'vigil' 'config_source' ''
    if ($src) { Stop-VigilPack "the configuration comes from [source.$src]: add the pack's jobs there"; return $false }
    try { ([System.IO.File]::Open($cfg, 'Open', 'Write', 'ReadWrite')).Dispose() }
    catch { Stop-VigilPack "$cfg is not writable: run this from an elevated prompt for a system install"; return $false }
    return $true
}

# Why the configuration now in place is not good for a pack, judged by its own
# jobs, so a problem that was already there stops nothing; '' when it is good.
function Get-VigilPackProblem {
    param([string]$Root, [string]$Name, [string]$Path = '')
    if (-not $Path) { $Path = Join-Path $Root 'config\vigil.config' }
    $p = ConvertFrom-VigilConfig -Path $Path
    if ($p.Errors.Count -gt 0) { return [string]$p.Errors[0].Message }
    foreach ($r in @(Test-VigilConfig -Parsed $p)) {
        if ($r.Kind -ceq 'ERROR' -or ($r.Kind -ceq 'INVALID' -and $r.Job.StartsWith("${Name}_", [System.StringComparison]::Ordinal))) { return "$($r.Message) ($($r.Code))" }
    }
    return ''
}

# The configuration with a pack's block changed: -Add jobs are added and -Drop
# jobs taken out, or the block goes with -All. Every other section stays as
# it is.
function Get-VigilPackRewrite {
    param([string]$Text, [string]$Name, $Pack, [string[]]$Add = @(), [string[]]$Drop = @(), [switch]$All)
    $start = Get-VigilPackStart $Name
    $end = Get-VigilPackEnd $Name
    $lines = $Text.Split("`n")
    $count = $lines.Length
    if ($count -gt 0 -and $lines[$count - 1] -ceq '') { $count-- }
    $out = New-Object 'System.Collections.Generic.List[string]'
    $in = $false; $keep = $true; $found = $false
    for ($i = 0; $i -lt $count; $i++) {
        $line = $lines[$i]
        $bare = $line.TrimEnd("`r")
        if (-not $in) {
            if ($bare -ceq $start) {
                $in = $true
                $keep = $true
                $found = $true
                if (-not $All) { $out.Add($line) }
            }
            else { $out.Add($line) }
            continue
        }
        if ($bare -ceq $end) {
            $in = $false
            if (-not $All) {
                foreach ($j in $Add) {
                    $out.Add('')
                    foreach ($t in $Pack.Sections[$j]) { $out.Add($t) }
                }
                $out.Add($line)
            }
            continue
        }
        if ($All) { continue }
        if ($bare.StartsWith("[job.${Name}_", [System.StringComparison]::Ordinal)) {
            $job = $bare.Substring(6 + $Name.Length).Split(']')[0]
            $keep = $Drop -cnotcontains $job
        }
        if ($keep) { $out.Add($line) }
    }
    if (-not $found -and $Add.Count -gt 0) {
        $out.Add('')
        $out.Add($start)
        foreach ($j in $Add) {
            $out.Add('')
            foreach ($t in $Pack.Sections[$j]) { $out.Add($t) }
        }
        $out.Add($end)
    }
    return (($out -join "`n") + "`n")
}

# Splits a name into a pack here and, if it names one job, that job: @{ Pack;
# Job }, or $null when there is no such pack.
function Get-VigilPackName {
    param([string]$Root, [string]$What)
    if ($What -cnotmatch '^[a-z0-9_]+$') { Stop-VigilPack "not a pack or job name: $What"; return $null }
    $packs = Join-Path $Root 'packs'
    if ([System.IO.File]::Exists((Join-Path $packs "$What\pack.config"))) { return @{ Pack = $What; Job = '' } }
    if ([System.IO.Directory]::Exists($packs)) {
        foreach ($d in [System.IO.Directory]::GetDirectories($packs)) {
            $n = [System.IO.Path]::GetFileName($d)
            if ($What.StartsWith("${n}_", [System.StringComparison]::Ordinal)) { return @{ Pack = $n; Job = $What.Substring($n.Length + 1) } }
        }
    }
    Stop-VigilPack "no pack or job called ${What}: vigil pack list"
    return $null
}

# Replaces the configuration with $Text, once $Text is valid. Replaced, never
# written over: a crash or a full disk leaves the old file or the new one,
# never part of one, which could still be valid with fewer jobs (46).
# File.Replace keeps the old file's ACL.
function Set-VigilPackConfig {
    param([string]$Root, [string]$Name, [string]$Text)
    $cfg = Join-Path $Root 'config\vigil.config'
    $check = Join-Path $Root "config\.vigil.config.pack.$PID"
    try {
        [System.IO.File]::WriteAllText($check, $Text)
        $why = Get-VigilPackProblem -Root $Root -Name $Name -Path $check
    }
    finally { try { [System.IO.File]::Delete($check) } catch { } }
    if ($why) {
        Stop-VigilPack "the configuration would not be valid: $why; nothing was changed"
        return $false
    }
    try { Write-VigilFileAtomic -Path $cfg -Text $Text }
    catch {
        Stop-VigilPack "cannot save ${cfg}: $($_.Exception.Message); nothing was changed"
        return $false
    }
    return $true
}

# Whether a job is in the configuration.
function Test-VigilPackOn {
    param($Parsed, [string]$Job)
    return [bool]($Parsed.Sections | Where-Object { $_.Name -ceq "job.$Job" })
}

# Whether secret reference $Ref can be had, as far as can be told here without
# reading it. A store is not asked: that is precheck's to do.
function Get-VigilPackSecretState {
    param([string]$Root, [string]$Ref)
    if ($Ref.StartsWith('secret:', [System.StringComparison]::Ordinal)) {
        $n = $Ref.Substring(7)
        $d = Join-Path $Root 'config\secrets'
        if (-not [System.IO.Directory]::Exists($d)) { return "not set: vigil secret set $n, as the account Vigil runs as (an elevated prompt for a system install)" }
        # The folder is the owner's only: another account cannot look in it.
        try { $names = @([System.IO.Directory]::GetFiles($d) | ForEach-Object { [System.IO.Path]::GetFileName($_) }) }
        catch { return 'cannot be told from this account: vigil precheck, as the account Vigil runs as (an elevated prompt for a system install)' }
        if ($names -ccontains $n) { return 'set' }
        return "not set: vigil secret set $n, as the account Vigil runs as (an elevated prompt for a system install)"
    }
    if ($Ref.StartsWith('env:', [System.StringComparison]::Ordinal)) { return 'from the environment Vigil runs in' }
    return 'from a secret store: vigil precheck checks it'
}

# What pack $Name's jobs in configuration $Parsed need, one line each after
# $Lead: each secret they name and whether it is there, the pack's own needs,
# and their settings (env, never a secret). So a pack is never turned on blind.
function Get-VigilPackNeeds {
    param([string]$Root, [string]$Name, $Pack, $Parsed, [string]$Lead)
    $seen = @{}
    $envs = New-Object 'System.Collections.Generic.List[string]'
    if ($Parsed) {
        foreach ($e in $Parsed.Entries) {
            if (-not $e.Section.StartsWith("job.${Name}_", [System.StringComparison]::Ordinal)) { continue }
            if (-not $Pack.Jobs.Contains($e.Section.Substring("job.${Name}_".Length))) { continue }
            if ($e.Key -ceq 'secret') {
                $ref = $e.Value.Substring($e.Value.IndexOf('=') + 1)
                if ($seen.ContainsKey($ref)) { continue }
                $seen[$ref] = $true
                Write-Output "${Lead}needs ${ref}: $(Get-VigilPackSecretState -Root $Root -Ref $ref)"
            }
            elseif ($e.Key -ceq 'env' -and -not $envs.Contains($e.Value)) { $envs.Add($e.Value) }
        }
    }
    foreach ($n in $Pack.Needs) { Write-Output "${Lead}needs $n" }
    if ($envs.Count -gt 0) { Write-Output "${Lead}settings in vigil.config: $($envs -join ' ')" }
}

function Get-VigilPackList {
    param([string]$Root)
    $packs = Join-Path $Root 'packs'
    $n = 0
    $cfg = Join-Path $Root 'config\vigil.config'
    # Whether a job is on cannot be told without the configuration, nor which
    # packs are here without the folder: say so, rather than "off".
    $denied = Get-VigilDenied $packs
    if (-not $denied) { $denied = Get-VigilDenied $cfg }
    if ($denied) { Stop-VigilPack (Get-VigilDeniedMessage $denied); return 1 }
    $p = if ([System.IO.File]::Exists($cfg)) { ConvertFrom-VigilConfig -Path $cfg } else { $null }
    if ([System.IO.Directory]::Exists($packs)) {
        foreach ($d in ([System.IO.Directory]::GetDirectories($packs) | Sort-Object)) {
            $name = [System.IO.Path]::GetFileName($d)
            $m = Read-VigilPack -Dir $d -Name $name
            if (-not $m) { continue }
            Write-Output "$name $($m.Version): $($m.About)"
            # Its pack.config ships everywhere, its scripts only where they run (46).
            if ($m.Jobs.Count -eq 0) {
                Write-Output '  not available here: no scripts for Windows'
                $n++
                continue
            }
            foreach ($j in $m.Jobs) {
                $state = if ($p -and (Test-VigilPackOn $p "${name}_$j")) { 'on' } else { 'off' }
                Write-Output ('  {0,-24} {1}' -f "${name}_$j", $state)
            }
            Get-VigilPackNeeds -Root $Root -Name $name -Pack $m -Parsed $p -Lead '  '
            $n++
        }
    }
    if ($n -eq 0) { Write-Output 'no packs here' }
}

function Enable-VigilPack {
    param([string]$Root, [string]$What)
    $w = Get-VigilPackName -Root $Root -What $What
    if (-not $w) { return 1 }
    if (-not (Test-VigilPackWritable -Root $Root)) { return 1 }
    $m = Read-VigilPack -Dir (Join-Path $Root "packs\$($w.Pack)") -Name $w.Pack
    if (-not $m) { Stop-VigilPack "cannot read pack $($w.Pack)"; return 1 }
    $list = @($m.Jobs)
    # Its pack.config ships everywhere, its scripts only where they run: nothing
    # here is nothing to turn on, not "already on" (46).
    if ($list.Count -eq 0) { Stop-VigilPack "pack $($w.Pack) has no scripts for Windows"; return 1 }
    if ($w.Job) {
        if (-not $m.Jobs.Contains($w.Job)) { Stop-VigilPack "no job called ${What}: vigil pack list"; return 1 }
        $list = @($w.Job)
    }
    $cfg = Join-Path $Root 'config\vigil.config'
    $p = ConvertFrom-VigilConfig -Path $cfg
    $add = @($list | Where-Object { -not (Test-VigilPackOn $p "$($w.Pack)_$_") })
    if ($add.Count -eq 0) { Write-Output "$What is already on"; Get-VigilPackNeeds -Root $Root -Name $w.Pack -Pack $m -Parsed $p -Lead ''; return 0 }
    $text = Get-VigilPackRewrite -Text ([System.IO.File]::ReadAllText($cfg)) -Name $w.Pack -Pack $m -Add $add
    if (-not (Set-VigilPackConfig -Root $Root -Name $w.Pack -Text $text)) { return 1 }
    foreach ($j in $add) { Write-Output "on: $($w.Pack)_$j" }
    Get-VigilPackNeeds -Root $Root -Name $w.Pack -Pack $m -Parsed (ConvertFrom-VigilConfig -Path $cfg) -Lead ''
    return 0
}

function Disable-VigilPack {
    param([string]$Root, [string]$What)
    $w = Get-VigilPackName -Root $Root -What $What
    if (-not $w) { return 1 }
    if (-not (Test-VigilPackWritable -Root $Root)) { return 1 }
    $cfg = Join-Path $Root 'config\vigil.config'
    $t = [System.IO.File]::ReadAllText($cfg)
    if ($w.Job) {
        if (-not (Test-VigilPackOn (ConvertFrom-VigilConfig -Path $cfg) $What)) { Write-Output "$What is already off"; return 0 }
        $text = Get-VigilPackRewrite -Text $t -Name $w.Pack -Pack $null -Drop @($w.Job)
    }
    else { $text = Get-VigilPackRewrite -Text $t -Name $w.Pack -Pack $null -All }
    if (-not (Set-VigilPackConfig -Root $Root -Name $w.Pack -Text $text)) { return 1 }
    Write-Output "off: $What"
    return 0
}

# Windows refuses to rename a folder while a process has a file in it open,
# and a job reads its script as it starts, so the refusal lasts a moment.
# The first packs of a packaged program (18.6), from the packs folder the
# package keeps beside app\. The install script copies them itself, from the
# archive. A pack already in the root stays as it is, so this never undoes a
# vigil pack update. Returns an exit code.
function Copy-VigilPackSeed {
    param([string]$Root, [string]$App)
    if (-not (Get-VigilPackaged -App $App)) { return 0 }
    $src = Join-Path (Split-Path -Parent $App) 'packs'
    if (-not [System.IO.Directory]::Exists($src)) { return 0 }
    try {
        foreach ($p in Get-ChildItem -LiteralPath $src -Directory) {
            if (-not [System.IO.File]::Exists((Join-Path $p.FullName 'pack.config'))) { continue }
            $to = Join-Path $Root "packs\$($p.Name)"
            if (Test-Path -LiteralPath $to) { continue }
            [void](New-Item -ItemType Directory -Force -Path $to -ErrorAction Stop)
            Copy-Item -LiteralPath (Join-Path $p.FullName 'pack.config') -Destination $to -ErrorAction Stop
            $own = Join-Path $p.FullName 'windows'
            if ([System.IO.Directory]::Exists($own)) { Get-ChildItem -LiteralPath $own -File | Copy-Item -Destination $to -ErrorAction Stop }
        }
    }
    catch {
        Stop-VigilPack "cannot write to $(Join-Path $Root 'packs'): $($_.Exception.Message)"
        return 1
    }
    return 0
}

function Move-VigilPackFolder {
    param([string]$From, [string]$To)
    for ($i = 0; ; $i++) {
        try { [System.IO.Directory]::Move($From, $To); return }
        catch {
            if ($i -ge 120) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

# Replaces a pack's scripts with the release's, and says what changed. Returns
# an exit code.
function Set-VigilPackScripts {
    param([string]$Root, [string]$App, [string]$Name, [string]$Src, $Was, $Diff = $null)
    $dir = Join-Path $Root "packs\$Name"
    $new = Read-VigilPack -Dir $Src -Name $Name
    if (-not $new) { return 1 }
    $ver = Join-Path $App 'VERSION'
    if ($new.Vigil -and [System.IO.File]::Exists($ver) -and (Test-VigilNewer $new.Vigil ([System.IO.File]::ReadAllText($ver).Trim()))) {
        Stop-VigilPack "pack $Name needs Vigil $($new.Vigil) or later: vigil self update"
        return 1
    }
    $changed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in [System.IO.Directory]::GetFiles($Src, '*.ps1')) {
        $b = [System.IO.Path]::GetFileName($f)
        $o = Join-Path $dir $b
        if ([System.IO.File]::Exists($o) -and (Get-FileHash -LiteralPath $f).Hash -cne (Get-FileHash -LiteralPath $o).Hash) {
            $changed.Add("${Name}_$([System.IO.Path]::GetFileNameWithoutExtension($b))")
        }
    }
    foreach ($p in @("$dir.new", "$dir.old")) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    try { Copy-Item -LiteralPath $Src -Destination "$dir.new" -Recurse -ErrorAction Stop }
    catch {
        Remove-Item -LiteralPath "$dir.new" -Recurse -Force -ErrorAction SilentlyContinue
        Stop-VigilPack "cannot write to $(Split-Path -Parent $dir); nothing was changed"
        return 1
    }
    # A script the pack dropped stays while a job runs it.
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $cfg = Join-Path $Root 'config\vigil.config'
    $p = if ([System.IO.File]::Exists($cfg)) { ConvertFrom-VigilConfig -Path $cfg } else { $null }
    if ($p) {
        foreach ($e in $p.Entries) {
            if ($e.Key -cne 'file' -or -not $e.Section.StartsWith('job.', [System.StringComparison]::Ordinal)) { continue }
            $v = $e.Value.Replace('\', '/')
            if (-not $v.StartsWith("packs/$Name/", [System.StringComparison]::Ordinal)) { continue }
            $b = $v.Substring(7 + $Name.Length)
            if (-not [System.IO.File]::Exists((Join-Path $Src $b)) -and [System.IO.File]::Exists((Join-Path $dir $b))) {
                [System.IO.File]::Copy((Join-Path $dir $b), (Join-Path "$dir.new" $b))
                $kept.Add($e.Section.Substring(4))
            }
        }
    }
    $had = [System.IO.Directory]::Exists($dir)
    try {
        if ($had) { Move-VigilPackFolder $dir "$dir.old" }
        Move-VigilPackFolder "$dir.new" $dir
    }
    catch {
        if ($had -and -not [System.IO.Directory]::Exists($dir)) { Move-VigilPackFolder "$dir.old" $dir }
        Remove-Item -LiteralPath "$dir.new" -Recurse -Force -ErrorAction SilentlyContinue
        Stop-VigilPack "cannot replace $dir; nothing was changed"
        return 1
    }
    if ($had) { Remove-Item -LiteralPath "$dir.old" -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $Was) {
        # Its jobs are all new, and all off: the caller says so.
        Write-Output "installed pack $Name $($new.Version)"
        return 0
    }
    if ($Was.Version -ceq $new.Version) {
        # The same version, put back as released ($Diff, what differed).
        Write-Output "restored pack $Name $($new.Version) as released"
        foreach ($b in @($Diff.Changed) + @($Diff.Missing)) { Write-Output "  put back  $b" }
        foreach ($b in @($Diff.Added)) { Write-Output "  removed   $b" }
        return 0
    }
    if (Test-VigilNewer $Was.Version $new.Version) { Write-Output "pack $Name went back from $($Was.Version) to $($new.Version)" }
    else { Write-Output "updated pack $Name $($Was.Version) to $($new.Version)" }
    if ($changed.Count -gt 0) { Write-Output "changed: $($changed -join ' ')" }
    foreach ($j in $new.Jobs) {
        if ($Was -and $Was.Jobs.Contains($j)) { continue }
        if ($p -and (Test-VigilPackOn $p "${Name}_$j")) { continue }
        Write-Output "new, not running: ${Name}_$j. To turn it on: vigil pack enable ${Name}_$j"
    }
    foreach ($j in $kept) { Write-Output "dropped from the pack, still running: $j. To stop it: vigil pack disable $j" }
    return 0
}

# Whether the installed packs can be read from this account: else what is
# here cannot be told, and every pack would look missing. A system install's
# root is closed to all but SYSTEM and Administrators, and .NET then says a
# folder in it does not exist rather than that it cannot be read.
function Test-VigilPackReadable {
    param([string]$Root)
    $packs = Join-Path $Root 'packs'
    try {
        if ([System.IO.Directory]::Exists($packs)) {
            foreach ($d in [System.IO.Directory]::GetDirectories($packs)) {
                [void][System.IO.Directory]::GetFiles($d)
                $f = Join-Path $d 'pack.config'
                if ([System.IO.File]::Exists($f)) { [void][System.IO.File]::ReadAllBytes($f) }
            }
        }
        else { [void][System.IO.Directory]::GetFileSystemEntries($Root) }
        return $true
    }
    catch { return $false }
}

# Whether $Spec is name[@version]: @{ Name; At }, or $null.
function Split-VigilPackSpec {
    param([string]$Spec)
    if ($Spec -cmatch '^([a-z0-9_]+)(@([0-9A-Za-z.-]+))?$') { return @{ Name = $Matches[1]; At = [string]$Matches[3] } }
    if ($Spec -cmatch '^[a-z0-9_]+@$') { Stop-VigilPack "no version after @: $Spec" }
    elseif ($Spec -cmatch '^[a-z0-9_]+@') { Stop-VigilPack "not a version: $Spec" }
    else { Stop-VigilPack "not a pack name: $Spec" }
    return $null
}

# Installs the picked version of pack $Name, or says it is here already.
# Returns an exit code.
function Install-VigilPackPick {
    param([string]$Root, $Repo, [string]$Name, $Pick)
    $dir = Join-Path $Root "packs\$Name"
    $was = Read-VigilPack -Dir $dir -Name $Name
    $src = Expand-VigilPackPick -Repo $Repo -Name $Name -Pick $Pick
    if (-not $src) { return 1 }
    $diff = $null
    if ($was -and $was.Version -ceq $Pick.Version) {
        # The version here: its files put back as released, where they differ.
        $diff = Compare-VigilPackFiles -Cfg (Join-Path $Root 'config\vigil.config') -Name $Name -Here $dir -Rel $src
        if ($diff.Changed.Count + $diff.Missing.Count + $diff.Added.Count -eq 0) { Write-Output "pack $Name $($was.Version) is here: nothing to do"; return 0 }
    }
    $code = 0
    Set-VigilPackScripts -Root $Root -App $Repo.App -Name $Name -Src $src -Was $was -Diff $diff | ForEach-Object { if ($_ -is [int]) { $code = $_ } else { $_ } }
    if ($code -ne 0 -or $was) { return $code }
    # Installed, and off: what it has and what it needs, so it is never
    # turned on blind.
    $now = Read-VigilPack -Dir $dir -Name $Name
    Write-Output "off until enabled: $(@($now.Jobs | ForEach-Object { "${Name}_$_" }) -join ' ')"
    Write-Output "To turn them all on: vigil pack enable $Name"
    $cfg = Join-Path $Root 'config\vigil.config'
    $p = if ([System.IO.File]::Exists($cfg)) { ConvertFrom-VigilConfig -Path $cfg } else { $null }
    Get-VigilPackNeeds -Root $Root -Name $Name -Pack $now -Parsed $p -Lead ''
    return 0
}

# What stops a change to packs\: what is here unreadable.
function Test-VigilPackChangeable {
    param([string]$Root)
    if (Test-VigilPackReadable -Root $Root) { return $true }
    Stop-VigilPack "cannot read $(Join-Path $Root 'packs') from this account: run this from an elevated prompt for a system install"
    return $false
}

function Install-VigilPack {
    param([string]$Root, [string]$App, [string]$From, [string[]]$Specs)
    $all = @()
    foreach ($s in $Specs) { $x = Split-VigilPackSpec $s; if (-not $x) { return 1 }; $all += , $x }
    if (-not (Test-VigilPackChangeable -Root $Root)) { return 1 }
    $repo = Open-VigilPackRepo -Root $Root -App $App -From $From
    try {
        if (-not $repo.Ok) { return 1 }
        $mine = Get-VigilPackMine -App $App
        $code = 0
        try { [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'packs') -ErrorAction Stop) }
        catch { Stop-VigilPack "$(Join-Path $Root 'packs') is not writable: run this from an elevated prompt for a system install"; return 1 }
        foreach ($x in $all) {
            $pick = Select-VigilPackVersion -Repo $repo -Name $x.Name -Want $x.At -Os windows -Mine $mine
            if (-not $pick.Version) { Stop-VigilPack $pick.Why; $code = 1; continue }
            Install-VigilPackPick -Root $Root -Repo $repo -Name $x.Name -Pick $pick | ForEach-Object { if ($_ -is [int]) { if ($_ -ne 0) { $code = 1 } } else { $_ } }
        }
        return $code
    }
    finally { Close-VigilPackRepo $repo }
}

function Update-VigilPack {
    param([string]$Root, [string]$App, [bool]$Check, [string[]]$Names = @())
    $packs = Join-Path $Root 'packs'
    # The packs named, else every pack here. Each named must be installed,
    # and is checked before anything is fetched. A version is install's to
    # pick: update only ever moves a pack forward.
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in @($Names | Where-Object { $_ })) {
        $x = Split-VigilPackSpec $s
        if (-not $x) { return 1 }
        if ($x.At) { Stop-VigilPack "pack update takes the newest version; for another: vigil pack install $s"; return 1 }
        $d = Join-Path $packs $x.Name
        if (-not (Read-VigilPack -Dir $d -Name $x.Name)) { Stop-VigilPack "pack $($x.Name) is not installed: vigil pack install $($x.Name)"; return 1 }
        $dirs.Add($d)
    }
    if (-not (Test-VigilPackChangeable -Root $Root)) { return 1 }
    $repo = Open-VigilPackRepo -Root $Root -App $App
    $code = 0
    try {
        if (-not $repo.Ok) { return 1 }
        $mine = Get-VigilPackMine -App $App
        $n = 0
        if (-not $dirs.Count -and [System.IO.Directory]::Exists($packs)) { foreach ($d in ([System.IO.Directory]::GetDirectories($packs) | Sort-Object)) { $dirs.Add($d) } }
        foreach ($d in $dirs) {
            $name = [System.IO.Path]::GetFileName($d)
            $was = Read-VigilPack -Dir $d -Name $name
            if (-not $was) { continue }
            $n++
            $pick = Select-VigilPackVersion -Repo $repo -Name $name -Want '' -Os windows -Mine $mine
            if (-not $pick.Version) {
                if ($pick.Newer) { Write-Output "pack $name $($was.Version) is here; $($pick.Newer) needs Vigil $($pick.NewerVigil) or later: vigil self update" }
                else { Write-Output "pack $name $($was.Version) is here, and not in the repository for Windows: kept as it is" }
                continue
            }
            # Never back a version: one newer than the repository's stays.
            if (-not (Test-VigilNewer $pick.Version $was.Version)) { Write-Output "pack $name $($was.Version) is here: nothing to do" }
            elseif ($Check) { Write-Output "pack $name $($was.Version) is here; $($pick.Version) is available: vigil pack update $name" }
            else {
                Install-VigilPackPick -Root $Root -Repo $repo -Name $name -Pick $pick | ForEach-Object { if ($_ -is [int]) { if ($_ -ne 0) { $code = 1 } } else { $_ } }
            }
            if ($pick.Newer) { Write-Output "  $name $($pick.Newer) needs Vigil $($pick.NewerVigil) or later: vigil self update" }
        }
        if ($n -eq 0) { Write-Output 'no packs here: vigil pack search, then vigil pack install <name>' }
        return $code
    }
    catch {
        Stop-VigilPack "$packs is not writable: run this from an elevated prompt for a system install"
        return 1
    }
    finally { Close-VigilPackRepo $repo }
}

# Checks the packs installed here against the packs release each version
# came from, every file byte for byte, its archive checked against the
# signed index as install checks it. Reads only. Returns an exit code.
function Test-VigilPack {
    param([string]$Root, [string]$App, [string]$From, [string[]]$Names = @())
    $packs = Join-Path $Root 'packs'
    if (-not (Test-VigilPackReadable -Root $Root)) {
        Stop-VigilPack "cannot read $packs from this account: run this from an elevated prompt for a system install"
        return 1
    }
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in @($Names | Where-Object { $_ })) {
        $x = Split-VigilPackSpec $s
        if (-not $x) { return 1 }
        if ($x.At) { Stop-VigilPack "pack verify checks the version installed here: vigil pack verify $($x.Name)"; return 1 }
        $d = Join-Path $packs $x.Name
        if (-not (Read-VigilPack -Dir $d -Name $x.Name)) { Stop-VigilPack "pack $($x.Name) is not installed: vigil pack list"; return 1 }
        $dirs.Add($d)
    }
    $repo = Open-VigilPackRepo -Root $Root -App $App -From $From
    try {
        if (-not $repo.Ok) { return 1 }
        if (-not $dirs.Count -and [System.IO.Directory]::Exists($packs)) {
            $all = [System.IO.Directory]::GetDirectories($packs)
            [Array]::Sort($all, [StringComparer]::Ordinal)
            foreach ($d in $all) { $dirs.Add($d) }
        }
        $cfg = Join-Path $Root 'config\vigil.config'
        $code = 0
        $n = 0
        foreach ($d in $dirs) {
            if (-not [System.IO.File]::Exists((Join-Path $d 'pack.config'))) { continue }
            $name = [System.IO.Path]::GetFileName($d)
            $was = Read-VigilPack -Dir $d -Name $name
            if (-not $was) { Write-Output "pack ${name}: cannot read its pack.config"; $code = 1; continue }
            $n++
            # A pack of your own, or a version no release has: nothing to check against.
            if (-not @($repo.Index.Packs | Where-Object { $_.Name -ceq $name -and $_.Version -ceq $was.Version }).Count) {
                Write-Output "pack $name $($was.Version): not in the repository, not checked"
                continue
            }
            $pick = Select-VigilPackVersion -Repo $repo -Name $name -Want $was.Version -Os windows -Mine ''
            if (-not $pick.Version) { Write-Output "pack $name $($was.Version): cannot check it: $($pick.Why)"; $code = 1; continue }
            # Why it cannot be had, or does not match the index, is on stderr.
            $src = Expand-VigilPackPick -Repo $repo -Name $name -Pick $pick
            if (-not $src) { Write-Output "pack $name $($pick.Version): cannot check it"; $code = 1; continue }
            $r = Compare-VigilPackFiles -Cfg $cfg -Name $name -Here $d -Rel $src
            $bad = $r.Changed.Count + $r.Missing.Count + $r.Added.Count
            if ($bad -eq 0) { Write-Output "pack $name $($pick.Version): its $($r.Count) files match $($pick.Release)" }
            else {
                Write-Output "pack $name $($pick.Version): differs from $($pick.Release)"
                $code = 1
            }
            foreach ($b in $r.Changed) { Write-Output "  changed  $b" }
            foreach ($b in $r.Missing) { Write-Output "  missing  $b" }
            foreach ($b in $r.Added) { Write-Output "  added    $b" }
            foreach ($b in $r.Kept) { $i = $b.IndexOf(':'); Write-Output "  kept     $($b.Substring(0, $i)): dropped from the pack, still run by $($b.Substring($i + 1))" }
            if ($bad -gt 0) { Write-Output "  To put it back as released: vigil pack install $name@$($pick.Version)" }
        }
        if ($n -eq 0) { Write-Output 'no packs here: vigil pack search, then vigil pack install <name>' }
        return $code
    }
    finally { Close-VigilPackRepo $repo }
}

# The jobs of configuration $Cfg that run a script of pack $Name.
function Get-VigilPackUsers {
    param([string]$Cfg, [string]$Name)
    $jobs = @()
    if (-not [System.IO.File]::Exists($Cfg)) { return , $jobs }
    $p = ConvertFrom-VigilConfig -Path $Cfg
    foreach ($e in $p.Entries) {
        if ($e.Key -ceq 'file' -and $e.Section.StartsWith('job.', [System.StringComparison]::Ordinal) -and
            $e.Value.Replace('\', '/').StartsWith("packs/$Name/", [System.StringComparison]::Ordinal)) { $jobs += $e.Section.Substring(4) }
    }
    return , $jobs
}

function Remove-VigilPack {
    param([string]$Root, [string[]]$Names, [switch]$Disable)
    foreach ($s in $Names) {
        $x = Split-VigilPackSpec $s
        if (-not $x) { return 1 }
        if ($x.At) { Stop-VigilPack "a pack is removed whole, any version: $($x.Name)"; return 1 }
    }
    $cfg = Join-Path $Root 'config\vigil.config'
    $denied = Get-VigilDenied $cfg
    if ($denied) { Stop-VigilPack (Get-VigilDeniedMessage $denied); return 1 }
    $p = $null
    if ([System.IO.File]::Exists($cfg)) {
        $p = ConvertFrom-VigilConfig -Path $cfg
        if ($p.Errors.Count -gt 0) { Stop-VigilPack "$cfg has errors: fix them first (vigil precheck)"; return 1 }
    }
    if (-not (Test-VigilPackChangeable -Root $Root)) { return 1 }
    $code = 0
    foreach ($s in $Names) {
        $dir = Join-Path $Root "packs\$s"
        $was = Read-VigilPack -Dir $dir -Name $s
        if (-not $was) { Stop-VigilPack "pack $s is not installed: vigil pack list"; $code = 1; continue }
        # A job running one of its scripts would fail at its next run. With
        # -Disable, the pack's own jobs are taken out first, as vigil pack
        # disable takes them. A job of the configuration's own that runs one
        # of its scripts keeps the pack: that is found first, and then
        # nothing is changed, not even the pack's jobs turned off.
        $jobs = Get-VigilPackUsers $cfg $s
        if ($Disable -and $jobs.Count -gt 0) {
            $theirs = @($was.Jobs | ForEach-Object { "${s}_$_" })
            $own = @($jobs | Where-Object { $theirs -cnotcontains $_ })
            if ($own.Count -gt 0) { Stop-VigilPack "pack $s is still used by jobs of your own: $($own -join ' '). Change them or take them out first"; $code = 1; continue }
            $failed = $false
            Disable-VigilPack -Root $Root -What $s | ForEach-Object { if ($_ -is [int]) { if ($_ -ne 0) { $failed = $true } } else { $_ } }
            if ($failed) { $code = 1; continue }
            $jobs = Get-VigilPackUsers $cfg $s
        }
        if ($jobs.Count -gt 0) { Stop-VigilPack "pack $s is in use by: $($jobs -join ' '). Turn them off first: vigil pack disable $s, or vigil pack remove --disable $s"; $code = 1; continue }
        try {
            if (Test-Path -LiteralPath "$dir.old") { Remove-Item -LiteralPath "$dir.old" -Recurse -Force -ErrorAction Stop }
            Move-VigilPackFolder $dir "$dir.old"
        }
        catch { Stop-VigilPack "cannot remove $dir"; $code = 1; continue }
        Remove-Item -LiteralPath "$dir.old" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "removed pack $s $($was.Version)"
    }
    return $code
}

# The width of the console standard output is, or 0 when it is redirected:
# rows piped or written to a file stay whole.
function Get-VigilPackCols {
    try {
        if ([Console]::IsOutputRedirected) { return 0 }
        $c = [Console]::WindowWidth
        if ($c -gt 0) { return $c }
    }
    catch { }
    return 0
}

# Rows (each an array of fields, the first the header) as a table: each
# column as wide as its widest field, a rule under each header, and with
# $Cols the console's width (0: none), the last column cut to fit, with
# "...", so each row stays one line.
function Format-VigilPackTable {
    param([object[]]$Rows, [int]$Cols)
    $k = $Rows[0].Count
    $w = New-Object 'int[]' $k
    foreach ($r in $Rows) { for ($i = 0; $i -lt $k; $i++) { if (([string]$r[$i]).Length -gt $w[$i]) { $w[$i] = ([string]$r[$i]).Length } } }
    if ($Cols -gt 0) {
        $room = $Cols - 1
        for ($i = 0; $i -lt $k - 1; $i++) { $room -= $w[$i] + 1 }
        if ($room -lt 10) { $room = 10 }
        if ($w[$k - 1] -gt $room) { $w[$k - 1] = $room }
    }
    $all = New-Object 'System.Collections.Generic.List[object]'
    $all.Add($Rows[0])
    $all.Add([string[]]@(for ($i = 0; $i -lt $k; $i++) { '-' * ([string]$Rows[0][$i]).Length }))
    for ($j = 1; $j -lt $Rows.Count; $j++) { $all.Add($Rows[$j]) }
    foreach ($r in $all) {
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $k; $i++) {
            $x = [string]$r[$i]
            if ($i -gt 0) { [void]$sb.Append(' ') }
            if ($i -lt $k - 1) { [void]$sb.Append($x.PadRight($w[$i])) }
            elseif ($x.Length -gt $w[$i]) { [void]$sb.Append($x.Substring(0, $w[$i] - 3) + '...') }
            else { [void]$sb.Append($x) }
        }
        $sb.ToString().TrimEnd(' ')
    }
}

# The index's packs, as a table with the newest version of each: those
# whose name or description has every word of $Words (all, when there is
# none), or with -Available, those not installed.
function Show-VigilPackIndex {
    param([string]$Root, $Repo, [string[]]$Words, [switch]$Available)
    $newest = @{}
    foreach ($p in $Repo.Index.Packs) {
        if (-not $newest.ContainsKey($p.Name) -or (Test-VigilNewer $p.Version $newest[$p.Name].Version)) { $newest[$p.Name] = $p }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $rows.Add([string[]]@('Name', 'Version', 'Here', 'About'))
    foreach ($name in ($newest.Keys | Sort-Object { $_ } -CaseSensitive)) {
        $p = $newest[$name]
        $t = "$name $($p.About)".ToLowerInvariant()
        $hit = $true
        foreach ($w in $Words) { if ($w -and -not $t.Contains($w.ToLowerInvariant())) { $hit = $false } }
        if (-not $hit) { continue }
        $was = Read-VigilPack -Dir (Join-Path $Root "packs\$name") -Name $name
        if ($Available -and $was) { continue }
        $here = ''
        if (-not $was) {
            if (-not ($Repo.Index.Files | Where-Object { $_.Name -ceq $name -and $_.Version -ceq $p.Version -and $_.Os -ceq 'windows' })) { $here = 'not for Windows' }
        }
        elseif ($was.Version -ceq $p.Version) { $here = 'installed' }
        else { $here = "$($was.Version) installed" }
        $rows.Add([string[]]@($name, $p.Version, $here, $p.About))
    }
    if ($rows.Count -eq 1) {
        if ($Available) { Write-Output 'every pack is installed' } else { Write-Output "no pack matches: $($Words -join ' ')" }
        return
    }
    if ($Available) { Write-Output "Packs in $($Repo.Index.Release) not installed here:" } else { Write-Output "Packs in $($Repo.Index.Release):" }
    Write-Output ''
    Format-VigilPackTable -Rows $rows.ToArray() -Cols (Get-VigilPackCols)
}

function Find-VigilPack {
    param([string]$Root, [string]$App, [string[]]$Words, [switch]$Available)
    $repo = Open-VigilPackRepo -Root $Root -App $App -Saved
    try {
        if (-not $repo.Ok) { return 1 }
        Show-VigilPackIndex -Root $Root -Repo $repo -Words $Words -Available:$Available
        return 0
    }
    finally { Close-VigilPackRepo $repo }
}

# A field of vigil pack info: its label, then its text wrapped at 78 columns
# under itself; a word is never split.
function Format-VigilPackField {
    param([string]$Label, [string]$Text)
    $pre = if ($Label) { '{0,-10} : ' -f $Label } else { ' ' * 13 }
    $line = ''
    foreach ($w in @($Text -split '\s+' | Where-Object { $_ })) {
        if ($line -and ($pre.Length + $line.Length + 1 + $w.Length -gt 78)) {
            $pre + $line
            $pre = ' ' * 13
            $line = $w
        }
        elseif ($line) { $line += " $w" }
        else { $line = $w }
    }
    $pre + $line
}

# Items as "a", "a and b" or "a, b and c".
function Join-VigilPackAnd {
    param([string[]]$Items)
    if ($Items.Count -le 1) { return ($Items -join '') }
    return (($Items[0..($Items.Count - 2)] -join ', ') + ' and ' + $Items[$Items.Count - 1])
}

# One pack, from the index: what it is, whether it is here, what it needs
# (its newest version's info records), and every version, newest first.
function Get-VigilPackInfo {
    param([string]$Root, [string]$App, [string]$Name)
    $x = Split-VigilPackSpec $Name
    if (-not $x) { return 1 }
    if ($x.At) { Stop-VigilPack "vigil pack info takes a name, without a version: $($x.Name)"; return 1 }
    $repo = Open-VigilPackRepo -Root $Root -App $App -Saved
    try {
        if (-not $repo.Ok) { return 1 }
        $all = @($repo.Index.Packs | Where-Object { $_.Name -ceq $Name })
        if ($all.Count -eq 0) { Stop-VigilPack "no pack called ${Name}: vigil pack search"; return 1 }
        # Newest first.
        $sorted = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $all) {
            $i = 0
            while ($i -lt $sorted.Count -and -not (Test-VigilNewer $p.Version $sorted[$i].Version)) { $i++ }
            $sorted.Insert($i, $p)
        }
        $newest = $sorted[0]
        $was = Read-VigilPack -Dir (Join-Path $Root "packs\$Name") -Name $Name
        $pick = Select-VigilPackVersion -Repo $repo -Name $Name -Want '' -Os windows -Mine (Get-VigilPackMine -App $App)
        if ($was) {
            if ($pick.Version -and (Test-VigilNewer $pick.Version $was.Version)) { $here = "$($was.Version) installed; $($pick.Version) is available: vigil pack update $name" }
            elseif ($pick.Newer -and (Test-VigilNewer $pick.Newer $was.Version)) { $here = "$($was.Version) installed; $($pick.Newer) needs Vigil $($pick.NewerVigil) or later: vigil self update" }
            elseif ($was.Version -ceq $newest.Version) { $here = "$($was.Version) installed, the newest" }
            else { $here = "$($was.Version) installed" }
        }
        elseif ($pick.Version) { $here = "not installed: vigil pack install $Name" }
        elseif ($pick.Newer) { $here = "not installed; $($pick.Newer) needs Vigil $($pick.NewerVigil) or later: vigil self update" }
        else { $here = 'not for Windows' }
        $pretty = @{ linux = 'Linux'; macos = 'macOS'; windows = 'Windows' }
        $has = @{}
        foreach ($f in $repo.Index.Files) { if ($f.Name -ceq $Name -and $f.Version -ceq $newest.Version) { $has[$f.Os] = $true } }
        $po = @('linux', 'macos', 'windows' | Where-Object { $has.ContainsKey($_) })
        $ps = @($po | ForEach-Object { $pretty[$_] })
        $one = @{}
        $sec = New-Object 'System.Collections.Generic.List[string]'
        $nd = New-Object 'System.Collections.Generic.List[string]'
        $st = New-Object 'System.Collections.Generic.List[string]'
        $info = $false
        foreach ($i in $repo.Index.Info) {
            if ($i.Name -cne $Name -or $i.Version -cne $newest.Version) { continue }
            $info = $true
            if ($i.Key -ceq 'secret') { $sec.Add($i.Value) }
            elseif ($i.Key -ceq 'needs') { $nd.Add($i.Value) }
            elseif ($i.Key -ceq 'setting') { $st.Add($i.Value) }
            else { $one[$i.Key] = $i.Value }
        }
        Format-VigilPackField 'Name' $Name
        Format-VigilPackField 'About' $newest.About
        Format-VigilPackField 'Here' $here
        Format-VigilPackField 'Platforms' $(if ($ps.Count -gt 0) { $ps -join ', ' } else { 'none' })
        if ($one['works_with']) { Format-VigilPackField 'Works with' $one['works_with'] }
        if ($info) {
            # This platform's programs; or, with no scripts here, those of
            # the platforms it has.
            if ($has.ContainsKey('windows')) {
                $p = $one['programs_windows']
                Format-VigilPackField 'Programs' $(if ($p) { $p } else { 'none on Windows' })
            }
            elseif ($po.Count -gt 0) {
                $vals = @($po | ForEach-Object { [string]$one["programs_$_"] })
                if (@($vals | Select-Object -Unique).Count -eq 1) {
                    Format-VigilPackField 'Programs' $(if ($vals[0]) { "$($vals[0]) (on $(Join-VigilPackAnd $ps))" } else { 'none' })
                }
                else {
                    $parts = @(for ($i = 0; $i -lt $po.Count; $i++) { if ($vals[$i]) { "$($vals[$i]) (on $($ps[$i]))" } })
                    Format-VigilPackField 'Programs' ($parts -join ', ')
                }
            }
            Format-VigilPackField 'Secrets' $(if ($sec.Count -gt 0) { $sec -join ', ' } else { 'none' })
            # What it is, wrapped, then the command whole on a line of its
            # own, to copy.
            for ($i = 0; $i -lt $nd.Count; $i++) {
                $label = if ($i -eq 0) { 'Needs' } else { '' }
                $p = $nd[$i].IndexOf(': ')
                if ($p -ge 0) {
                    Format-VigilPackField $label $nd[$i].Substring(0, $p + 1)
                    (' ' * 13) + $nd[$i].Substring($p + 2)
                }
                else { Format-VigilPackField $label $nd[$i] }
            }
            if ($st.Count -gt 0) { Format-VigilPackField 'Settings' "$($st -join ' ') (the env lines in vigil.config, once enabled)" }
            if ($one['docs']) { ('{0,-10} : ' -f 'Docs') + $one['docs'] }
        }
        ''
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $rows.Add([string[]]@('Version', 'Platforms', 'Needs Vigil', 'Release'))
        foreach ($p in $sorted) {
            $plats = @('linux', 'macos', 'windows' | Where-Object { $o = $_; @($repo.Index.Files | Where-Object { $_.Name -ceq $Name -and $_.Version -ceq $p.Version -and $_.Os -ceq $o }).Count -gt 0 } | ForEach-Object { $pretty[$_] })
            $rows.Add([string[]]@($p.Version, $(if ($plats.Count -gt 0) { $plats -join ', ' } else { 'none' }), $p.Vigil, $p.Release))
        }
        Format-VigilPackTable -Rows $rows.ToArray() -Cols 0
        return 0
    }
    finally { Close-VigilPackRepo $repo }
}

function Save-VigilPack {
    param([string]$Root, [string]$App, [string]$Os, [string]$To, [string[]]$Specs)
    $osName = @{ linux = 'Linux'; macos = 'macOS'; windows = 'Windows' }[$Os]
    if (-not $osName -or $Os -cnotmatch '^(linux|macos|windows)$') { Stop-VigilPack "not a platform: $Os (linux, macos or windows)"; return 1 }
    $all = @()
    foreach ($s in $Specs) { $x = Split-VigilPackSpec $s; if (-not $x) { return 1 }; $all += , $x }
    $dest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($To)
    try { [void](New-Item -ItemType Directory -Force -Path $dest -ErrorAction Stop) }
    catch { Stop-VigilPack "cannot write to $To"; return 1 }
    $repo = Open-VigilPackRepo -Root $Root -App $App
    try {
        if (-not $repo.Ok) { return 1 }
        $mine = Get-VigilPackMine -App $App
        foreach ($x in $all) {
            # The version install would take here; one asked for, whatever
            # Vigil it needs, as the machine it is for may run another.
            $m = if ($x.At) { '' } else { $mine }
            $pick = Select-VigilPackVersion -Repo $repo -Name $x.Name -Want $x.At -Os $Os -Mine $m
            if (-not $pick.Version) { Stop-VigilPack $pick.Why; return 1 }
            $f = Join-Path $repo.Work $pick.File
            if (-not (Get-VigilPackFile -Repo $repo -Rel $pick.Release -Name $pick.File -OutFile $f)) { return 1 }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLowerInvariant() -cne $pick.Sha) {
                Stop-VigilPack "$($pick.File) does not match the pack index; nothing was written"
                return 1
            }
            try { [System.IO.File]::Copy($f, (Join-Path $dest $pick.File), $true) }
            catch { Stop-VigilPack "cannot write to $To"; return 1 }
            Write-Output "downloaded $($x.Name) $($pick.Version) for ${osName}: $($pick.File)"
        }
        try {
            [System.IO.File]::Copy($repo.IndexPath, (Join-Path $dest 'packs.index'), $true)
            [System.IO.File]::Copy("$($repo.IndexPath).sig", (Join-Path $dest 'packs.index.sig'), $true)
        }
        catch { Stop-VigilPack "cannot write to $To"; return 1 }
        Write-Output 'with the signed index. There: vigil pack install <name> --from <this folder>'
        return 0
    }
    finally { Close-VigilPackRepo $repo }
}
