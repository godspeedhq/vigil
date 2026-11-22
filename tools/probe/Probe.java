// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// Probe.java - the probe's main (tools/probe/DESIGN.md): one job of a pack,
// from the pack's tables file.
//
//   java -cp _probe.jar Probe <tables file> <job>
//
// The tables file: settings, then a section for each job ([throughput], or
// the job's whole name), each a list of rows:
//
//   targets   <setting: the targets, jmx=host:port or jmxs=host:port>
//   user      <setting: the JMX user>
//   password  <setting: its password, a secret line>
//   cacert    <setting: a PEM file of CAs>
//   name      <tag> <MBean pattern> <key>   each target named by that key
//
//   [job]
//   <metric> <MBean> <attribute or attribute.key> [<key>...] [+tag=value] [*n] [>=n] [sum]
//   when <MBean> <attribute>       the rows after it, only when it is above 0
//
// Exit code: 0 on success, targets up or down; 1 if the tables file or a
// setting is wrong, or a target refuses the login or its certificate.

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import javax.management.*;

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
                        if (w.length != 4) throw new IllegalArgumentException("name <tag> <MBean pattern> <key>");
                        name = new String[]{ w[1], w[2], w[3] };
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
                    boolean sum = false;
                    for (int i = 3; i < w.length; i++) {
                        String x = w[i];
                        if (x.startsWith("+") && x.indexOf('=') > 1) { fixed.add(x.substring(1, x.indexOf('='))); fixed.add(x.substring(x.indexOf('=') + 1)); }
                        else if (x.startsWith("*")) scale = Double.parseDouble(x.substring(1));
                        else if (x.startsWith(">=")) floor = Double.parseDouble(x.substring(2));
                        else if (x.equals("sum")) sum = true;
                        else if (x.matches("[A-Za-z0-9_.-]+")) tags.add(x);
                        else throw new IllegalArgumentException("not a tag, +tag=value, *n, >=n or sum: " + x);
                    }
                    it.row = Jmx.row(w[0], w[1], w[2], tags.toArray(new String[0])).scale(scale).atLeast(floor).with(fixed.toArray(new String[0]));
                    if (sum) it.row.sum();
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
                if (m != null && name != null) {
                    for (ObjectName o : Jmx.query(m, name[1])) {
                        String v = o.getKeyProperty(name[2]);
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
