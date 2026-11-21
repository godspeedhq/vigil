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
    broker's and each topic's size, every replica counted; and, with tiered
    storage and KAFKA_JMX, what each broker has copied to remote storage and
    still has to. Read-only: it changes nothing in the cluster.

    Connects to KAFKA_BOOTSTRAP (host:port, comma-separated) with Kafka's own
    command-line tools, as KAFKA_USER with the password in KAFKA_PASSWORD, set
    by the job; never on a command line: it goes in a client configuration of
    the run's own, in a folder only this account can read, deleted at the end.
    KAFKA_SECURITY is PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL;
    KAFKA_SASL_MECHANISM SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN. With TLS, the
    brokers' certificates are checked against KAFKA_CACERT, a PEM file of CAs,
    or Java's own, and against their names; KAFKA_CERT and KAFKA_KEY give a
    client certificate. KAFKA_CLIENT_CONFIG, a client properties file of your
    own, replaces all of these, for a login this pack does not build (Kerberos,
    OAuth). KAFKA_HOME is where Kafka is unpacked, when its tools are not on the
    PATH.

    Reads each broker's JMX, at KAFKA_JMX: host:port, comma-separated, one per
    broker, through Kafka's own JmxTool (KAFKA_HOME, when its tools are not on
    the PATH). JMX without a password, as Kafka's start scripts set it up with
    JMX_PORT: JmxTool takes a password only on its command line, where this pack
    never puts one. Each broker is named by its id. With no KAFKA_JMX, it prints
    nothing.

    Metrics:
      size_bytes             a directory's size, tagged broker=<id> and dir=<its
                             path>
      partitions             its partitions, tagged the same
      offline                1 when the broker reports an error for it, tagged
                             the same
      future_replicas        replicas being moved into it, tagged the same
      dirs                   directories
      dirs_offline           of those, offline
      broker_size_bytes      a broker's data, tagged broker=<id>
      topic_size_bytes       a topic's data, every replica counted, tagged
                             topic=<name> (at most 100)
      topics_not_shown       topics past the first 100, left out
      jmx_up                 with KAFKA_JMX: 1 when a broker's JMX answers,
                             tagged broker=<id, or its JMX host:port>
      remote_size_bytes      a broker's data in remote storage (tiered storage),
                             tagged broker=<id>
      remote_copy_lag_bytes  data it has yet to copy there, tagged the same

    Example output (the rest are in the same form):
      metric size_bytes 4967681 broker=1 dir=/var/lib/kafka/data
      metric partitions 163 broker=1 dir=/var/lib/kafka/data
      metric offline 0 broker=1 dir=/var/lib/kafka/data
      metric future_replicas 0 broker=1 dir=/var/lib/kafka/data
      metric size_bytes 4907633 broker=2 dir=/var/lib/kafka/data

    Reading the results (starting points: tune them to the cluster):
      Healthy  dirs_offline 0; sizes growing and shrinking with retention.
      Watch    a broker's broker_size_bytes far above the others': partitions
               are unbalanced; remote_copy_lag_bytes growing.
      Act      offline 1: a disk failed, and its partitions moved away or went
               offline.

    Requires: Windows PowerShell 5.1 or PowerShell 7, Kafka's command-line tools
      (any from 3.9, the Kafka download), Java 17 or later, and a user with the
      ACLs packs/README.md lists
    Exit code: 0 on success, or when the cluster does not answer; 1 if the tools
      are missing, or the cluster refuses the login, its certificate or a
      request
#>

$ErrorActionPreference = 'Continue'
$job = 'logdirs'

# Fails the run: says why on stderr, exits 1.
function Stop-Run([string]$Why) {
    [Console]::Error.WriteLine("${job}: $Why")
    exit 1
}

# Kafka's own command-line tools: under KAFKA_HOME\bin\windows, else on the
# PATH, else where Kafka is often unpacked. $null when not found.
function Find-Tool([string]$Name) {
    foreach ($d in @($(if ($env:KAFKA_HOME) { Join-Path $env:KAFKA_HOME 'bin\windows' }), 'C:\kafka\bin\windows', 'C:\Program Files\kafka\bin\windows')) {
        if ($d -and [System.IO.File]::Exists((Join-Path $d "$Name.bat"))) { return (Join-Path $d "$Name.bat") }
    }
    $c = Get-Command "$Name.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
function Get-Tool([string]$Name) {
    $t = Find-Tool $Name
    if (-not $t) { Stop-Run "$Name.bat not found: install Kafka's command-line tools (the Kafka download), and set KAFKA_HOME to the folder that holds bin\" }
    return $t
}
if (-not $env:JAVA_HOME -and -not (Get-Command java.exe -ErrorAction SilentlyContinue)) {
    Stop-Run "java not found: Kafka's tools need Java 17 or later, on the PATH or in JAVA_HOME"
}

# A folder of this run's own, in this account's temporary folder (which only
# it, SYSTEM and administrators can read), for the client configuration
# (which holds the password) and the tools' output. Deleted at the end.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vigil-kafka.' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
$cfg = Join-Path $work 'client.properties'
$bootstrap = if ($env:KAFKA_BOOTSTRAP) { $env:KAFKA_BOOTSTRAP } else { 'localhost:9092' }
$security = if ($env:KAFKA_SECURITY) { $env:KAFKA_SECURITY } else { 'PLAINTEXT' }
# Paths in a properties file: forward slashes, which Java reads, and no
# backslash escapes to get wrong.
function ConvertTo-PropPath([string]$Path) { return $Path.Replace('\', '/') }

try {
    # The client configuration: KAFKA_CLIENT_CONFIG, a file of your own (for
    # a login this pack does not build, such as Kerberos or OAuth), or one
    # built from KAFKA_SECURITY and the settings beside it. Either way with
    # timeouts, so an unreachable cluster is told apart from one that refuses.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($env:KAFKA_CLIENT_CONFIG) {
        if (-not [System.IO.File]::Exists($env:KAFKA_CLIENT_CONFIG)) { Stop-Run "cannot read KAFKA_CLIENT_CONFIG $($env:KAFKA_CLIENT_CONFIG)" }
        foreach ($l in [System.IO.File]::ReadAllLines($env:KAFKA_CLIENT_CONFIG)) { $lines.Add($l) }
    }
    else {
        if ($security -cnotmatch '^(PLAINTEXT|SSL|SASL_PLAINTEXT|SASL_SSL)$') { Stop-Run "KAFKA_SECURITY is '$security': set it to PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL" }
        $lines.Add("security.protocol=$security")
        if ($security.StartsWith('SASL_')) {
            $mech = if ($env:KAFKA_SASL_MECHANISM) { $env:KAFKA_SASL_MECHANISM } else { 'SCRAM-SHA-512' }
            $module = switch -CaseSensitive ($mech) {
                'PLAIN' { 'org.apache.kafka.common.security.plain.PlainLoginModule' }
                'SCRAM-SHA-256' { 'org.apache.kafka.common.security.scram.ScramLoginModule' }
                'SCRAM-SHA-512' { 'org.apache.kafka.common.security.scram.ScramLoginModule' }
                default { Stop-Run "KAFKA_SASL_MECHANISM is '$mech': set it to SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN (or give KAFKA_CLIENT_CONFIG)" }
            }
            if (-not $env:KAFKA_PASSWORD) { Stop-Run "no password: KAFKA_SECURITY is $security, and KAFKA_PASSWORD is empty (vigil secret set KAFKA_MONITOR_PASSWORD)" }
            # In the JAAS line, a quote or a backslash is escaped.
            $u = $(if ($env:KAFKA_USER) { $env:KAFKA_USER } else { 'vigil_monitor' }).Replace('\', '\\').Replace('"', '\"')
            $p = $env:KAFKA_PASSWORD.Replace('\', '\\').Replace('"', '\"')
            $lines.Add("sasl.mechanism=$mech")
            $lines.Add("sasl.jaas.config=$module required username=`"$u`" password=`"$p`";")
        }
        if ($security -ceq 'SSL' -or $security -ceq 'SASL_SSL') {
            if ($env:KAFKA_CACERT) {
                $lines.Add('ssl.truststore.type=PEM')
                $lines.Add("ssl.truststore.location=$(ConvertTo-PropPath $env:KAFKA_CACERT)")
            }
            if ($env:KAFKA_CERT) {
                # A client certificate: its key and the certificate, in one PEM
                # file of this run's own, as Kafka reads them.
                $pem = Join-Path $work 'client.pem'
                [System.IO.File]::WriteAllText($pem, [System.IO.File]::ReadAllText($env:KAFKA_KEY) + "`n" + [System.IO.File]::ReadAllText($env:KAFKA_CERT))
                $lines.Add('ssl.keystore.type=PEM')
                $lines.Add("ssl.keystore.location=$(ConvertTo-PropPath $pem)")
            }
        }
    }
    $lines.Add('request.timeout.ms=10000')
    $lines.Add('default.api.timeout.ms=15000')
    $lines.Add('socket.connection.setup.timeout.max.ms=10000')
    [System.IO.File]::WriteAllLines($cfg, $lines)
    # An argument as the C runtime, and Java's launcher, read a command line:
    # always quoted (Java's launcher would expand a * in one that is not), a
    # quote escaped, and the backslashes before a quote doubled.
    function ConvertTo-Arg([string]$Arg) {
        $s = '"'; $bs = 0
        foreach ($ch in $Arg.ToCharArray()) {
            if ($ch -eq [char]'\') { $bs++; continue }
            if ($ch -eq [char]'"') { $s += ('\' * (2 * $bs + 1)) + '"' } else { $s += ('\' * $bs) + $ch }
            $bs = 0
        }
        return $s + ('\' * (2 * $bs)) + '"'
    }

    # Runs one of Kafka's tools: its .bat names the Java class it runs, and
    # Java runs it here, with Kafka's libs folder as a wildcard classpath. The
    # .bat files themselves are not run: kafka-run-class.bat lists every jar
    # by its full path, a line cmd.exe refuses as too long unless Kafka is in
    # a short folder such as C:\kafka. Returns @{ Code; Out; Err }.
    function Invoke-Tool([string]$Bat, [string[]]$Arguments) {
        $class = ''
        if ($Bat -match 'kafka-run-class\.bat$') { $class = $Arguments[0]; $Arguments = @($Arguments | Select-Object -Skip 1) }
        elseif ([System.IO.File]::ReadAllText($Bat) -cmatch 'kafka-run-class\.bat"?\s+([\w.$]+)') { $class = $Matches[1] }
        else { Stop-Run "cannot tell which Java class $Bat runs" }
        $home_ = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Bat))
        $java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { (Get-Command java.exe).Source }
        $jvm = @('-Xmx256m', '-Djava.awt.headless=true', '-cp', (Join-Path $home_ 'libs\*'))
        # The tools' own log settings, as their launcher sets them: errors only.
        $l2 = Join-Path $home_ 'config\tools-log4j2.yaml'
        $l1 = Join-Path $home_ 'config\tools-log4j.properties'
        if ([System.IO.File]::Exists($l2)) { $jvm += "-Dlog4j2.configurationFile=$l2" }
        elseif ([System.IO.File]::Exists($l1)) { $jvm += "-Dlog4j.configuration=file:$($l1.Replace('\', '/'))" }
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $java
        $si.Arguments = (@($jvm + $class + $Arguments | ForEach-Object { ConvertTo-Arg $_ }) -join ' ')
        $si.UseShellExecute = $false
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError = $true
        $si.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($si)
        # Both streams read at once, so neither fills and stops the tool.
        $o = $p.StandardOutput.ReadToEndAsync()
        $e = $p.StandardError.ReadToEndAsync()
        # Stopped if it has not finished in 45 seconds, and said so. The
        # client settings bound each request, but a tool can still hang:
        # Kafka 3.9's kafka-broker-api-versions logs a failed TLS handshake,
        # then waits forever.
        if (-not $p.WaitForExit(45000)) {
            try { $p.Kill() } catch { }
            $p.WaitForExit()
            return @{ Code = -1; Out = $o.Result; Err = $e.Result + "`nTimed out: no answer in 45 seconds, stopped"; Stopped = $true }
        }
        $p.WaitForExit()
        return @{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result; Stopped = $false }
    }

    # The most telling line of a tool's error output.
    function Get-Why([string]$Err) {
        $ls = @($Err -split "`r?`n" | Where-Object { $_ -match 'Exception|[Ee]rror' -and $_ -notmatch '^\s*at ' })
        $l = if ($ls.Count) { $ls[-1] } else { @($Err -split "`r?`n" | Where-Object { $_.Trim() })[-1] }
        if (-not $l) { $l = 'no message' }
        $l = $l -replace '^.*?\] ', ''
        if ($l.Length -gt 300) { $l = $l.Substring(0, 300) }
        return $l
    }
    $script:downPattern = 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls|Broker may not be available|disconnected'

    # Runs a tool: its output in $script:out. On failure: a cluster that
    # cannot be reached returns 2 (the caller reports it, or nothing);
    # anything else, a login or certificate refused, a permission missing,
    # says why and exits 1. -Soft returns 1 instead for anything but a login,
    # a permission or an unreachable cluster; -Lenient for anything but an
    # unreachable cluster.
    function Invoke-Kafka {
        param([string]$Tool, [string[]]$Arguments, [switch]$Soft, [switch]$Lenient)
        $r = Invoke-Tool (Get-Tool $Tool) $Arguments
        $script:out = $r.Out
        $script:err = $r.Err
        if ($r.Code -eq 0) { return 0 }
        if ($Lenient) {
            if ($r.Err -match 'TimeoutException|Timed out waiting|could not be established|Connection refused|UnknownHostException|No resolvable bootstrap urls') { return 2 }
            return 1
        }
        if ($r.Err -match 'SaslAuthenticationException|Authentication failed|SslAuthenticationException|SSL handshake failed|PKIX path|certificate') {
            Stop-Run "the cluster refused the login or its certificate: $(Get-Why $r.Err)"
        }
        if ($r.Err -match 'AuthorizationException|[Nn]ot authorized|Authorization failed') {
            Stop-Run "a permission is missing (packs/README.md lists the ACLs): $(Get-Why $r.Err)"
        }
        if ($r.Err -match $script:downPattern) { return 2 }
        if ($Soft) { return 1 }
        if ($r.Stopped) { Stop-Run "$Tool did not finish in 45 seconds, and was stopped: $(Get-Why $r.Err)" }
        Stop-Run "$Tool failed (exit $($r.Code)): $(Get-Why $r.Err)"
    }
    # The options every admin tool takes, in the order most take them.
    $conn = @('--bootstrap-server', $bootstrap, '--command-config', $cfg)

    # The brokers, as the cluster lists them, in $script:out:
    # kafka-broker-api-versions, or kafka-cluster api-versions where it has
    # gone (Kafka 5).
    function Invoke-BrokersList([switch]$Lenient) {
        if (Find-Tool 'kafka-broker-api-versions') { return Invoke-Kafka 'kafka-broker-api-versions' $conn -Lenient:$Lenient }
        if (Find-Tool 'kafka-cluster') { return Invoke-Kafka 'kafka-cluster' (@('api-versions') + $conn) -Lenient:$Lenient }
        [void](Get-Tool 'kafka-broker-api-versions')
    }
    # Kafka hides from a user the topics it may not describe: none at all may
    # mean an empty cluster, or missing ACLs. Said on stderr, for the job log.
    function Write-NoTopics {
        [Console]::Error.WriteLine("${job}: no topics are visible: the cluster has none, or this user may not describe them (packs/README.md lists the ACLs)")
    }

    # A tag's value: no spaces or control characters, never empty.
    function ConvertTo-Tag([string]$Value) {
        $v = $Value -replace '[\s\p{C}]', '_'
        if ($v) { return $v } else { return 'none' }
    }
    # A value as a metric value: no exponent, at most 4 decimals, whole
    # numbers without any. $null for a value that is not a number.
    function ConvertTo-Num($Value) {
        $d = 0.0
        if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $null }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        if ($d -eq [Math]::Floor($d) -and [Math]::Abs($d) -lt 1e15) { return ([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        return [Math]::Round($d, 4).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    function Write-Metric([string]$Name, $Value, [string]$Tags = '') {
        $v = ConvertTo-Num $Value
        if ($null -eq $v) { return }
        Write-Output ("metric $Name $v" + $(if ($Tags) { " $Tags" } else { '' }))
    }

    # JMX, for the jobs that read the brokers' own metrics: KAFKA_JMX lists
    # each broker's JMX host:port, comma-separated. Invoke-JmxEach asks each
    # broker for the objects named, and runs the block with $rows (one
    # @{ Name; Attr; Value } a value) and $broker, the broker's id (from
    # Kafka's app-info, else the endpoint). Each job's attributes include
    # Version, app-info's, which names the broker. A broker whose JMX does not
    # answer is reported as jmx_up 0; with no KAFKA_JMX, nothing is.
    function Invoke-JmxEach([scriptblock]$Block, [string[]]$Objects, [string]$Attributes) {
        if (-not $env:KAFKA_JMX) { return }
        $t = Get-Tool 'kafka-run-class'
        foreach ($ep in @($env:KAFKA_JMX -split '[,\s]+' | Where-Object { $_ })) {
            $a = @('org.apache.kafka.tools.JmxTool', '--jmx-url', "service:jmx:rmi:///jndi/rmi://$ep/jmxrmi", '--object-name', 'kafka.server:type=app-info,id=*')
            foreach ($o in $Objects) { $a += @('--object-name', $o) }
            $a += @('--attributes', $Attributes, '--one-time', 'true', '--report-format', 'tsv')
            $r = Invoke-Tool $t $a
            if ($r.Code -ne 0 -or $r.Out -notmatch 'app-info') {
                Write-Output "metric jmx_up 0 broker=$(ConvertTo-Tag $ep)"
                continue
            }
            $rows = New-Object 'System.Collections.Generic.List[object]'
            foreach ($l in ($r.Out -split "`r?`n")) {
                $i = $l.IndexOf("`t")
                if ($i -lt 1) { continue }
                $full = $l.Substring(0, $i)
                $j = $full.LastIndexOf(':')
                if ($j -lt 1) { continue }
                $rows.Add(@{ Name = $full.Substring(0, $j); Attr = $full.Substring($j + 1); Value = $l.Substring($i + 1) })
            }
            $broker = ConvertTo-Tag $ep
            foreach ($row in $rows) { if ($row.Name -cmatch '^kafka\.server:type=app-info,id=(\d+)$' -and $row.Attr -ceq 'Version') { $broker = $Matches[1] } }
            Write-Output "metric jmx_up 1 broker=$broker"
            & $Block
        }
    }
    # A JMX object's key, from its name: Get-Key 'a:type=X,name=Y' 'name' is Y.
    function Get-Key([string]$Name, [string]$Key) {
        if ($Name -cmatch "[:,]$([regex]::Escape($Key))=([^,]*)") { return $Matches[1] }
        return ''
    }

    # kafka-topics --describe, read: a topic line, tab-separated
    #   Topic: orders  TopicId: ...  PartitionCount: 6  ReplicationFactor: 3  Configs: min.insync.replicas=2
    # then one line per partition
    #   (tab) Topic: orders  Partition: 0  Leader: 1  Replicas: 1,2,3  Isr: 1,2,3  Elr:   LastKnownElr:
    # Returns @{ Topics; Parts }: each topic @{ Name; Partitions; Rf; Configs;
    # MinIsr } (min.insync.replicas, 1 when its Configs do not name it), each
    # partition @{ Topic; Leader; Replicas; Isr; Elr; Moving }.
    function Read-Describe([string]$Text) {
        $topics = New-Object 'System.Collections.Generic.List[object]'
        $parts = New-Object 'System.Collections.Generic.List[object]'
        foreach ($l in ($Text -split "`r?`n")) {
            if (-not $l.Trim()) { continue }
            $f = @{}
            foreach ($x in ($l.Trim() -split "`t")) { $i = $x.IndexOf(': '); if ($i -gt 0) { $f[$x.Substring(0, $i)] = $x.Substring($i + 2) } elseif ($x.EndsWith(':')) { $f[$x.TrimEnd(':')] = '' } }
            if (-not $f.ContainsKey('Topic')) { continue }
            $list = { param($s) if ($s) { @($s -split ',' | Where-Object { $_ }) } else { @() } }
            if ($f.ContainsKey('Partition')) {
                $moving = [bool]($f['Adding Replicas'] -or $f['Removing Replicas'])
                $parts.Add(@{ Topic = $f['Topic']; Leader = $f['Leader']; Replicas = (& $list $f['Replicas']); Isr = (& $list $f['Isr']); Elr = (& $list $f['Elr']); Moving = $moving })
            }
            else {
                $c = [string]$f['Configs']
                $min = 1
                if ($c -cmatch '(^|[ ,])min\.insync\.replicas=(\d+)') { $min = [int]$Matches[2] }
                $topics.Add(@{ Name = $f['Topic']; Partitions = [int]$f['PartitionCount']; Rf = [int]$f['ReplicationFactor']; Configs = $c; MinIsr = $min })
            }
        }
        return @{ Topics = $topics; Parts = $parts }
    }

    # A map whose keys keep their case, in the order they came: Kafka's names
    # do (Orders and orders are two topics), and PowerShell's own maps do not.
    function New-Map { return , (New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)) }

    # Every broker's log directories: their partitions and sizes, any error
    # (an offline directory), and future replicas (a move between
    # directories). The tool answers in one line of JSON, read as the bash
    # script reads it, split at each "{": Windows PowerShell's ConvertFrom-Json
    # refuses one longer than 2 MB, as a large cluster's is. Every partition
    # is then a piece of its own, and each directory's logDir and error come
    # after its partitions.
    if ((Invoke-Kafka 'kafka-log-dirs' ($conn + @('--describe'))) -ne 0) { return }
    $json = @($script:out -split "`r?`n" | Where-Object { $_.StartsWith('{') })
    $json = if ($json.Count) { $json[-1] } else { '' }
    $dirs = New-Object 'System.Collections.Generic.List[object]'
    $bsize = New-Map; $tsize = New-Map
    $broker = ''; $size = [double]0; $parts = 0; $future = 0
    foreach ($piece in $json.Split('{')) {
        if ($piece -cmatch '"broker":(\d+)') { $broker = $Matches[1]; continue }
        if ($piece -cmatch '"partition":"([^"]*)"') {
            $topic = $Matches[1] -creplace '-\d+$', ''
            $s = if ($piece -cmatch '"size":(\d+)') { [double]$Matches[1] } else { [double]0 }
            $size += $s; $parts++
            $tsize[$topic] = [double]$tsize[$topic] + $s
            $bsize[$broker] = [double]$bsize[$broker] + $s
            if ($piece -cmatch '"isFuture":true') { $future++ }
        }
        if ($piece -cmatch '"logDir":"([^"]*)"') {
            $dirs.Add(@{ Broker = $broker; Dir = (ConvertTo-Tag $Matches[1]); Size = $size; Parts = $parts; Offline = [int]($piece -cnotmatch '"error":null'); Future = $future })
            $size = [double]0; $parts = 0; $future = 0
        }
    }
    $offline = 0
    foreach ($d in $dirs) {
        $tags = "broker=$($d.Broker) dir=$($d.Dir)"
        Write-Metric 'size_bytes' $d.Size $tags
        Write-Output "metric partitions $($d.Parts) $tags"
        Write-Output "metric offline $($d.Offline) $tags"
        Write-Output "metric future_replicas $($d.Future) $tags"
        $offline += $d.Offline
    }
    Write-Output "metric dirs $($dirs.Count)"
    Write-Output "metric dirs_offline $offline"
    foreach ($b in $bsize.Keys) { Write-Metric 'broker_size_bytes' $bsize[$b] "broker=$b" }
    $n = 0; $hidden = 0
    foreach ($t in $tsize.Keys) { if (++$n -gt 100) { $hidden++; continue }; Write-Metric 'topic_size_bytes' $tsize[$t] "topic=$t" }
    Write-Output "metric topics_not_shown $hidden"

    # Tiered storage (Kafka 3.6 on), from JMX when KAFKA_JMX is set: what each
    # broker has copied to remote storage, and what it still has to copy. A
    # broker without tiered storage has neither.
    Invoke-JmxEach {
        foreach ($r in $rows) {
            if ($r.Attr -cne 'Value') { continue }
            switch -CaseSensitive (Get-Key $r.Name 'name') {
                'RemoteLogSizeBytes' { Write-Metric 'remote_size_bytes' $r.Value "broker=$broker" }
                'RemoteCopyLagBytes' { Write-Metric 'remote_copy_lag_bytes' $r.Value "broker=$broker" }
            }
        }
    } @('kafka.server:type=BrokerTopicMetrics,name=RemoteLogSizeBytes', 'kafka.server:type=BrokerTopicMetrics,name=RemoteCopyLagBytes') 'Version,Value'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
