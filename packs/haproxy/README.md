# The haproxy pack

An HAProxy process, from its runtime API. The pack reads HAProxy itself (its version and uptime, its connections against `maxconn` and how often it reached it, its connection, session, request and TLS rates and their peaks, TLS session reuse, how busy its threads are, its run queue, its memory pools and their failures, dropped logs, failed DNS resolutions, its warnings and its stick-table peers), every frontend (open or not, sessions against its limit, rates, answers by status class, what it denied, requests it could not read, failed TLS handshakes), every backend (up or not, its servers up, its queue, how long requests wait, connect, and take, errors, retries and redispatches, how long it has been down), and every server with its health check (its state, its last check's result and code, how long since it changed, how often it failed and went down). The worst first. Linux and macOS: HAProxy does not run on Windows.

**A socket at `level user`, and bash.** The jobs send HAProxy's runtime API `show info` and `show stat`, and nothing else: a socket at `level user` answers those and refuses anything that would change HAProxy. Over TCP, bash reads it itself (`/dev/tcp`); a socket file is read with `socat` or `nc`.

1. **A socket for Vigil**, in `haproxy.cfg`'s `global` section, then reload HAProxy. Either a TCP address, from this machine only:

   ```haproxy
   stats socket ipv4@127.0.0.1:9999 level user
   ```

   or a socket file the account Vigil runs as may use (its group):

   ```haproxy
   stats socket /run/haproxy/vigil.sock mode 660 group vigil level user
   ```

   A socket HAProxy already has (Debian's `/run/haproxy/admin.sock`, Fedora's `/var/lib/haproxy/stats`) works too, when the account may use it: the pack only ever sends `show info` and `show stat`, but such a socket is often at `level admin`, and one at `level user` is the safer one to hand a monitor.
2. `vigil pack enable haproxy`, then in `vigil.config` set the jobs' `HAPROXY_SOCKET`: `127.0.0.1:9999`, or the socket file's path. Left empty, the jobs use the first of `/run/haproxy/admin.sock`, `/var/lib/haproxy/stats` and `/var/run/haproxy.sock` that is there.

**HAProxy that does not answer is a reading**, `up 0`, and the run succeeds. A socket this account may not use, or one that refuses `show info` or `show stat`, fails the run, saying so.

## What it needs

| | Linux | macOS |
| --- | --- | --- |
| On the Vigil machine | `bash`; for a socket file, `socat` or `nc` | `bash`; for a socket file, `nc` (built in) or `socat` |
| HAProxy | 2.4 and later | |
| A socket | `stats socket ... level user` (step 1) | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `haproxy_info` | HAProxy itself: version, uptime, threads, connections against `maxconn` and times it reached it, connection, session, request and TLS rates and peaks, TLS connections, full handshakes and session reuse, how busy its threads are, run queue, tasks, streams, stopping, open files, memory pools and failures, dropped logs, failed DNS resolutions, warnings, stick-table peers | minute |
| `haproxy_frontends` | Each frontend: open, sessions against its limit, session and request rates, requests, answers 1xx to 5xx, requests and answers denied, requests it could not read, bytes in and out, failed TLS handshakes | minute |
| `haproxy_backends` | Each backend, the down ones first: up, its servers (up, active, backup), sessions, queue and its peak, time in the queue, to connect, to the first byte and in all, connection and response errors, retries, redispatches, answers 4xx and 5xx, aborts by clients and servers, time down and since it changed | minute |
| `haproxy_servers` | Each server, the worst first: its state (up, draining, maintenance, down, not checked), its last check (L4OK, L4CON, L4TOUT, L7STS...) and code and how long it took, time since it changed and time down, checks failed and times it went down, sessions against its `maxconn`, queue, time to answer, 5xx, errors, weight | minute |

Each job's script says, in its header, what every metric means and what healthy, watch and bad look like.
