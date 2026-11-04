#Requires -Version 5.1

<#
.SYNOPSIS
    size.ps1 - the size of each PostgreSQL database, on Windows
.DESCRIPTION
    Asks the server, as a read-only role (pg_monitor), how much disk each
    database takes. Template databases are left out. Connects as the libpq
    environment says: PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD, set
    by the job. psql is looked for on the PATH, then in PostgreSQL's own
    folders under Program Files, the newest version first.

    Metrics:
        size_bytes  disk used by the database, in bytes (tag: database)

    Example output:
      metric size_bytes 7631663 database=postgres
      metric size_bytes 52748591104 database=orders

    Reading the results (starting points: tune them to the server):
      Healthy  growing as the data does.
      Watch    growing much faster than the data, which can mean bloat that
               vacuum is not keeping up with.
      Act      approaching the space left on the disk.

    Requires: Windows PowerShell 5.1 or PowerShell 7, psql (PostgreSQL's
      client tools), and a role with pg_monitor
    Exit code: 0 on success; 1 if psql is missing, or the server cannot be
      reached or refuses the login or the query
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
#>

$ErrorActionPreference = 'Stop'

# psql: on the PATH, or the newest of PostgreSQL's own.
$psql = $null
$c = @(Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue)
if ($c.Count -gt 0) { $psql = $c[0].Source }
else {
    $found = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'PostgreSQL') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\psql.exe') } |
            Sort-Object { [int]($_.Name -replace '\D.*$', '') } -Descending)
    if ($found.Count -gt 0) { $psql = Join-Path $found[0].FullName 'bin\psql.exe' }
}
if (-not $psql) {
    [Console]::Error.WriteLine('size: psql not found: install PostgreSQL''s client tools')
    exit 1
}

$query = 'SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname'
$ErrorActionPreference = 'Continue'
$out = @(& $psql -X -q -A -t -F ' ' -v ON_ERROR_STOP=1 -c $query 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("size: the server could not be reached, or refused the login or the query: $($out -join ' ')")
    exit 1
}

foreach ($line in $out) {
    $name, $bytes = "$line".Trim().Split(' ', 2)
    if (-not $name -or -not $bytes) { continue }
    # A metric tag cannot hold a space, and a database name may.
    Write-Output "metric size_bytes $bytes database=$($name -replace '[^A-Za-z0-9_.-]', '_')"
}
