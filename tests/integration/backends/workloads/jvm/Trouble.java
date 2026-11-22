// Copyright (c) Bankole Ogundero and the Vigil contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. Run it at your own risk: review it first, and test it before you
// rely on it. In no event shall the authors or copyright holders be liable
// for any claim, damages or other liability arising from its use. See the
// LICENSE file for the full terms.
//
// Trouble.java - a JVM with problems on purpose, for the jvm pack's tests
// (scripts/run-jvm.sh). Java 8 and later: java Trouble <mode>...
//   busy        allocates steadily: young collections, a GC log to read
//   leak        keeps a little of what it allocates: old gen grows
//   gcstorm     allocates as fast as it can
//   deadlock    two threads, each holding the lock the other wants
//   contention  threads queueing for one lock
//   threadleak  starts a thread a second, each sleeping for ever (to 400)
//   offheap     direct buffers, 4 MB every two seconds (to 256 MB)
//   classleak   a classloader every five seconds, never freed (to 200)
//   finalizers  objects with a slow finalizer, piling up
//   oom         fills the heap until OutOfMemoryError, then lets it go
//   humongous   big arrays: G1 humongous allocations
//   hot         one thread in a busy loop
//   vthreads    virtual threads sleeping and waking (Java 21 and later)
//   crash       crashes the JVM, which writes hs_err_pid<pid>.log
// It runs until it is stopped.

import java.lang.reflect.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.concurrent.*;

public class Trouble {
    static final List<Object> keep = Collections.synchronizedList(new ArrayList<Object>());
    static volatile long sink;

    public static void main(String[] args) throws Exception {
        for (String m : args) start(m);
        System.out.println("trouble: " + String.join(" ", args));
        while (true) Thread.sleep(60_000);
    }

    static void start(String mode) throws Exception {
        switch (mode) {
            case "busy": loop("busy", () -> { byte[] b = new byte[64 * 1024]; sink += b.length; nap(2); }); break;
            case "leak": loop("leak", () -> { keep.add(new byte[16 * 1024]); if (keep.size() > 20_000) keep.subList(0, 1000).clear(); nap(50); }); break;
            case "gcstorm":
                for (int i = 0; i < 2; i++) loop("gcstorm-" + i, () -> { Object[] o = new Object[1000]; for (int k = 0; k < o.length; k++) o[k] = new byte[512]; sink += o.length; });
                break;
            case "deadlock": deadlock(); break;
            case "contention": contention(); break;
            case "threadleak": threadLeak(); break;
            case "offheap": loopN("offheap", 64, () -> { keep.add(ByteBuffer.allocateDirect(4 << 20)); nap(2000); }); break;
            case "classleak": classLeak(); break;
            case "finalizers": loop("finalizers", () -> { new Slow(); nap(5); }); break;
            case "oom": oom(); break;
            case "humongous": loop("humongous", () -> { byte[] b = new byte[8 << 20]; sink += b.length; nap(200); }); break;
            case "hot": loop("busy-loop", () -> { for (int i = 0; i < 1_000_000; i++) sink += i; }); break;
            case "vthreads": vthreads(); break;
            case "crash": crash(); break;
            default: throw new IllegalArgumentException("no mode " + mode);
        }
    }

    interface Step { void run() throws Exception; }

    static void loop(String name, Step s) { loopN(name, Long.MAX_VALUE, s); }

    static void loopN(String name, long times, Step s) {
        Thread t = new Thread(() -> {
            for (long i = 0; i < times; i++) {
                try { s.run(); } catch (OutOfMemoryError e) { keep.clear(); } catch (Exception e) { nap(1000); }
            }
            while (true) nap(60_000);
        }, name);
        t.setDaemon(true);
        t.start();
    }

    static void nap(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    static void deadlock() {
        final Object a = new Object(), b = new Object();
        Thread x = new Thread(() -> { synchronized (a) { nap(500); synchronized (b) { sink++; } } }, "deadlock-a");
        Thread y = new Thread(() -> { synchronized (b) { nap(500); synchronized (a) { sink++; } } }, "deadlock-b");
        x.setDaemon(true); y.setDaemon(true);
        x.start(); y.start();
    }

    static final Object HOT_LOCK = new Object();

    static void contention() {
        for (int i = 0; i < 8; i++) {
            loop("contender-" + i, () -> { synchronized (HOT_LOCK) { long e = System.nanoTime() + 20_000_000; while (System.nanoTime() < e) sink++; } });
        }
    }

    static void threadLeak() {
        loopN("threadleak", 400, () -> {
            Thread t = new Thread(() -> nap(Long.MAX_VALUE), "leaked-" + keep.size());
            t.setDaemon(true);
            t.start();
            keep.add(t);
            nap(1000);
        });
    }

    /** Payload: a class each new loader loads again. */
    public static class Payload { public static final byte[] DATA = new byte[1024]; }

    static void classLeak() {
        final URL here = Trouble.class.getProtectionDomain().getCodeSource().getLocation();
        loopN("classleak", 200, () -> {
            URLClassLoader l = new URLClassLoader(new URL[]{ here }, null);
            Class<?> c = l.loadClass("Trouble$Payload");
            keep.add(c);
            keep.add(l);
            nap(5000);
        });
    }

    static final class Slow {
        @SuppressWarnings("deprecation")
        protected void finalize() throws Throwable { Thread.sleep(50); }
    }

    static void oom() {
        Thread t = new Thread(() -> {
            nap(30_000);
            List<long[]> fill = new ArrayList<>();
            try {
                while (true) fill.add(new long[1 << 20]);
            } catch (OutOfMemoryError e) {
                fill.clear();
                System.out.println("trouble: ran out of memory, and let it go");
            }
            while (true) nap(60_000);
        }, "oom");
        t.setDaemon(true);
        t.start();
    }

    static void vthreads() throws Exception {
        Method of;
        try { of = Thread.class.getMethod("ofVirtual"); } catch (NoSuchMethodException e) { return; }
        Object builder = of.invoke(null);
        // Through the public interface: the builder's own class is internal.
        Method start = Class.forName("java.lang.Thread$Builder").getMethod("start", Runnable.class);
        for (int i = 0; i < 200; i++) {
            start.invoke(builder, (Runnable) () -> {
                while (true) {
                    long e = System.nanoTime() + 2_000_000;
                    while (System.nanoTime() < e) sink++;
                    nap(10);
                }
            });
        }
    }

    static void crash() throws Exception {
        Thread t = new Thread(() -> {
            nap(20_000);
            try {
                Field f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
                f.setAccessible(true);
                Object u = f.get(null);
                u.getClass().getMethod("putAddress", long.class, long.class).invoke(u, 0L, 0L);
            } catch (Exception e) {
                System.out.println("trouble: could not crash: " + e);
            }
        }, "crash");
        t.start();
    }
}
