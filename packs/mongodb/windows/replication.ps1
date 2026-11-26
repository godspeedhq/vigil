#Requires -Version 5.1

<#
.SYNOPSIS
    replication.ps1 - a MongoDB replica set, from one member: a primary or not, members up and down, how far behind, the oplog window, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the replica set as the server at MONGODB_URL sees it: its name
    and this member's role; whether there is a primary; members healthy and
    down; how far each member is behind the primary (or, with no primary, the
    furthest ahead); this member's own lag when it is a secondary; and the
    oplog's window, how much history it keeps as time, the longest a member
    may be away and still catch up without a full resync. A server not in a
    replica set reports replicated 0, and the run succeeds. From hello,
    replSetGetStatus and the oplog's first and last entries.

    Reads the server at MONGODB_URL (default mongodb://localhost:27017), as
    MONGODB_USER (default vigil, with the clusterMonitor role) with the
    password in MONGODB_PASSWORD (a secret), with mongosh.exe (MONGOSH names
    another): it runs _replication.js, beside this script, with no connection of its
    own, and _replication.js logs in from the environment, so the password is never
    on a command line. Over TLS, MONGODB_CACERT names the CA file when the
    system's are not enough. One server is read, as it is (never moved to the
    primary), unless MONGODB_URL names a replica set. What the jobs share is
    in _mongodb.js.

    Metrics:
      up                         1 when the server answers, else 0
      info                       always 1, tagged set=<rs0> role=<primary,
                                 secondary, arbiter, standalone, ...>
      replicated                 1 in a replica set, else 0
      members                    the set's members
      members_healthy            of those, answering
      members_down               of those, not answering
      primary                    1 when the set has a primary, else 0 (no
                                 writes)
      secondaries                members that are secondaries
      lag_seconds_max            the furthest a secondary is behind
      lag_seconds                this member's own lag, when a secondary
      member_health              1 when a member answers, else 0, tagged
                                 member=<host:port> state=<primary, ...>
      member_lag_seconds         how far a member is behind, same tags
      members_not_shown          past MONGODB_MOST, the members not listed
      oplog_window_hours         the oplog's history, as time
      oplog_bytes                the oplog's size
      oplog_max_bytes            the most it may hold

    Example output (the rest are in the same form):
      metric replicated 1
      metric info 1 set=rs0 role=secondary
      metric members_healthy 3
      metric primary 1
      metric lag_seconds_max 0
      metric oplog_window_hours 26.5

    Reading the results (starting points: tune them to the server):
      Healthy  primary 1; members_down 0; lag_seconds_max a few seconds;
               oplog_window_hours a day or more.
      Watch    lag_seconds_max past 60; oplog_window_hours below 24 (a member
               away for a day would need a full resync).
      Act      primary 0 (no writes); members_down above 0; lag_seconds_max
               past 600, or near oplog_window_hours (the member will fall off
               the oplog).

    Requires: PowerShell 5.1 or later, and mongosh
    Exit code: 0 on success, server up or down; 1 if mongosh is missing,
      the login is refused, or the user may not run what the job asks

    Example (vigil.config):
      [job.mongodb_replication]
      file        = packs/mongodb/replication.ps1
      metric_name = mongodb.replication
      run_every   = 1m
      env         = MONGODB_URL=mongodb://localhost:27017
      env         = MONGODB_USER=vigil
      secret      = MONGODB_PASSWORD=secret:MONGODB_PASSWORD
#>

$prog = if ($env:MONGOSH) { $env:MONGOSH } else { 'mongosh' }
if (-not (Get-Command $prog -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("replication: $prog not found: the mongodb pack reads MongoDB with mongosh (MONGOSH names another)")
    exit 1
}
& $prog --nodb --quiet --norc --file (Join-Path $PSScriptRoot '_replication.js')
exit $LASTEXITCODE
