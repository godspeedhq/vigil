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
    A pack is a set of scripts and jobs (SPECIFICATION.md 18.10), kept in the
    Vigil repository and carried by each release, signed with it.
    packs\<name>\ holds this platform's scripts and is Vigil's to replace.
    The configuration is the operator's: Vigil runs only what it names, so an
    update changes scripts and never the configuration, and a new script
    stays off until it is enabled. The twin of pack.sh.

    Get-VigilPackList -Root <dir>
        Each pack here and whether its jobs are on.
    Enable-VigilPack -Root <dir> -What <pack, or pack_job>
    Disable-VigilPack -Root <dir> -What <pack, or pack_job>
        Change the configuration, or nothing when the result is not valid.
    Update-VigilPack -Root <dir> -App <app dir> -Check <bool>
        Replaces the scripts with the latest release's.
    Copy-VigilPackSeed -Root <dir> -App <app dir>
        A packaged program only: copies in the packs the package keeps beside
        app\, those not here yet.
    Each returns an exit code: 0, or 1 with the reason on stderr; nothing is
    changed then.

    Requires Config.ps1, Validate.ps1 and SelfUpdate.ps1.
#>

function Stop-VigilPack {
    param([string]$Why)
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

# Finds the latest release and unpacks this platform's packs, verified: the
# signature against the key installed here, then the file against SHA256SUMS.
# From GitHub, or the configuration's release_url (18.7).
# @{ Ok; Work; Src; Want }; the caller removes Work.
function Get-VigilPackRelease {
    param([string]$Root, [string]$App)
    $out = @{ Ok = $false; Work = ''; Src = ''; Want = '' }
    $src = Get-VigilReleaseSource -Root $Root
    if ($src.Error) { Stop-VigilPack $src.Error; return $out }
    $base = $src.Base
    $key = Join-Path $App 'release-key.pem'
    if ($env:VIGIL_TEST_RELEASE_URL -and $env:VIGIL_TEST_RELEASE_KEY) { $key = $env:VIGIL_TEST_RELEASE_KEY }
    if (-not (Test-Path -LiteralPath $key)) { Stop-VigilPack 'no release key here: packs cannot be verified; nothing was changed'; return $out }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $saved = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $want = Get-VigilLatestVersion -Base $base -Mirror $src.Mirror -Path $src.Path -TimeoutSec 60 -Header $src.Header
        if (-not $want) { Stop-VigilPack (Get-VigilReleaseUnreadable $src); return $out }
        # A new folder of its own, never one that is already there.
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-pack.' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $work)
        $out.Work = $work
        $file = "vigil-packs-$want-windows.zip"
        try {
            foreach ($f in @($file, 'SHA256SUMS', 'SHA256SUMS.sig')) {
                Get-VigilReleaseFile -Src $src -Rel "releases/download/v$want/$f" -OutFile (Join-Path $work $f)
            }
        }
        catch {
            $why = Get-VigilReleaseRefused $src
            if ($why) { $why = ": $why" }
            Stop-VigilPack "cannot download the packs of release $want$why"
            return $out
        }
        $sums = Join-Path $work 'SHA256SUMS'
        if (-not (Test-VigilSignature -KeyFile $key -Data ([System.IO.File]::ReadAllBytes($sums)) -Signature ([System.IO.File]::ReadAllBytes((Join-Path $work 'SHA256SUMS.sig'))))) {
            Stop-VigilPack "release $want is not signed by the Vigil release key; nothing was changed"
            return $out
        }
        $sum = ''
        foreach ($l in [System.IO.File]::ReadAllLines($sums)) {
            $x = $l -split '\s+', 2
            if ($x.Count -eq 2 -and $x[1].TrimStart('*') -ceq $file) { $sum = $x[0].ToLowerInvariant() }
        }
        if (-not $sum -or (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $work $file)).Hash.ToLowerInvariant() -cne $sum) {
            Stop-VigilPack "the packs of release $want do not match its SHA256SUMS; nothing was changed"
            return $out
        }
        try { Expand-Archive -LiteralPath (Join-Path $work $file) -DestinationPath (Join-Path $work 'x') -ErrorAction Stop }
        catch { Stop-VigilPack "cannot unpack the packs of release $want"; return $out }
        $src = Join-Path $work "x\vigil-packs-$want"
        if (-not [System.IO.Directory]::Exists($src)) { Stop-VigilPack "the packs of release $want hold no vigil-packs-$want folder"; return $out }
        # Verified: the downloaded-from-the-internet mark would make a
        # RemoteSigned policy refuse them.
        Get-ChildItem -LiteralPath $src -Recurse -File | Unblock-File
        $out.Src = $src
        $out.Want = $want
        $out.Ok = $true
        return $out
    }
    finally { $ProgressPreference = $saved }
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
        if (-not [System.IO.Directory]::Exists($d)) { return "not set: vigil secret set $n, as the account Vigil runs as" }
        # The folder is the owner's only: another account cannot look in it.
        try { $names = @([System.IO.Directory]::GetFiles($d) | ForEach-Object { [System.IO.Path]::GetFileName($_) }) }
        catch { return 'cannot be told from this account: vigil precheck, as the account Vigil runs as' }
        if ($names -ccontains $n) { return 'set' }
        return "not set: vigil secret set $n, as the account Vigil runs as"
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
    param([string]$Root, [string]$App, [string]$Name, [string]$Src, $Was)
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
    if ($Was) { Write-Output "updated pack $Name $($Was.Version) to $($new.Version)" } else { Write-Output "added pack $Name $($new.Version)" }
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

function Update-VigilPack {
    param([string]$Root, [string]$App, [bool]$Check)
    $packs = Join-Path $Root 'packs'
    if (-not (Test-VigilPackReadable -Root $Root)) {
        Stop-VigilPack "cannot read $packs from this account: run this from an elevated prompt for a system install"
        return 1
    }
    $rel = Get-VigilPackRelease -Root $Root -App $App
    $code = 0
    try {
        if (-not $rel.Ok) { return 1 }
        if (-not $Check) { [void](New-Item -ItemType Directory -Force -Path $packs) }
        foreach ($d in ([System.IO.Directory]::GetDirectories($rel.Src) | Sort-Object)) {
            $name = [System.IO.Path]::GetFileName($d)
            $now = Read-VigilPack -Dir $d -Name $name
            if (-not $now) { continue }
            $was = Read-VigilPack -Dir (Join-Path $packs $name) -Name $name
            if ($was -and $now.Version -ceq $was.Version) { Write-Output "pack $name $($was.Version) is here: nothing to do" }
            elseif ($Check) { Write-Output "pack $name $(if ($was) { $was.Version } else { 'none' }) is here; $($now.Version) is available: vigil pack update" }
            else {
                Set-VigilPackScripts -Root $Root -App $App -Name $name -Src $d -Was $was | ForEach-Object {
                    if ($_ -is [int]) { if ($_ -ne 0) { $code = 1 } } else { $_ }
                }
            }
        }
        return $code
    }
    catch {
        Stop-VigilPack "$packs is not writable: run this from an elevated prompt for a system install"
        return 1
    }
    finally { if ($rel.Work) { Remove-Item -LiteralPath $rel.Work -Recurse -Force -ErrorAction SilentlyContinue } }
}
