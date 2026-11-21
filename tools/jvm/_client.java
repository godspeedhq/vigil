// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// _client.java - the jvm pack's client: every job of the pack, on every
// platform, run with the JDK's source launcher (java _client.java <job>), so
// each prints the same lines on Linux, macOS and Windows. Readable, nothing
// compiled to ship. JDK 11 or later runs it; the JVMs it watches may be any
// from Java 8.
//
// It reaches each JVM in up to three tiers, and uses each that reaches it:
//   1. the operating system: the process (no setup)
//   2. the JVM's own counters: its hsperfdata file (the same machine, and the
//      account that runs it, or root or an administrator)
//   3. JMX, at the address given for it (local or remote)
// It only reads. Nothing here pauses a JVM: no heap dump, no class histogram,
// no thread dump with stacks.
//
// Settings, in the environment (the job's env and secret lines):
//   JVM_TARGETS       the JVMs: name: key=value, ...; name: ... (empty: every
//                     JVM on this machine, named by its main class). Keys:
//                     main=<its main class or jar, or any text on its command
//                     line>, pid=<pid file>,
//                     jmx=<host:port>, jmxs=<host:port> (JMX over TLS),
//                     gclog=<the JVM's GC log>
//   JVM_JMX_USER      the JMX user, when JMX asks for one
//   JVM_JMX_PASSWORD  its password (a secret line: never on a command line)
//   JVM_CACERT        a PEM file of CAs for jmxs (else Java's own)
//   JVM_MBEANS        jvm_mbeans: object name/attribute; ... to report
//   JVM_DUMP_DIRS     more folders to look in for heap dumps and crash reports
//   JVM_PROCS_FILE    Windows: the process table the PowerShell script read

import java.io.*;
import java.lang.management.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.security.KeyStore;
import java.security.cert.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.*;
import javax.management.*;
import javax.management.openmbean.*;
import javax.management.remote.*;
import javax.net.ssl.*;
import javax.rmi.ssl.SslRMIClientSocketFactory;

class JvmClient {

    static String job = "jvm";
    static final PrintStream OUT = new PrintStream(new FileOutputStream(FileDescriptor.out), false);
    static int exitCode = 0;
    static final int LIST_CAP = 50;
    static final long DAY = 86400;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) { System.err.println("usage: java _client.java <job>"); System.exit(2); }
        job = args[0];
        // Every remote call gives up in time: the run is not left hanging.
        System.setProperty("sun.rmi.transport.connectionTimeout", "10000");
        System.setProperty("sun.rmi.transport.tcp.responseTimeout", "20000");
        System.setProperty("sun.rmi.transport.tcp.handshakeTimeout", "10000");
        List<Target> targets;
        try {
            targets = Targets.resolve();
        } catch (IllegalArgumentException e) {
            fail(e.getMessage());
            System.exit(1);
            return;
        }
        Job j = JOBS.get(job.startsWith("jvm_") ? job.substring(4) : job);
        if (j == null) { fail("no such job: " + job); System.exit(1); return; }
        // How many JVMs the job looked at: with none here, that is its reading.
        if (!job.endsWith("discovery")) metric("jvms", targets.size(), null);
        try {
            j.run(targets);
        } finally {
            for (Target t : targets) t.close();
            OUT.flush();
        }
        System.exit(exitCode);
    }

    // ---- output ---------------------------------------------------------

    /** A tag's value: no spaces, control characters or quotes, never empty. */
    static String tag(String v) {
        if (v == null) return "none";
        String s = v.replaceAll("['\"`]", "").replaceAll("[\\s\\p{Cntrl}]", "_");
        if (s.length() > 120) s = s.substring(0, 120);
        return s.isEmpty() ? "none" : s;
    }

    /** A number as a metric value: no exponent, at most 4 decimals. */
    static String num(double v) {
        if (Double.isNaN(v) || Double.isInfinite(v)) return null;
        if (v == Math.rint(v) && Math.abs(v) < 1e15) return Long.toString((long) v);
        String s = String.format(Locale.ROOT, "%.4f", v);
        s = s.replaceAll("0+$", "");
        return s.endsWith(".") ? s.substring(0, s.length() - 1) : s;
    }

    static void metric(String name, Number v, Target t, String... tags) {
        if (v == null) return;
        String n = num(v.doubleValue());
        if (n == null) return;
        StringBuilder b = new StringBuilder("metric ").append(name).append(' ').append(n);
        if (t != null) b.append(" jvm=").append(tag(t.name));
        for (int i = 0; i + 1 < tags.length; i += 2) b.append(' ').append(tags[i]).append('=').append(tag(tags[i + 1]));
        OUT.println(b);
    }

    static void metric(String name, boolean v, Target t, String... tags) { metric(name, v ? 1 : 0, t, tags); }

    static void say(String msg) { System.err.println(job + ": " + msg); }

    /** Says why, and makes the run fail (exit 1), after what could be printed. */
    static void fail(String msg) {
        say(msg);
        exitCode = 1;
    }

    // ---- targets --------------------------------------------------------

    static final class Target {
        String name, main, pidFile, jmx, gclog;
        boolean tls;
        Proc proc;                 // tier 1, when it runs here
        Perf perf;                 // tier 2
        boolean perfTried;
        JMXConnector conn;         // tier 3
        MBeanServerConnection mbs;
        boolean jmxTried;
        Target(String name) { this.name = name; }

        /** The JVM's counters (tier 2), or null. */
        Perf perf() {
            if (!perfTried) {
                perfTried = true;
                if (proc != null) perf = Perf.find(proc);
            }
            return perf;
        }

        /** The JVM's MBean server (tier 3), or null; says jmx_up when it has an address. */
        MBeanServerConnection jmx() {
            if (jmxTried) return mbs;
            jmxTried = true;
            if (jmx == null) return null;
            mbs = Jmx.connect(this);
            metric("jmx_up", mbs != null, this);
            return mbs;
        }

        boolean hasJmx() { return jmx != null; }

        void close() {
            if (conn != null) try { conn.close(); } catch (Exception e) { /* gone */ }
        }
    }

    static final class Targets {
        static List<Target> resolve() throws Exception {
            String spec = env("JVM_TARGETS");
            List<Target> ts = new ArrayList<>();
            List<Proc> procs = null;
            if (spec.trim().isEmpty()) {
                // Every JVM here, named by its main class.
                procs = Procs.list();
                Map<String, Integer> seen = new HashMap<>();
                for (Proc p : procs) {
                    if (ts.size() >= LIST_CAP) break;
                    String base = p.main == null || p.main.isEmpty() ? "pid" + p.pid : shortName(p.main);
                    int n = seen.merge(base, 1, Integer::sum);
                    Target t = new Target(n == 1 ? base : base + "-" + n);
                    t.proc = p;
                    ts.add(t);
                }
                return ts;
            }
            for (String entry : spec.split(";")) {
                entry = entry.trim();
                if (entry.isEmpty()) continue;
                int c = entry.indexOf(':');
                String name = (c < 0 ? entry : entry.substring(0, c)).trim();
                if (!name.matches("[A-Za-z0-9_.-]+"))
                    throw new IllegalArgumentException("JVM_TARGETS: '" + name + "' is not a name (letters, digits, _ . -): name: key=value, ...; ...");
                Target t = new Target(name);
                if (c >= 0) {
                    for (String kv : entry.substring(c + 1).split(",")) {
                        kv = kv.trim();
                        if (kv.isEmpty()) continue;
                        int e = kv.indexOf('=');
                        if (e < 0) throw new IllegalArgumentException("JVM_TARGETS: " + name + ": '" + kv + "' is not key=value");
                        String k = kv.substring(0, e).trim(), v = kv.substring(e + 1).trim();
                        switch (k) {
                            case "main": t.main = v; break;
                            case "pid": t.pidFile = v; break;
                            case "jmx": t.jmx = v; t.tls = false; break;
                            case "jmxs": t.jmx = v; t.tls = true; break;
                            case "gclog": t.gclog = v; break;
                            default: throw new IllegalArgumentException("JVM_TARGETS: " + name + ": no key '" + k + "' (main, pid, jmx, jmxs, gclog)");
                        }
                    }
                }
                if (t.main == null && t.pidFile == null && t.jmx == null)
                    throw new IllegalArgumentException("JVM_TARGETS: " + name + ": say how to find it: main=, pid= or jmx=");
                if (t.jmx != null && !t.jmx.matches(".+:[0-9]+"))
                    throw new IllegalArgumentException("JVM_TARGETS: " + name + ": " + (t.tls ? "jmxs" : "jmx") + "=" + t.jmx + " is not host:port");
                ts.add(t);
            }
            // Each one found here, by its pid file or its main class.
            for (Target t : ts) {
                if (t.pidFile != null) {
                    try {
                        long pid = Long.parseLong(new String(Files.readAllBytes(Paths.get(t.pidFile)), StandardCharsets.UTF_8).trim());
                        if (procs == null) procs = Procs.list();
                        for (Proc p : procs) if (p.pid == pid) t.proc = p;
                    } catch (IOException | NumberFormatException e) { /* not running, or no file: not found */ }
                } else if (t.main != null) {
                    if (procs == null) procs = Procs.list();
                    for (Proc p : procs) {
                        if (p.matches(t.main)) { t.proc = p; break; }
                    }
                }
            }
            return ts;
        }

        /** A JVM's own pid, from JMX, links a JMX-only JVM on this machine to its process. */
        static void linkByJmx(Target t) {
            if (t.proc != null || t.mbs == null || !isLocal(t.jmx)) return;
            try {
                Object name = t.mbs.getAttribute(new ObjectName("java.lang:type=Runtime"), "Name");
                String s = String.valueOf(name);
                long pid = Long.parseLong(s.substring(0, s.indexOf('@')));
                for (Proc p : Procs.list()) if (p.pid == pid) t.proc = p;
            } catch (Exception e) { /* not here */ }
        }

        static boolean isLocal(String hostPort) {
            String h = hostPort.substring(0, hostPort.lastIndexOf(':')).replace("[", "").replace("]", "");
            if (h.equals("localhost") || h.startsWith("127.") || h.equals("::1")) return true;
            try {
                InetAddress a = InetAddress.getByName(h);
                return a.isLoopbackAddress() || NetworkInterface.getByInetAddress(a) != null;
            } catch (Exception e) { return false; }
        }
    }

    static String shortName(String main) {
        String s = main.replace('\\', '/');
        s = s.substring(s.lastIndexOf('/') + 1);
        // A jar, or a source file run as it is (java Shop.java): its name.
        if (s.endsWith(".jar")) s = s.substring(0, s.length() - 4);
        else if (s.endsWith(".java")) s = s.substring(0, s.length() - 5);
        else if (s.contains(".") && !s.endsWith(".")) s = s.substring(s.lastIndexOf('.') + 1);
        s = s.replaceAll("[^A-Za-z0-9_.-]", "_");
        return s.isEmpty() ? "jvm" : s;
    }

    static String env(String k) {
        String v = System.getenv(k);
        return v == null ? "" : v;
    }

    // ---- tier 1: the operating system --------------------------------------

    static final class Proc {
        long pid = -1;
        long uid = -1;
        String user, main;
        List<String> args = new ArrayList<>();
        Long rss, vsz, threads, fds, fdMax, readBytes, writeBytes;
        Double cpuSeconds;
        Long startEpoch;
        long nspid = -1;           // its pid inside its container (Linux)
        boolean inContainer;

        boolean matches(String m) {
            if (main != null && main.contains(m)) return true;
            for (String a : args) if (a.contains(m)) return true;
            return false;
        }

        /** The value of -XX:name=value, -Dname=value or the like, last one wins. */
        String opt(String prefix) {
            String v = null;
            for (String a : args) if (a.startsWith(prefix)) v = a.substring(prefix.length());
            return v;
        }

        boolean flag(String name) {
            Boolean v = null;
            for (String a : args) {
                if (a.equals("-XX:+" + name)) v = true;
                else if (a.equals("-XX:-" + name)) v = false;
            }
            return v != null && v;
        }

        boolean has(String prefix) {
            for (String a : args) if (a.startsWith(prefix)) return true;
            return false;
        }
    }

    static final class Procs {
        static List<Proc> cached;

        static List<Proc> list() throws Exception {
            if (cached != null) return cached;
            String os = System.getProperty("os.name").toLowerCase(Locale.ROOT);
            List<Proc> l;
            if (os.contains("windows")) l = windows();
            else if (os.contains("mac")) l = mac();
            else l = linux();
            long self = ProcessHandle.current().pid();
            l.removeIf(p -> p.pid == self);
            l.sort(Comparator.comparingLong(p -> p.pid));
            cached = l;
            return l;
        }

        static boolean isJava(String argv0) {
            String b = argv0.replace('\\', '/');
            b = b.substring(b.lastIndexOf('/') + 1).toLowerCase(Locale.ROOT);
            return b.equals("java") || b.equals("java.exe") || b.equals("javaw") || b.equals("javaw.exe");
        }

        /** The main class or jar in a java command line. */
        static String mainOf(List<String> args) {
            for (int i = 1; i < args.size(); i++) {
                String a = args.get(i);
                if (a.equals("-jar") && i + 1 < args.size()) return args.get(i + 1);
                if (a.equals("-m") || a.equals("--module")) return i + 1 < args.size() ? args.get(i + 1) : null;
                if (a.startsWith("--module=")) return a.substring(9);
                if (a.equals("-cp") || a.equals("-classpath") || a.equals("--class-path") || a.equals("-p")
                        || a.equals("--module-path") || a.equals("--add-modules") || a.equals("--add-opens")
                        || a.equals("--add-exports") || a.equals("--add-reads") || a.equals("--patch-module")
                        || a.equals("--upgrade-module-path") || a.equals("--limit-modules")) { i++; continue; }
                if (a.startsWith("-")) continue;
                return a;
            }
            return null;
        }

        static List<Proc> linux() throws IOException {
            List<Proc> l = new ArrayList<>();
            long hz = 100, boot = 0;
            try {
                for (String s : Files.readAllLines(Paths.get("/proc/stat"))) if (s.startsWith("btime ")) boot = Long.parseLong(s.substring(6).trim());
            } catch (IOException e) { /* no boot time */ }
            long page = 4096;
            File[] ds = new File("/proc").listFiles((d, n) -> n.matches("[0-9]+"));
            if (ds == null) return l;
            for (File d : ds) {
                byte[] raw;
                try { raw = Files.readAllBytes(d.toPath().resolve("cmdline")); } catch (IOException e) { continue; }
                if (raw.length == 0) continue;
                List<String> args = new ArrayList<>();
                int s = 0;
                for (int i = 0; i < raw.length; i++) if (raw[i] == 0) { args.add(new String(raw, s, i - s, StandardCharsets.UTF_8)); s = i + 1; }
                if (s < raw.length) args.add(new String(raw, s, raw.length - s, StandardCharsets.UTF_8));
                if (args.isEmpty() || !isJava(args.get(0))) continue;
                Proc p = new Proc();
                p.pid = Long.parseLong(d.getName());
                p.args = args;
                p.main = mainOf(args);
                try {
                    for (String line : Files.readAllLines(d.toPath().resolve("status"))) {
                        String[] f = line.split("\\s+");
                        if (line.startsWith("Uid:")) p.uid = Long.parseLong(f[1]);
                        else if (line.startsWith("VmRSS:")) p.rss = Long.parseLong(f[1]) * 1024;
                        else if (line.startsWith("VmSize:")) p.vsz = Long.parseLong(f[1]) * 1024;
                        else if (line.startsWith("Threads:")) p.threads = Long.parseLong(f[1]);
                        else if (line.startsWith("NSpid:")) {
                            p.nspid = Long.parseLong(f[f.length - 1]);
                            p.inContainer = f.length > 2;
                        }
                    }
                } catch (IOException | RuntimeException e) { /* gone */ }
                try {
                    String st = new String(Files.readAllBytes(d.toPath().resolve("stat")), StandardCharsets.UTF_8);
                    String[] f = st.substring(st.lastIndexOf(')') + 2).split(" ");
                    p.cpuSeconds = (Long.parseLong(f[11]) + Long.parseLong(f[12])) / (double) hz;
                    if (boot > 0) p.startEpoch = boot + Long.parseLong(f[19]) / hz;
                } catch (IOException | RuntimeException e) { /* gone */ }
                try {
                    String[] fd = d.toPath().resolve("fd").toFile().list();
                    if (fd != null) p.fds = (long) fd.length;
                } catch (SecurityException e) { /* not ours */ }
                try {
                    for (String line : Files.readAllLines(d.toPath().resolve("limits"))) {
                        if (line.startsWith("Max open files")) {
                            String v = line.substring(26).trim().split("\\s+")[0];
                            if (v.matches("[0-9]+")) p.fdMax = Long.parseLong(v);
                        }
                    }
                } catch (IOException e) { /* not ours */ }
                try {
                    for (String line : Files.readAllLines(d.toPath().resolve("io"))) {
                        if (line.startsWith("read_bytes:")) p.readBytes = Long.parseLong(line.substring(11).trim());
                        else if (line.startsWith("write_bytes:")) p.writeBytes = Long.parseLong(line.substring(12).trim());
                    }
                } catch (IOException | RuntimeException e) { /* not ours */ }
                if (p.uid >= 0) p.user = userName(p.uid);
                l.add(p);
            }
            return l;
        }

        static Map<Long, String> users;

        static String userName(long uid) {
            if (users == null) {
                users = new HashMap<>();
                try {
                    for (String line : Files.readAllLines(Paths.get("/etc/passwd"))) {
                        String[] f = line.split(":");
                        if (f.length > 2 && f[2].matches("[0-9]+")) users.putIfAbsent(Long.parseLong(f[2]), f[0]);
                    }
                } catch (IOException e) { /* by number */ }
            }
            return users.getOrDefault(uid, Long.toString(uid));
        }

        static List<Proc> mac() throws Exception {
            List<Proc> l = new ArrayList<>();
            Process ps = new ProcessBuilder("ps", "-axww", "-o", "pid=,uid=,user=,rss=,vsz=,time=,etime=,args=").redirectErrorStream(false).start();
            ps.getOutputStream().close();
            BufferedReader r = new BufferedReader(new InputStreamReader(ps.getInputStream(), StandardCharsets.UTF_8));
            long now = Instant.now().getEpochSecond();
            String line;
            while ((line = r.readLine()) != null) {
                String[] f = line.trim().split("\\s+", 8);
                if (f.length < 8) continue;
                List<String> args = new ArrayList<>(Arrays.asList(f[7].split(" ")));
                if (args.isEmpty() || !isJava(args.get(0))) continue;
                Proc p = new Proc();
                try {
                    p.pid = Long.parseLong(f[0]);
                    p.uid = Long.parseLong(f[1]);
                    p.user = f[2];
                    p.rss = Long.parseLong(f[3]) * 1024;
                    p.vsz = Long.parseLong(f[4]) * 1024;
                    p.cpuSeconds = clock(f[5]);
                    Double el = clock(f[6]);
                    if (el != null) p.startEpoch = now - el.longValue();
                } catch (NumberFormatException e) { continue; }
                p.args = args;
                p.main = mainOf(args);
                l.add(p);
            }
            ps.waitFor(10, TimeUnit.SECONDS);
            return l;
        }

        /** ps's [[dd-]hh:]mm:ss[.ss], in seconds. */
        static Double clock(String s) {
            try {
                long days = 0;
                int dash = s.indexOf('-');
                if (dash > 0) { days = Long.parseLong(s.substring(0, dash)); s = s.substring(dash + 1); }
                String[] f = s.split(":");
                double v = 0;
                for (String x : f) v = v * 60 + Double.parseDouble(x);
                return v + days * DAY;
            } catch (RuntimeException e) { return null; }
        }

        /** Windows: the table the PowerShell script read, one process a line, tab-separated. */
        static List<Proc> windows() throws IOException {
            List<Proc> l = new ArrayList<>();
            String f = env("JVM_PROCS_FILE");
            if (f.isEmpty()) return l;
            for (String line : Files.readAllLines(Paths.get(f), StandardCharsets.UTF_8)) {
                String[] c = line.split("\t", -1);
                if (c.length < 11) continue;
                Proc p = new Proc();
                try {
                    p.pid = Long.parseLong(c[0]);
                    p.user = c[1].isEmpty() ? null : c[1];
                    p.rss = longOrNull(c[3]);
                    p.vsz = longOrNull(c[4]);
                    p.threads = longOrNull(c[5]);
                    p.fds = longOrNull(c[6]);
                    Long cpu = longOrNull(c[7]);
                    if (cpu != null) p.cpuSeconds = cpu / 1e7;
                    p.startEpoch = longOrNull(c[8]);
                    p.readBytes = longOrNull(c[9]);
                    p.writeBytes = longOrNull(c[10]);
                } catch (NumberFormatException e) { continue; }
                p.args = winArgs(c[2]);
                if (p.args.isEmpty()) continue;
                p.main = mainOf(p.args);
                l.add(p);
            }
            return l;
        }

        static Long longOrNull(String s) {
            s = s.trim();
            return s.isEmpty() ? null : Long.valueOf(s);
        }

        /** A Windows command line, split as the C runtime splits it. */
        static List<String> winArgs(String cmd) {
            List<String> out = new ArrayList<>();
            StringBuilder cur = new StringBuilder();
            boolean quoted = false, any = false;
            for (int i = 0; i < cmd.length(); i++) {
                char ch = cmd.charAt(i);
                if (ch == '\\') {
                    int n = 0;
                    while (i < cmd.length() && cmd.charAt(i) == '\\') { n++; i++; }
                    if (i < cmd.length() && cmd.charAt(i) == '"') {
                        for (int k = 0; k < n / 2; k++) cur.append('\\');
                        if (n % 2 == 1) { cur.append('"'); }
                        else { quoted = !quoted; }
                        any = true;
                    } else {
                        for (int k = 0; k < n; k++) cur.append('\\');
                        i--;
                    }
                    any = true;
                } else if (ch == '"') { quoted = !quoted; any = true; }
                else if ((ch == ' ' || ch == '\t') && !quoted) {
                    if (any) { out.add(cur.toString()); cur.setLength(0); any = false; }
                } else { cur.append(ch); any = true; }
            }
            if (any) out.add(cur.toString());
            return out;
        }
    }

    // ---- tier 2: the JVM's own counters (hsperfdata) ------------------------

    static final class Perf {
        final Map<String, Object> v = new LinkedHashMap<>();
        double hz = 1e9;

        Long l(String k) {
            Object o = v.get(k);
            return o instanceof Long ? (Long) o : null;
        }

        String s(String k) {
            Object o = v.get(k);
            return o instanceof String ? (String) o : null;
        }

        /** A counter in ticks, in seconds. */
        Double sec(String k) {
            Long t = l(k);
            return t == null ? null : t / hz;
        }

        /** The names under a prefix, such as sun.gc.collector.0. */
        List<String> under(String prefix) {
            List<String> r = new ArrayList<>();
            for (String k : v.keySet()) if (k.startsWith(prefix)) r.add(k);
            return r;
        }

        /** The file of process p, where HotSpot keeps it, if this account may read it. */
        static Perf find(Proc p) {
            String id = Long.toString(p.pid);
            List<Path> tries = new ArrayList<>();
            String os = System.getProperty("os.name").toLowerCase(Locale.ROOT);
            try {
                if (os.contains("windows")) {
                    for (String root : new String[]{ "C:\\Users", "C:\\Windows\\ServiceProfiles" }) {
                        File[] us = new File(root).listFiles();
                        if (us != null) for (File u : us) dirs(tries, new File(u, "AppData\\Local\\Temp"), id);
                    }
                    dirs(tries, new File("C:\\Windows\\Temp"), id);
                    dirs(tries, new File("C:\\Windows\\System32\\config\\systemprofile\\AppData\\Local\\Temp"), id);
                } else if (os.contains("mac")) {
                    // Each account's temporary folder: /var/folders/xx/yyyy/T.
                    File[] a = new File("/var/folders").listFiles();
                    if (a != null) for (File x : a) {
                        File[] b = x.listFiles();
                        if (b != null) for (File y : b) dirs(tries, new File(y, "T"), id);
                    }
                    dirs(tries, new File("/tmp"), id);
                } else {
                    // Through the process's own root: a JVM in a container keeps
                    // it in the container's /tmp, under its pid there.
                    String ns = p.nspid > 0 ? Long.toString(p.nspid) : id;
                    dirs(tries, new File("/proc/" + id + "/root/tmp"), ns);
                    dirs(tries, new File("/tmp"), id);
                }
            } catch (SecurityException e) { /* not ours to look in */ }
            for (Path f : tries) {
                try {
                    Perf perf = parse(Files.readAllBytes(f));
                    if (perf != null) return perf;
                } catch (IOException | RuntimeException e) { /* not ours to read */ }
            }
            return null;
        }

        static void dirs(List<Path> tries, File tmp, String id) {
            File[] hs = tmp.listFiles((d, n) -> n.startsWith("hsperfdata_"));
            if (hs == null) return;
            for (File h : hs) {
                File f = new File(h, id);
                if (f.isFile()) tries.add(f.toPath());
            }
        }

        /** HotSpot's PerfData memory: a prologue, then entries of longs and strings. */
        static Perf parse(byte[] b) {
            if (b.length < 32) return null;
            ByteBuffer bb = ByteBuffer.wrap(b);
            int magic = bb.getInt(0);
            if (magic != 0xcafec0c0 && magic != 0xc0c0feca) return null;
            bb.order(b[4] == 0 ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN);
            int major = b[5];
            if (major != 2) return null;
            if (b[7] == 0) return null;  // not accessible yet
            int entryOffset = bb.getInt(24);
            int numEntries = bb.getInt(28);
            Perf perf = new Perf();
            int off = entryOffset;
            for (int i = 0; i < numEntries && off + 20 <= b.length; i++) {
                int len = bb.getInt(off);
                if (len <= 0 || off + len > b.length) break;
                int nameOff = bb.getInt(off + 4);
                int vecLen = bb.getInt(off + 8);
                byte type = b[off + 12];
                int dataOff = bb.getInt(off + 16);
                int n0 = off + nameOff, n1 = n0;
                while (n1 < b.length && b[n1] != 0) n1++;
                String name = new String(b, n0, n1 - n0, StandardCharsets.US_ASCII);
                int d = off + dataOff;
                if (type == 'J' && vecLen == 0 && d + 8 <= b.length) perf.v.put(name, bb.getLong(d));
                else if (type == 'B' && vecLen > 0 && d + vecLen <= b.length) {
                    int e = d;
                    while (e < d + vecLen && b[e] != 0) e++;
                    perf.v.put(name, new String(b, d, e - d, StandardCharsets.UTF_8));
                }
                off += len;
            }
            Long f = perf.l("sun.os.hrt.frequency");
            if (f != null && f > 0) perf.hz = f;
            return perf;
        }
    }

    // ---- tier 3: JMX ------------------------------------------------------

    static final class Jmx {
        static boolean tlsReady;

        static MBeanServerConnection connect(Target t) {
            String url = "service:jmx:rmi:///jndi/rmi://" + t.jmx + "/jmxrmi";
            Map<String, Object> envm = new HashMap<>();
            String user = env("JVM_JMX_USER"), pw = env("JVM_JMX_PASSWORD");
            if (!user.isEmpty() || !pw.isEmpty()) envm.put(JMXConnector.CREDENTIALS, new String[]{ user, pw });
            if (t.tls) {
                try { tls(); } catch (Exception e) { fail("JVM_CACERT: " + e.getMessage()); return null; }
                envm.put("com.sun.jndi.rmi.factory.socket", new SslRMIClientSocketFactory());
            }
            ExecutorService ex = Executors.newSingleThreadExecutor(r -> { Thread th = new Thread(r); th.setDaemon(true); return th; });
            try {
                Future<JMXConnector> f = ex.submit(() -> JMXConnectorFactory.connect(new JMXServiceURL(url), envm));
                t.conn = f.get(30, TimeUnit.SECONDS);
                MBeanServerConnection m = t.conn.getMBeanServerConnection();
                t.mbs = m;
                Targets.linkByJmx(t);
                return m;
            } catch (TimeoutException e) {
                say(t.name + ": JMX at " + t.jmx + " did not answer in 30 seconds");
            } catch (IOException e) {
                say(t.name + ": JMX at " + t.jmx + " does not answer: " + rootMessage(e));
            } catch (ExecutionException e) {
                Throwable c = e.getCause();
                String why = rootMessage(c);
                if (c instanceof SecurityException || why.contains("Authentication failed") || why.contains("Invalid credentials")
                        || why.contains("Credentials required")) {
                    fail(t.name + ": JMX at " + t.jmx + " refused the login: " + why + " (JVM_JMX_USER, and the secret behind JVM_JMX_PASSWORD)");
                } else if (hasCause(c, SSLHandshakeException.class) || hasCause(c, CertificateException.class)
                        || why.contains("PKIX") || why.contains("certificate")) {
                    fail(t.name + ": JMX at " + t.jmx + ": its certificate is not trusted, or does not name it: " + why + " (JVM_CACERT)");
                } else {
                    say(t.name + ": JMX at " + t.jmx + " does not answer: " + why);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } finally {
                ex.shutdownNow();
            }
            return null;
        }

        static boolean hasCause(Throwable t, Class<?> c) {
            for (; t != null; t = t.getCause()) if (c.isInstance(t)) return true;
            return false;
        }

        static String rootMessage(Throwable t) {
            String m = String.valueOf(t);
            for (; t != null; t = t.getCause()) if (t.getMessage() != null) m = t.getClass().getSimpleName() + ": " + t.getMessage();
            m = m.replaceAll("[\\r\\n]+", " ");
            return m.length() > 300 ? m.substring(0, 300) : m;
        }

        /** TLS that checks the chain and the name: JVM_CACERT's CAs, or Java's own. */
        static void tls() throws Exception {
            if (tlsReady) return;
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            String ca = env("JVM_CACERT");
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
            InetAddress a = s.getInetAddress();
            return a.getHostAddress();
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
    }

    // ---- JMX helpers ------------------------------------------------------

    static ObjectName on(String s) {
        try { return new ObjectName(s); } catch (MalformedObjectNameException e) { throw new IllegalArgumentException(e); }
    }

    static Object attr(MBeanServerConnection m, String name, String a) {
        try { return m.getAttribute(on(name), a); } catch (Exception e) { return null; }
    }

    static Long attrL(MBeanServerConnection m, String name, String a) {
        Object o = attr(m, name, a);
        return o instanceof Number ? ((Number) o).longValue() : null;
    }

    static Double attrD(MBeanServerConnection m, String name, String a) {
        Object o = attr(m, name, a);
        return o instanceof Number ? ((Number) o).doubleValue() : null;
    }

    static Long cd(Object o, String k) {
        if (!(o instanceof CompositeData)) return null;
        CompositeData c = (CompositeData) o;
        if (!c.containsKey(k)) return null;
        Object v = c.get(k);
        return v instanceof Number ? ((Number) v).longValue() : null;
    }

    static Set<ObjectName> query(MBeanServerConnection m, String pattern) {
        try { return new TreeSet<>(m.queryNames(on(pattern), null)); } catch (Exception e) { return Collections.emptySet(); }
    }

    static boolean saidReadonly;

    /**
     * An operation, such as findDeadlockedThreads. A JMX user with readonly
     * access may read attributes but not run operations: said once, so the
     * job's log tells why it printed less.
     */
    static Object invoke(MBeanServerConnection m, String name, String op, Object[] args, String[] sig) {
        try {
            return m.invoke(on(name), op, args, sig);
        } catch (SecurityException e) {
            if (!saidReadonly) {
                saidReadonly = true;
                say("the JMX user may only read attributes (readonly): " + op + " is an operation, which needs readwrite access ("
                        + "packs/README.md): " + e.getMessage());
            }
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    /** A diagnostic command, such as vmNativeMemory, as its text; null where there is none. */
    static String dcmd(MBeanServerConnection m, String op, String... a) {
        Object r = invoke(m, "com.sun.management:type=DiagnosticCommand", op, new Object[]{ a }, new String[]{ String[].class.getName() });
        return r == null ? null : r.toString();
    }

    static String vmOption(MBeanServerConnection m, String name) {
        Object r = invoke(m, "com.sun.management:type=HotSpotDiagnostic", "getVMOption", new Object[]{ name }, new String[]{ String.class.getName() });
        if (r instanceof CompositeData) return String.valueOf(((CompositeData) r).get("value"));
        return null;
    }

    @SuppressWarnings("unchecked")
    static List<String> inputArgs(MBeanServerConnection m) {
        Object o = attr(m, "java.lang:type=Runtime", "InputArguments");
        if (o instanceof String[]) return Arrays.asList((String[]) o);
        if (o instanceof List) return (List<String>) o;
        return null;
    }

    static String sysProp(MBeanServerConnection m, String k) {
        Object o = attr(m, "java.lang:type=Runtime", "SystemProperties");
        if (o instanceof TabularData) {
            for (Object row : ((TabularData) o).values()) {
                CompositeData c = (CompositeData) row;
                if (k.equals(c.get("key"))) return String.valueOf(c.get("value"));
            }
        }
        return null;
    }

    // ---- the jobs -----------------------------------------------------------

    interface Job { void run(List<Target> ts) throws Exception; }

    static final Map<String, Job> JOBS = new LinkedHashMap<>();

    /** A job's work for each JVM; a JVM it cannot reach prints nothing. */
    interface Each { void run(Target t) throws Exception; }

    static void each(List<Target> ts, Each e) {
        for (Target t : ts) {
            try { e.run(t); } catch (Exception x) { say(t.name + ": " + Jmx.rootMessage(x)); }
        }
    }

    /** The JVM's MBean server, or null: jmx_up says why, when it has an address. */
    static MBeanServerConnection mbs(Target t) { return t.jmx(); }

    static {
        JOBS.put("process", Jobs::process);
        JOBS.put("discovery", Jobs::discovery);
        JOBS.put("status", Jobs::status);
        JOBS.put("flags", Jobs::flags);
        JOBS.put("container", Jobs::container);
        JOBS.put("release_age", Jobs::releaseAge);
        JOBS.put("security", Jobs::security);
        JOBS.put("startup", Jobs::startup);
        JOBS.put("heap", Jobs::heap);
        JOBS.put("pools", Jobs::pools);
        JOBS.put("metaspace", Jobs::metaspace);
        JOBS.put("codecache", Jobs::codecache);
        JOBS.put("buffers", Jobs::buffers);
        JOBS.put("native", Jobs::nativeMemory);
        JOBS.put("native_overhead", Jobs::nativeOverhead);
        JOBS.put("gc", Jobs::gc);
        JOBS.put("gc_cycles", Jobs::gcCycles);
        JOBS.put("gc_last", Jobs::gcLast);
        JOBS.put("gc_cpu", Jobs::gcCpu);
        JOBS.put("allocation", Jobs::allocation);
        JOBS.put("promotion", Jobs::promotion);
        JOBS.put("tlab", Jobs::tlab);
        JOBS.put("gclog", Jobs::gclog);
        JOBS.put("gclog_detail", Jobs::gclogDetail);
        JOBS.put("threads", Jobs::threads);
        JOBS.put("deadlocks", Jobs::deadlocks);
        JOBS.put("contention", Jobs::contention);
        JOBS.put("hot_threads", Jobs::hotThreads);
        JOBS.put("virtual_threads", Jobs::virtualThreads);
        JOBS.put("classes", Jobs::classes);
        JOBS.put("classloaders", Jobs::classloaders);
        JOBS.put("jit", Jobs::jit);
        JOBS.put("deopt", Jobs::deopt);
        JOBS.put("safepoints", Jobs::safepoints);
        JOBS.put("finalization", Jobs::finalization);
        JOBS.put("os", Jobs::os);
        JOBS.put("io", Jobs::io);
        JOBS.put("crashes", Jobs::crashes);
        JOBS.put("oom", Jobs::oom);
        JOBS.put("jfr", Jobs::jfr);
        JOBS.put("mbeans", Jobs::mbeans);
    }

    static final class Jobs {

        static final String MEMORY = "java.lang:type=Memory";
        static final String RUNTIME = "java.lang:type=Runtime";
        static final String THREADING = "java.lang:type=Threading";
        static final String OS = "java.lang:type=OperatingSystem";

        // -- finding and knowing each JVM --

        static void process(List<Target> ts) {
            each(ts, t -> {
                if (t.jmx != null && t.proc == null && Targets.isLocal(t.jmx)) mbs(t);
                if (t.proc == null) {
                    // A JVM looked for here, and not found: not running.
                    if (t.main != null || t.pidFile != null) metric("running", 0, t);
                    return;
                }
                Proc p = t.proc;
                metric("running", 1, t);
                metric("rss_bytes", p.rss, t);
                metric("virtual_bytes", p.vsz, t);
                metric("cpu_seconds", p.cpuSeconds, t);
                metric("threads", p.threads, t);
                metric("open_files", p.fds, t);
                metric("open_files_max", p.fdMax, t);
                if (p.startEpoch != null) metric("uptime_seconds", Math.max(0, Instant.now().getEpochSecond() - p.startEpoch), t);
            });
        }

        static void discovery(List<Target> ts) throws Exception {
            List<Proc> all = Procs.list();
            metric("jvms", all.size(), null);
            Set<Long> configured = new HashSet<>();
            for (Target t : ts) if (t.proc != null) configured.add(t.proc.pid);
            int n = 0;
            for (Proc p : all) {
                if (n++ >= LIST_CAP) break;
                Target t = new Target(p.main == null ? "pid" + p.pid : shortName(p.main));
                t.proc = p;
                metric("found", 1, null, "main", p.main == null ? "none" : shortName(p.main), "user", p.user == null ? "none" : p.user,
                        "watched", configured.contains(p.pid) || env("JVM_TARGETS").trim().isEmpty() ? "yes" : "no",
                        "counters", t.perf() != null ? "yes" : "no");
            }
            metric("jvms_not_shown", Math.max(0, all.size() - LIST_CAP), null);
        }

        static void status(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                Perf pf = t.perf();
                boolean up = t.proc != null || m != null;
                metric("up", up, t);
                metric("tier_os", t.proc != null, t);
                metric("tier_counters", pf != null, t);
                metric("tier_jmx", m != null, t);
                if (!up) return;
                String version = null, vendor = null, vm = null;
                Long uptime = null, heapMax = null;
                List<String> gcs = new ArrayList<>();
                if (m != null) {
                    version = str(attr(m, RUNTIME, "SpecVersion"));
                    String full = sysProp(m, "java.version");
                    if (full != null) version = full;
                    vendor = str(attr(m, RUNTIME, "VmVendor"));
                    vm = str(attr(m, RUNTIME, "VmName"));
                    uptime = attrL(m, RUNTIME, "Uptime");
                    if (uptime != null) uptime /= 1000;
                    heapMax = cd(attr(m, MEMORY, "HeapMemoryUsage"), "max");
                    for (ObjectName g : query(m, "java.lang:type=GarbageCollector,*")) gcs.add(g.getKeyProperty("name"));
                } else if (pf != null) {
                    version = pf.s("java.property.java.version");
                    vendor = pf.s("java.property.java.vm.vendor");
                    vm = pf.s("java.property.java.vm.name");
                    Long ticks = pf.l("sun.os.hrt.ticks");
                    if (ticks != null) uptime = (long) (ticks / pf.hz);
                    heapMax = perfHeap(pf, "maxCapacity");
                    for (int i = 0; i < 8; i++) {
                        String g = pf.s("sun.gc.collector." + i + ".name");
                        if (g != null) gcs.add(g);
                    }
                } else if (t.proc != null) {
                    String xmx = t.proc.opt("-Xmx");
                    if (xmx != null) heapMax = bytes(xmx);
                    if (t.proc.startEpoch != null) uptime = Instant.now().getEpochSecond() - t.proc.startEpoch;
                }
                metric("info", 1, t, "version", version == null ? "unknown" : version, "vendor", vendor == null ? "unknown" : vendor,
                        "vm", vm == null ? "unknown" : vm, "gc", gcs.isEmpty() ? "unknown" : String.join("+", gcs));
                metric("uptime_seconds", uptime, t);
                if (heapMax != null && heapMax > 0) metric("heap_max_bytes", heapMax, t);
            });
        }

        static void flags(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                List<String> args = m != null ? inputArgs(m) : (t.proc != null ? t.proc.args : null);
                if (args == null) return;
                Proc view = new Proc();
                view.args = args;
                boolean xmx = view.has("-Xmx") || view.has("-XX:MaxHeapSize=") || view.has("-XX:MaxRAMPercentage=") || view.has("-XX:MaxRAMFraction=");
                boolean dump, exit;
                if (m != null && vmOption(m, "HeapDumpOnOutOfMemoryError") != null) {
                    dump = "true".equals(vmOption(m, "HeapDumpOnOutOfMemoryError"));
                    exit = "true".equals(vmOption(m, "ExitOnOutOfMemoryError")) || "true".equals(vmOption(m, "CrashOnOutOfMemoryError"));
                } else {
                    dump = view.flag("HeapDumpOnOutOfMemoryError");
                    exit = view.flag("ExitOnOutOfMemoryError") || view.flag("CrashOnOutOfMemoryError") || view.has("-XX:OnOutOfMemoryError=");
                }
                boolean oldGc = view.flag("UseConcMarkSweepGC") || view.flag("UseParNewGC");
                boolean explicitOff = view.flag("DisableExplicitGC");
                Long heapMax = null, memory = null;
                if (m != null) {
                    heapMax = cd(attr(m, MEMORY, "HeapMemoryUsage"), "max");
                    memory = attrL(m, OS, "TotalMemorySize");
                    if (memory == null) memory = attrL(m, OS, "TotalPhysicalMemorySize");
                } else if (view.opt("-Xmx") != null) {
                    heapMax = bytes(view.opt("-Xmx"));
                }
                boolean over = heapMax != null && memory != null && heapMax > 0 && heapMax > memory;
                metric("heap_max_set", xmx, t);
                metric("heap_dump_on_oom", dump, t);
                metric("exit_on_oom", exit, t);
                metric("deprecated_gc", oldGc, t);
                metric("heap_over_memory", over, t);
                metric("explicit_gc_disabled", explicitOff, t);
                metric("risks", (xmx ? 0 : 1) + (dump ? 0 : 1) + (oldGc ? 1 : 0) + (over ? 1 : 0), t);
            });
        }

        static void container(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Long cpus = attrL(m, OS, "AvailableProcessors");
                Long mem = attrL(m, OS, "TotalMemorySize");
                if (mem == null) mem = attrL(m, OS, "TotalPhysicalMemorySize");
                metric("cpus", cpus, t);
                metric("memory_bytes", mem, t);
                if (Targets.isLocal(t.jmx)) {
                    // Here, this machine's own, for what a container's limits leave it.
                    MBeanServerConnection me = ManagementFactory.getPlatformMBeanServer();
                    long hostCpus = Runtime.getRuntime().availableProcessors();
                    Long hostMem = attrL(me, OS, "TotalMemorySize");
                    if (hostMem == null) hostMem = attrL(me, OS, "TotalPhysicalMemorySize");
                    metric("cpus_host", hostCpus, t);
                    metric("memory_host_bytes", hostMem, t);
                    if (cpus != null) metric("cpus_limited", cpus < hostCpus, t);
                    if (mem != null && hostMem != null) metric("memory_limited", mem < hostMem, t);
                }
            });
        }

        static void releaseAge(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                String date = null, version = null;
                if (m != null) {
                    date = sysProp(m, "java.version.date");
                    version = sysProp(m, "java.version");
                } else if (t.perf() != null) {
                    version = t.perf().s("java.property.java.version");
                }
                if (version == null) return;
                int feature = feature(version);
                metric("feature_version", feature, t);
                metric("lts", feature == 8 || feature == 11 || feature == 17 || feature == 21 || feature == 25, t);
                if (date != null) {
                    try {
                        long days = Duration.between(LocalDate.parse(date).atStartOfDay(), LocalDate.now().atStartOfDay()).toDays();
                        metric("release_age_days", Math.max(0, days), t, "version", version);
                    } catch (RuntimeException e) { /* no date */ }
                }
            });
        }

        static void security(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                List<String> args = m != null ? inputArgs(m) : (t.proc != null ? t.proc.args : null);
                if (args == null) return;
                Proc v = new Proc();
                v.args = args;
                String jdwp = v.opt("-agentlib:jdwp=");
                if (jdwp == null) jdwp = v.opt("-Xrunjdwp:");
                boolean debug = jdwp != null || v.has("-Xdebug");
                // A debugger that listens beyond this machine: anyone who reaches
                // the port can run code in the JVM.
                boolean debugRemote = false;
                if (jdwp != null && jdwp.contains("server=y")) {
                    Matcher a = Pattern.compile("address=([^,]*)").matcher(jdwp);
                    if (a.find()) {
                        String addr = a.group(1);
                        if (addr.matches("[0-9]+")) {
                            // A bare port listens on localhost from Java 9, on every address before.
                            debugRemote = javaFeature(m, t) < 9;
                        } else {
                            String host = addr.substring(0, Math.max(0, addr.lastIndexOf(':')));
                            debugRemote = !(host.equals("localhost") || host.startsWith("127.") || host.equals("[::1]") || host.equals("::1"));
                        }
                    }
                }
                boolean jmxPort = v.has("-Dcom.sun.management.jmxremote.port=");
                boolean noPassword = jmxPort && "false".equals(v.opt("-Dcom.sun.management.jmxremote.authenticate="));
                boolean noTls = jmxPort && "false".equals(v.opt("-Dcom.sun.management.jmxremote.ssl="));
                boolean verifyOff = v.has("-Xverify:none") || v.has("-noverify") || args.contains("-XX:-BytecodeVerificationRemote");
                metric("debug_agent", debug, t);
                metric("debug_agent_remote", debugRemote, t);
                metric("jmx_remote", jmxPort, t);
                metric("jmx_no_password", noPassword, t);
                metric("jmx_no_tls", noTls, t);
                metric("verify_off", verifyOff, t);
                metric("risks", (debugRemote ? 1 : 0) + (debug && !debugRemote ? 1 : 0) + (noPassword ? 1 : 0) + (noTls ? 1 : 0) + (verifyOff ? 1 : 0), t);
            });
        }

        static void startup(List<Target> ts) {
            each(ts, t -> {
                Perf pf = t.perf();
                Long start = null;
                if (pf != null) {
                    Long begin = pf.l("sun.rt.createVmBeginTime"), end = pf.l("sun.rt.createVmEndTime"), done = pf.l("sun.rt.vmInitDoneTime");
                    if (begin != null && end != null && end >= begin) metric("startup_seconds", (end - begin) / 1000.0, t);
                    if (begin != null && done != null && done >= begin) metric("init_seconds", (done - begin) / 1000.0, t);
                    if (begin != null) start = begin / 1000;
                }
                MBeanServerConnection m = null;
                if (start == null && t.hasJmx()) m = mbs(t);
                if (start == null && m != null) {
                    Long st = attrL(m, RUNTIME, "StartTime");
                    if (st != null) start = st / 1000;
                }
                if (start == null && t.proc != null) start = t.proc.startEpoch;
                if (start != null) {
                    metric("started_epoch_seconds", start, t);
                    metric("uptime_seconds", Math.max(0, Instant.now().getEpochSecond() - start), t);
                }
            });
        }

        // -- memory --

        static Long perfHeap(Perf pf, String what) {
            long sum = 0;
            boolean any = false;
            for (int g = 0; g < 2; g++) {
                for (int s = 0; s < 4; s++) {
                    Long v = pf.l("sun.gc.generation." + g + ".space." + s + "." + what);
                    if (v != null) { sum += v; any = true; }
                }
            }
            return any ? sum : null;
        }

        static void heap(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                Long used, committed, max;
                if (m != null) {
                    Object u = attr(m, MEMORY, "HeapMemoryUsage");
                    used = cd(u, "used"); committed = cd(u, "committed"); max = cd(u, "max");
                } else if (t.perf() != null) {
                    used = perfHeap(t.perf(), "used");
                    committed = perfHeap(t.perf(), "capacity");
                    max = perfHeap(t.perf(), "maxCapacity");
                } else return;
                metric("used_bytes", used, t);
                metric("committed_bytes", committed, t);
                if (max != null && max > 0) {
                    metric("max_bytes", max, t);
                    if (used != null) metric("used_percent", 100.0 * used / max, t);
                }
            });
        }

        static void pools(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                if (m != null) {
                    for (ObjectName p : query(m, "java.lang:type=MemoryPool,*")) {
                        String name = p.getKeyProperty("name");
                        String type = String.valueOf(attr(m, p.toString(), "Type"));
                        String kind = "HEAP".equals(type) ? "heap" : "non_heap";
                        Object u = attr(m, p.toString(), "Usage");
                        metric("used_bytes", cd(u, "used"), t, "pool", name, "type", kind);
                        metric("committed_bytes", cd(u, "committed"), t, "pool", name, "type", kind);
                        Long max = cd(u, "max");
                        if (max != null && max > 0) metric("max_bytes", max, t, "pool", name, "type", kind);
                        Object cu = attr(m, p.toString(), "CollectionUsage");
                        Long after = cd(cu, "used");
                        if (after != null) {
                            metric("after_gc_bytes", after, t, "pool", name, "type", kind);
                            if (max != null && max > 0) metric("after_gc_percent", 100.0 * after / max, t, "pool", name, "type", kind);
                        }
                    }
                } else if (t.perf() != null) {
                    Perf pf = t.perf();
                    for (int g = 0; g < 2; g++) for (int s = 0; s < 4; s++) {
                        String k = "sun.gc.generation." + g + ".space." + s + ".";
                        String name = pf.s(k + "name");
                        if (name == null) continue;
                        metric("used_bytes", pf.l(k + "used"), t, "pool", name, "type", "heap");
                        metric("committed_bytes", pf.l(k + "capacity"), t, "pool", name, "type", "heap");
                        Long max = pf.l(k + "maxCapacity");
                        if (max != null && max > 0) metric("max_bytes", max, t, "pool", name, "type", "heap");
                    }
                }
            });
        }

        static void metaspace(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                String[][] spaces = { { "Metaspace", "metaspace", "sun.gc.metaspace" }, { "Compressed Class Space", "class_space", "sun.gc.compressedclassspace" } };
                for (String[] s : spaces) {
                    Long used = null, committed = null, max = null;
                    if (m != null) {
                        Object u = attr(m, "java.lang:type=MemoryPool,name=" + s[0], "Usage");
                        used = cd(u, "used"); committed = cd(u, "committed"); max = cd(u, "max");
                    } else if (t.perf() != null) {
                        used = t.perf().l(s[2] + ".used"); committed = t.perf().l(s[2] + ".capacity"); max = t.perf().l(s[2] + ".maxCapacity");
                    }
                    if (used == null) continue;
                    metric(s[1] + "_used_bytes", used, t);
                    metric(s[1] + "_committed_bytes", committed, t);
                    if (max != null && max > 0 && max < Long.MAX_VALUE / 2) {
                        metric(s[1] + "_max_bytes", max, t);
                        metric(s[1] + "_used_percent", 100.0 * used / max, t);
                    }
                }
            });
        }

        static void codecache(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                if (m != null) {
                    for (ObjectName p : query(m, "java.lang:type=MemoryPool,*")) {
                        String name = p.getKeyProperty("name");
                        if (!name.startsWith("CodeHeap") && !name.equals("Code Cache")) continue;
                        Object u = attr(m, p.toString(), "Usage");
                        Long used = cd(u, "used"), max = cd(u, "max");
                        String seg = name.replace("CodeHeap ", "").replace("'", "");
                        metric("used_bytes", used, t, "segment", seg);
                        if (max != null && max > 0) {
                            metric("max_bytes", max, t, "segment", seg);
                            if (used != null) metric("used_percent", 100.0 * used / max, t, "segment", seg);
                        }
                    }
                } else if (t.perf() != null) {
                    Perf pf = t.perf();
                    for (String k : pf.under("sun.ci.")) {
                        if (k.endsWith("nmethodCodeSize")) metric("nmethod_code_bytes", pf.l(k), t);
                    }
                }
            });
        }

        static void buffers(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                for (ObjectName b : query(m, "java.nio:type=BufferPool,*")) {
                    // direct, mapped, mapped_non_volatile_memory.
                    String name = b.getKeyProperty("name").toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "_").replaceAll("^_|_$", "");
                    metric("count", attrL(m, b.toString(), "Count"), t, "pool", name);
                    metric("used_bytes", attrL(m, b.toString(), "MemoryUsed"), t, "pool", name);
                    metric("capacity_bytes", attrL(m, b.toString(), "TotalCapacity"), t, "pool", name);
                }
            });
        }

        static final Pattern NMT_TOTAL = Pattern.compile("Total: reserved=(\\d+)([KMG]B), committed=(\\d+)([KMG]B)");
        static final Pattern NMT_CAT = Pattern.compile("^-\\s+(.+?) \\(reserved=(\\d+)([KMG]B), committed=(\\d+)([KMG]B)\\)", Pattern.MULTILINE);

        static long kb(String n, String unit) {
            long v = Long.parseLong(n);
            return unit.equals("GB") ? v << 30 : unit.equals("MB") ? v << 20 : v << 10;
        }

        static void nativeMemory(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                String r = dcmd(m, "vmNativeMemory", "summary", "scale=KB");
                if (r == null) return;
                boolean on = !r.contains("not enabled");
                metric("tracking", on, t);
                if (!on) return;
                Matcher a = NMT_TOTAL.matcher(r);
                if (a.find()) {
                    metric("reserved_bytes", kb(a.group(1), a.group(2)), t);
                    metric("committed_bytes", kb(a.group(3), a.group(4)), t);
                }
                Matcher c = NMT_CAT.matcher(r);
                int n = 0;
                while (c.find() && n++ < LIST_CAP) {
                    String cat = c.group(1).trim().toLowerCase(Locale.ROOT).replace(' ', '_');
                    metric("category_committed_bytes", kb(c.group(4), c.group(5)), t, "category", cat);
                }
            });
        }

        static void nativeOverhead(List<Target> ts) {
            each(ts, t -> {
                if (t.jmx != null && t.proc == null && Targets.isLocal(t.jmx)) mbs(t);
                if (t.proc == null || t.proc.rss == null) return;
                Long heap = null;
                if (t.perf() != null) heap = perfHeap(t.perf(), "capacity");
                if (heap == null && t.hasJmx()) {
                    MBeanServerConnection m = mbs(t);
                    if (m != null) heap = cd(attr(m, MEMORY, "HeapMemoryUsage"), "committed");
                }
                if (heap == null) return;
                long outside = Math.max(0, t.proc.rss - heap);
                metric("rss_bytes", t.proc.rss, t);
                metric("heap_committed_bytes", heap, t);
                metric("outside_heap_bytes", outside, t);
                metric("outside_heap_percent", 100.0 * outside / t.proc.rss, t);
            });
        }

        // -- garbage collection --

        static boolean isConcurrent(String collector) {
            return collector.contains("Cycles") || collector.contains("Concurrent") || collector.equals("ConcurrentMarkSweep");
        }

        static void gc(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                long count = 0;
                double time = 0;
                boolean any = false;
                if (m != null) {
                    for (ObjectName g : query(m, "java.lang:type=GarbageCollector,*")) {
                        String name = g.getKeyProperty("name");
                        Long c = attrL(m, g.toString(), "CollectionCount"), ms = attrL(m, g.toString(), "CollectionTime");
                        if (c == null || c < 0) continue;
                        metric("collections", c, t, "collector", name);
                        metric("time_seconds", ms == null ? null : ms / 1000.0, t, "collector", name);
                        count += c;
                        if (ms != null && ms > 0) time += ms / 1000.0;
                        any = true;
                    }
                    Long up = attrL(m, RUNTIME, "Uptime");
                    if (any && up != null && up > 0) metric("time_percent_lifetime", 100.0 * time / (up / 1000.0), t);
                } else if (t.perf() != null) {
                    Perf pf = t.perf();
                    for (int i = 0; i < 8; i++) {
                        String k = "sun.gc.collector." + i + ".";
                        String name = pf.s(k + "name");
                        if (name == null) continue;
                        Long c = pf.l(k + "invocations");
                        Double s = pf.sec(k + "time");
                        metric("collections", c, t, "collector", name);
                        metric("time_seconds", s, t, "collector", name);
                        if (c != null) count += c;
                        if (s != null) time += s;
                        any = true;
                    }
                    Long ticks = pf.l("sun.os.hrt.ticks");
                    if (any && ticks != null && ticks > 0) metric("time_percent_lifetime", 100.0 * time / (ticks / pf.hz), t);
                    String cause = pf.s("sun.gc.lastCause");
                    if (cause != null) metric("last_cause", 1, t, "cause", cause);
                }
                if (any) {
                    metric("collections_total", count, t);
                    metric("time_seconds_total", time, t);
                }
            });
        }

        static void gcCycles(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                long pc = 0, cc = 0;
                double pt = 0, ct = 0;
                for (ObjectName g : query(m, "java.lang:type=GarbageCollector,*")) {
                    String name = g.getKeyProperty("name");
                    Long c = attrL(m, g.toString(), "CollectionCount"), ms = attrL(m, g.toString(), "CollectionTime");
                    if (c == null || c < 0) continue;
                    if (isConcurrent(name)) { cc += c; if (ms != null) ct += ms / 1000.0; }
                    else { pc += c; if (ms != null) pt += ms / 1000.0; }
                }
                metric("pauses", pc, t);
                metric("pause_seconds", pt, t);
                if (pc > 0) metric("pause_avg_ms", 1000.0 * pt / pc, t);
                metric("concurrent_cycles", cc, t);
                metric("concurrent_seconds", ct, t);
            });
        }

        static void gcLast(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Long up = attrL(m, RUNTIME, "Uptime");
                for (ObjectName g : query(m, "java.lang:type=GarbageCollector,*")) {
                    String name = g.getKeyProperty("name");
                    Object info = attr(m, g.toString(), "LastGcInfo");
                    if (!(info instanceof CompositeData)) continue;
                    CompositeData c = (CompositeData) info;
                    metric("duration_ms", cd(c, "duration"), t, "collector", name);
                    Long end = cd(c, "endTime");
                    if (up != null && end != null) metric("seconds_ago", Math.max(0, (up - end) / 1000.0), t, "collector", name);
                    long before = sumUsage(c.get("memoryUsageBeforeGc")), after = sumUsage(c.get("memoryUsageAfterGc"));
                    metric("freed_bytes", Math.max(0, before - after), t, "collector", name);
                    metric("after_bytes", after, t, "collector", name);
                }
            });
        }

        static long sumUsage(Object tab) {
            long s = 0;
            if (tab instanceof TabularData) {
                for (Object row : ((TabularData) tab).values()) {
                    Object v = ((CompositeData) row).get("value");
                    Long u = cd(v, "used");
                    if (u != null) s += u;
                }
            }
            return s;
        }

        static void gcCpu(List<Target> ts) {
            each(ts, t -> {
                // The GC threads' CPU: MemoryMXBean's, where the JVM has it,
                // else its own counters (HotSpot 22 and later keep them).
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                Long gcNs = m == null ? null : attrL(m, MEMORY, "TotalGcCpuTime");
                Perf pf = t.perf();
                if ((gcNs == null || gcNs < 0) && pf != null) {
                    Long v = pf.l("sun.threads.cpu_time.gc_total");
                    if (v == null) v = pf.l("sun.threads.total_gc_cpu_time");
                    if (v == null) {
                        // Before a total: the GC's threads by kind, added up.
                        long sum = 0;
                        boolean any = false;
                        for (String k : pf.under("sun.threads.cpu_time.gc_")) {
                            Long p = pf.l(k);
                            if (p != null && p >= 0) { sum += p; any = true; }
                        }
                        if (any) v = sum;
                    }
                    if (v != null) gcNs = v;
                }
                Long procNs = m == null ? null : attrL(m, OS, "ProcessCpuTime");
                if (procNs == null && t.proc != null && t.proc.cpuSeconds != null) procNs = (long) (t.proc.cpuSeconds * 1e9);
                if (gcNs == null || gcNs < 0) return;
                metric("gc_cpu_seconds", gcNs / 1e9, t);
                if (procNs != null && procNs > 0) {
                    metric("process_cpu_seconds", procNs / 1e9, t);
                    metric("gc_cpu_percent_lifetime", 100.0 * gcNs / procNs, t);
                }
            });
        }

        static void allocation(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Long total = attrL(m, THREADING, "TotalThreadAllocatedBytes");
                if (total != null && total >= 0) metric("allocated_bytes", total, t);
                // A rate, over two seconds: every live thread's allocations.
                long a = allocatedNow(m);
                if (a < 0) return;
                long t0 = System.nanoTime();
                Thread.sleep(2000);
                long b = allocatedNow(m);
                double secs = (System.nanoTime() - t0) / 1e9;
                if (b >= a) metric("allocation_bytes_per_second", (b - a) / secs, t);
            });
        }

        static long allocatedNow(MBeanServerConnection m) {
            Object ids = attr(m, THREADING, "AllThreadIds");
            if (!(ids instanceof long[])) return -1;
            Object r = invoke(m, THREADING, "getThreadAllocatedBytes", new Object[]{ ids }, new String[]{ long[].class.getName() });
            if (!(r instanceof long[])) return -1;
            long s = 0;
            for (long v : (long[]) r) if (v > 0) s += v;
            return s;
        }

        static void promotion(List<Target> ts) {
            each(ts, t -> {
                Perf pf = t.perf();
                if (pf == null) return;
                String[][] k = {
                    { "sun.gc.policy.promoted", "promoted_last_bytes" },
                    { "sun.gc.policy.survived", "survived_last_bytes" },
                    { "sun.gc.policy.tenuringThreshold", "tenuring_threshold" },
                    { "sun.gc.policy.maxTenuringThreshold", "tenuring_threshold_max" },
                    { "sun.gc.policy.desiredSurvivorSize", "survivor_desired_bytes" },
                    { "sun.gc.policy.avgPromotedAvg", "promoted_avg_bytes" },
                    { "sun.gc.policy.survivorOverflowed", "survivor_overflowed" },
                };
                for (String[] x : k) metric(x[1], pf.l(x[0]), t);
            });
        }

        static void tlab(List<Target> ts) {
            each(ts, t -> {
                Perf pf = t.perf();
                if (pf == null) return;
                String[][] k = {
                    { "sun.gc.tlab.alloc", "allocated_words" },
                    { "sun.gc.tlab.allocThreads", "threads" },
                    { "sun.gc.tlab.fills", "refills" },
                    { "sun.gc.tlab.maxFills", "refills_max" },
                    { "sun.gc.tlab.slowAlloc", "slow_allocations" },
                    { "sun.gc.tlab.maxSlowAlloc", "slow_allocations_max" },
                    { "sun.gc.tlab.gcWaste", "waste_gc_words" },
                    { "sun.gc.tlab.refillWaste", "waste_refill_words" },
                };
                for (String[] x : k) metric(x[1], pf.l(x[0]), t);
            });
        }

        // GC log: unified logging (Java 9+) and Java 8's -XX:+PrintGCDetails.
        static final Pattern U_LINE = Pattern.compile("^\\[(?:[^\\]]*\\]\\[)*?([0-9.]+)s\\].*?GC\\((\\d+)\\) (Pause [^\\n]*?) ([0-9.]+)ms\\s*$");
        static final Pattern U_UPTIME = Pattern.compile("\\[([0-9]+\\.[0-9]+)s\\]");
        static final Pattern U_PAUSE = Pattern.compile("GC\\((\\d+)\\) (Pause [^\\n]*?)\\s([0-9.]+)ms\\s*$");
        static final Pattern J8_PAUSE = Pattern.compile("^([0-9.]+): \\[(Full GC|GC)[^\\n]*?, ([0-9.]+) secs\\]");

        static final class Pause {
            double at, ms;
            String what;
            Pause(double at, double ms, String what) { this.at = at; this.ms = ms; this.what = what; }
        }

        /** The pauses in the last window seconds of the log, by the log's own clock; null without a log. */
        static List<Pause> pauses(Target t, double window, List<String> lines) throws IOException {
            if (t.gclog == null) return null;
            Path p = Paths.get(t.gclog);
            if (!Files.isReadable(p)) {
                say(t.name + ": the GC log " + t.gclog + " cannot be read by this account");
                return null;
            }
            // The end of the log: 4 MB holds hours of it.
            long size = Files.size(p);
            byte[] b;
            try (RandomAccessFile f = new RandomAccessFile(p.toFile(), "r")) {
                long from = Math.max(0, size - 4L * 1024 * 1024);
                f.seek(from);
                b = new byte[(int) (size - from)];
                f.readFully(b);
            }
            String text = new String(b, StandardCharsets.UTF_8);
            List<Pause> all = new ArrayList<>();
            double last = 0;
            for (String line : text.split("\\r?\\n")) {
                if (lines != null) lines.add(line);
                Matcher up = U_UPTIME.matcher(line);
                double at = up.find() ? Double.parseDouble(up.group(1)) : -1;
                if (at > last) last = at;
                Matcher u = U_PAUSE.matcher(line);
                if (u.find() && at >= 0) { all.add(new Pause(at, Double.parseDouble(u.group(3)), u.group(2))); continue; }
                Matcher j = J8_PAUSE.matcher(line);
                if (j.find()) {
                    double a8 = Double.parseDouble(j.group(1));
                    if (a8 > last) last = a8;
                    all.add(new Pause(a8, Double.parseDouble(j.group(3)) * 1000, j.group(2).equals("Full GC") ? "Pause Full" : "Pause Young"));
                }
            }
            List<Pause> r = new ArrayList<>();
            for (Pause x : all) if (x.at >= last - window) r.add(x);
            return r;
        }

        static void gclog(List<Target> ts) {
            each(ts, t -> {
                List<String> lines = new ArrayList<>();
                List<Pause> ps = pauses(t, 300, lines);
                if (ps == null) return;
                metric("window_seconds", 300, t);
                metric("pauses", ps.size(), t);
                if (!ps.isEmpty()) {
                    double[] v = new double[ps.size()];
                    double sum = 0;
                    for (int i = 0; i < v.length; i++) { v[i] = ps.get(i).ms; sum += v[i]; }
                    Arrays.sort(v);
                    metric("pause_max_ms", v[v.length - 1], t);
                    metric("pause_p99_ms", v[Math.min(v.length - 1, (int) Math.ceil(v.length * 0.99) - 1)], t);
                    metric("pause_total_ms", sum, t);
                }
                long full = ps.stream().filter(x -> x.what.startsWith("Pause Full")).count();
                metric("full_gcs", full, t);
                long stalls = 0;
                for (String l : lines) if (l.contains("Allocation Stall")) stalls++;
                metric("allocation_stalls_in_log", stalls, t);
            });
        }

        static void gclogDetail(List<Target> ts) {
            each(ts, t -> {
                List<String> lines = new ArrayList<>();
                List<Pause> ps = pauses(t, 900, lines);
                if (ps == null) return;
                long[] buckets = new long[4];
                for (Pause x : ps) buckets[x.ms < 10 ? 0 : x.ms < 100 ? 1 : x.ms < 1000 ? 2 : 3]++;
                String[] names = { "under_10ms", "10_to_100ms", "100ms_to_1s", "over_1s" };
                for (int i = 0; i < 4; i++) metric("pauses", buckets[i], t, "length", names[i]);
                long humongous = 0, exhausted = 0, evacFailed = 0, toSpace = 0;
                for (String l : lines) {
                    if (l.contains("Humongous Allocation")) humongous++;
                    if (l.contains("To-space exhausted")) exhausted++;
                    if (l.contains("Evacuation Failure")) evacFailed++;
                    if (l.contains("to-space overflow") || l.contains("promotion failed")) toSpace++;
                }
                metric("window_seconds", 900, t);
                metric("humongous_allocations_in_log", humongous, t);
                metric("to_space_exhausted_in_log", exhausted, t);
                metric("evacuation_failures_in_log", evacFailed, t);
                metric("promotion_failed_in_log", toSpace, t);
            });
        }

        // -- threads --

        static void threads(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                if (m != null) {
                    metric("live", attrL(m, THREADING, "ThreadCount"), t);
                    metric("daemon", attrL(m, THREADING, "DaemonThreadCount"), t);
                    metric("peak", attrL(m, THREADING, "PeakThreadCount"), t);
                    metric("started", attrL(m, THREADING, "TotalStartedThreadCount"), t);
                    Object ids = attr(m, THREADING, "AllThreadIds");
                    if (ids instanceof long[]) {
                        Object infos = invoke(m, THREADING, "getThreadInfo", new Object[]{ ids, 0 }, new String[]{ long[].class.getName(), int.class.getName() });
                        if (infos instanceof CompositeData[]) {
                            Map<String, Long> by = new TreeMap<>();
                            for (String s : new String[]{ "RUNNABLE", "BLOCKED", "WAITING", "TIMED_WAITING", "NEW" }) by.put(s, 0L);
                            for (CompositeData c : (CompositeData[]) infos) if (c != null) by.merge(String.valueOf(c.get("threadState")), 1L, Long::sum);
                            for (Map.Entry<String, Long> e : by.entrySet()) metric("state", e.getValue(), t, "state", e.getKey().toLowerCase(Locale.ROOT));
                        }
                    }
                } else if (t.perf() != null) {
                    Perf pf = t.perf();
                    metric("live", pf.l("java.threads.live"), t);
                    metric("daemon", pf.l("java.threads.daemon"), t);
                    metric("peak", pf.l("java.threads.livePeak"), t);
                    metric("started", pf.l("java.threads.started"), t);
                }
            });
        }

        static void deadlocks(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Object all = invoke(m, THREADING, "findDeadlockedThreads", new Object[0], new String[0]);
                Object mon = invoke(m, THREADING, "findMonitorDeadlockedThreads", new Object[0], new String[0]);
                long[] ids = all instanceof long[] ? (long[]) all : new long[0];
                long[] mids = mon instanceof long[] ? (long[]) mon : new long[0];
                metric("deadlocked", ids.length, t);
                metric("monitor_deadlocked", mids.length, t);
                if (ids.length > 0) {
                    Object infos = invoke(m, THREADING, "getThreadInfo", new Object[]{ ids, 0 }, new String[]{ long[].class.getName(), int.class.getName() });
                    if (infos instanceof CompositeData[]) {
                        int n = 0;
                        for (CompositeData c : (CompositeData[]) infos) {
                            if (c == null || n++ >= 20) continue;
                            metric("thread", 1, t, "thread", String.valueOf(c.get("threadName")), "waits_on", String.valueOf(c.get("lockName")),
                                    "held_by", String.valueOf(c.get("lockOwnerName")));
                        }
                    }
                }
            });
        }

        static void contention(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Object ids = attr(m, THREADING, "AllThreadIds");
                if (!(ids instanceof long[])) return;
                Object infos = invoke(m, THREADING, "getThreadInfo", new Object[]{ ids, 0 }, new String[]{ long[].class.getName(), int.class.getName() });
                if (!(infos instanceof CompositeData[])) return;
                long blocked = 0, waiting = 0, blockedTimes = 0;
                Map<String, Long> waiters = new HashMap<>();
                Map<String, String> owner = new HashMap<>();
                for (CompositeData c : (CompositeData[]) infos) {
                    if (c == null) continue;
                    String st = String.valueOf(c.get("threadState"));
                    Long bc = cd(c, "blockedCount");
                    if (bc != null) blockedTimes += bc;
                    if (st.equals("BLOCKED")) {
                        blocked++;
                        String lock = String.valueOf(c.get("lockName"));
                        waiters.merge(lock, 1L, Long::sum);
                        owner.put(lock, String.valueOf(c.get("lockOwnerName")));
                    } else if (st.equals("WAITING") || st.equals("TIMED_WAITING")) waiting++;
                }
                metric("blocked", blocked, t);
                metric("waiting", waiting, t);
                metric("blocked_times_total", blockedTimes, t);
                List<Map.Entry<String, Long>> top = new ArrayList<>(waiters.entrySet());
                top.sort((a, b) -> Long.compare(b.getValue(), a.getValue()));
                for (int i = 0; i < Math.min(10, top.size()); i++) {
                    String lock = top.get(i).getKey();
                    metric("lock_waiters", top.get(i).getValue(), t, "lock", lockClass(lock), "held_by", owner.get(lock));
                }
            });
        }

        /** A lock's class, without its identity hash: the same lock reads the same. */
        static String lockClass(String lock) {
            int at = lock.indexOf('@');
            return at > 0 ? lock.substring(0, at) : lock;
        }

        static void hotThreads(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                if (Boolean.FALSE.equals(attr(m, THREADING, "ThreadCpuTimeEnabled"))) {
                    metric("cpu_time_enabled", 0, t);
                    return;
                }
                Object ids = attr(m, THREADING, "AllThreadIds");
                if (!(ids instanceof long[])) return;
                long[] id = (long[]) ids;
                Object a = invoke(m, THREADING, "getThreadCpuTime", new Object[]{ id }, new String[]{ long[].class.getName() });
                if (!(a instanceof long[])) return;
                long t0 = System.nanoTime();
                Thread.sleep(2000);
                Object b = invoke(m, THREADING, "getThreadCpuTime", new Object[]{ id }, new String[]{ long[].class.getName() });
                double secs = (System.nanoTime() - t0) / 1e9;
                if (!(b instanceof long[])) return;
                long[] x = (long[]) a, y = (long[]) b;
                Integer[] order = new Integer[id.length];
                double[] pct = new double[id.length];
                double total = 0;
                for (int i = 0; i < id.length; i++) {
                    order[i] = i;
                    pct[i] = x[i] >= 0 && y[i] >= x[i] ? 100.0 * (y[i] - x[i]) / 1e9 / secs : 0;
                    total += pct[i];
                }
                Arrays.sort(order, (p, q) -> Double.compare(pct[q], pct[p]));
                metric("cpu_percent_total", total, t);
                int show = 0;
                long[] top = new long[Math.min(10, id.length)];
                for (int i = 0; i < top.length; i++) top[i] = id[order[i]];
                Object infos = invoke(m, THREADING, "getThreadInfo", new Object[]{ top, 0 }, new String[]{ long[].class.getName(), int.class.getName() });
                CompositeData[] ci = infos instanceof CompositeData[] ? (CompositeData[]) infos : new CompositeData[0];
                for (int i = 0; i < top.length && i < ci.length; i++) {
                    if (ci[i] == null || pct[order[i]] < 0.5) continue;
                    metric("cpu_percent", pct[order[i]], t, "thread", String.valueOf(ci[i].get("threadName")));
                    show++;
                }
                metric("busy_threads_shown", show, t);
            });
        }

        static void virtualThreads(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                String s = "jdk.management:type=VirtualThreadScheduler";
                Long par = attrL(m, s, "Parallelism");
                if (par != null) {
                    metric("scheduler_parallelism", par, t);
                    metric("carriers", attrL(m, s, "PoolSize"), t);
                    metric("mounted", attrL(m, s, "MountedVirtualThreadCount"), t);
                    metric("queued", attrL(m, s, "QueuedVirtualThreadCount"), t);
                    return;
                }
                // Before Java 24: the carriers, by their names.
                Object ids = attr(m, THREADING, "AllThreadIds");
                if (!(ids instanceof long[])) return;
                Object infos = invoke(m, THREADING, "getThreadInfo", new Object[]{ ids, 0 }, new String[]{ long[].class.getName(), int.class.getName() });
                if (!(infos instanceof CompositeData[])) return;
                long carriers = 0, busy = 0;
                for (CompositeData c : (CompositeData[]) infos) {
                    if (c == null) continue;
                    String n = String.valueOf(c.get("threadName"));
                    if (n.startsWith("ForkJoinPool-1-worker-")) {
                        carriers++;
                        if ("RUNNABLE".equals(String.valueOf(c.get("threadState")))) busy++;
                    }
                }
                int feature = javaFeature(m, t);
                if (feature >= 21) {
                    metric("carriers", carriers, t);
                    metric("carriers_runnable", busy, t);
                }
            });
        }

        // -- the runtime --

        static void classes(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                if (m != null) {
                    metric("loaded", attrL(m, "java.lang:type=ClassLoading", "LoadedClassCount"), t);
                    metric("loaded_total", attrL(m, "java.lang:type=ClassLoading", "TotalLoadedClassCount"), t);
                    metric("unloaded", attrL(m, "java.lang:type=ClassLoading", "UnloadedClassCount"), t);
                } else if (t.perf() != null) {
                    Perf pf = t.perf();
                    Long l = pf.l("java.cls.loadedClasses"), u = pf.l("java.cls.unloadedClasses"), sl = pf.l("java.cls.sharedLoadedClasses"), su = pf.l("java.cls.sharedUnloadedClasses");
                    if (l != null) {
                        long loaded = l + (sl == null ? 0 : sl), unloaded = (u == null ? 0 : u) + (su == null ? 0 : su);
                        metric("loaded", loaded - unloaded, t);
                        metric("loaded_total", loaded, t);
                        metric("unloaded", unloaded, t);
                    }
                    metric("load_seconds", pf.sec("sun.cls.time"), t);
                }
            });
        }

        static void classloaders(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                String r = dcmd(m, "vmClassloaderStats");
                if (r == null) return;
                // ClassLoader Parent CLD* Classes ChunkSz BlockSz Type, then a total.
                Map<String, long[]> by = new TreeMap<>();
                long loaders = 0;
                for (String line : r.split("\\r?\\n")) {
                    String[] f = line.trim().split("\\s+", 7);
                    if (f.length < 7 || !f[0].startsWith("0x")) continue;
                    // The type is the rest of the line: <boot class loader> has spaces.
                    String type = f[6].trim();
                    long classes;
                    try { classes = Long.parseLong(f[3]); } catch (NumberFormatException e) { continue; }
                    long[] v = by.computeIfAbsent(type, k -> new long[2]);
                    v[0]++;
                    v[1] += classes;
                    loaders++;
                }
                metric("loaders", loaders, t);
                List<Map.Entry<String, long[]>> top = new ArrayList<>(by.entrySet());
                top.sort((a, b) -> Long.compare(b.getValue()[0], a.getValue()[0]));
                for (int i = 0; i < Math.min(15, top.size()); i++) {
                    metric("loaders_of_type", top.get(i).getValue()[0], t, "type", top.get(i).getKey());
                    metric("classes_of_type", top.get(i).getValue()[1], t, "type", top.get(i).getKey());
                }
                metric("types_not_shown", Math.max(0, top.size() - 15), t);
            });
        }

        static void jit(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = t.hasJmx() ? mbs(t) : null;
                Perf pf = t.perf();
                if (m != null) {
                    Long ms = attrL(m, "java.lang:type=Compilation", "TotalCompilationTime");
                    metric("compile_seconds", ms == null ? null : ms / 1000.0, t);
                } else if (pf != null) {
                    metric("compile_seconds", pf.sec("java.ci.totalTime"), t);
                }
                if (pf != null) {
                    metric("compiles", pf.l("sun.ci.totalCompiles"), t);
                    metric("osr_compiles", pf.l("sun.ci.osrCompiles"), t);
                    metric("compiled_code_bytes", pf.l("sun.ci.nmethodCodeSize"), t);
                }
            });
        }

        static void deopt(List<Target> ts) {
            each(ts, t -> {
                Perf pf = t.perf();
                if (pf == null) return;
                metric("invalidated", pf.l("sun.ci.totalInvalidates"), t);
                metric("bailouts", pf.l("sun.ci.totalBailouts"), t);
                metric("compiles", pf.l("sun.ci.totalCompiles"), t);
                Long inv = pf.l("sun.ci.totalInvalidates"), c = pf.l("sun.ci.totalCompiles");
                if (inv != null && c != null && c > 0) metric("invalidated_percent", 100.0 * inv / c, t);
            });
        }

        static void safepoints(List<Target> ts) {
            each(ts, t -> {
                Perf pf = t.perf();
                if (pf == null) return;
                metric("safepoints", pf.l("sun.rt.safepoints"), t);
                // Newer JVMs keep these in nanoseconds, older ones in the
                // timer's ticks: the same on Linux, not on Windows (a 10 MHz
                // timer). Ticks that add up to more time than the JVM has run
                // are nanoseconds.
                Long stopT = pf.l("sun.rt.safepointTime"), syncT = pf.l("sun.rt.safepointSyncTime"), appT = pf.l("sun.rt.applicationTime");
                Long up = pf.l("sun.os.hrt.ticks");
                double per = pf.hz;
                if (stopT != null && appT != null && up != null && up > 0 && (stopT + appT) / pf.hz > 1.5 * up / pf.hz) per = 1e9;
                if (stopT != null) metric("stopped_seconds", stopT / per, t);
                if (syncT != null) metric("sync_seconds", syncT / per, t);
                // Against its uptime, which the timer gives surely.
                if (stopT != null && up != null && up > 0) metric("stopped_percent_lifetime", 100.0 * (stopT / per) / (up / pf.hz), t);
            });
        }

        static void finalization(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                metric("pending", attrL(m, MEMORY, "ObjectPendingFinalizationCount"), t);
            });
        }

        // -- the machine, as the JVM sees it --

        static void os(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Double pl = attrD(m, OS, "ProcessCpuLoad"), sl = attrD(m, OS, "CpuLoad");
                if (sl == null) sl = attrD(m, OS, "SystemCpuLoad");
                if (pl != null && pl >= 0) metric("process_cpu_percent", 100 * pl, t);
                if (sl != null && sl >= 0) metric("system_cpu_percent", 100 * sl, t);
                Long pct = attrL(m, OS, "ProcessCpuTime");
                metric("process_cpu_seconds", pct == null || pct < 0 ? null : pct / 1e9, t);
                Double load = attrD(m, OS, "SystemLoadAverage");
                if (load != null && load >= 0) metric("load_average", load, t);
                metric("cpus", attrL(m, OS, "AvailableProcessors"), t);
                Long total = attrL(m, OS, "TotalMemorySize"), free = attrL(m, OS, "FreeMemorySize");
                if (total == null) total = attrL(m, OS, "TotalPhysicalMemorySize");
                if (free == null) free = attrL(m, OS, "FreePhysicalMemorySize");
                metric("memory_bytes", total, t);
                metric("memory_free_bytes", free, t);
                metric("swap_bytes", attrL(m, OS, "TotalSwapSpaceSize"), t);
                metric("swap_free_bytes", attrL(m, OS, "FreeSwapSpaceSize"), t);
                Long fds = attrL(m, OS, "OpenFileDescriptorCount"), max = attrL(m, OS, "MaxFileDescriptorCount");
                metric("open_files", fds, t);
                metric("open_files_max", max, t);
                if (fds != null && max != null && max > 0) metric("open_files_percent", 100.0 * fds / max, t);
            });
        }

        static void io(List<Target> ts) {
            each(ts, t -> {
                if (t.jmx != null && t.proc == null && Targets.isLocal(t.jmx)) mbs(t);
                Proc p = t.proc;
                if (p == null) return;
                metric("read_bytes", p.readBytes, t);
                metric("write_bytes", p.writeBytes, t);
                File fd = new File("/proc/" + p.pid + "/fd");
                File[] fs = fd.listFiles();
                if (fs == null) return;
                long sockets = 0, pipes = 0, files = 0, other = 0;
                for (File f : fs) {
                    String to;
                    try { to = Files.readSymbolicLink(f.toPath()).toString(); } catch (IOException e) { continue; }
                    if (to.startsWith("socket:")) sockets++;
                    else if (to.startsWith("pipe:")) pipes++;
                    else if (to.startsWith("/")) files++;
                    else other++;
                }
                metric("open", sockets, t, "kind", "socket");
                metric("open", pipes, t, "kind", "pipe");
                metric("open", files, t, "kind", "file");
                metric("open", other, t, "kind", "other");
            });
        }

        // -- trouble --

        /** The folders a JVM writes crash reports or heap dumps into, as far as can be told here. */
        static List<Path> dumpDirs(Target t, String option) {
            Set<Path> ds = new LinkedHashSet<>();
            if (t.proc != null) {
                String v = t.proc.opt(option);
                if (v != null) {
                    Path p = Paths.get(v);
                    ds.add(Files.isDirectory(p) ? p : (p.getParent() == null ? Paths.get(".") : p.getParent()));
                }
                if (!System.getProperty("os.name").toLowerCase(Locale.ROOT).contains("windows")) {
                    try { ds.add(Files.readSymbolicLink(Paths.get("/proc/" + t.proc.pid + "/cwd"))); } catch (IOException | UnsupportedOperationException e) { /* not ours */ }
                }
            }
            for (String d : env("JVM_DUMP_DIRS").split(";")) if (!d.trim().isEmpty()) ds.add(Paths.get(d.trim()));
            return new ArrayList<>(ds);
        }

        static void filesIn(List<Path> dirs, String glob, Target t, String what, String option) {
            long day = 0, newestAge = -1, bytes = 0, all = 0;
            long now = System.currentTimeMillis();
            boolean looked = false;
            for (Path d : dirs) {
                if (!Files.isDirectory(d)) continue;
                looked = true;
                try (DirectoryStream<Path> s = Files.newDirectoryStream(d, glob)) {
                    for (Path f : s) {
                        BasicFileAttributes a;
                        try { a = Files.readAttributes(f, BasicFileAttributes.class); } catch (IOException e) { continue; }
                        all++;
                        bytes += a.size();
                        long age = (now - a.lastModifiedTime().toMillis()) / 1000;
                        if (age < DAY) day++;
                        if (newestAge < 0 || age < newestAge) newestAge = age;
                    }
                } catch (IOException e) { /* cannot list */ }
            }
            if (!looked) return;
            metric(what + "_day", day, t);
            metric(what, all, t);
            metric(what + "_bytes", bytes, t);
            if (newestAge >= 0) metric("newest_" + what.replaceAll("s$", "") + "_age_seconds", newestAge, t);
        }

        static void crashes(List<Target> ts) {
            each(ts, t -> {
                if (t.jmx != null && t.proc == null && Targets.isLocal(t.jmx)) mbs(t);
                List<Path> dirs = dumpDirs(t, "-XX:ErrorFile=");
                filesIn(dirs, "hs_err_pid*.log", t, "crash_reports", "-XX:ErrorFile=");
                filesIn(dirs, "replay_pid*.log", t, "compiler_replays", null);
                filesIn(dirs, "core*", t, "core_dumps", null);
            });
        }

        static void oom(List<Target> ts) {
            each(ts, t -> {
                if (t.jmx != null && t.proc == null && Targets.isLocal(t.jmx)) mbs(t);
                List<Path> dirs = dumpDirs(t, "-XX:HeapDumpPath=");
                filesIn(dirs, "*.hprof", t, "heap_dumps", "-XX:HeapDumpPath=");
            });
        }

        static void jfr(List<Target> ts) {
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                Object r = attr(m, "jdk.management.jfr:type=FlightRecorder", "Recordings");
                if (r == null) { metric("available", 0, t); return; }
                metric("available", 1, t);
                long running = 0, all = 0;
                if (r instanceof CompositeData[]) {
                    for (CompositeData c : (CompositeData[]) r) {
                        all++;
                        if ("RUNNING".equals(String.valueOf(c.get("state")))) running++;
                    }
                }
                metric("recordings", all, t);
                metric("recordings_running", running, t);
            });
        }

        // -- your own --

        static void mbeans(List<Target> ts) {
            String spec = env("JVM_MBEANS");
            if (spec.trim().isEmpty()) {
                say("JVM_MBEANS is empty: name the attributes to report, as object name/attribute; ...");
                return;
            }
            each(ts, t -> {
                MBeanServerConnection m = mbs(t);
                if (m == null) return;
                int n = 0;
                for (String item : spec.split(";")) {
                    item = item.trim();
                    int slash = item.lastIndexOf('/');
                    if (slash <= 0 || n >= 100) continue;
                    String name = item.substring(0, slash), a = item.substring(slash + 1), key = null;
                    int dot = a.indexOf('.');
                    if (dot > 0) { key = a.substring(dot + 1); a = a.substring(0, dot); }
                    for (ObjectName o : query(m, name)) {
                        if (n++ >= 100) break;
                        Object v = attr(m, o.toString(), a);
                        if (key != null) v = v instanceof CompositeData && ((CompositeData) v).containsKey(key) ? ((CompositeData) v).get(key) : null;
                        if (v instanceof Boolean) v = ((Boolean) v) ? 1 : 0;
                        if (v instanceof Number) metric("value", (Number) v, t, "mbean", o.toString(), "attribute", key == null ? a : a + "." + key);
                    }
                }
            });
        }
    }

    // ---- small things -----------------------------------------------------

    static String str(Object o) { return o == null ? null : o.toString(); }

    /** 512m, 4g, 1024k, or bytes. */
    static Long bytes(String s) {
        try {
            s = s.trim().toLowerCase(Locale.ROOT);
            long mul = 1;
            char c = s.charAt(s.length() - 1);
            if (c == 'k') mul = 1L << 10; else if (c == 'm') mul = 1L << 20; else if (c == 'g') mul = 1L << 30; else if (c == 't') mul = 1L << 40;
            if (mul > 1) s = s.substring(0, s.length() - 1);
            return Long.parseLong(s) * mul;
        } catch (RuntimeException e) { return null; }
    }

    /** 1.8.0_402 is 8; 17.0.9 is 17. */
    static int feature(String version) {
        Matcher m = Pattern.compile("^(?:1\\.)?(\\d+)").matcher(version);
        return m.find() ? Integer.parseInt(m.group(1)) : 0;
    }

    static int javaFeature(MBeanServerConnection m, Target t) {
        String v = null;
        if (m != null) v = str(attr(m, "java.lang:type=Runtime", "SpecVersion"));
        if (v == null && t.perf() != null) v = t.perf().s("java.property.java.version");
        return v == null ? 0 : feature(v);
    }
}
