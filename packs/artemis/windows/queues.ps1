#Requires -Version 5.1

<#
.SYNOPSIS
    queues.ps1 - an Artemis broker's queues, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each queue (Artemis's own left out): messages waiting and the age of
    the oldest, those being delivered and scheduled, added, acknowledged,
    expired and killed (sent to the dead letter address), its consumers, its
    size on disk, groups and prepared transactions, and whether it is paused.
    The deepest 100 queues first. Read-only: it reads attributes over JMX, and
    changes nothing.

    Reads each ActiveMQ Artemis broker's JMX, at ARTEMIS_JMX: jmx=host:port, or
    jmxs=host:port over TLS, separated by ; or , each with a name first if you
    like (art1: jmxs=host:port); with ARTEMIS_JMX_USER and the password in
    ARTEMIS_JMX_PASSWORD when JMX asks for them; a certificate is checked
    against ARTEMIS_CACERT, a PEM file of CAs, or Java's own, and against the
    server's name. With no ARTEMIS_JMX, it prints nothing. ActiveMQ Classic is
    the activemq pack's; the broker's JVM (heap, garbage collection, threads,
    CPU, open files) is the jvm pack's, not this one's.

    The probe (_probe.jar, tools/probe) reads it, from this pack's
    _probe.tables, beside this script: nothing of Artemis's is needed here.

    Metrics:
      jmx_up                        1 when JMX answers, else 0, tagged
                                    broker=<its name> and jmx=<its address>
      messages                      messages waiting, tagged address=<its
                                    address> and queue=<the queue>; the deepest
                                    first
      oldest_seconds                the age of its oldest message, tagged the
                                    same
      delivering                    messages being delivered, not yet
                                    acknowledged, tagged the same
      scheduled                     messages scheduled for later, tagged the
                                    same
      added_count                   messages added, tagged the same
      acknowledged_count            messages acknowledged, tagged the same
      expired_count                 messages that expired, tagged the same
      killed_count                  messages sent to the dead letter address
                                    (too many deliveries), tagged the same
      consumers                     consumers, tagged the same
      persistent_bytes              the size of its messages, tagged the same
      groups                        message groups, tagged the same
      prepared                      messages in prepared (XA) transactions,
                                    tagged the same
      paused                        1 when it is paused, tagged the same
      enabled                       1 when it is enabled (receives messages),
                                    tagged the same
      durable_messages              of its messages, those that are durable,
                                    tagged the same
      delivering_bytes              the size of the messages being delivered,
                                    tagged the same
      scheduled_bytes               the size of the messages scheduled, tagged
                                    the same
      acknowledge_attempts_count    acknowledgements tried, tagged the same
      max_consumers                 the most consumers it allows, when it has a
                                    limit, tagged the same
      messages_not_shown            of messages, those past the first 100, left
                                    out (the largest are shown)
      oldest_seconds_not_shown      of oldest_seconds, those past the first 100,
                                    left out (the largest are shown)
      delivering_not_shown          of delivering, those past the first 100,
                                    left out (the largest are shown)
      scheduled_not_shown           of scheduled, those past the first 100, left
                                    out (the largest are shown)
      added_count_not_shown         of added_count, those past the first 100,
                                    left out (the largest are shown)
      acknowledged_count_not_shown
                                    of acknowledged_count, those past the first
                                    100, left out (the largest are shown)
      expired_count_not_shown       of expired_count, those past the first 100,
                                    left out (the largest are shown)
      killed_count_not_shown        of killed_count, those past the first 100,
                                    left out (the largest are shown)
      consumers_not_shown           of consumers, those past the first 100, left
                                    out (the largest are shown)
      persistent_bytes_not_shown    of persistent_bytes, those past the first
                                    100, left out (the largest are shown)
      groups_not_shown              of groups, those past the first 100, left
                                    out (the largest are shown)
      prepared_not_shown            of prepared, those past the first 100, left
                                    out (the largest are shown)
      paused_not_shown              of paused, those past the first 100, left
                                    out (the largest are shown)
      enabled_not_shown             of enabled, those past the first 100, left
                                    out (the largest are shown)
      durable_messages_not_shown    of durable_messages, those past the first
                                    100, left out (the largest are shown)
      delivering_bytes_not_shown    of delivering_bytes, those past the first
                                    100, left out (the largest are shown)
      scheduled_bytes_not_shown     of scheduled_bytes, those past the first
                                    100, left out (the largest are shown)
      acknowledge_attempts_count_not_shown
                                    of acknowledge_attempts_count, those past
                                    the first 100, left out (the largest are
                                    shown)
      max_consumers_not_shown       of max_consumers, those past the first 100,
                                    left out (the largest are shown)

    Example output (the rest are in the same form):
      metric jmx_up 1 broker=art244 jmx=localhost:19333
      metric messages 2999 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric oldest_seconds 116.385 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric delivering 434 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric scheduled 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric added_count 3000 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric acknowledged_count 1 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric expired_count 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric killed_count 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric consumers 1 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric persistent_bytes 7164611 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric groups 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric prepared 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric paused 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric enabled 1 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric durable_messages 2999 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric delivering_bytes 1036826 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric scheduled_bytes 0 broker=art244 jmx=localhost:19333 address=orders queue=orders
      metric acknowledge_attempts_count 1 broker=art244 jmx=localhost:19333 address=orders queue=orders

    Reading the results (starting points: tune them to your brokers):
      Healthy  messages rising and falling; oldest_seconds small; consumers
               above 0 on every queue that should be read.
      Watch    oldest_seconds growing: consumers are falling behind;
               killed_count rising.
      Act      messages growing with consumers 0: nothing reads it;
               oldest_seconds in hours; prepared above 0 for long: an XA
               transaction left in doubt.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Artemis's JMX
    Exit code: 0 on success, Artemis up or down (jmx_up says which); 1 if Java
      is missing, _probe.jar does not match its digest, or JMX refuses the login
      or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'artemis_queues'

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
    [Console]::Error.WriteLine("${job}: java not found: the artemis pack runs with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

# The jar is run only once it matches its digest.
$probe = Join-Path $PSScriptRoot '_probe.jar'
if (-not [System.IO.File]::Exists($probe)) {
    [Console]::Error.WriteLine("${job}: _probe.jar not found: this copy of the pack has none: install the pack from a packs release (vigil pack install artemis), or build it (tools/release/client-jar.sh)")
    exit 1
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$f = [System.IO.File]::OpenRead($probe)
try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
finally { $f.Dispose(); $sha.Dispose() }
if ($sum -ne $probeSha256) {
    [Console]::Error.WriteLine("${job}: _probe.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify artemis says what differs")
    exit 1
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-artemis.' + [guid]::NewGuid().ToString('N'))
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
