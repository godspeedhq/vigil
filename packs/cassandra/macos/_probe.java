// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// _probe.java - the probe (tools/probe/DESIGN.md), as tools/probe/gen.py
// writes it from tools/probe/Probe.java and tools/probe/Jmx.java: one
// generic tool for application packs, which reads their tables (MBeans over
// JMX) and prints Vigil's metric lines. Every pack that carries it ships this
// same file, built by its release into _probe.jar. It reads only.

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.KeyStore;
import java.security.cert.*;
import java.util.*;
import java.util.concurrent.*;
import javax.management.*;
import javax.management.openmbean.*;
import javax.management.remote.*;
import javax.net.ssl.*;
import javax.rmi.ssl.SslRMIClientSocketFactory;

final class Probe {

    private Probe() { }

    /** A row, or a gate: the rows after it only when its value is above 0. */
    static final class Item {
        Jmx.Row row;
        String whenPattern, whenAttribute;
    }

    public static void main(String[] args) {
        if (args.length != 2) { System.err.println("usage: java -cp _probe.jar Probe <tables file> <job>"); System.exit(2); }
        Jmx.job = args[1];
        Map<String, String> set = new HashMap<>();
        String[] name = null;
        List<Item> items = null;
        String section = null;
        int lineNo = 0;
        try {
            for (String raw : Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8)) {
                lineNo++;
                String l = raw.trim();
                if (l.isEmpty() || l.startsWith("#")) continue;
                if (l.startsWith("[") && l.endsWith("]")) {
                    section = l.substring(1, l.length() - 1).trim();
                    boolean mine = section.equals(args[1]) || args[1].endsWith("_" + section);
                    if (items != null && mine) throw new IllegalArgumentException("a second [" + section + "]");
                    if (mine) items = new ArrayList<>();
                    continue;
                }
                String[] w = l.split("\\s+");
                if (section == null) {
                    if (w[0].equals("name")) {
                        if (w.length != 4 && w.length != 2) throw new IllegalArgumentException("name <tag> <MBean pattern> <key>, or name <tag>");
                        if (!w[1].matches("[A-Za-z0-9_.-]+")) throw new IllegalArgumentException("not a tag: " + w[1]);
                        name = w.length == 4 ? new String[]{ w[1], w[2], w[3] } : new String[]{ w[1], null, null };
                    } else if (w.length == 2 && w[0].matches("targets|user|password|cacert")) {
                        set.put(w[0], w[1]);
                    } else {
                        throw new IllegalArgumentException("not a setting: " + l);
                    }
                    continue;
                }
                if (items == null || !(section.equals(args[1]) || args[1].endsWith("_" + section))) continue;
                Item it = new Item();
                if (w[0].equals("when")) {
                    if (w.length != 3) throw new IllegalArgumentException("when <MBean> <attribute>");
                    it.whenPattern = w[1];
                    it.whenAttribute = w[2];
                } else {
                    if (w.length < 3) throw new IllegalArgumentException("<metric> <MBean> <attribute> [...]");
                    Jmx.on(w[1]);
                    List<String> tags = new ArrayList<>(), fixed = new ArrayList<>();
                    double scale = 1, floor = Double.NEGATIVE_INFINITY;
                    boolean sum = false, top = false, age = false;
                    String[] states = null;
                    String text = null;
                    List<String[]> without = new ArrayList<>();
                    for (int i = 3; i < w.length; i++) {
                        String x = w[i];
                        if (x.startsWith("+") && x.indexOf('=') > 1) { fixed.add(x.substring(1, x.indexOf('='))); fixed.add(x.substring(x.indexOf('=') + 1)); }
                        else if (x.startsWith("-") && x.indexOf('=') > 1) without.add(new String[]{ x.substring(1, x.indexOf('=')), x.substring(x.indexOf('=') + 1) });
                        else if (x.startsWith("=") && x.length() > 1) states = x.substring(1).split("\\|");
                        else if (x.matches("@[A-Za-z0-9_.-]+")) text = x.substring(1);
                        else if (x.startsWith("*")) scale = Double.parseDouble(x.substring(1));
                        else if (x.startsWith(">=")) floor = Double.parseDouble(x.substring(2));
                        else if (x.equals("sum")) sum = true;
                        else if (x.equals("top")) top = true;
                        else if (x.equals("age")) age = true;
                        else if (x.matches("[A-Za-z0-9_.-]+/?")) tags.add(x);
                        else throw new IllegalArgumentException("not a tag, +tag=value, -key=pattern, =STATE, @tag, *n, >=n, sum, top or age: " + x);
                    }
                    if (sum && top) throw new IllegalArgumentException("sum or top, not both");
                    if ((states != null ? 1 : 0) + (text != null ? 1 : 0) + (age ? 1 : 0) > 1) throw new IllegalArgumentException("one of =STATE, @tag and age");
                    if (text != null && (sum || top)) throw new IllegalArgumentException("@tag is a text: not with sum or top");
                    it.row = Jmx.row(w[0], w[1], w[2], tags.toArray(new String[0])).scale(scale).atLeast(floor).with(fixed.toArray(new String[0]));
                    if (sum) it.row.sum();
                    if (top) it.row.top();
                    if (states != null) it.row.states(states);
                    if (text != null) it.row.text(text);
                    if (age) it.row.age();
                    for (String[] x : without) it.row.without(x[0], x[1]);
                }
                items.add(it);
            }
        } catch (IOException e) {
            Jmx.fail("cannot read the tables file " + args[0] + ": " + e.getMessage());
            exit();
        } catch (IllegalArgumentException e) {
            Jmx.fail(args[0] + ", line " + lineNo + ": " + e.getMessage());
            exit();
        }
        if (items == null) { Jmx.fail("no section for " + args[1] + " in " + args[0]); exit(); }
        if (!set.containsKey("targets")) { Jmx.fail(args[0] + ": no targets setting"); exit(); }
        Jmx.settings(set.getOrDefault("user", "JMX_USER"), set.getOrDefault("password", "JMX_PASSWORD"), set.getOrDefault("cacert", "JMX_CACERT"));
        List<Jmx.Target> ts;
        try {
            ts = Jmx.targets(set.get("targets"));
        } catch (IllegalArgumentException e) {
            Jmx.fail(e.getMessage());
            exit();
            return;
        }
        if (ts.isEmpty()) Jmx.say("no " + set.get("targets") + ": nothing to read (jmx=host:port or jmxs=host:port)");
        String tagName = name == null ? "target" : name[0];
        try {
            for (Jmx.Target t : ts) {
                MBeanServerConnection m = t.mbs();
                if (m != null && name != null && name[1] != null) {
                    for (ObjectName o : Jmx.query(m, name[1])) {
                        String v = Jmx.unquote(o.getKeyProperty(name[2]));
                        if (v != null) t.name = v;
                    }
                }
                String[] tags = { tagName, t.name, "jmx", t.address };
                Jmx.metric("jmx_up", m != null, tags);
                if (m == null) continue;
                List<Jmx.Row> chunk = new ArrayList<>();
                for (Item it : items) {
                    if (it.row != null) { chunk.add(it.row); continue; }
                    Jmx.table(t, chunk, tags);
                    chunk = new ArrayList<>();
                    Number gate = Jmx.number(Jmx.attr(m, it.whenPattern, it.whenAttribute), null);
                    if (gate == null || gate.doubleValue() <= 0) { chunk = null; break; }
                }
                if (chunk != null) Jmx.table(t, chunk, tags);
            }
        } finally {
            Jmx.closeAll(ts);
        }
        exit();
    }

    static void exit() {
        Jmx.OUT.flush();
        System.exit(Jmx.exitCode);
    }
}

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
     * separated by ; or , and a bare host:port as jmx=. Each may have a name
     * of its own first (web1: jmxs=host:port), else it is named by its
     * address, or by the pack's name row. Empty: none.
     */
    static List<Target> targets(String var) {
        List<Target> ts = new ArrayList<>();
        for (String part : env(var).split("[;,]")) {
            String p = part.trim();
            if (p.isEmpty()) continue;
            String label = null;
            java.util.regex.Matcher named = java.util.regex.Pattern.compile("([A-Za-z0-9_.-]+):\\s*(jmxs?=.*)").matcher(p);
            if (named.matches()) { label = named.group(1); p = named.group(2).trim(); }
            boolean tls = false;
            if (p.startsWith("jmxs=")) { tls = true; p = p.substring(5).trim(); }
            else if (p.startsWith("jmx=")) p = p.substring(4).trim();
            if (!p.matches("[^\\s:=]+:[0-9]{1,5}") && !p.matches("\\[[0-9A-Fa-f:.]+\\]:[0-9]{1,5}")) {
                throw new IllegalArgumentException(var + ": not jmx=host:port or jmxs=host:port, with a name first or not (web1: jmxs=host:port): " + part.trim());
            }
            Target t = new Target(p, tls);
            if (label != null) t.name = label;
            ts.add(t);
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
            // A refused login, however the server says it: the JDK's agent a
            // SecurityException; Cassandra's a LoginException, deeper down.
            if (hasCause(c, SecurityException.class) || hasCause(c, javax.security.auth.login.LoginException.class)
                    || why.contains("Authentication failed") || why.contains("Invalid credentials")
                    || why.contains("Credentials required") || why.contains("Invalid username or password")) {
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
        /** The MBeans that match, added up by their tags: one line for each. */
        boolean sum;

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

        /** The MBeans that match added up, one line for each set of tags. */
        Row sum() {
            sum = true;
            return this;
        }

        /** Tags of its own, the same for every MBean it reads: name, value, ... */
        Row with(String... tags) {
            fixed = tags;
            return this;
        }

        /** A state as a number: 1 when the attribute's text is one of these (case aside), else 0. */
        String[] states;
        /** Its MBeans in order of its value, largest first, for every row of its pattern: the worst shown, not the first. */
        boolean top;
        /** MBeans left out: a key of their name, and its value's pattern (* any characters). */
        final List<String[]> excludes = new ArrayList<>();

        Row states(String... s) {
            states = s;
            return this;
        }

        Row top() {
            top = true;
            return this;
        }

        /** Leaves out the MBeans whose key k has a value like glob (* any characters). */
        Row without(String k, String glob) {
            excludes.add(new String[]{ k, glob });
            return this;
        }

        /** Its pattern and what it leaves out: the rows that read the same MBeans. */
        String group() {
            StringBuilder b = new StringBuilder(pattern);
            for (String[] x : excludes) b.append(" -").append(x[0]).append('=').append(x[1]);
            return b.toString();
        }

        boolean keeps(ObjectName o) {
            for (String[] x : excludes) {
                String v = o.getKeyProperty(x[0]);
                if (v != null && like(unquote(v), x[1])) return false;
            }
            return true;
        }

        /** The attribute's text as this tag, the value 1: a version, a role. */
        String textTag;
        /** The seconds since the attribute's time (milliseconds since 1970): since a start. */
        boolean age;

        Row text(String tag) {
            textTag = tag;
            return this;
        }

        Row age() {
            age = true;
            return this;
        }

        /** The attribute's value itself, or key k of a composite one; null when there is none. */
        Object raw(Object v) {
            if (key == null) return v;
            if (!(v instanceof CompositeData) || !((CompositeData) v).containsKey(key)) return null;
            return ((CompositeData) v).get(key);
        }

        /** Its value from an attribute's: a number, 1 or 0 for a state, 1 for a text, an age; null when there is none. */
        Number value(Object v) {
            if (states == null && textTag == null && !age) return number(v, key);
            v = raw(v);
            if (v == null) return null;
            if (age) {
                if (!(v instanceof Number) || ((Number) v).longValue() <= 0) return null;
                return Math.max(0, (System.currentTimeMillis() - ((Number) v).longValue()) / 1000);
            }
            if (textTag != null) return String.valueOf(v).trim().isEmpty() ? null : 1;
            String s = String.valueOf(v).trim();
            for (String x : states) if (x.equalsIgnoreCase(s)) return 1;
            return 0;
        }
    }

    /** A row's tag: a key of the MBean's name, or key/ for its value after the last / (Jetty's server@hash/h1: h1). */
    static String tagName(String t) {
        return t.endsWith("/") ? t.substring(0, t.length() - 1) : t;
    }

    /** The value of tag t for MBean o: its key's value, unquoted, or after the last / for key/. */
    static String keyTag(ObjectName o, String t) {
        String v = unquote(o.getKeyProperty(tagName(t)));
        if (v == null || !t.endsWith("/")) return v;
        return v.substring(v.lastIndexOf('/') + 1);
    }

    /** A key's value without the quotes JMX puts around some ("http-nio-8080"). */
    static String unquote(String v) {
        if (v != null && v.length() >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
            try { return ObjectName.unquote(v); } catch (IllegalArgumentException e) { return v.substring(1, v.length() - 1); }
        }
        return v;
    }

    /** Whether s is like glob, where * is any characters. */
    static boolean like(String s, String glob) {
        String[] parts = glob.split("\\*", -1);
        StringBuilder r = new StringBuilder();
        for (int i = 0; i < parts.length; i++) {
            if (i > 0) r.append(".*");
            r.append(java.util.regex.Pattern.quote(parts[i]));
        }
        return s.matches(r.toString());
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
     * counted in <metric>_not_shown: the first by name, or with a top row,
     * the largest by its value, for every row of that pattern. One round
     * trip for each MBean, every attribute its rows want at once.
     */
    static void table(Target t, List<Row> rows, String... tags) {
        MBeanServerConnection m = t.mbs();
        if (m == null) return;
        Map<String, List<ObjectName>> found = new HashMap<>();
        Map<String, Row> order = new HashMap<>();
        for (Row r : rows) {
            found.computeIfAbsent(r.group(), g -> {
                List<ObjectName> l = new ArrayList<>();
                for (ObjectName o : on(r.pattern).isPattern() ? query(m, r.pattern) : exists(m, r.pattern)) if (r.keeps(o)) l.add(o);
                return l;
            });
            if (r.top) order.putIfAbsent(r.group(), r);
        }
        Map<ObjectName, Set<String>> wanted = new LinkedHashMap<>();
        for (Row r : rows) {
            boolean all = r.sum || order.containsKey(r.group());
            int n = 0;
            for (ObjectName o : found.get(r.group())) {
                if (++n > LIST_CAP && !all) break;
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
        // The worst first: by the top row's value, largest first, those with none last; ties by name.
        for (Map.Entry<String, Row> e : order.entrySet()) {
            Row r = e.getValue();
            Map<ObjectName, Double> by = new HashMap<>();
            for (ObjectName o : found.get(e.getKey())) {
                Number v = r.value(values.getOrDefault(o, Collections.emptyMap()).get(r.attribute));
                by.put(o, v == null ? Double.NEGATIVE_INFINITY : v.doubleValue());
            }
            found.get(e.getKey()).sort((a, b) -> Double.compare(by.get(b), by.get(a)));
        }
        for (Row r : rows) {
            List<ObjectName> names = found.get(r.group());
            if (r.sum) {
                sum(r, names, values, tags);
                continue;
            }
            int n = 0;
            for (ObjectName o : names) {
                if (++n > LIST_CAP) break;
                Object got = values.getOrDefault(o, Collections.emptyMap()).get(r.attribute);
                Number v = r.value(got);
                if (v == null || v.doubleValue() < r.floor) continue;
                String[] all = Arrays.copyOf(tags, tags.length + 2 * r.tags.length + r.fixed.length + (r.textTag == null ? 0 : 2));
                for (int i = 0; i < r.tags.length; i++) {
                    all[tags.length + 2 * i] = tagName(r.tags[i]);
                    all[tags.length + 2 * i + 1] = keyTag(o, r.tags[i]);
                }
                System.arraycopy(r.fixed, 0, all, tags.length + 2 * r.tags.length, r.fixed.length);
                if (r.textTag != null) {
                    all[all.length - 2] = r.textTag;
                    all[all.length - 1] = String.valueOf(r.raw(got)).trim();
                }
                metric(r.metric, r.scale == 1 ? v : v.doubleValue() * r.scale, all);
            }
            if (names.size() > LIST_CAP) metric(r.metric + "_not_shown", names.size() - LIST_CAP, tags);
        }
    }

    /** Row r's MBeans, added up by the tags they print with: one line each, up to LIST_CAP. */
    static void sum(Row r, List<ObjectName> names, Map<ObjectName, Map<String, Object>> values, String[] tags) {
        Map<List<String>, double[]> by = new TreeMap<>(Comparator.comparing(Object::toString));
        for (ObjectName o : names) {
            Number v = r.value(values.getOrDefault(o, Collections.emptyMap()).get(r.attribute));
            if (v == null) continue;
            List<String> k = new ArrayList<>();
            for (String t : r.tags) k.add(keyTag(o, t));
            by.computeIfAbsent(k, x -> new double[1])[0] += v.doubleValue();
        }
        int n = 0;
        for (Map.Entry<List<String>, double[]> e : by.entrySet()) {
            if (++n > LIST_CAP) break;
            double v = e.getValue()[0] * r.scale;
            if (v < r.floor) continue;
            String[] all = Arrays.copyOf(tags, tags.length + 2 * r.tags.length + r.fixed.length);
            for (int i = 0; i < r.tags.length; i++) {
                all[tags.length + 2 * i] = tagName(r.tags[i]);
                all[tags.length + 2 * i + 1] = e.getKey().get(i);
            }
            System.arraycopy(r.fixed, 0, all, tags.length + 2 * r.tags.length, r.fixed.length);
            metric(r.metric, v, all);
        }
        if (by.size() > LIST_CAP) metric(r.metric + "_not_shown", by.size() - LIST_CAP, tags);
    }

    /** The one MBean named, or none. */
    static SortedSet<ObjectName> exists(MBeanServerConnection m, String name) {
        SortedSet<ObjectName> s = new TreeSet<>();
        try { if (m.isRegistered(on(name))) s.add(on(name)); } catch (Exception e) { /* not there */ }
        return s;
    }
}
