<#
.SYNOPSIS
    _sqlite.ps1 - what the sqlite pack's scripts share on Windows: the list of databases, a file's size and age, a database's header read as bytes, and the helpers that print. Each job's script dot-sources it; it is never run as a job.
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0
    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    SQLITE_FILES is the databases to watch, their paths separated by ;
    (C:\ProgramData\app\data.db; D:\srv\other.db). A database's header is
    its first 100 bytes, read as a file like any other, opened so that the
    application using it may go on reading, writing and deleting: no SQLite
    library, no lock taken, nothing it can notice. Until it is set, the jobs
    report databases 0 (status) and checked 0 (check).
#>
$ErrorActionPreference = 'Stop'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# The databases, the spaces around each taken off; none when SQLITE_FILES
# is not set.
function Get-Databases {
    $f = @()
    if ($env:SQLITE_FILES) { $f = @($env:SQLITE_FILES -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return , $f
}

# A path as a tag's value: / for \, no spaces, quotes or control
# characters, and at most 120 characters, its end kept (the file's name).
function Safe($s) {
    $s = (([string]$s) -replace '\\', '/') -replace '[^A-Za-z0-9@._:/+-]', '_'
    if (-not $s) { return 'none' }
    if ($s.Length -gt 120) { return $s.Substring($s.Length - 120) }
    return $s
}
function M([string]$name, $v, [string]$tags) {
    $t = if ($tags) { ' ' + $tags } else { '' }
    "metric $name $(([double]$v).ToString('0.##', $script:Inv))$t"
}
# A file's size and when it was last written, in seconds since 1970; $null
# when there is no such file.
function Get-Stat([string]$path) {
    $i = New-Object System.IO.FileInfo -ArgumentList $path
    if (-not $i.Exists) { return $null }
    return [pscustomobject]@{ Size = [double]$i.Length; Time = [DateTimeOffset]::new($i.LastWriteTimeUtc).ToUnixTimeSeconds() }
}
# The first $n bytes of a file, opened so that others may go on reading,
# writing and deleting it. Fewer when the file is shorter.
function Read-Head([string]$path, [int]$n) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $s = New-Object System.IO.FileStream -ArgumentList $path, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), $share
    try {
        $b = New-Object byte[] $n
        $got = 0
        while ($got -lt $n) {
            $r = $s.Read($b, $got, $n - $got)
            if ($r -le 0) { break }
            $got += $r
        }
        if ($got -lt $n) { $b = [byte[]]($b[0..($got - 1)]) }
        if ($got -eq 0) { return , (New-Object byte[] 0) }
        return , $b
    } finally { $s.Dispose() }
}
function U16([byte[]]$b, [int]$i) { return [double]$b[$i] * 256 + $b[$i + 1] }
function U32([byte[]]$b, [int]$i) { return (([double]$b[$i] * 256 + $b[$i + 1]) * 256 + $b[$i + 2]) * 256 + $b[$i + 3] }
