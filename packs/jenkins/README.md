# The jenkins pack

A Jenkins controller, from its REST API. The pack reads whether Jenkins answers and its version, whether it is shutting down, every node online or not, why and since when, each label's executors against what is busy, the build queue with what waits the longest and why, the builds running now against how long they usually take (and those Jenkins itself thinks stuck), every job (folders and multibranch pipelines too) failing, unstable or disabled with its health and its last ten builds, Jenkins' own load averages, and its plugins. It reports Jenkins', never its JVM: heap, garbage collection and threads are the [jvm pack](../jvm/README.md)'s. Linux, macOS and Windows.

**A read-only user, `curl` and `jq`.** Every job reads `/api/json` with `curl` and `jq` (Linux, macOS), or `Invoke-WebRequest` (Windows, nothing to install), as a user that may only read, with its API token. Each job asks Jenkins for just the fields it reports (`tree=`), so a Jenkins of thousands of jobs answers in one small page per job.

1. **A user for Vigil**, with Overall/Read, Job/Read and Agent/Read and nothing else (with the [Matrix Authorization](https://plugins.jenkins.io/matrix-auth/) or [Role-based Authorization](https://plugins.jenkins.io/role-strategy/) plugin). Log in as it, and under its *Security* page, add an API token.
2. **For the plugins**, give it Overall/SystemRead too: a read-only view of Jenkins' configuration, which Jenkins offers when started with `-Djenkins.security.SystemReadPermission=true`. Without it, `jenkins_plugins` says `readable 0` and nothing else, and no run fails.
3. `vigil pack enable jenkins`, then in `vigil.config` set the jobs' `JENKINS_URL` (`https://jenkins.example.com`), `JENKINS_USER` (`vigil`), and for https with a private CA, `JENKINS_CACERT` (Linux and macOS; on Windows, the certificate must be one Windows trusts). Add a secret line to each job, under its `env` lines, and the token:

   ```ini
   secret = JENKINS_API_TOKEN=secret:JENKINS_API_TOKEN
   ```

   ```sh
   vigil secret set JENKINS_API_TOKEN
   ```

   The token reaches `curl` on its standard input (its config, `-K -`), and PowerShell in a header made in memory: never on a command line.

**What a read-only user cannot see.** Jenkins shows its node monitors (free disk, temporary space, memory, swap, response time, clock drift) to administrators only. The pack reads them when they are there (`monitors_readable 1`), and does not ask for an administrator's token for them: a node a monitor took offline (free disk below its threshold) says so in its reason, which any user sees, and `jenkins_nodes` reports it.

**A wrong token fails the run, saying so** (HTTP 401). A Jenkins that does not answer is a reading, `up 0`, and the run succeeds. An address that answers but is not Jenkins (no `X-Jenkins` header) fails the run.

## What it needs

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| On the Vigil machine | `curl`, `jq` | `curl`, `jq` (Homebrew; macOS 15 has it) | Nothing: `Invoke-WebRequest`, `ConvertFrom-Json` |
| Jenkins | 2.x, LTS or weekly | | |
| A user | Overall/Read, Job/Read, Agent/Read; and Overall/SystemRead for the plugins | | |
| A secret | `JENKINS_API_TOKEN`, the user's API token (step 3) | | |

## Its jobs

| Job | Reports | Every |
| --- | --- | --- |
| `jenkins_status` | Whether Jenkins answers, its version, whether it is shutting down (quiet mode), executors busy against the total, the queue (buildable, blocked, stuck), nodes offline and taken offline | minute |
| `jenkins_nodes` | Each node: online, why not and since when, taken offline by hand, its executors busy, idle and stuck; with an administrator's token, Jenkins' monitors (free disk against its threshold, temporary space, memory, swap, response time, clock) | minute |
| `jenkins_labels` | Each label: executors total, busy and idle, busy %, its nodes and those offline, the jobs tied to it | minute |
| `jenkins_queue` | The queue: its length, the oldest and the average wait, stuck, blocked and buildable; each item, the oldest first, with how long and Jenkins' reason | minute |
| `jenkins_builds` | Builds running now, pipelines too, the longest first: how long, against Jenkins' estimate, how far along, and whether Jenkins thinks them stuck; those past twice their estimate | minute |
| `jenkins_jobs` | Every job, four folders deep: failing, unstable, aborted, disabled, never built, building, waiting; builds and failures in the last hour; for the worst 100, health score, success rate over the last ten builds, builds since the last success, time since the last success, failure and build, the last build's duration | 5 minutes |
| `jenkins_load` | Jenkins' own averages of the queue and its executors (busy, idle, online, available, connecting), over 10 seconds, a minute and an hour | minute |
| `jenkins_plugins` | Plugins installed, with updates, not active, disabled, pinned, bundled, to be removed at a restart; each with an update or not active; the update sites with updates (with SystemRead) | hour |

Past 100 of anything (nodes, labels, queue items, builds running, jobs), the worst first (the oldest, the longest, failing then unstable), and the rest counted in a `_not_shown` line. Jobs are tagged by their full name, folders and all (`team/nightly`).


<!-- grid:start -->
## Every metric, at a glance

Every job, every metric it prints and what it measures, and what good, watch and bad look like. It is the header of each job's script, laid out (`tools/pack-grid.py` writes it), so it says what the scripts say. A metric's full name is its job's name, then its own: `jenkins.up`.

```text
+--------------------------------------------------------------------------------------------------+
| jenkins_status   jenkins.<metric>   every 1m                                                     |
+---------------------------+----------------------------------------------------------------------+
| up                        | 1 when Jenkins answers, else 0                                       |
| version                   | always 1, tagged version=<Jenkins' version>                          |
| quieting_down             | 1 when it is preparing to shut down: no new build starts             |
| executors_total           | executors on every node online                                       |
| executors_busy            | of those, running a build now                                        |
| executors_busy_pct        | executors_busy, as a percentage of the total                         |
| queue_length              | items waiting in the build queue                                     |
| queue_buildable           | of those, ready and waiting for an executor                          |
| queue_blocked             | of those, blocked (by another build, or a resource)                  |
| queue_stuck               | of those, waiting far longer than they should                        |
| nodes                     | nodes: the built-in node and every agent                             |
| nodes_offline             | of those, offline                                                    |
| nodes_temporarily_offline | of those, taken offline by someone                                   |
+---------------------------+----------------------------------------------------------------------+
| GOOD  up 1; quieting_down 0; executors_busy_pct below 80 most of the time; queue_stuck 0;        |
|       nodes_offline only those taken offline on purpose.                                         |
| WATCH executors_busy_pct at 100 for long stretches, with queue_buildable above 0: builds wait    |
|       for executors; add agents. nodes_temporarily_offline you did not expect.                   |
| BAD   up 0; quieting_down 1 when no restart is planned: nothing new builds; queue_stuck above 0: |
|       builds that will not start (a label no node has, or every node for it offline);            |
|       nodes_offline rising.                                                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_nodes   jenkins.nodes.<metric>   every 1m                                                |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when Jenkins answers, else 0                                            |
| nodes                | the nodes                                                                 |
| monitors_readable    | 1 when Jenkins shows this user its node monitors (an administrator), else |
|                      | 0                                                                         |
| online               | 1 when a node is online, else 0, tagged node=<its name> and, when         |
|                      | offline, reason=<why>                                                     |
| temporarily_offline  | 1 when someone took it offline, tagged node=<its name>                    |
| offline_seconds      | how long it has been offline, when Jenkins knows                          |
| executors            | its executors                                                             |
| busy                 | of those, running a build now                                             |
| idle                 | of those, idle                                                            |
| stuck                | of those, running a build Jenkins thinks stuck                            |
| disk_free_bytes      | free space where it keeps its workspace                                   |
| disk_threshold_bytes | the free space below which Jenkins takes it offline                       |
| tmp_free_bytes       | free space in its temporary folder                                        |
| memory_free_bytes    | free physical memory                                                      |
| memory_total_bytes   | physical memory                                                           |
| swap_free_bytes      | free swap                                                                 |
| response_ms          | how long it takes to answer Jenkins, on average                           |
| clock_diff_ms        | its clock against the controller's                                        |
| ..._not_shown        | past 100 of a list (nodes), how many were left out                        |
+----------------------+---------------------------------------------------------------------------+
| GOOD  online 1 for every node you expect; disk_free_bytes far above disk_threshold_bytes;        |
|       clock_diff_ms within a second; stuck 0.                                                    |
| WATCH disk_free_bytes under twice disk_threshold_bytes: Jenkins will take the node offline;      |
|       response_ms in the seconds; a node temporarily_offline for days: someone forgot it.        |
| BAD   online 0 where temporarily_offline is 0 (its reason says why: the agent stopped, its disk  |
|       filled); stuck above 0; clock_diff_ms in the minutes.                                      |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_labels   jenkins.labels.<metric>   every 1m                                              |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when Jenkins answers, else 0                                                 |
| labels          | the labels                                                                     |
| executors_total | executors with a label, on its nodes online, tagged label=<its name>           |
| executors_busy  | of those, running a build now                                                  |
| executors_idle  | of those, idle                                                                 |
| busy_pct        | executors_busy, as a percentage of executors_total                             |
| nodes           | nodes with the label                                                           |
| nodes_offline   | of those, offline                                                              |
| tied_jobs       | jobs tied to the label                                                         |
| ..._not_shown   | past 100 of a list (labels), how many were left out                            |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  busy_pct below 80 most of the time; nodes_offline 0.                                       |
| WATCH busy_pct at 100 for long stretches: the jobs tied to it wait (jenkins_queue says which).   |
| BAD   executors_total 0 where tied_jobs is above 0: every node with the label is offline, and    |
|       its jobs will not run.                                                                     |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_queue   jenkins.queue.<metric>   every 1m                                                |
+-----------------+--------------------------------------------------------------------------------+
| up              | 1 when Jenkins answers, else 0                                                 |
| queue_length    | items waiting                                                                  |
| oldest_seconds  | how long the oldest has waited                                                 |
| average_seconds | how long they have waited, on average                                          |
| stuck           | items waiting far longer than they should                                      |
| blocked         | items blocked (by another build of the job, a lock)                            |
| buildable       | items ready, waiting for an executor                                           |
| waiting_seconds | how long one item has waited, tagged job=<the job's full name>, state=<stuck,  |
|                 | blocked, buildable or waiting> and why=<Jenkins' reason>                       |
| ..._not_shown   | past 100 of a list (items), how many were left out                             |
+-----------------+--------------------------------------------------------------------------------+
| GOOD  queue_length near 0 most of the time; oldest_seconds in seconds.                           |
| WATCH oldest_seconds in minutes with state=buildable: builds wait for an executor                |
|       (jenkins_labels says which label is full).                                                 |
| BAD   stuck above 0: a build that will not start (its label matches no node online, every such   |
|       node is offline); why says which.                                                          |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_builds   jenkins.builds.<metric>   every 1m                                              |
+-------------------+------------------------------------------------------------------------------+
| up                | 1 when Jenkins answers, else 0                                               |
| running           | builds running now                                                           |
| overdue           | of those, running more than twice their estimate                             |
| likely_stuck      | of those, that Jenkins thinks stuck (far past the time its builds take)      |
| running_seconds   | how long one build has run, tagged job=<the job's full name>, build=<its     |
|                   | number> and node=<where it runs>                                             |
| estimated_seconds | how long Jenkins expects it to take (from its last successful builds),       |
|                   | tagged the same                                                              |
| estimate_pct      | running_seconds, as a percentage of the estimate                             |
| progress_pct      | how far along Jenkins thinks it is (0 to 99; none when it has no estimate)   |
| stuck             | 1 when Jenkins thinks this build stuck, else 0                               |
| ..._not_shown     | past 100 of a list (builds), how many were left out                          |
+-------------------+------------------------------------------------------------------------------+
| GOOD  overdue and likely_stuck 0; estimate_pct below 150.                                        |
| WATCH estimate_pct above 150: slower than usual (a slow agent, a slow dependency, tests that     |
|       grew).                                                                                     |
| BAD   likely_stuck or overdue above 0, estimate_pct climbing run after run: a build hung         |
|       (waiting for input, a lock, a network call), holding its executor.                         |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_jobs   jenkins.jobs.<metric>   cron 2/5 * * * *                                          |
+--------------------------+-----------------------------------------------------------------------+
| up                       | 1 when Jenkins answers, else 0                                        |
| jobs                     | the jobs (folders not counted)                                        |
| failing                  | of those, whose last completed build failed                           |
| unstable                 | of those, whose last completed build was unstable (tests failed)      |
| aborted                  | of those, whose last completed build was aborted                      |
| disabled                 | of those, disabled                                                    |
| never_built              | of those, never built                                                 |
| building                 | of those, building now                                                |
| in_queue                 | of those, waiting in the queue                                        |
| builds_last_hour         | builds started in the last hour (of each job's last ten)              |
| failures_last_hour       | of those, failed                                                      |
| job_failing              | 1 when one job's last completed build failed, else 0, tagged job=<its |
|                          | full name>                                                            |
| job_unstable             | 1 when it was unstable, tagged the same                               |
| health_score             | Jenkins' health for it, 0 to 100 (its weather: the share of recent    |
|                          | builds that passed), tagged the same                                  |
| success_rate_pct         | of its last ten completed builds, the share that succeeded            |
| builds_since_success     | builds since its last success                                         |
| last_success_age_seconds | how long since its last successful build                              |
| last_failure_age_seconds | how long since its last failed build                                  |
| last_build_age_seconds   | how long since its last build started                                 |
| last_duration_seconds    | how long its last build took                                          |
| ..._not_shown            | past 100 of a list (jobs), how many were left out                     |
+--------------------------+-----------------------------------------------------------------------+
| GOOD  failing and unstable 0, or a known few; health_score high; last_success_age_seconds recent |
|       for the jobs you build often.                                                              |
| WATCH unstable rising: tests failing; success_rate_pct falling: a flaky job;                     |
|       builds_since_success above 0 for a job you release from; a nightly job past a day and a    |
|       half without a success.                                                                    |
| BAD   failing rising, or a job_failing you depend on (a release, a deploy) 1; failures_last_hour |
|       climbing; last_duration_seconds climbing build after build.                                |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_load   jenkins.load.<metric>   every 1m                                                  |
+----------------------+---------------------------------------------------------------------------+
| up                   | 1 when Jenkins answers, else 0                                            |
| queue_length         | items in the queue that can run, on average, tagged window=<10s, 1m or    |
|                      | 1h>                                                                       |
| queue_length_total   | every item in the queue, on average, tagged the same                      |
| executors_busy       | executors busy, on average, tagged the same                               |
| executors_idle       | executors idle, on average, tagged the same                               |
| executors_available  | executors that could take a build, on average                             |
| executors_online     | executors on nodes online, on average                                     |
| executors_connecting | executors on nodes still connecting, on average                           |
| executors_defined    | executors defined, online or not, on average                              |
| executors_total      | executors in all, on average                                              |
+----------------------+---------------------------------------------------------------------------+
| GOOD  queue_length window=1h below 1; executors_busy window=1h well below executors_online.      |
| WATCH queue_length window=1h above 1: the queue rarely empties; executors_busy close to          |
|       executors_online for the hour.                                                             |
| BAD   executors_connecting window=1h above 0 for long: agents that cannot connect;               |
|       executors_online falling against executors_defined: nodes dropping.                        |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| jenkins_plugins   jenkins.plugins.<metric>   cron 13 * * * *                                     |
+--------------------+-----------------------------------------------------------------------------+
| up                 | 1 when Jenkins answers, else 0                                              |
| readable           | 1 when this user may read the plugins, else 0                               |
| plugins            | plugins installed                                                           |
| updates            | of those, with a newer version to install                                   |
| inactive           | of those, not active (failed to load, or a dependency missing)              |
| disabled           | of those, disabled                                                          |
| pinned             | of those, pinned to their version                                           |
| bundled            | of those, that came with Jenkins                                            |
| deleted            | of those, to be removed at the next restart                                 |
| downgradable       | of those, with an older version kept to go back to                          |
| update             | always 1, for one plugin with an update, tagged plugin=<its name> and       |
|                    | version=<the version installed>                                             |
| inactive_plugin    | always 1, for one plugin not active, tagged the same                        |
| sites              | update sites                                                                |
| sites_with_updates | of those, offering updates                                                  |
| ..._not_shown      | past 100 of a list (updates), how many were left out                        |
+--------------------+-----------------------------------------------------------------------------+
| GOOD  inactive 0; updates few, and applied on a schedule.                                        |
| WATCH updates climbing: plugins left behind (and their security fixes); deleted above 0: a       |
|       restart is due; readable 0: give the user Overall/SystemRead to see the plugins.           |
| BAD   inactive above 0: a plugin failed to load, and what depends on it does not work (the       |
|       reason is in Jenkins' log).                                                                |
+--------------------------------------------------------------------------------------------------+
```
<!-- grid:end -->

## What to alert on

Starting points, from the same figures each script's header explains; "In our tests" is what two Jenkins in trouble on purpose (below) showed:

| Metric | Healthy | Watch | Act | In our tests |
| --- | --- | --- | --- | --- |
| `jenkins.up` | 1 | | 0: Jenkins is down; a wrong token fails the run instead, saying so | 0 for an address where nothing listened |
| `jenkins.quieting_down` | 0 | | 1 with no restart planned: nothing new builds | 0 |
| `jenkins.nodes.online` | 1 for every node you expect | A node `temporarily_offline` for days: someone forgot it | 0 where `temporarily_offline` is 0: the agent dropped; its `reason` says why | 0 for both agents; `reason=patching__back_Monday` for the one taken offline by hand, `offline_seconds` counting |
| `jenkins.labels.executors_total` against `tied_jobs`; `busy_pct` | Executors for every label in use; below 80 | `busy_pct` at 100 for long stretches | `executors_total` 0 for a label jobs need: every node with it offline | 0 for `agents`, both its nodes offline |
| `jenkins.queue.stuck`, `oldest_seconds` | 0; seconds | Minutes, `state=buildable`: waiting for executors | `stuck` above 0: a build that will not start; `why` says which | 1: `why=There_are_no_nodes_with_the_label__nowhere_` |
| `jenkins.builds.overdue`, `likely_stuck`, `estimate_pct` | 0; below 150 | `estimate_pct` above 150 | Above 0, or `estimate_pct` climbing: a build hung, holding its executor | 1 overdue: the 15 minute build of a job whose estimate was 3 seconds, at 726% after 23 seconds |
| `jenkins.jobs.failing`, `job_failing` | 0, or a known few | | Rising, or a job you depend on failing | 2: `fail` and `team/nightly` (in a folder), health 0, success rate 0 |
| `jenkins.jobs.unstable`, `success_rate_pct` | 0; near 100 | Unstable rising; success rate falling: a flaky job | | 1: an unstable pipeline (Jenkins counts unstable as a success: health 100, success rate 0) |
| `jenkins.jobs.failures_last_hour` | Near 0 | | Climbing | 2 of 6 builds |
| `jenkins.plugins.inactive`, `updates` | 0; few | `updates` climbing; `readable` 0: give the user SystemRead | `inactive` above 0: a plugin failed to load | 52 plugins read with SystemRead, 0 inactive; `readable 0` for the user without it |

## How it was tested

**Tested** on 2026-11-23 on the Fedora 44 test machine by `tests/integration/backends/scripts/run-jenkins.sh`, against `compose.jenkins.yaml`: **Jenkins 2.580.2 LTS on Java 21** and **Jenkins 2.528.3 LTS on Java 17**, each in Docker, set up at its first start by `configs/services/jenkins/vigil.groovy`: a read-only user with SystemRead, one without, two agents that never connect (one taken offline by hand, with a reason), jobs passing, failing (one in a folder), unstable (a pipeline), disabled and never built, a job whose second build runs 15 minutes against an estimate of 3 seconds, and one waiting for a label no node has. The API tokens were read from each Jenkins with `docker exec` into the run's own folder, never printed.
- **On Fedora**: every job directly as the read-only user, on both Jenkins, each reading checked (the agents offline and why, the label with no executors, the stuck queue item and its reason, the overdue build, the failing, unstable and disabled jobs, health and success rates, the load averages, the plugins with SystemRead and `readable 0` without), a wrong token failing the run and saying so, a Jenkins that does not answer read as `up 0`; then `service-packs.sh` through Vigil (enable, and that the JVM is the jvm pack's; the token as a secret line on every job; every job; a wrong token failing the run; a Jenkins that does not answer read as `up 0`; the token written nowhere; the metrics reaching the backend): **70 passed, 0 failed**, and through Vigil **20 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/fedora/pack-jenkins/console.txt)).
- **On macOS**, on the Intel Mac test machine (macOS 12.7.6, bash 3.2, `jq` 1.8.2 from its release), against both Jenkins through SSH tunnels: every job, **28 passed, 0 failed**; through Vigil, **20 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/macos/pack-jenkins-macos/console.txt)).
- **On Windows**, as an account that is not an administrator, against both Jenkins through SSH tunnels: every job directly, then `Service-Packs.ps1` through Vigil, on Windows 11 under Windows PowerShell 5.1 and PowerShell 7, **52 passed, 0 failed** and **18 passed, 0 failed** on each ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows/pack-jenkins-windows/console.txt)), and on Windows Server 2025 under Windows PowerShell 5.1, **26 passed, 0 failed** and **18 passed, 0 failed** ([the console output](../../tests/integration/backends/reports/runs/2026-11-23/windows-server-2025/pack-jenkins-windows/console.txt)). The Windows scripts printed the same lines, values apart, as the Linux ones against the same Jenkins.

---

[All packs](../README.md) · [Writing a pack](../../CONTRIBUTING.md#your-first-pack) · [The packs releases](https://github.com/godspeedhq/vigil/releases)

## Disclaimer

These scripts are provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied, including any warranty of title, non-infringement, merchantability or fitness for a particular purpose.

**Run them at your own risk.** Review them and test them on a non-production machine before you rely on them. You are responsible for deciding whether they are right for your systems.

In no event shall the authors, contributors or copyright holders be liable for any claim, damages or other liability, whether direct, indirect, incidental or consequential, including loss of data, downtime or business interruption, arising from the use of these scripts or the inability to use them.

The [Apache License 2.0](../../LICENSE) gives the full terms, and it takes precedence over this summary.
