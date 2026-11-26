#Requires -Version 5.1

<#
.SYNOPSIS
    requests.ps1 - a Cassandra node's requests as a coordinator, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the requests each node coordinates, by kind (Read, Write,
    RangeSlice, CASRead, CASWrite and the rest): how many, their latency (the
    99th percentile and the mean), and those that timed out, found too few
    replicas up (unavailable), or failed. Read-only: it reads attributes over
    JMX, and changes nothing.

    Reads each Cassandra node's JMX, at CASSANDRA_JMX: jmx=host:port, or
    jmxs=host:port over TLS, separated by ; or , each with a name first if you
    like (db1: jmx=host:7199); with CASSANDRA_JMX_USER and the password in
    CASSANDRA_JMX_PASSWORD when JMX asks for them; a certificate is checked
    against CASSANDRA_CACERT, a PEM file of CAs, or Java's own. With no
    CASSANDRA_JMX, it prints nothing. Cassandra's JVM (heap, garbage collection,
    threads) is the jvm pack's, not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: nothing of Cassandra's is needed here.

    Metrics:
      jmx_up                        1 when JMX answers, else 0, tagged node=<its
                                    name> and jmx=<its address>
      requests_count                requests coordinated (a running total),
                                    tagged scope=<Read, Write, RangeSlice, ...>
                                    (the counts Cassandra keeps per consistency
                                    level, Write-ALL and the like, left out)
      latency_p99_ms                the 99th percentile of their latency, tagged
                                    the same
      latency_mean_ms               their mean latency, tagged the same
      timeouts_count                requests that timed out waiting for replicas
                                    (a running total), tagged the same
      unavailables_count            requests refused at once: too few replicas
                                    up for their consistency level (a running
                                    total), tagged the same
      failures_count                requests a replica failed (a running total),
                                    tagged the same
      requests_count_not_shown      of requests_count, those past the first 100,
                                    left out
      latency_p99_ms_not_shown      of latency_p99_ms, those past the first 100,
                                    left out
      latency_mean_ms_not_shown     of latency_mean_ms, those past the first
                                    100, left out
      timeouts_count_not_shown      of timeouts_count, those past the first 100,
                                    left out
      unavailables_count_not_shown
                                    of unavailables_count, those past the first
                                    100, left out
      failures_count_not_shown      of failures_count, those past the first 100,
                                    left out

    Example output (the rest are in the same form):
      metric jmx_up 1 node=c1 jmx=localhost:17199
      metric requests_count 175 node=c1 jmx=localhost:17199 scope=Read
      metric requests_count 129 node=c1 jmx=localhost:17199 scope=Write
      metric latency_p99_ms 182.785 node=c1 jmx=localhost:17199 scope=Read
      metric latency_p99_ms 2346.799 node=c1 jmx=localhost:17199 scope=Write
      metric timeouts_count 3 node=c1 jmx=localhost:17199 scope=Write

    Reading the results (starting points: tune them to your Cassandra):
      Healthy  latency_p99_ms steady; timeouts_count, unavailables_count and
               failures_count flat.
      Watch    latency_p99_ms rising run after run; timeouts_count rising now
               and then.
      Act      unavailables_count rising: replicas are down for the consistency
               level asked; timeouts_count or failures_count rising fast.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Cassandra's JMX
    Exit code: 0 on success, Cassandra up or down (jmx_up says which); 1 if Java
      is missing, _probe.jar does not match its digest, or JMX refuses the login
      or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'cassandra_requests'

# The probe's SHA-256, written when the pack was released: built from
# _probe.java, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
$probeSha256 = '@PROBE_JAR_SHA256@'

# The probe, beside this script, run by Java 11 or later: JAVA_HOME's, else
# the PATH's.
$java = $null
if ($env:JAVA_HOME -and [System.IO.File]::Exists((Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
    $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
}
else {
    $c = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($c) { $java = $c.Source }
}
if (-not $java) {
    [Console]::Error.WriteLine("${job}: java not found: the cassandra pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install cassandra), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify cassandra says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-cassandra.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches). The probe reads
    # this job's table.
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx128m "-Djava.io.tmpdir=$work" `
        -cp $probe Probe (Join-Path $PSScriptRoot '_probe.tables') $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
