# Bugs and problems found by the fleet test (2026-11-26)

Each entry: what happens, what should happen, the evidence, where it was
seen. Found in run 1 (`../fleet/`) or run 2 (this folder). Nothing here is
fixed yet, except where marked: this is the list to plan the fixes from.

## Vigil

### B5. The metric sender livelocks: once a run outlasts max_runtime, metrics stop (most serious; fixed in #281)

- **Status: fixed, merged 2026-11-28** (#281, backlog 68). The cause was the bash sender's OTLP count handling, not sending. A batch's counts and the backend's running totals were each kept as one string, and each series was found by pattern matching, which in bash takes time that grows with the square of the string's length. One 160 KB batch took 52 s of CPU (bash 5.3) and 115 s (bash 3.2); now 2.3 s and 11 s, with byte-for-byte the same output. With the fix in place, fedora-c1's backlog of 1,711 files drained in 34 minutes and a sender run finished on its own for the first time in three hours. Evidence: `../sender-totals/`.

- **Seen:** run 2, every Alpine container. These are small instances: bash Vigil and the base pack, capped at half a CPU and 64 MB.
- **What happens:**
  1. When the backlog grows, a sender run takes longer each time. fedora-c1's runs: 197 s, 267 s, 287 s, then fedora-c2's 308 s.
  2. Past the 5-minute `max_runtime`, the supervisor kills every run ("passed max_runtime; sent TERM to its job", then "timed out").
  3. A killed run sends nothing, so the next run starts with more to do and is killed too.
  4. The instance keeps running its jobs and taking configurations, but no metric had reached the backend for about 30 minutes when this was captured, and the spool was still growing.
- **The numbers:**
  - Each Fedora container was killed 5–6 times in a row from about 20:35. At 21:06 their spools held 400–530 files, about 2 MB each.
  - The Lenovo containers had sent no metric for more than 5 minutes, and the Mac and HP containers were 4–5 minutes behind and falling.
  - Every bare-metal instance stayed current, its newest metric 17–27 s old.
  - On the dashboard (`00-whole-run.png`), "Instances by kind" shows the containers reporting fall from 19 to 7 over the hour.
- **Should:** a sender that cannot send everything in one run should still make progress. It could send a bounded batch per run and commit what was sent, so a backlog drains over several runs. It should also say clearly in metrics and in `vigil status` that it is falling behind.
- **Related:** B2 (the sender's cost per event) makes this likely on small hosts. The livelock itself is the bug: any backlog large enough, from an outage or a slow link, would cause it on any host.
- **Evidence:** `11-sender-livelock.txt`, `00-whole-run.png`, `08-backend.png`.

### B1. Forwarded log lines carry the revision active when they are sent, not when they were written (fixed in #284)

- **Status: fixed, merged 2026-11-28** (#284, backlog 70). The supervisor records each revision it activates, with its tags and the time, in `state/config.history`; the forwarder gives each line the revision active at the line's own time, and a request never mixes two.

- **Seen:** run 1, wave 3 (linux containers on Fedora).
- **Specification (§14, log forwarding):** every record carries "the active configuration revision" and the `[tags]`.
- **What happens:** the forwarder tags a line with the revision and `[tags]` (such as `wave`) active when it sends the line. Near a change, lines get the wrong configuration, in both directions:
  - fedora-c1: lines written at 18:15:38 and 18:15:44 carry revision `a21e3a374b61`, which loaded only at 18:15:47.
  - On 6 of 10 containers, the line "configuration revision a21e3a374b61 loaded" itself carries the previous revision, `df547f88403b`.
- **Why it matters:** the minutes around a push are exactly when someone reads the logs to judge whether the push was bad.
- **Evidence:** `../fleet/findings.txt`, section 2.
- **Run 2:** 21 activation lines carry a revision other than the one they announce, across waves 10–17 (`10-followup-gitea-and-activations.txt`). A query by tag therefore undercounts activations: by the `wave` tag, round 1 shows 19 of 24.

### B2. The metric sender is slow, and falls behind under load (fixed in #281)

- **Status: fixed with B5, same cause.** Merging the 30 KB totals file alone cost about 12 s of CPU per batch, whatever the batch's size.

- **Seen:** run 1, Alpine containers (bash Vigil, base pack).
- **What happens:** the sender is the largest share of an instance's CPU, about 8 of roughly 18 CPU seconds a minute. On a host short of CPU, sender runs took minutes, and metrics reached the backend 4–5 minutes late. Nothing was lost.
- **Evidence:** `../fleet/findings.txt`, sections 3 and 4.
- **Run 2 (24 instances):**
  - Round 1: by their own logs, every instance activated wave 10 between 6 and 56 s after the push, but Prometheus showed all of them only at 204 s.
  - Round 2: 18 of 22 were on wave 11 in Prometheus at the 300 s limit.
  - Ages of the newest metric, a little after round 2: lenovo-c1 282 s, lenovo-c5 255 s, lenovo-c4 242 s, fedora-c1 220 s, lenovo-c3 201 s, fedora-c3 187 s, fedora-c4 159 s, fedora-c2 134 s.
  - So the delay is metric delivery, not configuration: the containers on two hosts (Lenovo, with 5 containers and the bare-metal Windows instance; Fedora, with 4) deliver their metrics minutes late.
  - **The sender falls behind and cannot catch up (20:30).**
    - fedora-c2 (0.5 CPU cap) had Fedora's load down to 2.3, yet its sender took 240 s and 28 CPU seconds a run, against 2.8 in run 1. Its spool held 83 files (332 KB), the supervisor writing an events file every 10 s.
    - Sender runs, from its job log:
      ```
      20:21:56 run end succeeded in 240s, cpu 28.17s
      20:23:04 run end succeeded in 61s, cpu 6.54s
      20:26:51 run end succeeded in 209s, cpu 23.87s
      ```
    - At the same time, the Lenovo containers' logs were current (20:29) but their newest metrics were over 5 minutes old, and the dashboard shows none of them.
    - The sender's cost grows with its backlog: a slow run leaves more for the next. Look at the cost per spooled event, which is about 12 KB per CPU second here.

### B3. On Windows, a check of the configuration's source costs 5–8 CPU seconds (fixed in #285)

- **Status: fixed, merged 2026-11-28** (#285, backlog 71). Most of it was validating the fetched configuration in each new PowerShell process, the same file nearly every time. A file that passed is now recorded and not validated again under the same Vigil: median 7.1 s of CPU a check on the HP, now 2.9.

- **Seen:** run 1, Windows 11 (HP, Lenovo).
- **What happens:** `vigil_fetch` uses 4.9–7.8 s of CPU per run, against 0.55–0.80 s on Linux and about 1.1 s on macOS. At a 30 s `check_every`, that is about a fifth of a core.
- **Evidence:** `../fleet/wave-4-unknown.txt`.

### B4. A refused configuration and an unreachable source look the same in metrics (not a Vigil bug; tests in #287)

- **Seen:** run 1, wave 4.
- **What happens:** both raise only `vigil_source_failures_total`, and `vigil_supervisor_config_reload_failed` stays 0. Only the log tells them apart: `line 93: unknown section [fleet_nonsense] (E_SECTION_UNKNOWN)`.
- **Decide:** whether this is worth a metric, given that Vigil should stay simple.
- **Resolved (2026-11-28):** Vigil already tells them apart. `vigil.source.failures` carries `reason`: `invalid` for a refused configuration, `unreachable` (or `timeout`, `auth`, `digest`) otherwise (§14.5). The fleet dashboard summed the counter without it. Now:
  - PR #287 tests both reasons in `fetch.sh` and `Fetch.ps1`.
  - The dashboard's two panels, and `run-all.sh`'s counts, split by reason.
- **Evidence:** `../fleet/findings.txt`, section 6.

### B6. A stopped sender's leftover process keeps its run alive, reported as ORPHANED

- **Status: fixed, merged 2026-11-28** (#282, backlog 69). The supervisor started the sender in its own process group, so TERM never reached what it started; now it does, and the supervisor KILLs that group after grace itself.

- **Seen:** while verifying the B5 fix in fedora-c1 (2026-11-26, 22:51).
- **What happens:**
  1. The supervisor stopped a sender run at `max_runtime` (22:51:05, "sent TERM to its job").
  2. The sender is its own job, so the process the TERM ended was also its worker.
  3. A child process of the sender (a `curl`, or a subshell) still held the run token, so the run lived on.
  4. For an ordinary job, the worker sends the group KILL once `grace` has passed (§11.6). The sender's worker was gone, so nothing did: the run ended only when the child ended on its own, 96 s after TERM (22:52:41) instead of the usual 10–13 s.
  5. Meanwhile `vigil status` reported `ORPHANED: vigil_sender: run …, its worker (pid 390253) is gone; its job (pid 390253) still runs`: the same pid, gone and running.
- **Should:** when the job's own process is the worker (Vigil's internal workers), the supervisor should send the group KILL after `grace` itself, and the report should name what still runs.
- **Severity:** low. The children end by themselves (`curl` has `--max-time`), and no second sender starts meanwhile.
- **Evidence:** fedora-c1's supervisor log, 22:51:05 and 22:52:41; `app/lib/posix/supervisor.sh`, `_vigil_sup_timeout` (it returns early once the job's process is gone, expecting the worker to finish the group).

### B7. After a long outage, current metrics wait behind hours of history (fixed in #288)

- **Seen:** the Mac, HP and Lenovo containers, patched with the B5 fix at about 07:05 on 2026-11-27 after some ten hours stuck.
- **What happens:** the spool is delivered oldest first, and it is bounded only by size (`[spool] max_mb`, 100 MB by default), not by age. Ten hours of a small instance's events is about 10,000 files, well inside the cap, so all of it waits to be sent, at roughly 50 files a minute net on half a CPU: three to four hours before the instance's current metrics arrive. Prometheus refuses everything more than about an hour old (D2), so most of that time goes on events that will not be kept. 15 minutes after the patch, none of the 15 containers was current, and Prometheus's "too old" count rose by about 1,000 samples a minute.
- **Decide:** whether the spool should have an age limit (for example `[spool] max_age`, older events dropped and counted with `reason=too_old`, as Datadog's already are), or deliver the newest first after a backlog. Either changes spec 4.5; neither is needed for a short outage.
- **Decided (2026-11-28): an age limit.** `[spool] max_age`, default `6h`, `0s` for no limit. Older queued files are dropped and counted `too_old`, by backend. Delivery stays oldest first. Merged in #288 on 2026-11-28.
- **Evidence:** `../sender-totals/04-fleet-containers-recovering.txt`.
- **Outage test (2026-11-27):** on the fixed build, five bare-metal instances were current again 4–8 minutes after a 2-hour outage. Hours of backlog are a problem for weak machines, not for a 2-hour outage. "Newest first" would also make Loki drop more of the backlog (B8).

### B8. After a long outage, Loki drops forwarded log lines, because the whole fleet is one stream (stream per instance in #286; the rest is D3)

- **Seen:** the bare-metal outage test, 2026-11-27 (`../../2026-11-27/outage/`). The backend was down 17:35–19:35. Fedora's log lines from the outage all arrived. The HP, Lenovo, Mac and Server 2025 lost theirs from the outage's start (17:35) to about 18:45. Loki's `loki_discarded_samples_total{reason="too_far_behind"}` was 10,692. Every metric arrived (D2's 6-hour window).
- **What happens:**
  - The forwarder's only resource attribute that Loki indexes is `service.name=vigil`. Host, job and tags go in as structured metadata. So every instance in a fleet writes to one Loki stream, `{service_name="vigil"}`.
  - Loki accepts a line only up to `max_chunk_age / 2` behind the newest line in its stream. The default `max_chunk_age` is 2h, so the window is 1 hour.
  - Fedora's backlog went in first, which moved the stream's newest line to the present. After that, the other four instances' lines more than an hour old were refused.
  - Each instance sends its own spool oldest first, so if each had its own stream, none of this backlog would have been refused.
- **Vigil cannot see it:** the collector answered 2xx, as in D2. The spools drained to 0, and nothing was counted as dropped.
- **Found later the same day:** a stream per instance is not enough on its own. The forwarder sends each log file to its end before the next. So even in one instance's stream, the first file brings the stream up to date, and the next files' lines more than an hour old are refused. Fedora's base_cpu lines (its first file) all arrived, but base_load kept 32 of its 120 lines from 18:00 to 19:00.
- **Decided (2026-11-28):** a stream per instance plus documentation (D3); the forwarder's order is unchanged. Merged in #286 on 2026-11-28.
- **Fix to decide (as first written):** give the forwarded records an index label per instance. The OpenTelemetry way is `service.instance.id` = the instance name, which Loki indexes by default. That would be one stream per instance, so an instance's backlog falls behind only its own newest line.
  - Logs only: the metrics already carry `host`, and adding the attribute to metrics would start new series in Prometheus.
  - Spec 13.4.2, both twins, and a test that checks the resource attribute.
  - Even then, an instance that sent its newest lines first (one way of doing B7) would lose its backlog beyond an hour. D3 applies either way.

### B9. CI: macOS "uninstall succeeds" failed once (found on #284's CI, not by the fleet)

- **What happened:** in the macOS install suite (run 46020947666), `vigil uninstall` failed with `rm: /opt/vigil-it-u-89299/logs: Directory not empty`, so "the root is gone" failed too. A re-run passed, and the suite passed on every other PR.
- **Likely cause (not confirmed):** a test just before leaves a job running after Vigil is removed. If that job writes a log line while uninstall deletes `logs/`, `rm -r` finds the folder not empty.
- **To do:** confirm from the test. Then either the test waits for the job, or uninstall retries its delete once.

## Documentation

### D1. Remote config on Windows with a private CA

- **Status: documented, merged 2026-11-28** (#283): the README's Sources section.

- **Git for Windows:** it checks certificates against its own bundle, not the Windows store, so it needs `http.<url>.sslCAInfo`.
- **MinGit:** it uses schannel, which demands a revocation check a private CA may not support, and ignores `sslCAInfo`, so it needs `http.sslBackend = openssl`.
- **Until then:** the instance waits with "SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)".


### D2. Prometheus keeps only the last hour of a backlog

- **Status: documented, merged 2026-11-28** (#281): the README's backends section.

- **Seen:** verifying the B5 fix (`../sender-totals/03-what-prometheus-kept.txt`).
- **What happens:** with no `out_of_order_time_window`, Prometheus refuses a sample more than about an hour older than the newest it holds. Other hosts keep that current, so after a long outage the oldest part of an instance's backlog is refused. fedora-c1's readings from 20:35 to 22:25 were lost: 66,580 samples "too old".
- **Vigil cannot see it:** the OpenTelemetry Collector in front of Prometheus had answered 2xx, and its own write was refused. Nothing was counted as dropped.
- **Docs:** the backend docs should say that a Prometheus meant to keep a backlog needs `out_of_order_time_window` at least as long as the outages it should survive, and that "delivered late, not lost" holds up to the backend's answer.
- **Confirmed (2026-11-27):** with a 6-hour window (`../../../../../fleet/backend/prometheus.yaml`), a 2-hour outage lost no samples: every 10 minutes held 10 CPU readings per instance, and "too old" stayed 0.

### D3. Loki keeps only the last hour behind a stream's newest line

- **Status: documented, merged 2026-11-28** (#286): the README's "Forwarding Vigil's logs".
- **What happens:** Loki refuses a line more than `max_chunk_age / 2` (1 hour by default) behind its stream's newest line ("too_far_behind"). Today the whole fleet is one stream (B8), so this applies across instances.
- **Docs:** beside D2, the README should say that Loki needs `ingester.max_chunk_age` of twice the outages it should survive. Until B8 is fixed, it should also say that the window counts from the newest line any instance has sent.

## The test kit (fixed as found, for the record)

- **No config folder:** `install --no-init` doesn't create `config/`, so the container entrypoint must.
- **PowerShell 5.1 and native stderr:**
  - `Set-Content -Encoding` failed to bind when writing the credentials file.
  - Docker's "No such object" on stderr ended the script.
- **Windows background processes:** WMI process creation is denied over SSH, and Windows ends what an SSH session started, so the instance runs as the remote command of a held SSH session.
- **Git Bash:** it has no `/dev/fd/3`.
- **Fedora's capacity:** 4 cores, with a demo Vigil and its own Vigil service. 10 containers overloaded it (load 35), and so did 6 (load 14). It runs 4.
- **`run-all.sh`, partition round:** the wait loop printed "on wave 17 300s after reconnecting" when it hit its limit. fedora-c2's own log shows it loaded wave 17 at 20:58:57, 29 s after reconnecting (`09-partition-fedora-c2-own-logs.txt`).
- **`evidence.sh`:** it counts activations by the `wave` tag, so bug B1 hides some. `10-followup-gitea-and-activations.txt` recounts by revision.
- **Deploying the fixes for the outage test (2026-11-27):**
  - `Bare.ps1 down` printed "stopped" when Windows refused to end the supervisor (Access denied: another SSH session started it), and removed its pid file. The app was then swapped under the running 1.5.3 supervisor, and the new ones were refused ("another supervisor owns"). Fixed: `down` waits and says FAILED; `Stop-FleetNode.ps1` stops it as Administrator.
  - Ending a held SSH session does not end the Windows supervisor that `Bare.ps1 run` started.
  - On the Mac, a supervisor started just after the old one stopped found its lock still held and exited. Fixed: `bare.sh up` retries.
- **`outage.sh` (2026-11-27):**
  - It stopped as recovery began ("done_at: unbound variable"). Under `set -u`, this bash counts an empty associative array as unset. Fixed: a plain counter. It also gained `RESUME="<start> <down> <up>"`, which picked the run up two minutes later; recovery times are still measured from the backend's return.
  - Its screenshot step failed because the browser was given a relative path. Fixed: `screenshot.sh` makes the path absolute.
