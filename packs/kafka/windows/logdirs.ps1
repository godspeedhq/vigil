#Requires -Version 5.1

<#
.SYNOPSIS
    logdirs.ps1 - Kafka's data on disk, on Windows
.NOTES
    Copyright (c) Bankole Ogundero and the Vigil contributors
    SPDX-License-Identifier: Apache-2.0

    Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
    implied. Run it at your own risk: review it first, and test it before you
    rely on it. In no event shall the authors or copyright holders be liable
    for any claim, damages or other liability arising from its use. See the
    LICENSE file for the full terms.
.DESCRIPTION
    Reports every broker's log directories: their size, partitions, errors (an
    offline directory) and replicas being moved between directories; each
    broker's and each topic's size, every replica counted. With KAFKA_JMX, from
    each broker: what it has copied to remote storage (tiered storage) and still
    has to, how long a flush to disk takes, and the log cleaner (compaction).
    Read-only: it changes nothing in the cluster.

    Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) through Kafka's
    admin API, as KAFKA_USER with the password in KAFKA_PASSWORD, set by the
    job: never on a command line, never in a file. KAFKA_SECURITY is PLAINTEXT,
    SSL, SASL_PLAINTEXT or SASL_SSL; KAFKA_SASL_MECHANISM SCRAM-SHA-512,
    SCRAM-SHA-256 or PLAIN. With TLS, the brokers' certificates are checked
    against KAFKA_CACERT, a PEM file of CAs, or Java's own, and against their
    names; KAFKA_CERT and KAFKA_KEY give a client certificate.
    KAFKA_CLIENT_CONFIG, a client properties file of your own, comes first, for
    a login this pack does not build (Kerberos, OAuth).

    Reads each broker's JMX, at KAFKA_JMX: jmx=host:port, or jmxs=host:port over
    TLS, separated by ; or , one per broker, with KAFKA_JMX_USER and the
    password in KAFKA_JMX_PASSWORD when JMX asks for them; a certificate is
    checked against KAFKA_CACERT, or Java's own CAs, and against the broker's
    name. Each broker is named by its id. With no KAFKA_JMX, it prints nothing
    of the brokers' own. The broker's JVM (heap, garbage collection, threads,
    CPU, open files) is the jvm pack's, not this one's.

    Kafka's library is not in the pack: KAFKA_HOME, a Kafka download (its
    libs/), or KAFKA_LIBS, a folder of its jars, any kafka-clients from 3.x or
    4.x.

    Metrics:
      size_bytes                 a directory's size, tagged broker=<id> and
                                 dir=<its path>
      partitions                 its partitions, tagged the same
      offline                    1 when the broker reports an error for it,
                                 tagged the same
      future_replicas            replicas being moved into it, tagged the same
      dirs                       directories
      dirs_offline               of those, offline
      broker_size_bytes          a broker's data, tagged broker=<id>
      topic_size_bytes           a topic's data, every replica counted, tagged
                                 topic=<name> (at most 100)
      topics_not_shown           topics past the first 100, left out
      jmx_up                     with KAFKA_JMX: 1 when a broker's JMX answers,
                                 tagged broker=<id, or its JMX host:port>
      remote_size_bytes          a broker's data in remote storage (tiered
                                 storage), tagged broker=<id>
      remote_copy_lag_bytes      data it has yet to copy there, tagged the same
      flush_ms_p99               the time a log flush takes, in ms, 99th
                                 percentile, tagged broker=<id>
      flushes_count              log flushes, a running total, tagged the same
      cleaner_max_dirty_pct      the most of a compacted log not yet compacted,
                                 as a percent, tagged the same
      cleaner_idle_seconds       since the log cleaner last ran, tagged the
                                 same; left out before it first has
      cleaner_dead_threads       log cleaner threads that died, tagged the same
      cleaner_max_clean_seconds  the longest a clean took, tagged the same; left
                                 out before the first

    Example output (the rest are in the same form):
      metric size_bytes 4967681 broker=1 dir=/var/lib/kafka/data
      metric partitions 163 broker=1 dir=/var/lib/kafka/data
      metric offline 0 broker=1 dir=/var/lib/kafka/data
      metric future_replicas 0 broker=1 dir=/var/lib/kafka/data
      metric size_bytes 4907633 broker=2 dir=/var/lib/kafka/data

    Reading the results (starting points: tune them to the cluster):
      Healthy  dirs_offline 0; sizes growing and shrinking with retention;
               cleaner_dead_threads 0.
      Watch    a broker's broker_size_bytes far above the others': partitions
               are unbalanced; remote_copy_lag_bytes growing; flush_ms_p99
               rising: the disk is slow.
      Act      offline 1: a disk failed, and its partitions moved away or went
               offline; cleaner_dead_threads above 0: compacted topics grow
               without bound.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Java 11 or later
      (JAVA_HOME, or java on the PATH), a JDK or a JRE, to run _client.jar,
      beside this script, once it matches its digest (a copy of the pack without
      the jar runs _client.java, which needs a JDK); Kafka's library (KAFKA_HOME
      or KAFKA_LIBS); a user with the ACLs packs/README.md lists
    Exit code: 0 on success, or when the cluster does not answer; 1 if Java or
      Kafka's library is missing, _client.jar does not match its digest, or the
      cluster refuses the login or its certificate
#>

$ErrorActionPreference = 'Stop'
$job = 'kafka_logdirs'

# _client.jar's SHA-256, written when the pack was released: built from
# _client.java, beside it, by javac @CLIENT_JAR_JAVAC@ (tools/release/client-jar.sh).
$jarSha256 = '@CLIENT_JAR_SHA256@'

# The client, beside this script, run by Java 11 or later: JAVA_HOME's, else
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
    [Console]::Error.WriteLine("${job}: java not found: the kafka pack runs its client with Java 11 or later (a JDK or a JRE), on the PATH or in JAVA_HOME")
    exit 1
}

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

# The jar, the client compiled, once it matches the digest above: any Java
# 11 or later runs it. A copy of the pack without one (from the repository,
# not a release) runs the source, which needs a JDK.
$jar = Join-Path $PSScriptRoot '_client.jar'
if (-not [System.IO.File]::Exists($jar)) {
    $client = @('-cp', (Join-Path $libs '*'), (Join-Path $PSScriptRoot '_client.java'))
}
else {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $f = [System.IO.File]::OpenRead($jar)
    try { $sum = -join ($sha.ComputeHash($f) | ForEach-Object { $_.ToString('x2') }) }
    finally { $f.Dispose(); $sha.Dispose() }
    if ($sum -ne $jarSha256) {
        [Console]::Error.WriteLine("${job}: _client.jar does not match the digest in this script, so it is not run: it was changed or damaged. vigil pack verify kafka says what differs")
        exit 1
    }
    $client = @('-cp', ($jar + ';' + (Join-Path $libs '*')), 'KafkaClient')
}

# A folder of this run's own, for what Java writes while it runs: gone when
# the run ends.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-kafka.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$code = 1
try {
    # A small JVM, quick to start, that keeps no counters of its own (the
    # jvm pack would find it among the JVMs it watches).
    & $java -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -XX:-UsePerfData -Xshare:auto -Xmx256m "-Djava.io.tmpdir=$work" @client $job
    $code = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
