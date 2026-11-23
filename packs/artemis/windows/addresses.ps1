#Requires -Version 5.1

<#
.SYNOPSIS
    addresses.ps1 - an Artemis broker's addresses and paging, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports each address (Artemis's own left out): its size in memory and
    against its limit, its messages, whether it is paging and how many pages are
    on disk, the messages routed to its queues and those routed nowhere, its
    queues, and whether it is paused. The 100 largest first. Read-only: it reads
    attributes over JMX, and changes nothing.

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
      jmx_up                     1 when JMX answers, else 0, tagged broker=<its
                                 name> and jmx=<its address>
      size_bytes                 memory its messages hold, tagged address=<the
                                 address>; the largest first
      limit_pct                  of its max-size-bytes, in use, tagged the same
      messages                   messages in its queues, tagged the same
      paging                     1 when it is paging to disk, tagged the same
      pages                      pages on disk, tagged the same
      routed_count               messages routed to its queues, tagged the same
      unrouted_count             messages sent to it and routed nowhere (no
                                 queue), tagged the same
      queues                     its queues, tagged the same
      paused                     1 when it is paused, tagged the same
      duplicate_cache            IDs in its duplicate detection cache, tagged
                                 the same
      size_bytes_not_shown       of size_bytes, those past the first 100, left
                                 out (the largest are shown)
      limit_pct_not_shown        of limit_pct, those past the first 100, left
                                 out (the largest are shown)
      messages_not_shown         of messages, those past the first 100, left out
                                 (the largest are shown)
      paging_not_shown           of paging, those past the first 100, left out
                                 (the largest are shown)
      pages_not_shown            of pages, those past the first 100, left out
                                 (the largest are shown)
      routed_count_not_shown     of routed_count, those past the first 100, left
                                 out (the largest are shown)
      unrouted_count_not_shown   of unrouted_count, those past the first 100,
                                 left out (the largest are shown)
      queues_not_shown           of queues, those past the first 100, left out
                                 (the largest are shown)
      paused_not_shown           of paused, those past the first 100, left out
                                 (the largest are shown)
      duplicate_cache_not_shown
                                 of duplicate_cache, those past the first 100,
                                 left out (the largest are shown)

    Example output (the rest are in the same form):
      metric jmx_up 1 broker=art244 jmx=localhost:19333
      metric size_bytes 1074830 broker=art244 jmx=localhost:19333 address=blocked
      metric limit_pct 102 broker=art244 jmx=localhost:19333 address=blocked
      metric messages 95 broker=art244 jmx=localhost:19333 address=blocked
      metric paging 0 broker=art244 jmx=localhost:19333 address=blocked
      metric pages 0 broker=art244 jmx=localhost:19333 address=blocked
      metric routed_count 95 broker=art244 jmx=localhost:19333 address=blocked
      metric unrouted_count 0 broker=art244 jmx=localhost:19333 address=blocked
      metric queues 1 broker=art244 jmx=localhost:19333 address=blocked
      metric paused 0 broker=art244 jmx=localhost:19333 address=blocked
      metric duplicate_cache 0 broker=art244 jmx=localhost:19333 address=blocked

    Reading the results (starting points: tune them to your brokers):
      Healthy  paging 0; limit_pct well below 100; unrouted_count flat.
      Watch    paging 1: the address holds more than memory allows, on disk now;
               pages growing.
      Act      limit_pct at 100 on an address with BLOCK or FAIL: producers are
               blocked or refused; unrouted_count rising: messages sent where no
               queue reads them are lost.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Artemis's JMX
    Exit code: 0 on success, Artemis up or down (jmx_up says which); 1 if Java
      is missing, _probe.jar does not match its digest, or JMX refuses the login
      or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'artemis_addresses'

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
