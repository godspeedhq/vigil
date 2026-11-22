// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// Jmx.java - the shared JMX engine (tools/jmx/DESIGN.md): what every pack for
// a Java application needs of JMX. A pack's generator copies it into the
// pack's _client.java, after the pack's own client, so each pack stands
// alone. It connects over RMI, plain or TLS, with a login; checks every
// certificate, its chain and its name; gives up in time; reads MBeans by
// tables of rows; and prints Vigil's metric lines. It reads only.

import java.io.*;
import java.net.*;
import java.security.KeyStore;
import java.security.cert.*;
import java.util.*;
import java.util.concurrent.*;
import javax.management.*;
import javax.management.openmbean.*;
import javax.management.remote.*;
import javax.net.ssl.*;
import javax.rmi.ssl.SslRMIClientSocketFactory;

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
        } catch (TimeoutException e) {
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

        /** Its value times s: 0.001 for ns to µs, 100 for a fraction to a percent. */
        Row scale(double s) {
            scale = s;
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
                if (v == null) continue;
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
