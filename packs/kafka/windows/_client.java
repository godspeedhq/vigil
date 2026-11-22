// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// _client.java - the kafka pack's client (tools/kafka/DESIGN.md): every job
// of the pack, on every platform, so each prints the same lines on Linux,
// macOS and Windows. It asks Kafka's admin API what any Kafka admin would, as
// a user that may only describe, and reads each broker's own figures over JMX
// through the shared engine (tools/jmx), which follows it in this file. It
// reports Kafka's, never the JVM's: the broker's heap, garbage collection,
// threads, CPU and open files are the jvm pack's.
//
// Kafka's library is not in the pack: the script puts the user's on the
// class path (KAFKA_HOME/libs, or KAFKA_LIBS), any kafka-clients from 3.x or
// 4.x. The client is compiled against 3.9 and calls only what every such
// library has; what came later it looks up while it runs (Lib.call), and
// skips where the library or the cluster has none.
//
// Settings, in the environment (the job's env and secret lines):
//   KAFKA_BOOTSTRAP        brokers, host:port, comma-separated
//   KAFKA_SECURITY         PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL
//   KAFKA_SASL_MECHANISM   SCRAM-SHA-512, SCRAM-SHA-256 or PLAIN
//   KAFKA_USER             the user, one that may only describe
//   KAFKA_PASSWORD         its password (a secret line: never on a command line)
//   KAFKA_CACERT           a PEM file of CAs, for the brokers' TLS and JMX's
//   KAFKA_CERT, KAFKA_KEY  a client certificate and its key (PEM, PKCS#8), for
//                          brokers that ask for one
//   KAFKA_CLIENT_CONFIG    a client properties file of your own (Kerberos,
//                          OAuth): its settings come first
//   KAFKA_JMX              the brokers' JMX: jmx=host:port or jmxs=host:port, ;-separated
//   KAFKA_JMX_USER         JMX's user
//   KAFKA_JMX_PASSWORD     its password (a secret line)
//   KAFKA_TXN_LONG         seconds after which an open transaction is long-running

import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.KeyStore;
import java.security.cert.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import javax.management.*;
import javax.management.openmbean.*;
import javax.management.remote.*;
import javax.net.ssl.*;
import javax.rmi.ssl.SslRMIClientSocketFactory;
import org.apache.kafka.clients.admin.*;
import org.apache.kafka.clients.consumer.OffsetAndMetadata;
import org.apache.kafka.common.*;
import org.apache.kafka.common.acl.*;
import org.apache.kafka.common.config.ConfigResource;
import org.apache.kafka.common.errors.*;
import org.apache.kafka.common.quota.*;
import org.apache.kafka.common.resource.*;

class KafkaClient {

    static final int TOPIC_CAP = 100, GROUP_CAP = 150, BROKER_CAP = 150;
    static final long WAIT = 30;

    public static void main(String[] args) {
        if (args.length < 1) { System.err.println("usage: java _client.java <job>"); System.exit(2); }
        String job = args[0].startsWith("kafka_") ? args[0] : "kafka_" + args[0];
        Jmx.job = job;
        Jmx.settings("KAFKA_JMX_USER", "KAFKA_JMX_PASSWORD", "KAFKA_CACERT");
        quiet();
        Runnable j = JOBS.get(job.substring(6));
        if (j == null) { Jmx.fail("no such job: " + job); exit(); }
        try {
            j.run();
        } catch (Stop s) {
            // Said already.
        } catch (IllegalArgumentException e) {
            Jmx.fail(e.getMessage());
        } catch (Exception e) {
            Jmx.fail(Jmx.rootMessage(e));
        } finally {
            if (admin != null) try { admin.close(Duration.ofSeconds(5)); } catch (Exception e) { /* closing */ }
            Jmx.closeAll(jmxTargets);
        }
        exit();
    }

    static void exit() {
        Jmx.OUT.flush();
        System.out.flush();
        System.exit(Jmx.exitCode);
    }

    /** A job that cannot go on, having said why. */
    static final class Stop extends RuntimeException {
        Stop() { super(null, null, false, false); }
    }

    /**
     * Kafka's library logs through SLF4J to whatever the user's Kafka has
     * (reload4j in 3.x, log4j2 in 4.x), which would fill the job's log:
     * turned off, as the job says what matters itself.
     */
    static void quiet() {
        System.setProperty("org.apache.logging.log4j.level", "OFF");
        System.setProperty("log4j2.level", "OFF");
        try {
            File f = File.createTempFile("vigil-kafka-log4j", ".properties");
            f.deleteOnExit();
            try (Writer w = new OutputStreamWriter(new FileOutputStream(f), StandardCharsets.UTF_8)) {
                w.write("log4j.rootLogger=OFF\n");
            }
            System.setProperty("log4j.configuration", f.toURI().toString());
        } catch (IOException e) { /* only quieter */ }
        // SLF4J's own notices (no provider, several), never a job's.
        PrintStream err = System.err;
        System.setErr(new PrintStream(new OutputStream() {
            final ByteArrayOutputStream line = new ByteArrayOutputStream();
            public void write(int b) {
                if (b != '\n') { line.write(b); return; }
                String s = new String(line.toByteArray(), StandardCharsets.UTF_8);
                line.reset();
                if (s.startsWith("SLF4J") || s.startsWith("log4j:")) return;
                err.println(s);
            }
            public void flush() { err.flush(); }
        }, true));
    }

    // ---- the admin client -----------------------------------------------------

    static Admin admin;
    /** The security protocol the admin client uses. */
    static String protocol = "PLAINTEXT";

    static String env(String k) { return Jmx.env(k); }

    /** Kafka's admin client, configured in memory: the password never touches a file. */
    static Admin admin() {
        if (admin != null) return admin;
        Properties p = new Properties();
        String own = env("KAFKA_CLIENT_CONFIG");
        if (!own.isEmpty()) {
            try (InputStream in = new FileInputStream(own)) { p.load(in); } catch (IOException e) {
                throw new IllegalArgumentException("KAFKA_CLIENT_CONFIG: cannot read " + own + ": " + e.getMessage());
            }
        }
        String boot = env("KAFKA_BOOTSTRAP");
        if (boot.isEmpty() && !p.containsKey("bootstrap.servers")) throw new IllegalArgumentException("KAFKA_BOOTSTRAP is empty: the brokers, host:port, comma-separated");
        if (!boot.isEmpty()) p.setProperty("bootstrap.servers", boot);
        String sec = env("KAFKA_SECURITY").toUpperCase(Locale.ROOT);
        if (!sec.isEmpty()) {
            if (!sec.matches("PLAINTEXT|SSL|SASL_PLAINTEXT|SASL_SSL")) throw new IllegalArgumentException("KAFKA_SECURITY: not PLAINTEXT, SSL, SASL_PLAINTEXT or SASL_SSL: " + sec);
            p.putIfAbsent("security.protocol", sec);
        }
        String proto = p.getProperty("security.protocol", "PLAINTEXT").toUpperCase(Locale.ROOT);
        protocol = proto;
        if (proto.startsWith("SASL_") && !p.containsKey("sasl.jaas.config")) {
            String mech = env("KAFKA_SASL_MECHANISM").isEmpty() ? "SCRAM-SHA-512" : env("KAFKA_SASL_MECHANISM").toUpperCase(Locale.ROOT);
            String module;
            if (mech.startsWith("SCRAM-")) module = "org.apache.kafka.common.security.scram.ScramLoginModule";
            else if (mech.equals("PLAIN")) module = "org.apache.kafka.common.security.plain.PlainLoginModule";
            else throw new IllegalArgumentException("KAFKA_SASL_MECHANISM: " + mech + " needs KAFKA_CLIENT_CONFIG, with its own sasl.jaas.config");
            p.putIfAbsent("sasl.mechanism", mech);
            p.setProperty("sasl.jaas.config", module + " required username=\"" + jaas(env("KAFKA_USER")) + "\" password=\"" + jaas(env("KAFKA_PASSWORD")) + "\";");
        }
        if (proto.endsWith("SSL") && !env("KAFKA_CACERT").isEmpty() && !p.containsKey("ssl.truststore.location")) {
            try {
                p.setProperty("ssl.truststore.type", "PEM");
                p.setProperty("ssl.truststore.certificates", new String(Files.readAllBytes(Paths.get(env("KAFKA_CACERT"))), StandardCharsets.US_ASCII));
            } catch (IOException e) {
                throw new IllegalArgumentException("KAFKA_CACERT: cannot read " + env("KAFKA_CACERT") + ": " + e.getMessage());
            }
        }
        // A client certificate, for brokers that ask for one (ssl.client.auth):
        // its key PKCS#8, as Kafka reads PEM.
        if (proto.endsWith("SSL") && !env("KAFKA_CERT").isEmpty() && !p.containsKey("ssl.keystore.location")) {
            if (env("KAFKA_KEY").isEmpty()) throw new IllegalArgumentException("KAFKA_CERT is set but KAFKA_KEY is not: the certificate's private key, PEM (PKCS#8)");
            try {
                p.setProperty("ssl.keystore.type", "PEM");
                p.setProperty("ssl.keystore.certificate.chain", new String(Files.readAllBytes(Paths.get(env("KAFKA_CERT"))), StandardCharsets.US_ASCII));
                p.setProperty("ssl.keystore.key", new String(Files.readAllBytes(Paths.get(env("KAFKA_KEY"))), StandardCharsets.US_ASCII));
            } catch (IOException e) {
                throw new IllegalArgumentException("KAFKA_CERT, KAFKA_KEY: " + e.getMessage());
            }
        }
        // The broker's name is always checked: no setting turns it off.
        p.remove("ssl.endpoint.identification.algorithm");
        p.putIfAbsent("client.id", "vigil-" + Jmx.job);
        p.putIfAbsent("request.timeout.ms", "15000");
        p.putIfAbsent("default.api.timeout.ms", "30000");
        p.putIfAbsent("retry.backoff.ms", "500");
        admin = Admin.create(p);
        return admin;
    }

    /** A value inside a JAAS line's quotes. */
    static String jaas(String v) { return v.replace("\\", "\\\\").replace("\"", "\\\""); }

    /**
     * A future's value, waited for. What stops the cluster answering is said,
     * and Stop thrown: a login refused or a certificate not trusted fails the
     * run; a cluster that does not answer, or an answer the user may not have,
     * is said only.
     */
    static <T> T get(KafkaFuture<T> f, String what) {
        try {
            return f.get(WAIT, TimeUnit.SECONDS);
        } catch (ExecutionException e) {
            throw stop(e.getCause(), what);
        } catch (java.util.concurrent.TimeoutException e) {
            Jmx.say(what + ": the cluster did not answer in " + WAIT + " seconds (" + bootstrap() + ")");
            throw new Stop();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Stop();
        }
    }

    /** The same, or null when the cluster or the library has no such thing (said). */
    static <T> T maybe(KafkaFuture<T> f, String what) {
        try {
            return f.get(WAIT, TimeUnit.SECONDS);
        } catch (ExecutionException e) {
            Throwable c = e.getCause();
            if (c instanceof UnsupportedVersionException) { Jmx.say(what + ": not supported by this cluster"); return null; }
            if (c instanceof AuthorizationException) { Jmx.say(what + ": the user may not describe it: " + Jmx.rootMessage(c)); return null; }
            throw stop(c, what);
        } catch (java.util.concurrent.TimeoutException e) {
            Jmx.say(what + ": the cluster did not answer in " + WAIT + " seconds (" + bootstrap() + ")");
            throw new Stop();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Stop();
        }
    }

    static String bootstrap() { return env("KAFKA_BOOTSTRAP").isEmpty() ? "KAFKA_CLIENT_CONFIG" : env("KAFKA_BOOTSTRAP"); }

    static Stop stop(Throwable c, String what) {
        String why = Jmx.rootMessage(c);
        if (c instanceof SslAuthenticationException || Jmx.hasCause(c, CertificateException.class) || Jmx.hasCause(c, SSLHandshakeException.class)) {
            Jmx.fail("the brokers' certificate is not trusted, or does not name the broker: " + why + " (KAFKA_CACERT; connect by the name on the certificate)");
        } else if (c instanceof AuthenticationException) {
            Jmx.fail("the cluster refused the login: " + why + " (KAFKA_USER, and the secret behind KAFKA_PASSWORD)");
        } else if (c instanceof AuthorizationException) {
            Jmx.say(what + ": the user may not describe it: " + why + " (packs/README.md lists the ACLs it needs)");
        } else if (c instanceof org.apache.kafka.common.errors.TimeoutException) {
            Jmx.say(what + ": the cluster does not answer: " + why + " (" + bootstrap() + ")");
        } else {
            Jmx.say(what + ": " + why);
        }
        return new Stop();
    }

    // ---- what only some libraries have ---------------------------------------------

    /** Methods looked up while the client runs: there in newer libraries, not in 3.9's. */
    static final class Lib {
        /** obj.name(args), or null when the library has no such method. */
        static Object call(Object obj, String name, Object... args) {
            if (obj == null) return null;
            for (Method m : obj.getClass().getMethods()) {
                if (!m.getName().equals(name) || m.getParameterCount() != args.length) continue;
                try {
                    m.setAccessible(true);
                    return m.invoke(obj, args);
                } catch (InvocationTargetException e) {
                    Throwable t = e.getCause();
                    if (t instanceof RuntimeException) throw (RuntimeException) t;
                    throw new RuntimeException(t);
                } catch (IllegalAccessException e) {
                    return null;
                }
            }
            return null;
        }

        static boolean has(Object obj, String name) {
            if (obj == null) return false;
            for (Method m : obj.getClass().getMethods()) if (m.getName().equals(name)) return true;
            return false;
        }

        /** An Optional's value, or the thing itself; null for an empty one. */
        static Object unwrap(Object o) {
            if (o instanceof Optional) return ((Optional<?>) o).orElse(null);
            return o;
        }
    }

    // ---- shared readings ---------------------------------------------------------------

    static DescribeClusterResult cluster;
    static Collection<Node> nodes;

    static Collection<Node> nodes() {
        if (nodes != null) return nodes;
        DescribeClusterOptions o = new DescribeClusterOptions().timeoutMs((int) (WAIT * 1000));
        // Kafka 4's library can list fenced brokers too.
        Lib.call(o, "includeFencedBrokers", true);
        cluster = admin().describeCluster(o);
        nodes = new ArrayList<>(get(cluster.nodes(), "the cluster"));
        return nodes;
    }

    /** Whether node n is fenced; null when the library cannot tell. */
    static Boolean fenced(Node n) {
        Object f = Lib.call(n, "isFenced");
        return f instanceof Boolean ? (Boolean) f : null;
    }

    static Set<String> topicNames;

    static Set<String> topicNames() {
        if (topicNames == null) topicNames = new TreeSet<>(get(admin().listTopics(new ListTopicsOptions().listInternal(true)).names(), "the topics"));
        return topicNames;
    }

    static Map<String, TopicDescription> topics;

    @SuppressWarnings("unchecked")
    static Map<String, TopicDescription> topics() {
        if (topics != null) return topics;
        DescribeTopicsResult r = admin().describeTopics(topicNames());
        topics = new TreeMap<>(get(r.allTopicNames(), "the topics"));
        return topics;
    }

    /** Each topic's settings, those named. */
    static Map<String, Map<String, String>> topicConfigs(String... keys) {
        Set<String> want = new HashSet<>(Arrays.asList(keys));
        List<ConfigResource> rs = new ArrayList<>();
        for (String t : topicNames()) rs.add(new ConfigResource(ConfigResource.Type.TOPIC, t));
        Map<String, Map<String, String>> out = new TreeMap<>();
        if (rs.isEmpty()) return out;
        Map<ConfigResource, Config> got = maybe(admin().describeConfigs(rs).all(), "the topics' settings");
        if (got == null) return out;
        for (Map.Entry<ConfigResource, Config> e : got.entrySet()) {
            Map<String, String> m = new HashMap<>();
            for (ConfigEntry c : e.getValue().entries()) if (want.contains(c.name()) && c.value() != null) m.put(c.name(), c.value());
            out.put(e.getKey().name(), m);
        }
        return out;
    }

    /** Each broker's settings, all of them. */
    static Map<Integer, Map<String, String>> brokerConfigs() {
        List<ConfigResource> rs = new ArrayList<>();
        for (Node n : nodes()) rs.add(new ConfigResource(ConfigResource.Type.BROKER, n.idString()));
        Map<Integer, Map<String, String>> out = new TreeMap<>();
        Map<ConfigResource, Config> got = maybe(admin().describeConfigs(rs).all(), "the brokers' settings");
        if (got == null) return out;
        for (Map.Entry<ConfigResource, Config> e : got.entrySet()) {
            Map<String, String> m = new TreeMap<>();
            for (ConfigEntry c : e.getValue().entries()) if (c.value() != null) m.put(c.name(), c.value());
            out.put(Integer.parseInt(e.getKey().name()), m);
        }
        return out;
    }

    /** The latest (or earliest) offset of each partition. */
    static Map<TopicPartition, Long> offsets(Collection<TopicPartition> tps, OffsetSpec spec, String what) {
        Map<TopicPartition, Long> out = new HashMap<>();
        if (tps.isEmpty()) return out;
        Map<TopicPartition, OffsetSpec> q = new HashMap<>();
        for (TopicPartition tp : tps) q.put(tp, spec);
        Map<TopicPartition, ListOffsetsResult.ListOffsetsResultInfo> got = maybe(admin().listOffsets(q).all(), what);
        if (got != null) for (Map.Entry<TopicPartition, ListOffsetsResult.ListOffsetsResultInfo> e : got.entrySet()) out.put(e.getKey(), e.getValue().offset());
        return out;
    }

    static List<TopicPartition> partitions(Collection<TopicDescription> ds) {
        List<TopicPartition> out = new ArrayList<>();
        for (TopicDescription d : ds) for (TopicPartitionInfo p : d.partitions()) out.add(new TopicPartition(d.name(), p.partition()));
        return out;
    }

    static boolean offline(TopicPartitionInfo p) { return p.leader() == null || p.leader().id() < 0 || p.leader().isEmpty(); }

    static int intOr(String v, int d) {
        try { return Integer.parseInt(v.trim()); } catch (Exception e) { return d; }
    }

    static long longOr(String v, long d) {
        try { return Long.parseLong(v.trim()); } catch (Exception e) { return d; }
    }

    // ---- the KRaft quorum ---------------------------------------------------------------

    static Object quorum;
    static boolean quorumAsked;

    /** The metadata quorum (KRaft, 3.3 and later), or null on ZooKeeper (said, when said is true). */
    static Object quorum(boolean said) {
        if (quorumAsked) return quorum;
        quorumAsked = true;
        Object r = Lib.call(admin(), "describeMetadataQuorum");
        if (r == null) { if (said) Jmx.say("the KRaft quorum: this Kafka library cannot describe it (3.3 and later)"); return null; }
        try {
            @SuppressWarnings("unchecked") KafkaFuture<Object> f = (KafkaFuture<Object>) Lib.call(r, "quorumInfo");
            quorum = f.get(WAIT, TimeUnit.SECONDS);
        } catch (ExecutionException e) {
            Throwable c = e.getCause();
            if (c instanceof UnsupportedVersionException) { if (said) Jmx.say("the KRaft quorum: this cluster runs on ZooKeeper"); return null; }
            throw stop(c, "the KRaft quorum");
        } catch (java.util.concurrent.TimeoutException e) {
            Jmx.say("the KRaft quorum: the cluster did not answer in " + WAIT + " seconds");
            throw new Stop();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Stop();
        }
        return quorum;
    }

    static long l(Object o) {
        Object v = Lib.unwrap(o);
        if (v instanceof OptionalLong) return ((OptionalLong) v).isPresent() ? ((OptionalLong) v).getAsLong() : -1;
        return v instanceof Number ? ((Number) v).longValue() : -1;
    }

    // ---- the jobs -------------------------------------------------------------------------

    static final Map<String, Runnable> JOBS = new LinkedHashMap<>();

    static {
        JOBS.put("status", Jobs::status);
        JOBS.put("quorum", Jobs::quorum);
        JOBS.put("brokers", Jobs::brokers);
        JOBS.put("replication", Jobs::replication);
        JOBS.put("reassignment", Jobs::reassignment);
        JOBS.put("consumers", Jobs::consumers);
        JOBS.put("groups", Jobs::groups);
        JOBS.put("topics", Jobs::topics);
        JOBS.put("logdirs", Jobs::logdirs);
        JOBS.put("transactions", Jobs::transactions);
        JOBS.put("config", Jobs::config);
        JOBS.put("security", Jobs::security);
        JOBS.put("features", Jobs::features);
        JOBS.put("tls", Jobs::tls);
        JOBS.put("throughput", Jobs::throughput);
        JOBS.put("requests", Jobs::requests);
        JOBS.put("controller", Jobs::controller);
        JOBS.put("connections", Jobs::connections);
    }

    static void metric(String name, Number v, String... tags) { Jmx.metric(name, v, tags); }

    static void metric(String name, boolean v, String... tags) { Jmx.metric(name, v, tags); }

    static final class Jobs {

        // Is the cluster up, and in control?

        static void status() {
            Collection<Node> ns;
            try {
                ns = nodes();
            } catch (Stop s) {
                metric("up", 0);
                throw s;
            }
            metric("up", 1);
            String id = maybe(cluster.clusterId(), "the cluster's id");
            Object q = KafkaClient.quorum(false);
            metric("info", 1, "cluster_id", id == null ? "none" : id, "kraft", q != null ? "yes" : "no");
            int fenced = 0;
            boolean known = false;
            for (Node n : ns) {
                Boolean f = fenced(n);
                if (f != null) { known = true; if (f) fenced++; }
            }
            metric("brokers", ns.size() - fenced);
            if (known) metric("brokers_fenced", fenced);
            if (q != null) {
                metric("controller_id", l(Lib.call(q, "leaderId")));
            } else {
                Node c = maybe(cluster.controller(), "the controller");
                if (c != null && c.id() >= 0) metric("controller_id", c.id());
            }
        }

        static void quorum() {
            Object q = KafkaClient.quorum(true);
            metric("kraft", q != null);
            if (q == null) return;
            metric("leader_id", l(Lib.call(q, "leaderId")));
            metric("leader_epoch", l(Lib.call(q, "leaderEpoch")));
            metric("high_watermark", l(Lib.call(q, "highWatermark")));
            long leader = l(Lib.call(q, "leaderId"));
            List<?> voters = (List<?>) Lib.call(q, "voters"), observers = (List<?>) Lib.call(q, "observers");
            long leaderEnd = -1, now = System.currentTimeMillis();
            for (Object v : voters) if (l(Lib.call(v, "replicaId")) == leader) leaderEnd = l(Lib.call(v, "logEndOffset"));
            long maxLag = 0, maxLagMs = 0;
            metric("voters", voters.size());
            metric("observers", observers.size());
            for (int pass = 0; pass < 2; pass++) {
                for (Object r : pass == 0 ? voters : observers) {
                    long id = l(Lib.call(r, "replicaId")), end = l(Lib.call(r, "logEndOffset"));
                    String role = pass == 1 ? "observer" : id == leader ? "leader" : "follower";
                    long lag = leaderEnd >= 0 && end >= 0 ? Math.max(0, leaderEnd - end) : -1;
                    if (lag >= 0) metric("node_lag", lag, "node", Long.toString(id), "role", role);
                    long fetched = l(Lib.call(r, "lastFetchTimestamp")), caught = l(Lib.call(r, "lastCaughtUpTimestamp"));
                    if (fetched > 0) metric("node_fetch_age_seconds", Math.max(0, now - fetched) / 1000.0, "node", Long.toString(id), "role", role);
                    if (caught > 0) metric("node_caught_up_age_seconds", Math.max(0, now - caught) / 1000.0, "node", Long.toString(id), "role", role);
                    if (pass == 0 && id != leader) {
                        if (lag > maxLag) maxLag = lag;
                        if (caught > 0) maxLagMs = Math.max(maxLagMs, now - caught);
                    }
                }
            }
            metric("max_follower_lag", maxLag);
            metric("max_follower_lag_ms", maxLagMs);
        }

        static void controller() {
            List<Jmx.Row> rows = Arrays.asList(
                    Jmx.row("brokers", "kafka.controller:type=KafkaController,name=ActiveBrokerCount", "Value"),
                    Jmx.row("fenced_brokers", "kafka.controller:type=KafkaController,name=FencedBrokerCount", "Value"),
                    Jmx.row("topics", "kafka.controller:type=KafkaController,name=GlobalTopicCount", "Value"),
                    Jmx.row("partitions", "kafka.controller:type=KafkaController,name=GlobalPartitionCount", "Value"),
                    Jmx.row("offline_partitions", "kafka.controller:type=KafkaController,name=OfflinePartitionsCount", "Value"),
                    Jmx.row("preferred_imbalance", "kafka.controller:type=KafkaController,name=PreferredReplicaImbalanceCount", "Value"),
                    Jmx.row("metadata_errors", "kafka.controller:type=KafkaController,name=MetadataErrorCount", "Value"),
                    Jmx.row("metadata_lag_ms", "kafka.controller:type=KafkaController,name=LastAppliedRecordLagMs", "Value"),
                    Jmx.row("timed_out_heartbeats", "kafka.controller:type=KafkaController,name=TimedOutBrokerHeartbeatCount", "Value"),
                    Jmx.row("controller_changes", "kafka.controller:type=KafkaController,name=NewActiveControllersCount", "Value"),
                    Jmx.row("elections_count", "kafka.controller:type=ControllerStats,name=LeaderElectionRateAndTimeMs", "Count"),
                    Jmx.row("unclean_elections_count", "kafka.controller:type=ControllerStats,name=UncleanLeaderElectionsPerSec", "Count"),
                    Jmx.row("eligible_leader_elections_count", "kafka.controller:type=ControllerStats,name=ElectionFromEligibleLeaderReplicasPerSec", "Count"),
                    Jmx.row("event_queue", "kafka.controller:type=ControllerEventManager,name=EventQueueSize", "Value"),
                    Jmx.row("event_queue_ms_p99", "kafka.controller:type=ControllerEventManager,name=EventQueueTimeMs", "99thPercentile"));
            for (Jmx.Target t : jmx()) {
                if (t.mbs() == null) continue;
                Object a = Jmx.attr(t.mbs(), "kafka.controller:type=KafkaController,name=ActiveControllerCount", "Value");
                Number n = Jmx.number(a, null);
                if (n == null) continue;
                boolean active = n.doubleValue() > 0;
                metric("active_controller", active, broker(t));
                if (active) Jmx.table(t, rows, broker(t));
            }
        }

        // Is the data safe?

        static void replication() {
            Map<String, TopicDescription> ts = KafkaClient.topics();
            Map<String, Map<String, String>> cfg = topicConfigs("min.insync.replicas");
            int parts = 0, under = 0, off = 0, underMin = 0, atMin = 0, notPreferred = 0, elr = 0;
            Map<String, int[]> byTopic = new TreeMap<>();
            for (TopicDescription d : ts.values()) {
                int min = intOr(cfg.getOrDefault(d.name(), Collections.emptyMap()).getOrDefault("min.insync.replicas", "1"), 1);
                int[] c = new int[3];
                for (TopicPartitionInfo p : d.partitions()) {
                    parts++;
                    int rf = p.replicas().size(), isr = p.isr().size();
                    if (isr < rf) { under++; c[0]++; }
                    if (offline(p)) { off++; c[1]++; }
                    if (isr < min) { underMin++; c[2]++; }
                    else if (isr == min && rf > min) atMin++;
                    if (!offline(p) && !p.replicas().isEmpty() && p.leader().id() != p.replicas().get(0).id()) notPreferred++;
                    Object e = Lib.unwrap(Lib.call(p, "elr"));
                    if (e instanceof Collection && !((Collection<?>) e).isEmpty()) elr++;
                }
                if (c[0] + c[1] + c[2] > 0) byTopic.put(d.name(), c);
            }
            metric("topics", ts.size());
            metric("partitions", parts);
            metric("under_replicated", under);
            metric("offline", off);
            metric("under_min_isr", underMin);
            metric("at_min_isr", atMin);
            metric("not_preferred_leader", notPreferred);
            TopicPartitionInfo any = null;
            for (TopicDescription d : ts.values()) if (any == null && !d.partitions().isEmpty()) any = d.partitions().get(0);
            // Eligible leader replicas: Kafka 4's library and later.
            if (Lib.has(any, "elr")) metric("with_eligible_leaders", elr);
            Map<TopicPartition, PartitionReassignment> moving = maybe(admin().listPartitionReassignments().reassignments(), "partition moves");
            if (moving != null) metric("reassigning", moving.size());
            int n = 0;
            for (Map.Entry<String, int[]> e : byTopic.entrySet()) {
                if (++n > TOPIC_CAP) break;
                if (e.getValue()[0] > 0) metric("topic_under_replicated", e.getValue()[0], "topic", e.getKey());
                if (e.getValue()[1] > 0) metric("topic_offline", e.getValue()[1], "topic", e.getKey());
                if (e.getValue()[2] > 0) metric("topic_under_min_isr", e.getValue()[2], "topic", e.getKey());
            }
        }

        static void brokers() {
            Collection<Node> ns = nodes();
            Map<Integer, Node> byId = new TreeMap<>();
            for (Node n : ns) byId.put(n.id(), n);
            Map<Integer, int[]> c = new TreeMap<>();
            for (Node n : ns) c.put(n.id(), new int[4]);
            for (TopicDescription d : KafkaClient.topics().values()) {
                for (TopicPartitionInfo p : d.partitions()) {
                    if (!offline(p)) c.computeIfAbsent(p.leader().id(), k -> new int[4])[0]++;
                    Set<Integer> isr = new HashSet<>();
                    for (Node r : p.isr()) isr.add(r.id());
                    for (int i = 0; i < p.replicas().size(); i++) {
                        int id = p.replicas().get(i).id();
                        int[] x = c.computeIfAbsent(id, k -> new int[4]);
                        x[1]++;
                        if (!isr.contains(id)) x[2]++;
                        if (i == 0) x[3]++;
                    }
                }
            }
            int k = 0;
            for (Map.Entry<Integer, int[]> e : c.entrySet()) {
                if (++k > BROKER_CAP) break;
                String id = Integer.toString(e.getKey());
                Node n = byId.get(e.getKey());
                metric("online", n != null, "broker", id, "rack", n == null || n.rack() == null ? "none" : n.rack());
                Boolean f = n == null ? null : fenced(n);
                if (f != null) metric("fenced", f, "broker", id);
                metric("leaders", e.getValue()[0], "broker", id);
                metric("replicas", e.getValue()[1], "broker", id);
                metric("out_of_sync_replicas", e.getValue()[2], "broker", id);
                metric("preferred_leaders", e.getValue()[3], "broker", id);
            }
            if (c.size() > BROKER_CAP) metric("brokers_not_shown", c.size() - BROKER_CAP);
        }

        // Are consumers keeping up?

        /** The groups, of every type the library and cluster know: id, type, state. */
        static List<String[]> listGroups() {
            List<String[]> out = new ArrayList<>();
            Object r = Lib.call(admin(), "listGroups");
            if (r != null) {
                @SuppressWarnings("unchecked") KafkaFuture<Collection<Object>> f = (KafkaFuture<Collection<Object>>) Lib.call(r, "all");
                Collection<Object> all = maybe(f, "the groups");
                if (all == null) return out;
                for (Object g : all) {
                    Object type = Lib.unwrap(Lib.call(g, "type")), state = Lib.unwrap(Lib.call(g, "groupState"));
                    out.add(new String[]{ String.valueOf(Lib.call(g, "groupId")), lower(type, "classic"), lower(state, "unknown") });
                }
                return out;
            }
            // Before Kafka 4's library: consumer groups only, by the call 4.x marks for removal.
            Object old = Lib.call(admin(), "listConsumerGroups");
            if (old == null) { Jmx.say("the groups: this Kafka library cannot list them"); return out; }
            @SuppressWarnings("unchecked") KafkaFuture<Collection<Object>> f = (KafkaFuture<Collection<Object>>) Lib.call(old, "all");
            Collection<Object> all = maybe(f, "the groups");
            if (all == null) return out;
            for (Object g : all) {
                Object type = Lib.unwrap(Lib.call(g, "type")), state = Lib.unwrap(Lib.call(g, "groupState"));
                if (state == null) state = Lib.unwrap(Lib.call(g, "state"));
                out.add(new String[]{ String.valueOf(Lib.call(g, "groupId")), lower(type, "classic"), lower(state, "unknown") });
            }
            return out;
        }

        static String lower(Object o, String d) {
            if (o == null) return d;
            return o.toString().toLowerCase(Locale.ROOT).replace('_', '-');
        }

        static void consumers() {
            List<String[]> groups = listGroups();
            Map<String, Map<TopicPartition, OffsetAndMetadata>> committed = new TreeMap<>();
            for (String[] g : groups) {
                if (!g[1].equals("classic") && !g[1].equals("consumer")) continue;
                Map<TopicPartition, OffsetAndMetadata> o = maybe(admin().listConsumerGroupOffsets(g[0]).partitionsToOffsetAndMetadata(), "the offsets of group " + g[0]);
                if (o != null && !o.isEmpty()) committed.put(g[0], o);
            }
            Set<TopicPartition> tps = new HashSet<>();
            Set<String> topicsSeen = new TreeSet<>();
            for (Map<TopicPartition, OffsetAndMetadata> o : committed.values()) for (TopicPartition tp : o.keySet()) topicsSeen.add(tp.topic());
            Map<String, TopicDescription> ds = new TreeMap<>();
            if (!topicsSeen.isEmpty()) {
                Map<String, TopicDescription> got = maybe(admin().describeTopics(topicsSeen).allTopicNames(), "the groups' topics");
                if (got != null) ds.putAll(got);
            }
            for (TopicDescription d : ds.values()) for (TopicPartitionInfo p : d.partitions()) tps.add(new TopicPartition(d.name(), p.partition()));
            Map<TopicPartition, Long> ends = offsets(tps, OffsetSpec.latest(), "the topics' ends");
            metric("groups", committed.size());
            long total = 0;
            int pairs = 0, shown = 0;
            for (Map.Entry<String, Map<TopicPartition, OffsetAndMetadata>> g : committed.entrySet()) {
                Map<String, long[]> byTopic = new TreeMap<>();
                Set<String> mine = new TreeSet<>();
                for (TopicPartition tp : g.getValue().keySet()) mine.add(tp.topic());
                for (String t : mine) {
                    long[] x = new long[3];
                    TopicDescription d = ds.get(t);
                    if (d == null) continue;
                    for (TopicPartitionInfo p : d.partitions()) {
                        TopicPartition tp = new TopicPartition(t, p.partition());
                        OffsetAndMetadata om = g.getValue().get(tp);
                        Long end = ends.get(tp);
                        if (om == null) { x[2]++; continue; }
                        if (end == null) continue;
                        long lag = Math.max(0, end - om.offset());
                        x[0] += lag;
                        x[1] = Math.max(x[1], lag);
                    }
                    byTopic.put(t, x);
                }
                long groupLag = 0;
                for (Map.Entry<String, long[]> e : byTopic.entrySet()) {
                    groupLag += e.getValue()[0];
                    pairs++;
                    if (++shown > GROUP_CAP) continue;
                    metric("lag", e.getValue()[0], "group", g.getKey(), "topic", e.getKey());
                    metric("lag_max", e.getValue()[1], "group", g.getKey(), "topic", e.getKey());
                    if (e.getValue()[2] > 0) metric("no_offset_partitions", e.getValue()[2], "group", g.getKey(), "topic", e.getKey());
                }
                total += groupLag;
                lagOf.put(g.getKey(), groupLag);
            }
            metric("total_lag", total);
            if (pairs > GROUP_CAP) metric("pairs_not_shown", pairs - GROUP_CAP);
            int n = 0;
            for (Map.Entry<String, Long> e : lagOf.entrySet()) if (++n <= GROUP_CAP) metric("group_lag", e.getValue(), "group", e.getKey());
        }

        static final Map<String, Long> lagOf = new TreeMap<>();

        static void groups() {
            List<String[]> groups = listGroups();
            Map<String, Integer> byTypeState = new TreeMap<>();
            int rebalancing = 0, empty = 0, dead = 0;
            for (String[] g : groups) {
                byTypeState.merge(g[1] + "\t" + g[2], 1, Integer::sum);
                if (g[2].contains("rebalance") || g[2].equals("assigning") || g[2].equals("reconciling")) rebalancing++;
                if (g[2].equals("empty")) empty++;
                if (g[2].equals("dead")) dead++;
            }
            metric("all_groups", groups.size());
            Map<String, Integer> members = new TreeMap<>();
            List<String> consumerIds = new ArrayList<>();
            for (String[] g : groups) if (g[1].equals("classic") || g[1].equals("consumer")) consumerIds.add(g[0]);
            if (!consumerIds.isEmpty()) {
                Map<String, ConsumerGroupDescription> d = maybe(admin().describeConsumerGroups(consumerIds).all(), "the groups' members");
                if (d != null) for (Map.Entry<String, ConsumerGroupDescription> e : d.entrySet()) members.put(e.getKey(), e.getValue().members().size());
            }
            int all = 0;
            for (int m : members.values()) all += m;
            metric("all_members", all);
            metric("rebalancing", rebalancing);
            metric("empty", empty);
            metric("dead", dead);
            for (Map.Entry<String, Integer> e : byTypeState.entrySet()) {
                String[] k = e.getKey().split("\t");
                metric("groups", e.getValue(), "type", k[0], "state", k[1]);
            }
            int n = 0;
            for (String[] g : groups) {
                Integer m = members.get(g[0]);
                if (m == null) continue;
                if (++n > GROUP_CAP) break;
                metric("members", m, "group", g[0], "type", g[1]);
            }
            if (groups.size() > GROUP_CAP) metric("groups_not_shown", groups.size() - GROUP_CAP);
        }

        // Is the disk all right?

        static void topics() {
            Map<String, TopicDescription> ts = KafkaClient.topics();
            Map<String, Map<String, String>> cfg = topicConfigs("cleanup.policy");
            int internal = 0, rf1 = 0, compacted = 0;
            for (TopicDescription d : ts.values()) {
                boolean in = d.isInternal() || d.name().startsWith("__");
                if (in) internal++;
                else if (!d.partitions().isEmpty() && d.partitions().get(0).replicas().size() == 1) rf1++;
                if (cfg.getOrDefault(d.name(), Collections.emptyMap()).getOrDefault("cleanup.policy", "").contains("compact")) compacted++;
            }
            metric("topics", ts.size());
            metric("internal_topics", internal);
            metric("rf1_topics", rf1);
            metric("compacted_topics", compacted);
            List<TopicDescription> shown = new ArrayList<>();
            for (TopicDescription d : ts.values()) if (shown.size() < TOPIC_CAP) shown.add(d);
            List<TopicPartition> tps = partitions(shown);
            Map<TopicPartition, Long> ends = offsets(tps, OffsetSpec.latest(), "the topics' ends"), starts = offsets(tps, OffsetSpec.earliest(), "the topics' starts");
            for (TopicDescription d : shown) {
                long written = 0, held = 0;
                boolean known = true;
                for (TopicPartitionInfo p : d.partitions()) {
                    TopicPartition tp = new TopicPartition(d.name(), p.partition());
                    Long e = ends.get(tp), s = starts.get(tp);
                    if (e == null || s == null) { known = false; continue; }
                    written += e;
                    held += Math.max(0, e - s);
                }
                metric("partitions", d.partitions().size(), "topic", d.name());
                metric("replication_factor", d.partitions().isEmpty() ? 0 : d.partitions().get(0).replicas().size(), "topic", d.name());
                if (known) {
                    metric("messages_count", written, "topic", d.name());
                    metric("retained_messages", held, "topic", d.name());
                }
            }
            if (ts.size() > TOPIC_CAP) metric("topics_not_shown", ts.size() - TOPIC_CAP);
        }

        static void logdirs() {
            List<Integer> ids = new ArrayList<>();
            for (Node n : nodes()) ids.add(n.id());
            Map<Integer, Map<String, LogDirDescription>> all = get(admin().describeLogDirs(ids).allDescriptions(), "the log directories");
            int dirs = 0, off = 0;
            Map<String, Long> topicSize = new TreeMap<>();
            for (Map.Entry<Integer, Map<String, LogDirDescription>> b : new TreeMap<>(all).entrySet()) {
                String broker = Integer.toString(b.getKey());
                long brokerSize = 0;
                for (Map.Entry<String, LogDirDescription> e : new TreeMap<>(b.getValue()).entrySet()) {
                    LogDirDescription d = e.getValue();
                    long size = 0;
                    int parts = 0, future = 0;
                    for (Map.Entry<TopicPartition, ReplicaInfo> r : d.replicaInfos().entrySet()) {
                        size += r.getValue().size();
                        parts++;
                        if (r.getValue().isFuture()) future++;
                        topicSize.merge(r.getKey().topic(), r.getValue().size(), Long::sum);
                    }
                    brokerSize += size;
                    dirs++;
                    boolean bad = d.error() != null;
                    if (bad) off++;
                    metric("size_bytes", size, "broker", broker, "dir", e.getKey());
                    metric("partitions", parts, "broker", broker, "dir", e.getKey());
                    metric("offline", bad, "broker", broker, "dir", e.getKey());
                    metric("future_replicas", future, "broker", broker, "dir", e.getKey());
                }
                metric("broker_size_bytes", brokerSize, "broker", broker);
            }
            metric("dirs", dirs);
            metric("dirs_offline", off);
            int n = 0;
            for (Map.Entry<String, Long> e : topicSize.entrySet()) if (++n <= TOPIC_CAP) metric("topic_size_bytes", e.getValue(), "topic", e.getKey());
            if (topicSize.size() > TOPIC_CAP) metric("topics_not_shown", topicSize.size() - TOPIC_CAP);
            // From each broker's own figures: tiered storage, flushes and the log cleaner.
            List<Jmx.Row> rows = Arrays.asList(
                    Jmx.row("remote_size_bytes", "kafka.server:type=BrokerTopicMetrics,name=RemoteLogSizeBytes", "Value"),
                    Jmx.row("remote_copy_lag_bytes", "kafka.server:type=BrokerTopicMetrics,name=RemoteCopyLagBytes", "Value"),
                    Jmx.row("flush_ms_p99", "kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs", "99thPercentile"),
                    Jmx.row("flushes_count", "kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs", "Count"),
                    Jmx.row("cleaner_max_dirty_pct", "kafka.log:type=LogCleanerManager,name=max-dirty-percent", "Value"),
                    Jmx.row("cleaner_idle_seconds", "kafka.log:type=LogCleaner,name=time-since-last-run-ms", "Value").scale(0.001).atLeast(0),
                    Jmx.row("cleaner_dead_threads", "kafka.log:type=LogCleaner,name=DeadThreadCount", "Value"),
                    Jmx.row("cleaner_max_clean_seconds", "kafka.log:type=LogCleaner,name=max-clean-time-secs", "Value").atLeast(0));
            jmxTable(rows);
        }

        // Is it fast, or saturated?

        static void throughput() {
            String[][] m = {
                    { "messages_in_count", "MessagesInPerSec" }, { "bytes_in_count", "BytesInPerSec" },
                    { "bytes_out_count", "BytesOutPerSec" }, { "bytes_rejected_count", "BytesRejectedPerSec" },
                    { "replication_bytes_in_count", "ReplicationBytesInPerSec" }, { "replication_bytes_out_count", "ReplicationBytesOutPerSec" },
                    { "produce_requests_count", "TotalProduceRequestsPerSec" }, { "fetch_requests_count", "TotalFetchRequestsPerSec" },
                    { "failed_produce_requests_count", "FailedProduceRequestsPerSec" }, { "failed_fetch_requests_count", "FailedFetchRequestsPerSec" },
                    { "produce_conversions_count", "ProduceMessageConversionsPerSec" }, { "fetch_conversions_count", "FetchMessageConversionsPerSec" },
                    { "invalid_crc_records_count", "InvalidMessageCrcRecordsPerSec" }, { "invalid_sequence_records_count", "InvalidOffsetOrSequenceRecordsPerSec" } };
            List<Jmx.Row> rows = new ArrayList<>();
            for (String[] x : m) rows.add(Jmx.row(x[0], "kafka.server:type=BrokerTopicMetrics,name=" + x[1], "Count"));
            jmxTable(rows);
        }

        static void requests() {
            List<Jmx.Row> rows = new ArrayList<>();
            for (String r : new String[]{ "Produce", "FetchConsumer", "FetchFollower" }) {
                String base = "kafka.network:type=RequestMetrics,name=";
                rows.add(Jmx.row("total_ms_p99", base + "TotalTimeMs,request=" + r, "99thPercentile", "request"));
                rows.add(Jmx.row("queue_ms_p99", base + "RequestQueueTimeMs,request=" + r, "99thPercentile", "request"));
                rows.add(Jmx.row("remote_ms_p99", base + "RemoteTimeMs,request=" + r, "99thPercentile", "request"));
                rows.add(Jmx.row("requests_count", base + "TotalTimeMs,request=" + r, "Count", "request"));
            }
            rows.add(Jmx.row("request_queue", "kafka.network:type=RequestChannel,name=RequestQueueSize", "Value"));
            rows.add(Jmx.row("response_queue", "kafka.network:type=RequestChannel,name=ResponseQueueSize", "Value"));
            rows.add(Jmx.row("purgatory", "kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Produce", "Value").with("operation", "produce"));
            rows.add(Jmx.row("purgatory", "kafka.server:type=DelayedOperationPurgatory,name=PurgatorySize,delayedOperation=Fetch", "Value").with("operation", "fetch"));
            // The idle shares are fractions, 0 to 1: as percents.
            rows.add(Jmx.row("handler_idle_pct", "kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent", "OneMinuteRate").scale(100));
            rows.add(Jmx.row("network_idle_pct", "kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent", "Value").scale(100));
            jmxTable(rows);
        }

        static void connections() {
            String[][] m = { { "connections", "connection-count" }, { "created_count", "connection-creation-total" },
                    { "logins_count", "successful-authentication-total" }, { "failed_logins_count", "failed-authentication-total" },
                    { "failed_relogins_count", "failed-reauthentication-total" } };
            for (Jmx.Target t : jmx()) {
                if (t.mbs() == null) continue;
                // Each listener's network processors, added up.
                Map<String, double[]> byListener = new TreeMap<>();
                for (ObjectName o : Jmx.query(t.mbs(), "kafka.server:type=socket-server-metrics,listener=*,networkProcessor=*")) {
                    double[] sum = byListener.computeIfAbsent(o.getKeyProperty("listener"), k -> new double[m.length]);
                    for (int i = 0; i < m.length; i++) {
                        Number v = Jmx.number(Jmx.attr(t.mbs(), o.toString(), m[i][1]), null);
                        if (v != null) sum[i] += v.doubleValue();
                    }
                }
                for (Map.Entry<String, double[]> e : byListener.entrySet()) {
                    for (int i = 0; i < m.length; i++) {
                        String[] tags = broker(t);
                        String[] all = Arrays.copyOf(tags, tags.length + 2);
                        all[tags.length] = "listener";
                        all[tags.length + 1] = e.getKey();
                        metric(m[i][0], e.getValue()[i], all);
                    }
                }
            }
        }

        // What is stuck?

        static void reassignment() {
            Map<TopicPartition, PartitionReassignment> moving = get(admin().listPartitionReassignments().reassignments(), "partition moves");
            int adding = 0, removing = 0;
            Map<String, Integer> byTopic = new TreeMap<>();
            for (Map.Entry<TopicPartition, PartitionReassignment> e : moving.entrySet()) {
                adding += e.getValue().addingReplicas().size();
                removing += e.getValue().removingReplicas().size();
                byTopic.merge(e.getKey().topic(), 1, Integer::sum);
            }
            metric("partitions", moving.size());
            metric("adding_replicas", adding);
            metric("removing_replicas", removing);
            metric("topics", byTopic.size());
            int n = 0;
            for (Map.Entry<String, Integer> e : byTopic.entrySet()) if (++n <= TOPIC_CAP) metric("topic_partitions", e.getValue(), "topic", e.getKey());
        }

        static void transactions() {
            Collection<TransactionListing> all = maybe(admin().listTransactions().all(), "the transactions");
            if (all == null) return;
            Map<String, Integer> byState = new TreeMap<>();
            List<String> open = new ArrayList<>();
            for (TransactionListing t : all) {
                String s = t.state().toString().toLowerCase(Locale.ROOT).replace("_", "");
                byState.merge(s, 1, Integer::sum);
                if (s.equals("ongoing")) open.add(t.transactionalId());
            }
            metric("all_transactions", all.size());
            for (Map.Entry<String, Integer> e : byState.entrySet()) metric("transactions", e.getValue(), "state", e.getKey());
            metric("ongoing", open.size());
            long limit = intOr(env("KAFKA_TXN_LONG").isEmpty() ? "300" : env("KAFKA_TXN_LONG"), 300) * 1000L;
            int longRunning = 0;
            if (!open.isEmpty()) {
                Map<String, TransactionDescription> d = maybe(admin().describeTransactions(open).all(), "the open transactions");
                long now = System.currentTimeMillis();
                if (d != null) for (TransactionDescription t : d.values()) {
                    long started = l(Lib.call(t, "transactionStartTimeMs"));
                    if (started > 0 && now - started > limit) longRunning++;
                }
            }
            metric("long_running", longRunning);
        }

        // What is risky?

        static void config() {
            Map<Integer, Map<String, String>> b = brokerConfigs();
            if (b.isEmpty()) return;
            Map<String, String> c = b.values().iterator().next();
            metric("unclean_leader_election", "true".equals(c.get("unclean.leader.election.enable")));
            metric("auto_create_topics", "true".equals(c.get("auto.create.topics.enable")));
            metric("auto_leader_rebalance", "true".equals(c.get("auto.leader.rebalance.enable")));
            String auth = c.getOrDefault("authorizer.class.name", "");
            metric("authorizer", !auth.isEmpty());
            for (String[] k : new String[][]{ { "min_insync_replicas", "min.insync.replicas" }, { "default_replication_factor", "default.replication.factor" },
                    { "offsets_replication_factor", "offsets.topic.replication.factor" }, { "transactions_replication_factor", "transaction.state.log.replication.factor" },
                    { "message_max_bytes", "message.max.bytes" } }) {
                if (c.containsKey(k[1])) metric(k[0], intOr(c.get(k[1]), -1));
            }
            metric("retention_hours", retentionHours(c));
            metric("plaintext_listeners", plaintextListeners(c));
            // Settings that differ between brokers, apart from those that must.
            Set<String> own = new HashSet<>(Arrays.asList("broker.id", "node.id", "listeners", "advertised.listeners", "broker.rack",
                    "log.dirs", "log.dir", "metadata.log.dir", "ssl.keystore.location", "ssl.truststore.location"));
            int differ = 0;
            Set<String> keys = new TreeSet<>();
            for (Map<String, String> m : b.values()) keys.addAll(m.keySet());
            for (String k : keys) {
                if (own.contains(k) || k.contains("password")) continue;
                Set<String> vals = new HashSet<>();
                for (Map<String, String> m : b.values()) vals.add(m.get(k));
                if (vals.size() > 1) differ++;
            }
            metric("settings_differ", differ);
            Map<String, Map<String, String>> t = topicConfigs("unclean.leader.election.enable", "min.insync.replicas");
            Map<String, TopicDescription> ds = KafkaClient.topics();
            int unclean = 0, minGeRf = 0, min1 = 0;
            for (Map.Entry<String, Map<String, String>> e : t.entrySet()) {
                if ("true".equals(e.getValue().get("unclean.leader.election.enable"))) unclean++;
                TopicDescription d = ds.get(e.getKey());
                if (d == null || d.partitions().isEmpty()) continue;
                int rf = d.partitions().get(0).replicas().size(), min = intOr(e.getValue().getOrDefault("min.insync.replicas", "1"), 1);
                if (rf > 1 && min >= rf) minGeRf++;
                if (rf >= 3 && min == 1) min1++;
            }
            metric("topics_unclean_election", unclean);
            metric("topics_min_isr_ge_rf", minGeRf);
            metric("topics_min_isr_1", min1);
        }

        static double retentionHours(Map<String, String> c) {
            if (c.containsKey("log.retention.ms")) { long v = longOr(c.get("log.retention.ms"), -1); return v < 0 ? -1 : v / 3600000.0; }
            if (c.containsKey("log.retention.minutes")) { long v = longOr(c.get("log.retention.minutes"), -1); return v < 0 ? -1 : v / 60.0; }
            return intOr(c.getOrDefault("log.retention.hours", "168"), 168);
        }

        static int plaintextListeners(Map<String, String> c) {
            Map<String, String> map = new HashMap<>();
            for (String p : c.getOrDefault("listener.security.protocol.map", "").split(",")) {
                int i = p.indexOf(':');
                if (i > 0) map.put(p.substring(0, i).trim().toUpperCase(Locale.ROOT), p.substring(i + 1).trim().toUpperCase(Locale.ROOT));
            }
            Set<String> controllers = new HashSet<>();
            for (String n : c.getOrDefault("controller.listener.names", "").split(",")) if (!n.trim().isEmpty()) controllers.add(n.trim().toUpperCase(Locale.ROOT));
            int plain = 0;
            for (String l : c.getOrDefault("listeners", "").split(",")) {
                int i = l.indexOf("://");
                if (i <= 0) continue;
                String name = l.substring(0, i).trim().toUpperCase(Locale.ROOT);
                if (controllers.contains(name)) continue;
                if ("PLAINTEXT".equals(map.getOrDefault(name, name))) plain++;
            }
            return plain;
        }

        static void security() {
            Collection<AclBinding> acls = null;
            try {
                acls = admin().describeAcls(AclBindingFilter.ANY).values().get(WAIT, TimeUnit.SECONDS);
            } catch (ExecutionException e) {
                if (e.getCause() instanceof SecurityDisabledException) { metric("authorizer", 0); }
                else throw stop(e.getCause(), "the ACLs");
            } catch (Exception e) {
                throw stop(e, "the ACLs");
            }
            if (acls != null) {
                metric("authorizer", 1);
                metric("all_acls", acls.size());
                int anyone = 0, everything = 0;
                Map<String, Integer> by = new TreeMap<>();
                for (AclBinding a : acls) {
                    if ("User:*".equals(a.entry().principal())) anyone++;
                    if (a.entry().operation() == AclOperation.ALL) everything++;
                    by.merge(a.pattern().resourceType().toString().toLowerCase(Locale.ROOT) + "\t" + a.entry().permissionType().toString().toLowerCase(Locale.ROOT), 1, Integer::sum);
                }
                metric("any_principal_acls", anyone);
                metric("all_operations_acls", everything);
                for (Map.Entry<String, Integer> e : by.entrySet()) {
                    String[] k = e.getKey().split("\t");
                    metric("acls", e.getValue(), "resource", k[0], "permission", k[1]);
                }
            }
            Map<String, UserScramCredentialsDescription> scram = maybe(admin().describeUserScramCredentials().all(), "the SCRAM users");
            if (scram != null) metric("scram_users", scram.size());
            Map<ClientQuotaEntity, Map<String, Double>> q = maybe(admin().describeClientQuotas(ClientQuotaFilter.all()).entities(), "the quotas");
            if (q != null) {
                Map<String, Integer> by = new TreeMap<>();
                for (ClientQuotaEntity e : q.keySet()) {
                    for (String type : e.entries().keySet()) by.merge(type.equals(ClientQuotaEntity.USER) ? "user" : type.equals(ClientQuotaEntity.CLIENT_ID) ? "client" : type, 1, Integer::sum);
                }
                for (Map.Entry<String, Integer> e : by.entrySet()) metric("quotas", e.getValue(), "entity", e.getKey());
            }
        }

        static void features() {
            FeatureMetadata f = get(admin().describeFeatures().featureMetadata(), "the features");
            Map<String, FinalizedVersionRange> fin = f.finalizedFeatures();
            Map<String, SupportedVersionRange> sup = f.supportedFeatures();
            int behind = 0;
            Set<String> names = new TreeSet<>(fin.keySet());
            names.addAll(sup.keySet());
            for (String n : names) {
                FinalizedVersionRange a = fin.get(n);
                SupportedVersionRange s = sup.get(n);
                if (n.equals("metadata.version") && a != null) {
                    metric("metadata_version", 1, "version", metadataVersion(a.maxVersionLevel()), "supported", s == null ? "none" : metadataVersion(s.maxVersion()));
                }
                if (a != null) metric("level", a.maxVersionLevel(), "feature", n);
                if (s != null) metric("supported_level", s.maxVersion(), "feature", n);
                boolean b = a != null && s != null && a.maxVersionLevel() < s.maxVersion();
                if (a != null && s != null) metric("behind", b, "feature", n);
                if (b) behind++;
            }
            metric("features", names.size());
            metric("features_behind", behind);
        }

        /** metadata.version's level as Kafka names it (3.9-IV0), when Kafka's server library is there; else the level. */
        static String metadataVersion(short level) {
            try {
                Class<?> mv = Class.forName("org.apache.kafka.server.common.MetadataVersion");
                Object v = mv.getMethod("fromFeatureLevel", short.class).invoke(null, level);
                return String.valueOf(v.getClass().getMethod("version").invoke(v));
            } catch (Throwable e) {
                return Short.toString(level);
            }
        }

        /**
         * Each broker's certificate, read in a TLS handshake whether it is
         * trusted or not, to say how long it has; then checked, its chain
         * against KAFKA_CACERT or Java's CAs, and its name. Nothing is sent.
         */
        static void tls() {
            Collection<Node> ns = nodes();
            boolean tls = protocol.endsWith("SSL");
            metric("tls", tls);
            if (!tls) return;
            List<String> eps = new ArrayList<>();
            for (Node n : ns) eps.add(n.host() + ":" + n.port());
            Collections.sort(eps);
            metric("endpoints", eps.size());
            X509TrustManager trust;
            try { trust = trustManager(); } catch (Exception e) { Jmx.fail("KAFKA_CACERT: " + Jmx.rootMessage(e)); return; }
            for (String ep : eps) {
                X509Certificate[] chain = certificate(ep);
                metric("reachable", chain != null, "endpoint", ep);
                if (chain == null) continue;
                long days = Math.floorDiv(chain[0].getNotAfter().getTime() - System.currentTimeMillis(), 86400000L);
                metric("expires_days", days, "endpoint", ep);
                boolean ok;
                try {
                    trust.checkServerTrusted(chain, "RSA".equals(chain[0].getPublicKey().getAlgorithm()) ? "ECDHE_RSA" : "ECDHE_ECDSA");
                    Jmx.checkName(chain[0], ep.substring(0, ep.lastIndexOf(':')));
                    ok = true;
                } catch (CertificateException e) {
                    ok = false;
                    Jmx.say(ep + ": " + Jmx.rootMessage(e));
                }
                metric("trusted", ok, "endpoint", ep);
            }
        }

        static X509TrustManager trustManager() throws Exception {
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            String ca = env("KAFKA_CACERT");
            if (ca.isEmpty()) {
                tmf.init((KeyStore) null);
            } else {
                KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
                ks.load(null, null);
                int i = 0;
                try (InputStream in = new FileInputStream(ca)) {
                    for (java.security.cert.Certificate c : CertificateFactory.getInstance("X.509").generateCertificates(in)) ks.setCertificateEntry("ca" + i++, c);
                }
                if (i == 0) throw new IOException(ca + " holds no certificate");
                tmf.init(ks);
            }
            for (TrustManager m : tmf.getTrustManagers()) if (m instanceof X509TrustManager) return (X509TrustManager) m;
            throw new IOException("no trust manager");
        }

        /** The chain a broker shows in a handshake, trusted or not; null when it gives none (said). */
        static X509Certificate[] certificate(String ep) {
            final X509Certificate[][] seen = new X509Certificate[1][];
            try {
                SSLContext ctx = SSLContext.getInstance("TLS");
                // Only looks: records the chain, and the handshake goes on; nothing is sent after it.
                ctx.init(null, new TrustManager[]{ new X509TrustManager() {
                    public void checkClientTrusted(X509Certificate[] c, String a) throws CertificateException { throw new CertificateException("not a server"); }
                    public void checkServerTrusted(X509Certificate[] c, String a) { seen[0] = c; }
                    public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                } }, null);
                int i = ep.lastIndexOf(':');
                try (Socket raw = new Socket()) {
                    raw.connect(new InetSocketAddress(ep.substring(0, i), Integer.parseInt(ep.substring(i + 1))), 10000);
                    raw.setSoTimeout(10000);
                    try (SSLSocket s = (SSLSocket) ctx.getSocketFactory().createSocket(raw, ep.substring(0, i), Integer.parseInt(ep.substring(i + 1)), false)) {
                        s.startHandshake();
                    }
                }
            } catch (Exception e) {
                if (seen[0] == null) Jmx.say(ep + ": no certificate: " + Jmx.rootMessage(e));
            }
            return seen[0];
        }
    }

    // ---- JMX, through the shared engine ----------------------------------------------------

    static List<Jmx.Target> jmxTargets = new ArrayList<>();
    static boolean jmxRead;

    /** The brokers' JMX targets, each named by its broker id once connected. */
    static List<Jmx.Target> jmx() {
        if (jmxRead) return jmxTargets;
        jmxRead = true;
        jmxTargets = Jmx.targets("KAFKA_JMX");
        if (jmxTargets.isEmpty()) Jmx.say("no KAFKA_JMX: the brokers' own figures are not read (each broker's JMX, jmx=host:port or jmxs=host:port)");
        for (Jmx.Target t : jmxTargets) {
            if (t.mbs() != null) {
                for (ObjectName o : Jmx.query(t.mbs(), "kafka.server:type=app-info,id=*")) t.name = o.getKeyProperty("id");
            }
            metric("jmx_up", t.mbs() != null, "broker", t.name, "jmx", t.address);
        }
        return jmxTargets;
    }

    static String[] broker(Jmx.Target t) { return new String[]{ "broker", t.name, "jmx", t.address }; }

    static void jmxTable(List<Jmx.Row> rows) {
        for (Jmx.Target t : jmx()) Jmx.table(t, rows, broker(t));
    }
}

// ---- the shared JMX engine, tools/jmx/Jmx.java (tools/jmx/DESIGN.md), as
// it is in the repository: every Java application pack carries the same copy.
final class Jmx {

    private Jmx() { }

    // ---- the run: output, messages, exit code -------------------------------

    /** The job, for messages. */
    static String job = "jmx";
    static final PrintStream OUT = new PrintStream(new FileOutputStream(FileDescriptor.out), false);
    /** 0, or 1 once fail was called. */
    static int exitCode = 0;
    /** The most of one list a run prints; the rest are counted. */
    static final int LIST_CAP = 100;

    /** A tag's value: no spaces, control characters or quotes, never empty. */
    static String tag(String v) {
        if (v == null) return "none";
        String s = v.replaceAll("['\"`]", "").replaceAll("[\\s\\p{Cntrl}]", "_");
        if (s.length() > 120) s = s.substring(0, 120);
        return s.isEmpty() ? "none" : s;
    }

    /** A number as a metric value: no exponent, at most 4 decimals; null when it is none. */
    static String num(double v) {
        if (Double.isNaN(v) || Double.isInfinite(v)) return null;
        if (v == Math.rint(v) && Math.abs(v) < 1e15) return Long.toString((long) v);
        String s = String.format(Locale.ROOT, "%.4f", v);
        s = s.replaceAll("0+$", "");
        return s.endsWith(".") ? s.substring(0, s.length() - 1) : s;
    }

    /** metric <name> <value> <tag>=<value>...; nothing when v is not a number. */
    static void metric(String name, Number v, String... tags) {
        if (v == null) return;
        String n = num(v.doubleValue());
        if (n == null) return;
        StringBuilder b = new StringBuilder("metric ").append(name).append(' ').append(n);
        for (int i = 0; i + 1 < tags.length; i += 2) b.append(' ').append(tags[i]).append('=').append(tag(tags[i + 1]));
        OUT.println(b);
    }

    static void metric(String name, boolean v, String... tags) { metric(name, v ? 1 : 0, tags); }

    static void say(String msg) {
        OUT.flush();
        System.err.println(job + ": " + msg);
    }

    /** Says why, and makes the run fail (exit 1), after what could be printed. */
    static void fail(String msg) {
        say(msg);
        exitCode = 1;
    }

    static String env(String k) {
        String v = System.getenv(k);
        return v == null ? "" : v.trim();
    }

    /** The innermost message of t and its causes, on one line. */
    static String rootMessage(Throwable t) {
        String m = String.valueOf(t);
        for (; t != null; t = t.getCause()) if (t.getMessage() != null) m = t.getClass().getSimpleName() + ": " + t.getMessage();
        m = m.replaceAll("[\\r\\n]+", " ");
        return m.length() > 300 ? m.substring(0, 300) : m;
    }

    static boolean hasCause(Throwable t, Class<?> c) {
        for (; t != null; t = t.getCause()) if (c.isInstance(t)) return true;
        return false;
    }

    // ---- settings, named by the pack ------------------------------------------

    static String userVar = "JMX_USER", passwordVar = "JMX_PASSWORD", cacertVar = "JMX_CACERT";

    /** The names of the pack's settings: the JMX user, its password (a secret), the CA file. */
    static void settings(String user, String password, String cacert) {
        userVar = user;
        passwordVar = password;
        cacertVar = cacert;
    }

    // ---- targets ----------------------------------------------------------------

    static final class Target {
        /** host:port. */
        final String address;
        final boolean tls;
        /** What the application says it is, once known; else its address. */
        String name;
        JMXConnector conn;
        MBeanServerConnection mbs;
        boolean tried;

        Target(String address, boolean tls) {
            this.address = address;
            this.tls = tls;
            this.name = address;
        }

        /** Its MBean server, connecting the first time; null when it cannot be had (said why). */
        MBeanServerConnection mbs() {
            if (!tried) {
                tried = true;
                mbs = connect(this);
            }
            return mbs;
        }

        void close() {
            if (conn != null) try { conn.close(); } catch (Exception e) { /* gone already */ }
            conn = null;
            mbs = null;
        }
    }

    /**
     * The targets in setting var: jmx=host:port or jmxs=host:port (TLS),
     * separated by ; or , and a bare host:port as jmx=. Empty: none.
     */
    static List<Target> targets(String var) {
        List<Target> ts = new ArrayList<>();
        for (String part : env(var).split("[;,]")) {
            String p = part.trim();
            if (p.isEmpty()) continue;
            boolean tls = false;
            if (p.startsWith("jmxs=")) { tls = true; p = p.substring(5).trim(); }
            else if (p.startsWith("jmx=")) p = p.substring(4).trim();
            if (!p.matches("[^\\s:=]+:[0-9]{1,5}") && !p.matches("\\[[0-9A-Fa-f:.]+\\]:[0-9]{1,5}")) {
                throw new IllegalArgumentException(var + ": not jmx=host:port or jmxs=host:port: " + part.trim());
            }
            ts.add(new Target(p, tls));
        }
        return ts;
    }

    static void closeAll(List<Target> ts) {
        for (Target t : ts) t.close();
    }

    /** jmx_up 1 or 0 for t, with its tags. */
    static void up(Target t, String... tags) {
        metric("jmx_up", t.mbs() != null, tags);
    }

    // ---- connecting ---------------------------------------------------------------

    static boolean timeoutsSet;

    /** Connects to t: its MBean server, or null, saying why (and failing the run for a refused login or certificate). */
    static MBeanServerConnection connect(Target t) {
        if (!timeoutsSet) {
            // Every remote call gives up in time: the run is not left hanging.
            System.setProperty("sun.rmi.transport.connectionTimeout", "10000");
            System.setProperty("sun.rmi.transport.tcp.responseTimeout", "20000");
            System.setProperty("sun.rmi.transport.tcp.handshakeTimeout", "10000");
            timeoutsSet = true;
        }
        String url = "service:jmx:rmi:///jndi/rmi://" + t.address + "/jmxrmi";
        Map<String, Object> envm = new HashMap<>();
        String user = env(userVar), pw = env(passwordVar);
        if (!user.isEmpty() || !pw.isEmpty()) envm.put(JMXConnector.CREDENTIALS, new String[]{ user, pw });
        if (t.tls) {
            try { tls(); } catch (Exception e) { fail(cacertVar + ": " + e.getMessage()); return null; }
            envm.put("com.sun.jndi.rmi.factory.socket", new SslRMIClientSocketFactory());
        }
        ExecutorService ex = Executors.newSingleThreadExecutor(r -> { Thread th = new Thread(r); th.setDaemon(true); return th; });
        try {
            Future<JMXConnector> f = ex.submit(() -> JMXConnectorFactory.connect(new JMXServiceURL(url), envm));
            t.conn = f.get(30, TimeUnit.SECONDS);
            return t.conn.getMBeanServerConnection();
        } catch (java.util.concurrent.TimeoutException e) {
            say("JMX at " + t.address + " did not answer in 30 seconds");
        } catch (IOException e) {
            say("JMX at " + t.address + " does not answer: " + rootMessage(e));
        } catch (ExecutionException e) {
            Throwable c = e.getCause();
            String why = rootMessage(c);
            if (c instanceof SecurityException || why.contains("Authentication failed") || why.contains("Invalid credentials")
                    || why.contains("Credentials required")) {
                fail("JMX at " + t.address + " refused the login: " + why + " (" + userVar + ", and the secret behind " + passwordVar + ")");
            } else if (hasCause(c, CertificateException.class) || why.contains("PKIX") || why.contains("certificate")) {
                fail("JMX at " + t.address + ": its certificate is not trusted, or does not name it: " + why + " (" + cacertVar + ")");
            } else if (t.tls && hasCause(c, SSLException.class)) {
                fail("JMX at " + t.address + " does not speak TLS: " + why + " (jmxs= is for JMX over TLS, jmx= for plain)");
            } else {
                say("JMX at " + t.address + " does not answer: " + why);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            ex.shutdownNow();
        }
        return null;
    }

    static boolean tlsReady;

    /** TLS that checks the chain and the name: the pack's CAs, or Java's own. */
    static void tls() throws Exception {
        if (tlsReady) return;
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        String ca = env(cacertVar);
        if (ca.isEmpty()) {
            tmf.init((KeyStore) null);
        } else {
            KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
            ks.load(null, null);
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            int i = 0;
            try (InputStream in = new FileInputStream(ca)) {
                for (java.security.cert.Certificate c : cf.generateCertificates(in)) ks.setCertificateEntry("ca" + i++, c);
            }
            if (i == 0) throw new IOException(ca + " holds no certificate");
            tmf.init(ks);
        }
        X509TrustManager inner = null;
        for (TrustManager m : tmf.getTrustManagers()) if (m instanceof X509TrustManager) inner = (X509TrustManager) m;
        final X509TrustManager chain = inner;
        X509ExtendedTrustManager named = new X509ExtendedTrustManager() {
            public void checkServerTrusted(X509Certificate[] c, String a, Socket s) throws CertificateException {
                chain.checkServerTrusted(c, a);
                String host = s.getInetAddress() == null ? null : hostOf(s);
                if (host != null) checkName(c[0], host);
            }
            public void checkServerTrusted(X509Certificate[] c, String a, SSLEngine e) throws CertificateException {
                chain.checkServerTrusted(c, a);
                if (e.getPeerHost() != null) checkName(c[0], e.getPeerHost());
            }
            public void checkServerTrusted(X509Certificate[] c, String a) throws CertificateException {
                // No socket, no name to check: refused.
                throw new CertificateException("no host to check the certificate's name against");
            }
            public void checkClientTrusted(X509Certificate[] c, String a, Socket s) throws CertificateException { throw new CertificateException("not a server"); }
            public void checkClientTrusted(X509Certificate[] c, String a, SSLEngine e) throws CertificateException { throw new CertificateException("not a server"); }
            public void checkClientTrusted(X509Certificate[] c, String a) throws CertificateException { throw new CertificateException("not a server"); }
            public X509Certificate[] getAcceptedIssuers() { return chain.getAcceptedIssuers(); }
        };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[]{ named }, null);
        SSLContext.setDefault(ctx);
        tlsReady = true;
    }

    /** The name the socket was opened to, else its address. */
    static String hostOf(Socket s) {
        if (s instanceof SSLSocket) {
            SSLSession hs = ((SSLSocket) s).getHandshakeSession();
            if (hs != null && hs.getPeerHost() != null) return hs.getPeerHost();
        }
        return s.getInetAddress().getHostAddress();
    }

    /** The certificate names host, as a DNS name (a wildcard for one label) or an IP address. */
    static void checkName(X509Certificate c, String host) throws CertificateException {
        String h = host.toLowerCase(Locale.ROOT).replace("[", "").replace("]", "");
        boolean ip = h.matches("[0-9.]+") || h.contains(":");
        Collection<List<?>> sans = c.getSubjectAlternativeNames();
        if (sans != null) {
            for (List<?> san : sans) {
                int kind = (Integer) san.get(0);
                String v = String.valueOf(san.get(1)).toLowerCase(Locale.ROOT);
                if (ip && kind == 7) {
                    try {
                        if (InetAddress.getByName(v).equals(InetAddress.getByName(h))) return;
                    } catch (UnknownHostException e) { /* not this one */ }
                } else if (!ip && kind == 2) {
                    if (v.equals(h)) return;
                    if (v.startsWith("*.") && h.indexOf('.') > 0 && h.substring(h.indexOf('.')).equals(v.substring(1))) return;
                }
            }
        }
        throw new CertificateException("the certificate does not name " + host);
    }

    // ---- reading ------------------------------------------------------------------

    static ObjectName on(String s) {
        try { return new ObjectName(s); } catch (MalformedObjectNameException e) { throw new IllegalArgumentException(e); }
    }

    /** An attribute, or null when the MBean or the attribute is not there. */
    static Object attr(MBeanServerConnection m, String name, String a) {
        try { return m.getAttribute(on(name), a); } catch (Exception e) { return null; }
    }

    /** The MBeans matching a pattern, in order; none when there are none. */
    static SortedSet<ObjectName> query(MBeanServerConnection m, String pattern) {
        try { return new TreeSet<>(m.queryNames(on(pattern), null)); } catch (Exception e) { return new TreeSet<>(); }
    }

    /** A number from an attribute's value: itself, or key k of a composite one. */
    static Number number(Object v, String k) {
        if (k != null) {
            if (!(v instanceof CompositeData)) return null;
            CompositeData c = (CompositeData) v;
            if (!c.containsKey(k)) return null;
            v = c.get(k);
        }
        if (v instanceof Number) return (Number) v;
        if (v instanceof Boolean) return ((Boolean) v) ? 1 : 0;
        return null;
    }

    // ---- tables -------------------------------------------------------------------

    /** One row of a table: an MBean's attribute as a metric. */
    static final class Row {
        final String metric, pattern, attribute, key;
        final String[] tags;
        double scale = 1;

        Row(String metric, String pattern, String attribute, String[] tags) {
            this.metric = metric;
            this.pattern = pattern;
            int dot = attribute.indexOf('.');
            this.attribute = dot < 0 ? attribute : attribute.substring(0, dot);
            this.key = dot < 0 ? null : attribute.substring(dot + 1);
            this.tags = tags;
        }

        /** Fixed tags, after the MBean's own: name, value, ... */
        String[] fixed = new String[0];
        /** A value below this is no reading (a figure not yet measured): not printed. */
        double floor = Double.NEGATIVE_INFINITY;

        /** Its value times s: 0.001 for ns to µs, 100 for a fraction to a percent. */
        Row scale(double s) {
            scale = s;
            return this;
        }

        /** Values below f are not printed: -1 for "never", or worse. */
        Row atLeast(double f) {
            floor = f;
            return this;
        }

        /** Tags of its own, the same for every MBean it reads: name, value, ... */
        Row with(String... tags) {
            fixed = tags;
            return this;
        }
    }

    /**
     * A row: metric, from the MBeans matching pattern, attribute (or
     * attribute.key of a composite one), tagged with the MBean's own keys
     * named in tags.
     */
    static Row row(String metric, String pattern, String attribute, String... tags) {
        return new Row(metric, pattern, attribute, tags);
    }

    /**
     * Prints the rows for target t: every MBean each matches, its value,
     * tagged with tags first and then the MBean's own keys. An MBean that is
     * not there prints nothing; one pattern's MBeans past LIST_CAP are
     * counted in <metric>_not_shown. One round trip for each MBean, every
     * attribute its rows want at once.
     */
    static void table(Target t, List<Row> rows, String... tags) {
        MBeanServerConnection m = t.mbs();
        if (m == null) return;
        Map<String, SortedSet<ObjectName>> found = new HashMap<>();
        Map<ObjectName, Set<String>> wanted = new LinkedHashMap<>();
        for (Row r : rows) {
            SortedSet<ObjectName> names = found.computeIfAbsent(r.pattern, p -> on(p).isPattern() ? query(m, p) : exists(m, p));
            int n = 0;
            for (ObjectName o : names) {
                if (++n > LIST_CAP) break;
                wanted.computeIfAbsent(o, x -> new LinkedHashSet<>()).add(r.attribute);
            }
        }
        Map<ObjectName, Map<String, Object>> values = new HashMap<>();
        for (Map.Entry<ObjectName, Set<String>> e : wanted.entrySet()) {
            Map<String, Object> got = new HashMap<>();
            try {
                for (Object o : m.getAttributes(e.getKey(), e.getValue().toArray(new String[0]))) {
                    javax.management.Attribute a = (javax.management.Attribute) o;
                    got.put(a.getName(), a.getValue());
                }
            } catch (Exception x) { /* gone since the query: nothing */ }
            values.put(e.getKey(), got);
        }
        for (Row r : rows) {
            SortedSet<ObjectName> names = found.get(r.pattern);
            int n = 0;
            for (ObjectName o : names) {
                if (++n > LIST_CAP) break;
                Number v = number(values.getOrDefault(o, Collections.emptyMap()).get(r.attribute), r.key);
                if (v == null || v.doubleValue() < r.floor) continue;
                String[] all = Arrays.copyOf(tags, tags.length + 2 * r.tags.length + r.fixed.length);
                for (int i = 0; i < r.tags.length; i++) {
                    all[tags.length + 2 * i] = r.tags[i];
                    all[tags.length + 2 * i + 1] = o.getKeyProperty(r.tags[i]);
                }
                System.arraycopy(r.fixed, 0, all, tags.length + 2 * r.tags.length, r.fixed.length);
                metric(r.metric, r.scale == 1 ? v : v.doubleValue() * r.scale, all);
            }
            if (names.size() > LIST_CAP) metric(r.metric + "_not_shown", names.size() - LIST_CAP, tags);
        }
    }

    /** The one MBean named, or none. */
    static SortedSet<ObjectName> exists(MBeanServerConnection m, String name) {
        SortedSet<ObjectName> s = new TreeSet<>();
        try { if (m.isRegistered(on(name))) s.add(on(name)); } catch (Exception e) { /* not there */ }
        return s;
    }
}
