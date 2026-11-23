// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// Fixture.java - MBeans made for the probe's test (probe-test.sh), served
// over plain JMX on this machine only, at a free port it prints:
//
//   java Fixture.java        ready <port>, then serves until it is stopped
//
//   fixture:type=Queue,name=q000 ... q149    Size (a mix of 0 to 149; q007
//                                            9999, the worst) and Enqueued
//   fixture:type=Queue,name=ActiveMQ.Advisory.<n>   three, Size 50000: noise
//   fixture:type=App,name="//localhost/<app>"  stateName STARTED, FAILED or
//                                            STOPPED; available, a boolean
//   fixture:type=Pool,name="http-nio-8080"   busy, max: a quoted name
//   fixture:type=Memory                      Usage, a composite: used, state
//   fixture:type=sessioncache,context=oejs_Server@1a2b3c/_shop   a key with
//                                            a hash a restart changes (Jetty's)
//   fixture:type=Server                      serverNumber, a text; startTime,
//                                            an hour ago; neverTime, 0

import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.rmi.registry.LocateRegistry;
import java.rmi.server.RMIServerSocketFactory;
import java.util.*;
import javax.management.*;
import javax.management.openmbean.*;
import javax.management.remote.*;
import javax.management.remote.rmi.RMIConnectorServer;

public final class Fixture {

    private Fixture() { }

    /** An MBean of fixed attributes, read only. */
    static final class Bean implements DynamicMBean {
        final Map<String, Object> a = new LinkedHashMap<>();

        Bean put(String k, Object v) {
            a.put(k, v);
            return this;
        }

        public Object getAttribute(String n) throws AttributeNotFoundException {
            if (!a.containsKey(n)) throw new AttributeNotFoundException(n);
            return a.get(n);
        }

        public AttributeList getAttributes(String[] ns) {
            AttributeList l = new AttributeList();
            for (String n : ns) if (a.containsKey(n)) l.add(new Attribute(n, a.get(n)));
            return l;
        }

        public void setAttribute(Attribute x) { throw new UnsupportedOperationException("read only"); }

        public AttributeList setAttributes(AttributeList l) { return new AttributeList(); }

        public Object invoke(String op, Object[] p, String[] s) { throw new UnsupportedOperationException("read only"); }

        public MBeanInfo getMBeanInfo() {
            List<MBeanAttributeInfo> ai = new ArrayList<>();
            for (Map.Entry<String, Object> e : a.entrySet()) {
                String type = e.getValue() instanceof CompositeData ? CompositeData.class.getName() : e.getValue().getClass().getName();
                ai.add(new MBeanAttributeInfo(e.getKey(), type, e.getKey(), true, false, false));
            }
            return new MBeanInfo(Bean.class.getName(), "the probe's test", ai.toArray(new MBeanAttributeInfo[0]), null, null, null);
        }
    }

    public static void main(String[] args) throws Exception {
        MBeanServer s = ManagementFactory.getPlatformMBeanServer();
        for (int i = 0; i < 150; i++) {
            long size = i == 7 ? 9999 : (i * 37L) % 150;
            s.registerMBean(new Bean().put("Size", size).put("Enqueued", 10L * i), new ObjectName(String.format("fixture:type=Queue,name=q%03d", i)));
        }
        for (int i = 0; i < 3; i++) {
            s.registerMBean(new Bean().put("Size", 50000L).put("Enqueued", 1L), new ObjectName("fixture:type=Queue,name=ActiveMQ.Advisory." + i));
        }
        String[][] apps = { { "shop", "STARTED" }, { "broken", "FAILED" }, { "stopped", "STOPPED" } };
        for (String[] app : apps) {
            s.registerMBean(new Bean().put("stateName", app[1]).put("available", app[1].equals("STARTED")),
                new ObjectName("fixture:type=App,name=" + ObjectName.quote("//localhost/" + app[0])));
        }
        s.registerMBean(new Bean().put("busy", 5).put("max", 200), new ObjectName("fixture:type=Pool,name=" + ObjectName.quote("http-nio-8080")));
        s.registerMBean(new Bean().put("sessionsCurrent", 3L), new ObjectName("fixture:type=sessioncache,context=oejs_Server@1a2b3c/_shop,id=0"));
        s.registerMBean(new Bean().put("serverNumber", "11.0.29.0").put("startTime", System.currentTimeMillis() - 3600_000L).put("neverTime", 0L),
            new ObjectName("fixture:type=Server"));
        CompositeType ct = new CompositeType("Usage", "usage", new String[]{ "used", "state" }, new String[]{ "used", "state" },
            new OpenType<?>[]{ SimpleType.LONG, SimpleType.STRING });
        s.registerMBean(new Bean().put("Usage", new CompositeDataSupport(ct, new String[]{ "used", "state" }, new Object[]{ 10L, "OK" })),
            new ObjectName("fixture:type=Memory"));

        int port;
        try (ServerSocket f = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) { port = f.getLocalPort(); }
        System.setProperty("java.rmi.server.hostname", "localhost");
        // This machine only: the registry and the connector on the loopback address.
        RMIServerSocketFactory local = p -> new ServerSocket(p, 50, InetAddress.getLoopbackAddress());
        LocateRegistry.createRegistry(port, null, local);
        Map<String, Object> env = new HashMap<>();
        env.put(RMIConnectorServer.RMI_SERVER_SOCKET_FACTORY_ATTRIBUTE, local);
        JMXServiceURL u = new JMXServiceURL("service:jmx:rmi://localhost:" + port + "/jndi/rmi://localhost:" + port + "/jmxrmi");
        JMXConnectorServerFactory.newJMXConnectorServer(u, env, s).start();
        System.out.println("ready " + port);
        System.out.flush();
        Thread.sleep(Long.MAX_VALUE);
    }
}
