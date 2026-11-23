#Requires -Version 5.1

<#
.SYNOPSIS
    broker.ps1 - an Artemis broker's memory, disk and totals, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the broker's address memory against global-max-size (past it,
    addresses page, block or drop, as each says), its disk use against
    max-disk-usage (past it, it blocks producers), its connections, sessions and
    consumers now and since it started, its messages and totals, its addresses
    and queues, and the logins and authorizations it has refused. Read-only: it
    reads attributes over JMX, and changes nothing.

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
      address_memory_bytes          memory the addresses hold
      address_memory_pct            of global-max-size, in use
      global_max_bytes              global-max-size
      disk_pct                      of the disk the journal is on, in use
      disk_max_pct                  max-disk-usage: past it, producers are
                                    blocked
      connections                   client connections now
      connections_count             client connections since it started
      sessions                      sessions now
      sessions_count                sessions since it started
      consumers                     consumers now
      messages                      messages waiting, every queue
      added_count                   messages added to queues
      acknowledged_count            messages acknowledged
      addresses                     addresses
      queues                        queues
      login_failed_count            logins refused
      login_count                   logins
      authorization_failed_count    actions refused for a role
      mirror_pending                acknowledgements a mirror owes (AMQP
                                    mirroring)
      address_memory_bytes_not_shown
                                    of address_memory_bytes, those past the
                                    first 100, left out
      address_memory_pct_not_shown
                                    of address_memory_pct, those past the first
                                    100, left out
      global_max_bytes_not_shown    of global_max_bytes, those past the first
                                    100, left out
      disk_pct_not_shown            of disk_pct, those past the first 100, left
                                    out
      disk_max_pct_not_shown        of disk_max_pct, those past the first 100,
                                    left out
      connections_not_shown         of connections, those past the first 100,
                                    left out
      connections_count_not_shown   of connections_count, those past the first
                                    100, left out
      sessions_not_shown            of sessions, those past the first 100, left
                                    out
      sessions_count_not_shown      of sessions_count, those past the first 100,
                                    left out
      consumers_not_shown           of consumers, those past the first 100, left
                                    out
      messages_not_shown            of messages, those past the first 100, left
                                    out
      added_count_not_shown         of added_count, those past the first 100,
                                    left out
      acknowledged_count_not_shown
                                    of acknowledged_count, those past the first
                                    100, left out
      addresses_not_shown           of addresses, those past the first 100, left
                                    out
      queues_not_shown              of queues, those past the first 100, left
                                    out
      login_failed_count_not_shown
                                    of login_failed_count, those past the first
                                    100, left out
      login_count_not_shown         of login_count, those past the first 100,
                                    left out
      authorization_failed_count_not_shown
                                    of authorization_failed_count, those past
                                    the first 100, left out
      mirror_pending_not_shown      of mirror_pending, those past the first 100,
                                    left out

    Example output (the rest are in the same form):
      (draft: no example yet)

    Reading the results (starting points: tune them to your brokers):
      Healthy  address_memory_pct and disk_pct well below their limits;
               login_failed_count flat.
      Watch    address_memory_pct above 70: addresses near paging; disk_pct
               nearing disk_max_pct.
      Act      disk_pct at disk_max_pct: producers are blocked;
               address_memory_pct at 100: addresses page to disk, block or drop
               (artemis_addresses says which are paging); login_failed_count
               rising: a client with a wrong password, or someone guessing.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _probe.jar,
      beside this script, once it matches its digest; Artemis's JMX
    Exit code: 0 on success, Artemis up or down (jmx_up says which); 1 if Java
      is missing, _probe.jar does not match its digest, or JMX refuses the login
      or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'artemis_broker'

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
