#Requires -Version 5.1

<#
.SYNOPSIS
    controller.ps1 - the Kafka controller's view, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports which node is the active controller, and from it the cluster as it
    sees it: brokers active and fenced, topics and partitions, offline
    partitions, leaders not where they prefer, metadata errors and lag,
    heartbeats that timed out, leader elections (unclean ones too), and its
    event queue. The other nodes report active_controller 0 and nothing else.
    Read-only: it changes nothing in the cluster.

    Reads each broker's JMX, at KAFKA_JMX: jmx=host:port, or jmxs=host:port over
    TLS, separated by ; or , one per broker, with KAFKA_JMX_USER and the
    password in KAFKA_JMX_PASSWORD when JMX asks for them; a certificate is
    checked against KAFKA_CACERT, or Java's own CAs, and against the broker's
    name. Each broker is named by its id. With no KAFKA_JMX, it prints nothing
    of the brokers' own. The broker's JVM (heap, garbage collection, threads,
    CPU, open files) is the jvm pack's, not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: no Kafka library is needed.

    Metrics:
      jmx_up                           1 when a node's JMX answers, tagged
                                       broker=<id, or its JMX host:port>
      active_controller                1 on the active controller, else 0,
                                       tagged broker=<id>
      brokers                          brokers active, tagged the same
      fenced_brokers                   brokers fenced, tagged the same
      topics                           topics, tagged the same
      partitions                       partitions, tagged the same
      offline_partitions               partitions with no leader, tagged the
                                       same
      preferred_imbalance              partitions not led by their preferred
                                       leader, tagged the same
      metadata_errors                  errors applying metadata, tagged the same
      metadata_lag_ms                  how far behind its metadata is, in ms,
                                       tagged the same
      timed_out_heartbeats             broker heartbeats that timed out, tagged
                                       the same
      controller_changes               times a new controller became active,
                                       tagged the same
      elections_count                  leader elections, a running total, tagged
                                       the same
      unclean_elections_count          unclean leader elections (data lost), a
                                       running total, tagged the same
      eligible_leader_elections_count  leaders elected from eligible leader
                                       replicas (Kafka 4), a running total,
                                       tagged the same
      event_queue                      events waiting in the controller's queue,
                                       tagged the same
      event_queue_ms_p99               the time an event waits there, in ms,
                                       tagged the same

    Example output (the rest are in the same form):
      metric jmx_up 1 broker=1 jmx=127.0.0.1:19991
      metric active_controller 0 broker=1 jmx=127.0.0.1:19991
      metric jmx_up 1 broker=2 jmx=127.0.0.1:19992
      metric active_controller 0 broker=2 jmx=127.0.0.1:19992
      metric jmx_up 1 broker=3 jmx=127.0.0.1:19993
      metric active_controller 1 broker=3 jmx=127.0.0.1:19993
      metric brokers 3 broker=3 jmx=127.0.0.1:19993
      metric fenced_brokers 0 broker=3 jmx=127.0.0.1:19993

    Reading the results (starting points: tune them to the cluster):
      Healthy  one node with active_controller 1; offline_partitions 0;
               metadata_errors 0.
      Watch    elections_count rising fast: leaders keep changing;
               timed_out_heartbeats rising.
      Act      no node with active_controller 1; offline_partitions above 0;
               unclean_elections_count rising: data was lost.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; the brokers' JMX
    Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
      Kafka's library is missing, _client.jar does not match its digest, or the
      cluster refuses the login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_controller'

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
$probeSha256 = '@PROBE_JAR_SHA256@'
# The jars, beside this script, run by Java 11 or later: JAVA_HOME's, else
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
    [Console]::Error.WriteLine("${job}: java not found: the kafka pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# A jar is run only once it matches its digest.
function Test-Jar {
    param([string]$Jar, [string]$Want)
    $n = [System.IO.Path]::GetFileName($Jar)
    if (-not [System.IO.File]::Exists($Jar)) {
        [Console]::Error.WriteLine("${job}: ${n} not found: this copy of the pack has none: install the pack from a packs release (vigil pack install kafka), or build it (tools/release/client-jar.sh)")
        exit 1
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $f = [System.IO.File]::OpenRead($Jar)
    try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
    finally { $f.Dispose(); $sha.Dispose() }
    if ($sum -ne $Want) {
        [Console]::Error.WriteLine("${job}: $n does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs")
        exit 1
    }
}
$probe = Join-Path $PSScriptRoot '_probe.jar'
Test-Jar $probe $probeSha256

# The probe reads this job's table: the brokers' JMX only, no Kafka library.
$run = @('-cp', $probe, 'Probe', (Join-Path $PSScriptRoot '_probe.tables'))

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-kafka.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m "-Djava.io.tmpdir=$work" @run $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
