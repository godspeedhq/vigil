# Bugs and problems found by the fleet test (2026-11-26)

Each entry: what happens, what should happen, the evidence, where it was
seen. Found in run 1 (`../fleet/`) or run 2 (this folder). Nothing here is
fixed yet: this is the list to plan the fixes from.

## Vigil

### B5. The metric sender livelocks: once a run outlasts max_runtime, metrics stop (most serious)

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

### B1. Forwarded log lines carry the revision active when they are sent, not when they were written

- **Seen:** run 1, wave 3 (linux containers on Fedora).
- **Specification (§14, log forwarding):** every record carries "the active configuration revision" and the `[tags]`.
- **What happens:** the forwarder tags a line with the revision and `[tags]` (such as `wave`) active when it sends the line. Near a change, lines get the wrong configuration, in both directions:
  - fedora-c1: lines written at 18:15:38 and 18:15:44 carry revision `a21e3a374b61`, which loaded only at 18:15:47.
  - On 6 of 10 containers, the line "configuration revision a21e3a374b61 loaded" itself carries the previous revision, `df547f88403b`.
- **Why it matters:** the minutes around a push are exactly when someone reads the logs to judge whether the push was bad.
- **Evidence:** `../fleet/findings.txt`, section 2.
- **Run 2:** 21 activation lines carry a revision other than the one they announce, across waves 10–17 (`10-followup-gitea-and-activations.txt`). A query by tag therefore undercounts activations: by the `wave` tag, round 1 shows 19 of 24.

### B2. The metric sender is slow, and falls behind under load

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

### B3. On Windows, a check of the configuration's source costs 5–8 CPU seconds

- **Seen:** run 1, Windows 11 (HP, Lenovo).
- **What happens:** `vigil_fetch` uses 4.9–7.8 s of CPU per run, against 0.55–0.80 s on Linux and about 1.1 s on macOS. At a 30 s `check_every`, that is about a fifth of a core.
- **Evidence:** `../fleet/wave-4-unknown.txt`.

### B4. A refused configuration and an unreachable source look the same in metrics

- **Seen:** run 1, wave 4.
- **What happens:** both raise only `vigil_source_failures_total`, and `vigil_supervisor_config_reload_failed` stays 0. Only the log tells them apart: `line 93: unknown section [fleet_nonsense] (E_SECTION_UNKNOWN)`.
- **Decide:** whether this is worth a metric, given that Vigil should stay simple.
- **Evidence:** `../fleet/findings.txt`, section 6.

## Documentation

### D1. Remote config on Windows with a private CA

- **Git for Windows:** it checks certificates against its own bundle, not the Windows store, so it needs `http.<url>.sslCAInfo`.
- **MinGit:** it uses schannel, which demands a revocation check a private CA may not support, and ignores `sslCAInfo`, so it needs `http.sslBackend = openssl`.
- **Until then:** the instance waits with "SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)".

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
