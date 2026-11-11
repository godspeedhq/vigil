# 47. What the documents claim matches what was tested

Found in the engineering-challenges review of 2026-11-10 (challenges 9.2,
9.3, 9.4, 5.4 and 10.1, [the review](reviews/2026-11-10_engineering_challenges.md)).
Documentation only: no behaviour changes.

## Where the claims run ahead

- **Windows Server.** SPECIFICATION.md §5.1 calls Server 2016, 2019, 2022 and
  2025 "Supported" and 2012/2012 R2 "Supported once WMF 5.1 is installed";
  §22.5 says Server 2016 to 2025 are tested in Hyper-V VMs, as present fact;
  README.md says Server 2012 R2 works with WMF 5.1. The evidence
  (`tests/integration/backends/reports/windows-compatibility.md`): Windows 11
  and GitHub's `windows-latest` only. Server 2016 has, since 2026-11-10, an
  install with the README's command and a passing precheck, not yet recorded
  there; 2019, 2022, 2012, 2012 R2, 2008 R2 and a 2025 VM: not run.
- **macOS.** Real-machine testing is Intel macOS 12 only; CI's
  `macos-latest` is Apple Silicon. The service packs and real backends have
  never run on macOS, yet README.md says CI "runs everything on macOS".
- **Built versus specified.** SPECIFICATION.md §15.3 is titled "Supported
  Types" and lists about 20 backends, while README.md's table says most are
  "Specified, not built". README.md line 20 still says "early release
  (v0.2.x)".
- **Tested how.** Datadog (metrics and logs) and the AWS, Azure and GCP
  secret stores were tested against mocks and emulators only; remote SMB and
  NFS release paths only against `\\localhost`; Artifactory over plain http
  on one machine. The README's "What works" table does not say so. Backlog
  37 still says a real Artifactory with anonymous read off was not tried,
  which 0.6.2 did.
- **Fleets and new keys.** A fleet that moves `version =` and adds a key
  only the new version knows, in the same change, leaves older hosts stuck:
  they reject the whole configuration (`E_KEY_UNKNOWN`), keep the old one,
  and never update. A job using a new key stops running on older hosts. No
  document says to move `version =` first and use new keys after.

## Proposed

- §5.1 gets a "Tested" column that mirrors windows-compatibility.md, and the
  untested versions say "expected, not tested"; §22.5 becomes the plan it
  is; the Server 2016 run is recorded.
- README's "What works" says how each is tested (real service, emulator,
  mock); §15.3 is split into built and planned; line 20 is brought up to
  date; the macOS CI sentence is corrected.
- §18.11 "Fleets" and the release-notes habit: move `version =` first, add
  new keys after.
- Backlogs 36 and 37 are corrected.

## Done when

Every support or test claim in SPECIFICATION.md and README.md can be traced
to a report, a CI job or a release note's capture, or says it is untested.

## Built (2026-11-11)

- **Windows versions.** §5.1's table has an "Intended" and a "Tested"
  column, each tested entry traced to `windows-compatibility.md`; untested
  versions say "Not tested", "expected to work". §22.5 says what is tested
  today and what is planned, platform by platform. The README's Windows
  sentence and status line say the same.
- **Server 2016 recorded:** run on 2026-11-11, as an ordinary account over
  SSH, and written into `windows-compatibility.md` as "Works with caveats".
  Install and service: passed. Conformance: 145 passed. Integration: 9
  suites pass, 6 fail, 9 not run (no Python or Git Bash on the VM). The
  failures that are Vigil's are backlog 48.
- **macOS.** The review was partly wrong here, and the docs now say so. The
  real backends (LGTM), the secret stores and the sources did run on the
  Intel Mac (reports of 2026-11-03). The service packs are what never ran
  there: CI runs them on Ubuntu and Windows only. The README's CI sentence
  now says which runners run what.
- **Built versus planned.** §15.3 is "Types: Built and Planned", with a
  status column. A planned type is accepted in a configuration, and its
  events are dropped as `not_implemented`: it is not refused, as I first
  wrote, and the text says what the code does. README status: v0.6.x, not
  v0.2.x.
- **How each is tested.** The README's "What works today" has a "Tested
  against" column: the suites (mocks), or a real product, and where. For
  example: Datadog against a mock only; Azure, AWS and GCP stores against
  emulators only; `release_path` never against a real SMB or NFS server;
  Artifactory over plain http on one machine.
- **Fleets.** §18.11 "New keys come after the version". Tried first: an
  unknown `[vigil]` key rejects the whole configuration, and an unknown job
  key only that job (`vigil precheck`, as quoted there).
- **Backlogs 36 and 37:** 36 says what `release_path` was not tried
  against; 37 records the real Artifactory run of 0.6.2.
- **Found on the way:** §11.2 still said a Windows job does not inherit the
  run token, which backlog 43 changed. Corrected.
