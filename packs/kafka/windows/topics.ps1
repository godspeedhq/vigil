#Requires -Version 5.1

<#
.SYNOPSIS
    topics.ps1 - Kafka topics and their messages, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports the topics: how many, internal, with a single replica, compacted;
    and each topic's partitions, replication factor, every message ever written
    to it (a running total, from the end of each partition), and the messages it
    still holds (from its start). Read-only: it changes nothing in the cluster.

    Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) through Kafka's
    admin API, as KAFKA_USER with the password in KAFKA_PASSWORD, set by the
    job: never on a command line, never in a file. KAFKA_SECURITY is PLAINTEXT,
    SSL, SASL_PLAINTEXT or SASL_SSL; KAFKA_SASL_MECHANISM SCRAM-SHA-512,
    SCRAM-SHA-256 or PLAIN. With TLS, the brokers' certificates are checked
    against KAFKA_CACERT, a PEM file of CAs, or Java's own, and against their
    names; KAFKA_CERT and KAFKA_KEY give a client certificate.
    KAFKA_CLIENT_CONFIG, a client properties file of your own, comes first, for
    a login this pack does not build (Kerberos, OAuth).

    Kafka's library is not in the pack: KAFKA_HOME, a Kafka download (its
    libs/), or KAFKA_LIBS, a folder of its jars, any kafka-clients from 3.x or
    4.x.

    Metrics:
      topics              topics
      internal_topics     Kafka's own topics (their names start with __)
      rf1_topics          topics of your own with a single replica: a broker
                          lost is data lost
      compacted_topics    topics compacted (cleanup.policy compact)
      partitions          a topic's partitions, tagged topic=<name> (at most 100
                          topics)
      replication_factor  its replication factor, tagged the same
      messages_count      messages ever written to it, a running total, tagged
                          the same
      retained_messages   messages it still holds, tagged the same
      topics_not_shown    topics past the first 100, left out

    Example output (the rest are in the same form):
      metric topics 7
      metric rf1_topics 1
      metric partitions 6 topic=orders
      metric replication_factor 3 topic=orders
      metric messages_count 21393 topic=orders

    Reading the results (starting points: tune them to the cluster):
      Healthy  rf1_topics 0, unless on purpose; messages_count rising on every
               topic you write to.
      Watch    messages_count flat on a topic that should be written to: its
               producers stopped.
      Act      rf1_topics above 0 for data you cannot lose.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _client.jar and
      _probe.jar, beside this script, once they match their digests; Kafka's
      library (KAFKA_HOME or KAFKA_LIBS); a user with the ACLs packs/README.md
      lists
    Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
      Kafka's library is missing, _client.jar does not match its digest, or the
      cluster refuses the login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_topics'

# The jars' SHA-256s, written when the pack was released: each built from
# its source, beside it, by javac @PROBE_JAR_JAVAC@ (tools/release/client-jar.sh).
$probeSha256 = '@PROBE_JAR_SHA256@'
$clientSha256 = '@CLIENT_JAR_SHA256@'
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
$client = Join-Path $PSScriptRoot '_client.jar'
Test-Jar $client $clientSha256

# Kafka's library, the user's: KAFKA_LIBS, else a Kafka download's libs\.
$libs = $env:KAFKA_LIBS
if (-not $libs -and $env:KAFKA_HOME) { $libs = Join-Path $env:KAFKA_HOME 'libs' }
if (-not $libs) {
    [Console]::Error.WriteLine("${job}: no Kafka library: set KAFKA_HOME to a Kafka download, or KAFKA_LIBS to a folder of its jars")
    exit 1
}
if (-not [System.IO.Directory]::Exists($libs) -or @([System.IO.Directory]::GetFiles($libs, 'kafka-clients-*.jar')).Count -eq 0) {
    [Console]::Error.WriteLine("${job}: no kafka-clients-*.jar in ${libs}: KAFKA_HOME is a Kafka download (its libs\), KAFKA_LIBS a folder of its jars")
    exit 1
}
$run = @('-cp', ($client + ';' + $probe + ';' + (Join-Path $libs '*')), 'KafkaClient')

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
