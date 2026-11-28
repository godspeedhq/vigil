# A 2-hour backend outage, on bare metal (2026-11-27)

**Question:** when the backend is gone for two hours, does each Vigil instance keep everything and deliver it afterwards? How long does it take to be current again?

## Setup

- **Instances:** five bare-metal instances, on the fixed build: `fleet-fixes`, which is main plus PRs #281, #282, #284 and #285.
  - fedora: Linux.
  - mac: macOS, an older Intel laptop.
  - hp: Windows 11.
  - lenovo: Windows 11, low-powered.
  - server2025: Windows Server 2025.
- **Configuration:** each instance takes its configuration from the fleet's Git repository and runs the base pack every 60 s.
- **Not measured:** the HP's five containers and fedora-c1 ran on 1.5.3 with only the B5 patch.
- **Backend:** grafana/otel-lgtm on the Dell. Prometheus has a 6-hour out-of-order window (`../../../../../fleet/backend/prometheus.yaml`). Loki uses the image's defaults.
- **Script:** `tests/integration/fleet/scenarios/outage.sh`.
  - 15 minutes of baseline.
  - `docker stop` of the backend at 17:35:08 UTC, and `docker start` at 19:35:09 UTC.
  - Recovery is watched until each instance's newest CPU reading is under 3 minutes old.
  - After 5 minutes for late events, what the backend holds is counted in 10-minute buckets.

## Results

### Recovery: every instance current within 8 minutes

| Instance | Current again after the backend came back |
| --- | --- |
| lenovo | 4 m 2 s |
| hp | 4 m 33 s |
| fedora | 4 m 34 s |
| server2025 | 5 m 5 s |
| mac | 7 m 39 s |

The script checks every 30 s, so each time is within about 30 s.

### Metrics: nothing lost

- **CPU readings:** every instance has all 10 in every 10-minute bucket, from the baseline through the outage to the end. That is 14 buckets × 5 instances, all complete.
- **Prometheus refusals:** "too old" stayed at 0.
- **Spool:**
  - The spool grew by about 160 KB per 10 minutes per instance, to 1.8–2.0 MB at the end of the outage.
  - On the dashboard it drops to 0 within minutes of the backend's return.
  - Nothing was dropped: the spool cap is 100 MB.

### Forwarded logs: an hour lost on four of the five instances (bug B8)

| Bucket end, UTC | fedora | hp | lenovo | mac | server2025 |
| --- | --- | --- | --- | --- | --- |
| 17:30 | 10 | 10 | 10 | 10 | 10 |
| 17:40 | 10 | 5 | 4 | 5 | 5 |
| 17:50 – 18:40 | 10 each | – | – | – | – |
| 18:50 | 10 | 6 | 5 | 6 | 4 |
| 19:00 – 19:40 | 10 each | 10 each | 10 each | 10 each | 10 each |

(These are base_cpu's "end" lines in Loki: one a minute.)

- **What Loki did:** it refused 10,692 lines as `too_far_behind`. By 19:52 it had refused 14,178, because the containers were still sending their backlog.
- **Why:**
  - Vigil's forwarded records reach Loki with `service.name=vigil` as their only indexed label. So the whole fleet is one stream.
  - Loki accepts a line only up to `max_chunk_age / 2` (1 hour by default) behind its stream's newest line.
  - Fedora's backlog arrived first. After that, the other instances' lines more than an hour behind it were refused.
- **Vigil cannot see it:** the collector answered 2xx. Each spool drained to 0, and nothing was counted as dropped.
- **Recorded:** as B8 and D3 in `../../2026-11-26/fleet-run2/BUGS.md`.
- **Found afterwards:** the one stream is only half of it. Fedora's other jobs lost lines too: base_load kept 32 of its 120 lines from 18:00 to 19:00. The forwarder sends each log file to its end before the next, so within one instance the first file brings the stream up to date, and the next file's lines more than an hour behind are refused.
- **Decided:** a stream per instance (`service.instance.id`, PR #286), and the README's note that Loki needs `max_chunk_age` of twice the outages whose logs it should keep (D3).

### Test-kit problems (fixed)

- **The script stopped as recovery began:** under `set -u`, Git Bash counted an empty associative array as unset.
  - Fixed, and the script gained `RESUME`. It resumed at 19:36:06.
  - Recovery times are measured from 19:35:09 either way. The first check came before any instance was current.
- **The screenshot step failed:** the browser was given a relative path. Fixed, and `outage.png` was taken afterwards.

## Answer

- **Metrics:** after two hours without a backend, every instance delivered everything it measured and was current again in 4–8 minutes. That holds with a Prometheus whose out-of-order window covers the outage.
- **Logs:** they were not complete. With Loki's defaults, an instance keeps only the log lines within an hour of its stream's newest line, and today the whole fleet is one stream (B8, D3).

## Evidence

| File | Contents |
| --- | --- |
| `console.txt` | The whole run, masked. |
| `01-baseline.txt`, `02-outage.txt`, `03-recovery.txt` | Each step. |
| `04-completeness.txt` | The three tables: CPU readings, log lines, spool bytes. |
| `05-screenshot.txt`, `outage.png` | The dashboard from 17:20 to 19:48. The yellow lines are the unmeasured containers, still catching up. |
| `06-loki-refused.txt` | Loki's discard counter, its one stream, its version, and Prometheus's too-old count. |
