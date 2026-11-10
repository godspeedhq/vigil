# Engineering challenges review, 2026-11-10 (Vigil 0.6.5)

The owner's "Consolidated Engineering Challenges" (reviews of 0.3.1 to
0.6.5), checked against main at `2b87631`. Four reviewers (Claude) each took
a part, read the code, tests, specification and backlogs, and ran small
reproductions in throwaway roots on Windows PowerShell 5.1 and Git Bash.
Every DEFECT below was then checked again in the code, and the pack one
reproduced again, before a backlog was opened.

"Reproduced" means it was run; "read" means it was found in the code and not
run. Following the challenge's own instruction, this is not an implementation
list: backlogs were opened only for confirmed defects and for documentation
that misleads. Everything else is recorded here with the reason.

## Results

| ID | Challenge | Classification | Priority | v1 blocker | Backlog |
| --- | --- | --- | --- | --- | --- |
| 1.1 | Code-signing certificates | DEFERRED | — | No | 12, 33 (on hold) |
| 2.1 | Release credentials | SATISFIED | Low | No | — |
| 2.2 | Permissions | **DEFECT** (Windows update temp folder), PARTIALLY SATISFIED | High | Yes | [41](../41_windows_update_temp_folder.md) |
| 2.3 | Script-source trust | SATISFIED | Low | No | — |
| 2.4 | Update-source precedence | PARTIALLY SATISFIED | Low | No | [45](../45_unreadable_is_not_missing.md) |
| 3.1 | Corrupt state | **DEFECT** | Medium | No, but fix before v1 | [44](../44_corrupt_numbers_stop_the_supervisor.md), [43](../43_windows_orphaned_runs.md) |
| 3.2 | Worker lifecycle | **DEFECT** (Windows orphan runs twice) | High | Yes | [43](../43_windows_orphaned_runs.md) |
| 3.3 | Concurrent supervisors | SATISFIED | Low | No | — |
| 3.4 | Bounded failure | PARTIALLY SATISFIED | Low | No | — (below) |
| 3.5 | Timing (Max-Runtime) | UNVERIFIED | Medium | No | [19](../19_intermittent_test_failures.md) (note added) |
| 4.1 | Missing vs inaccessible | **DEFECT** | Medium | No | [45](../45_unreadable_is_not_missing.md) |
| 4.2 | Atomic writes | **DEFECT** (pack enable/disable), otherwise SATISFIED | Medium | No | [46](../46_pack_enable_safety.md) |
| 4.3 | Windows file locks | SATISFIED | Low | No | — (below) |
| 5.1 | Install ownership | SATISFIED; DOCUMENTATION for switching methods | Low | No | — (below) |
| 5.2 | Interrupted updates | PARTIALLY SATISFIED (untested failure paths) | Low | No | — (below) |
| 5.3 | Downgrades | SATISFIED | None | No | — |
| 5.4 | Mixed-version configuration | SATISFIED (clean rejection); DOCUMENTATION | Medium | No | [47](../47_claims_match_evidence.md) |
| 6.1 | Remote SMB/NFS | PARTIALLY SATISFIED (only `\\localhost` tested); DEFECT in the error | Medium | No | [45](../45_unreadable_is_not_missing.md), [47](../47_claims_match_evidence.md) |
| 6.2 | Other repositories | PARTIALLY SATISFIED | Low | No | [47](../47_claims_match_evidence.md) |
| 6.3 | Release source down | SATISFIED | Low | No | — |
| 6.4 | Service identities | **DEFECT** (`secret:` under the service account) | High | Yes | [42](../42_secrets_for_the_service_account.md) |
| 7.1 | Pack output correctness | PARTIALLY SATISFIED | Medium | No | — (below) |
| 7.2 | AI contributions | PARTIALLY SATISFIED | Low | No | — (below) |
| 7.3 | Pack contract stability | SATISFIED | None | No | — |
| 7.4 | Pack precheck | **DEFECT** (no scripts for the platform) | Medium | No | [46](../46_pack_enable_safety.md) |
| 7.5 | Cross-platform consistency | SATISFIED (one wording drift) | Low | No | — |
| 8.1 | Mutable references | SATISFIED | None | No | — |
| 8.2 | Integrity vs correctness | SATISFIED | None | No | — |
| 8.3, 8.4 | Fleet rollout, coexistence | SATISFIED | None | No | — |
| 9.1 | Regression evidence | PARTIALLY SATISFIED | Low | No | — (below) |
| 9.2, 9.4 | Real-OS testing, support claims | DOCUMENTATION (claims ahead of evidence) | High | Yes, if §5.1 ships as written | [47](../47_claims_match_evidence.md) |
| 9.3 | Real-service integration | PARTIALLY SATISFIED | Medium | No, if labelled | [47](../47_claims_match_evidence.md) |
| 10.1–10.3 | Feature creep, core stability | SATISFIED; DOCUMENTATION (§15.3) | Medium | No | [47](../47_claims_match_evidence.md) |

**v1 blockers: 41, 42, 43, and 47's support table.** Each is cheap except 42,
which needs a decision first.

## What holds, with the evidence

- **2.1 Release credentials.** The header is built only for a `release_url`,
  given to curl on stdin (`-K -`, `-q`), with `--max-redirs 0` whenever a
  header is set; Windows uses `HttpWebRequest` with `AllowAutoRedirect =
  $false`. Reproduced: a local listener answering 302 to a second port; with
  a header, curl stopped (`Maximum (0) redirects followed`) and PowerShell
  threw `HTTP 302`, and the second port never received the header. Messages
  name the reference, never the value; tests check it is on no command line
  and in no output (`self-update.sh`, `Self-Update.ps1`). Low note: without
  a header, PowerShell 5.1 follows redirects including https to http;
  integrity still holds through the signature.
- **2.3 Sources.** https and sftp scripts require `sha256`, checked before an
  atomic move; git takes no hooks or submodules, refuses links out of the
  tree, holds a moved tag; activation is validated and atomic. Covered by
  `fetch.sh`/`Fetch.ps1` and the real-server runs in `sources-compatibility.md`.
  Not tested: an interrupted sftp transfer; Windows https against a real
  server (its test CA was not trusted).
- **2.4 Precedence.** `release_path` > `release_url` > GitHub, both set is an
  error, a bad secret is an error, not a fallback. The one silent fallback,
  to GitHub when the configuration cannot be read (reproduced), is in 45.
- **3.3 Supervisor lock.** One exclusive open on Windows, released by the OS
  on death; POSIX re-checks for another holder; both test "a second
  supervisor is refused". The inherited-lock defect was POSIX (the background
  `sleep` holding fd 8), fixed in #109 with `tests/packages/linux.sh`.
- **3.4 Bounds.** Backend queues capped at `max_mb` with a drop count; sender
  backoff to 5 min, log forwarder to 15 min, update retry 300 s; logs 50 MB
  per file and `retain_days`. One gap, below.
- **4.3 Locks.** New files are copied before anything stops, renames retry for
  30 s, a held `vendor.old` is moved aside, `app.old` goes only after the new
  version runs; tested (`Self-Update.ps1`). Cleanup touches only renamed
  leftovers.
- **5.1 Ownership.** Every package writes `PACKAGED`; `self update` and
  `uninstall` refuse; tested (`Packaged.ps1`, `packaged.sh`).
- **5.3 Downgrades.** `self update --version` and `version =` go back on
  purpose; only "latest" never goes back; going back past a data format
  change is refused; all tested.
- **5.4 New keys.** An unknown `[vigil]` key rejects the whole configuration
  and the last valid one stays; an unknown job key invalidates that job only
  (§16.3, by design). The missing advice is in 47.
- **6.3 Release source down.** The update is a detached worker; `unavailable`
  is retried after 300 s, logged, shown in `status`; jobs carry on (tested in
  `version-config.sh`, `Version-Config.ps1`).
- **7.3 Packs and the core.** No pack is named in `app/` except `init`'s
  default `base`; discovery is by folder.
- **8.1, 8.2.** Unpinned branches warn (`W_SCRIPT_UNPINNED`), moved tags warn;
  checksums are described as pinning, never as safety.
- **8.3, 8.4, 10.** No fleet controller in the code or the open backlogs;
  rollout is one configuration line pulled by each host; WHY.md recommends
  keeping cron, Telegraf and OpenTelemetry where they suffice.

## Rebuttals

- **3.3, "macOS without `lsof`".** `lsof` ships with macOS (`/usr/sbin/lsof`);
  not a real case. No change.
- **7.1, "a sanity bound for each base metric".** The base metrics come from
  the operating system's own counters; a bound would encode a guess about
  the host (a disk can be 100% full) and test the bound, not the metric. Not
  opened. The real gap, macOS service packs never run against a real
  service, is a CI addition, below.
- **4.2, "the supervisor would silently drop jobs".** True only if the write
  is cut off mid-way; the window is one small write. Still worth the fix
  because it is cheap and every other writer already replaces (46).

## Real, but not opened

Small enough to fix when the code is next touched, or not worth a backlog of
their own:

- **3.4.** While a fetch-mode install waits for its first fetch, the
  supervisor writes an events file each tick but the sender and log
  retention are skipped, so `incoming/` and the supervisor log grow while a
  source stays unreachable (read, not run).
- **4.3.** If the rollback's own rename times out, the installer stops
  without saying how to recover (rename `app.old` back); print it.
- **5.1.** Switching from the install script to Scoop, Homebrew or MacPorts
  is not documented (different roots; copy `config`, `scripts`, `packs`).
- **5.2.** Untested failure paths: copy fails (disk full), a rename fails
  after its retries, killed between the two renames.
- **6.1.** A `release_path` read mid-copy is refused by the signature, but
  recorded `failed`, which is not retried until the configuration names
  another version; publish by copying, then renaming the `v<version>`
  folder. And a hung NFS mount pins the update worker (jobs unaffected).
- **7.1.** Run `service-packs.sh` in the macOS CI job (postgres from
  Homebrew).
- **7.2.** CONTRIBUTING's review checklist omits the real-service test for a
  service pack; it could also say the same bar applies however the code was
  written.
- **2.1.** `user:pass@` in a `release_url` is rejected by the validator
  (`E_URL`) but not by the runtime path that resolves the release source,
  and `vigil about` prints the URL; reject it there too.
- **7.5.** One message differs: a relative `release_path` at runtime.
- **9.1.** Of five sampled bug backlogs, two show the test failing before
  the fix. From now on, a bug's "Built" notes say which version the new test
  fails on.
