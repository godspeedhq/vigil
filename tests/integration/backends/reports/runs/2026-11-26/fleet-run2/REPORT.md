# Vigil fleet test, run 2: 24 instances, 9 rounds

**Date:** 2026-11-26, 20:04–21:04 UTC. **Vigil:** 1.5.3, base pack. **Result:** the configuration handling passed every round. The metric sender failed under load: see [BUGS.md](BUGS.md), B5.

## The fleet

| Machine | Containers (Alpine, bash Vigil, supervisord) | Bare metal |
| --- | --- | --- |
| Fedora 44 (4 cores) | 4: `fedora-c1`–`c4` | `fedora` |
| macOS (Intel) | 5: `mac-c1`–`c5` (Docker Desktop) | `mac` |
| Windows 11, HP | 5: `hp-c1`–`c5` (Docker Desktop) | `hp` |
| Windows 11, Lenovo | 5: `lenovo-c1`–`c5` (Docker Desktop) | `lenovo` |
| Windows Server 2025 | — | `server2025` |
| **Total** | **19** | **5** |

Every instance:
- fetches its configuration from Gitea (`https://192.168.4.40:8443/fleet/config`, a private repository), checking every 30 s, with a read-only token held by Git's credential helper;
- sends metrics and its own log lines over https to Grafana's LGTM stack (Prometheus, Loki), on the Dell that also runs Gitea.

Each kind of instance has its own configuration file: `linux-container`, `linux-bare`, `macos-bare` and `windows-bare`. Each file carries a `wave` tag, so a change shows in the backend as a new wave.

Host names: the bare-metal machines' real names are replaced with `mac`, `hp`, `lenovo` and `server2025` throughout.

## The rounds

How long changes took is counted from each instance's own "configuration revision … loaded" log line, matched on the revision the line names ([10-followup-gitea-and-activations.txt](10-followup-gitea-and-activations.txt)). Times seen in Prometheus are longer, because of the sender (B2, B5).

| # | Round | What was done | What the fleet did | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Valid change | Wave 10 pushed | **All 24** loaded it, 6–61 s after the push | [01-good.txt](01-good.txt), [png](01-good.png) |
| 2 | One job broken | Wave 11: a job with `run_every = banana` | **All 24** took the file, set that job aside as INVALID and ran the rest (§16.3), 3–74 s after the push | [02-job.txt](02-job.txt), [png](02-job.png) |
| 3 | Unknown section | Wave 12: `[fleet_nonsense]` in every file | **None** took it. 23 refused it within the 150 s window, each logging `unknown section [fleet_nonsense] (E_SECTION_UNKNOWN)`, and kept wave 11 | [03-section.txt](03-section.txt), [png](03-section.png) |
| 4 | Windows only | Wave 13: only `windows-bare.config` invalid | **21** non-Windows instances loaded it. **All 3** Windows instances refused it and kept wave 11 (revision `9f7477db3012`) | [04-windows.txt](04-windows.txt), [png](04-windows.png) |
| 5 | Valid change | Wave 14 | **All 24**, 13–82 s after the push | [05-good.txt](05-good.txt), [png](05-good.png) |
| 6 | Force-push | `main` rewritten: waves 13 and 14 dropped, wave 15 put on wave 12 | **All 24** followed the rewritten branch, 13–82 s after the push | [06-force.txt](06-force.txt), [png](06-force.png) |
| 7 | Gitea down | Gitea stopped 20:35:10–20:39:15, then wave 16 pushed | **All 24** logged failed fetches (`502`), 8–14 each at their normal pace, and kept running wave 15. With Gitea back, there was no rush: **all 24** loaded wave 16, 15–65 s after the push | [07-gitea.txt](07-gitea.txt), [png](07-gitea.png), [10-followup…](10-followup-gitea-and-activations.txt) |
| 8 | Backend down | LGTM stopped 20:44:52–20:48:54 | The spools held what could not be sent: 149 KB before, 569 KB at +2 min, 265 KB at +3 min. Readings from the middle of the outage (20:46:53) were in Prometheus afterwards, from 15 instances, so data was delivered late, not lost | [08-backend.txt](08-backend.txt), [png](08-backend.png) |
| 9 | Partition | `fedora-c2` cut from the network 20:52:18–20:58:28 while wave 17 landed | The other 23 loaded wave 17. `fedora-c2` failed 9 fetches, cleanly ("Failed to connect"), kept its configuration, and **loaded wave 17 29 s after reconnecting** | [09-partition.txt](09-partition.txt), [png](09-partition.png), [own logs](09-partition-fedora-c2-own-logs.txt) |

[00-whole-run.png](00-whole-run.png) is the dashboard over the whole hour. [console.txt](console.txt) is the run's console, and [pushes.txt](pushes.txt) lists every push with its commit.

## What it shows

**Configuration from Git works, on every platform tested** (Alpine, Fedora, macOS, Windows 11, Windows Server 2025):
- Valid changes reached every instance within about a minute and a half.
- Broken files were refused, without disturbing what ran, and with the exact reason and line in the instance's log.
- A broken job sidelined only that job.
- A rewritten history was followed.
- An unreachable Gitea, or a host cut off, cost nothing but failed fetches, and the instances caught up as soon as they could.
- After an outage, the fleet didn't stampede Gitea.

**Metric delivery does not keep up on small instances** (B5, B2):
- The containers are capped at half a CPU. There, a sender run took longer as its backlog grew.
- Once it passed the 5-minute `max_runtime`, every run was killed and sent nothing.
- From about 20:35, the Fedora containers sent no metrics at all. The Lenovo's containers stopped too, and the Mac's and HP's fell 4–5 minutes behind.
- The dashboard's "Instances reporting" fell from 24 to 12 while the logs showed all 24 working.
- Every bare-metal instance stayed current throughout.

**Log records near a change can be tagged with the wrong configuration** (B1): 21 times in this run.

## Bugs

[BUGS.md](BUGS.md) holds all of them, with their evidence:

| Bug | What |
| --- | --- |
| B5 | The sender livelocks: once a run outlasts `max_runtime`, metrics stop (most serious) |
| B1 | A forwarded log line carries the revision active when it is sent, not when it was written |
| B2 | The sender's cost per event is high, and grows with its backlog |
| B3 | On Windows, checking the configuration's source costs 5–8 CPU seconds |
| B4 | A refused configuration and an unreachable source look the same in metrics |
| D1 | Docs: remote configuration on Windows with a private CA |

## How to run it yourself

The kit is in `tests/integration/fleet/`: the backend's compose file and `backend/setup.sh`, the node image and `node/fleet.sh`, the bare-metal scripts `node/bare.sh` and `node/Bare.ps1`, and `scenarios/run-all.sh`, which ran this test.

Run 1 (14 instances, earlier the same day) is in [../fleet/](../fleet/).
