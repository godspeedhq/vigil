#Requires -Version 5.1

<#
.SYNOPSIS
    crashdumps.ps1 - the crash dumps Erlang VMs left behind, and why they died
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    An Erlang VM that dies writes a crash dump (erl_crash.dump, or where
    ERL_CRASH_DUMP says), whose first lines say why: its slogan, such as
    "eheap_alloc: Cannot allocate 2545496 bytes of memory (of type "heap")."
    This script finds them and reports each, newest first. It looks in each
    folder or file in BEAM_CRASH_DUMPS (separated by ;, set by the job), and
    in RabbitMQ's log folder in each profile (AppData\Roaming\RabbitMQ\log,
    the service's too, under systemprofile). A file is a dump when its
    first line says so; it reads a dump's first lines only, however large
    it is.

    Metrics:
        dumps               the crash dumps found
        dump                always 1, tagged file=<its path>, node=<the
                            node that died, when the dump names it> and
                            slogan=<why it died>
        age_seconds         how long ago it was written, tagged file=<the
                            same>
        newest_age_seconds  how long ago the newest was written
        dumps_not_shown     past the first 20, newest first, how many were
                            left out

    Example output:
      metric dump 1 file=C:/Users/svc/AppData/Roaming/RabbitMQ/log/erl_crash.dump node=rabbit@win1 slogan=eheap_alloc:_Cannot_allocate_2545496_bytes_of_memory_(of_type_heap).
      metric age_seconds 412 file=C:/Users/svc/AppData/Roaming/RabbitMQ/log/erl_crash.dump
      metric dumps 1
      metric newest_age_seconds 412
      metric dumps_not_shown 0

    Reading the results (starting points: tune them to the machine):
      Healthy  dumps 0, or only old ones you have read and kept.
      Watch    newest_age_seconds under a day: a VM died since yesterday;
               read its slogan, then move or delete the dump (one dump
               file, erl_crash.dump, is overwritten by the next).
      Act      newest_age_seconds under an hour: a VM died just now. Its
               slogan says why: "Cannot allocate": out of memory (beam.vm
               memory_bytes); "no more index entries in atom_tab": the atom
               limit (beam.vm atom_pct); "Kernel pid terminated": an
               application it could not run without stopped.

    Requires: Windows PowerShell 5.1 or PowerShell 7
    Exit code: 0 on success, dumps or none
#>

$ErrorActionPreference = 'Stop'

$places = New-Object System.Collections.Generic.List[string]
foreach ($p in (([string]$env:BEAM_CRASH_DUMPS) -split ';')) { if ($p.Trim()) { $places.Add($p.Trim()) } }
foreach ($d in @(Get-ChildItem -Path "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue)) {
    $places.Add((Join-Path $d.FullName 'AppData\Roaming\RabbitMQ\log'))
}
$places.Add("$env:SystemRoot\System32\config\systemprofile\AppData\Roaming\RabbitMQ\log")

# The candidates: erl_crash.dump and *.dump in each folder, or the file. A
# dump starts =erl_crash_dump:; the same file found twice counts once.
$seen = @{}
$dumps = New-Object System.Collections.Generic.List[object]
foreach ($p in $places) {
    $files = @()
    try {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $files = @(Get-Item -LiteralPath $p) }
        elseif (Test-Path -LiteralPath $p -PathType Container) { $files = @(Get-ChildItem -LiteralPath $p -Filter '*.dump' -File) }
    }
    catch { continue }
    foreach ($f in $files) {
        if ($seen.ContainsKey($f.FullName)) { continue }
        $seen[$f.FullName] = $true
        try {
            $s = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $buf = New-Object byte[] 65536
                $n = $s.Read($buf, 0, $buf.Length)
            }
            finally { $s.Close() }
        }
        catch { continue }
        $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
        if (-not $head.StartsWith('=erl_crash_dump:')) { continue }
        $dumps.Add([pscustomobject]@{ File = $f.FullName; Time = $f.LastWriteTimeUtc; Head = $head })
    }
}

# The node that died: its =node: line, past its processes (in the first
# 16 MB, as a dump can be gigabytes).
function NodeOf([string]$file) {
    try {
        $r = New-Object System.IO.StreamReader((New-Object System.IO.FileStream($file, 'Open', 'Read', 'ReadWrite')), [System.Text.Encoding]::ASCII)
        try {
            $read = 0
            while ($null -ne ($l = $r.ReadLine()) -and $read -lt 16000000) {
                $read += $l.Length + 1
                if ($l -match "^=node:'(.*)'") { return $Matches[1] }
            }
        }
        finally { $r.Close() }
    }
    catch { }
    ''
}

$now = [datetime]::UtcNow
$newest = $null
$shown = 0
foreach ($d in ($dumps | Sort-Object Time -Descending)) {
    $age = [long][Math]::Max(0, ($now - $d.Time).TotalSeconds)
    if ($null -eq $newest) { $newest = $age }
    if ($shown -ge 20) { continue }
    $shown++
    $slogan = 'unknown'
    if ($d.Head -match '(?m)^Slogan: (.*?)\r?$') { $slogan = $Matches[1] }
    $slogan = (($slogan -replace '["''`]', '') -replace '[^A-Za-z0-9@._:/+=,()-]', '_').TrimEnd('_')
    if ($slogan.Length -gt 120) { $slogan = $slogan.Substring(0, 120) }
    $file = ($d.File -replace '\\', '/') -replace '[^A-Za-z0-9@._:/+=,-]', '_'
    $node = (NodeOf $d.File) -replace '[^A-Za-z0-9@._-]', '_'
    $nodeTag = if ($node) { " node=$node" } else { '' }
    Write-Output "metric dump 1 file=$file$nodeTag slogan=$slogan"
    Write-Output "metric age_seconds $age file=$file"
}
Write-Output "metric dumps $($dumps.Count)"
if ($null -ne $newest) { Write-Output "metric newest_age_seconds $newest" }
Write-Output "metric dumps_not_shown $([Math]::Max(0, $dumps.Count - 20))"
exit 0
