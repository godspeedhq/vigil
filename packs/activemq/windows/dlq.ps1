#Requires -Version 5.1

<#
.SYNOPSIS
    dlq.ps1 - an ActiveMQ broker's dead letter queues, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each dead letter queue (a queue whose name has DLQ in it:
    ActiveMQ.DLQ, or a DLQ of each destination): messages in it and sent to it.
    A message lands there when it expires or fails delivery too many times.
    Read-only: it reads attributes over JMX, and changes nothing.

    Reads each ActiveMQ Classic broker's JMX, at ACTIVEMQ_JMX: jmx=host:port, or
    jmxs=host:port over TLS, separated by ; or , each with a name first if you
    like (amq1: jmxs=host:port); with ACTIVEMQ_JMX_USER and the password in
    ACTIVEMQ_JMX_PASSWORD when JMX asks for them; a certificate is checked
    against ACTIVEMQ_CACERT, a PEM file of CAs, or Java's own, and against the
    server's name. With no ACTIVEMQ_JMX, it prints nothing. ActiveMQ Artemis is
    the artemis pack's; the broker's JVM (heap, garbage collection, threads,
    CPU, open files) is the jvm pack's, not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: nothing of ActiveMQ's is needed here.

    Metrics:
      jmx_up                    1 when JMX answers, else 0, tagged broker=<its
                                name> and jmx=<its address>
      size                      messages in it, tagged destinationName=<the
                                queue>; the most first
      enqueued_count            messages sent to it, tagged the same
      size_not_shown            of size, those past the first 100, left out (the
                                largest are shown)
      enqueued_count_not_shown
                                of enqueued_count, those past the first 100,
                                left out (the largest are shown)

    Example output (the rest are in the same form):
      metric jmx_up 1 broker=a62 jmx=localhost:19323
      metric size 50 broker=a62 jmx=localhost:19323 destinationName=ActiveMQ.DLQ
      metric enqueued_count 50 broker=a62 jmx=localhost:19323 destinationName=ActiveMQ.DLQ

    Reading the results (starting points: tune them to your brokers):
      Healthy  size 0, or flat.
      Watch    enqueued_count rising: messages are expiring or failing delivery.
      Act      size growing: messages nobody handled are piling up (and taking
               store); read or purge them once the cause is fixed.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; ActiveMQ's JMX
    Exit code: 0 on success, ActiveMQ up or down (jmx_up says which); 1 if Java
      is missing, _probe.jar does not match its digest, or JMX refuses the login
      or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'activemq_dlq'

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
    [Console]::Error.WriteLine("${job}: java not found: the activemq pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install activemq), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify activemq says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-activemq.' + [guid]::NewGuid().ToString('N'))
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
