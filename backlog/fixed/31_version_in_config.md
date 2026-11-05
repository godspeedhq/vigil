# Vigil's version in the configuration

Set the Vigil release a machine runs in its configuration, so a fleet that
reads a remote configuration is updated by changing one line. Vigil updates
or downgrades itself to match, and keeps running what it has whenever the
update cannot be done, as it already does for a bad configuration or a bad
job.

## The setting

```ini
[vigil]
instance = db-windows
# The Vigil release this machine runs. Change it to update or downgrade;
# remove it to go back to manual updates.
version  = 0.3.1
```

- `version` is an exact release number. No `latest`: that would update a
  whole fleet the moment a release is published, which is the opposite of
  controlled.
- It means the same in any configuration: a local one sets it for one
  machine, a fetched one for every machine that reads it.
- It cannot be in a pointer file (`E_POINTER_ONLY`, §6.8). The pointer file
  holds only `config_source`, `config_file` and `state_dir`; `version` goes
  in the file it points to.
- Without `version`, nothing changes: updates are manual, with
  `vigil self update`.

## Behaviour

- **When it acts:** each time the configuration is loaded (every
  `check_every` for a fetched one, when the file changes for a local one),
  and only when `version` differs from the installed release. A machine
  already on that release does nothing and contacts nothing.
- **How:** through the existing self update (§18.7): the release is
  downloaded, its signature and SHA256SUMS verified, and the installer's
  three proofs applied (the new code runs, the supervisor reloads onto it,
  it stays up). Running jobs carry on across the hot reload.
- **Not available or unreachable** (no such release, no network, the
  download throttled or failed): logged, and Vigil carries on with what it
  has. Tried again at the next check, as for an unreachable configuration.
- **Installed but failed** (one of the three proofs failed): the installer
  rolls back, as today. Logged once, and that version is not tried again
  until the `version` line changes. Otherwise every machine would download a
  broken release every `check_every`.
- **Downgrade across a data format change:** a release cannot read state of
  a newer format than its own (§18.7), so this is refused and logged, and
  Vigil stays where it is. Release notes of a version that changes the data
  format must say that going back past it does not work.
- **Cannot update itself** (a system install without the `--update-by` sudo
  rule): logged, and Vigil carries on. `vigil precheck` should say whether
  this machine can update itself, so an operator knows before a rollout.

## `vigil self update` while `version` is set

It refuses, and says where to go:

```text
$ vigil self update
vigil: the version is set in the configuration (version = 0.3.1): change it there to update
```

Otherwise it would install another release and the next configuration load
would undo it. So the version has one place it is decided: the `version`
line when it is set, the command when it is not. `vigil self update --check`
and the update notice only report, and work as today.

## Vigil never writes to its configuration

The configuration is the operator's instructions; Vigil does not edit them.

- It is often not Vigil's file: kept in git, written by Ansible or Puppet,
  owned by root on a system install. A rewrite would show in git as a change
  nobody made, and the next Ansible run would undo it.
- A fetched configuration cannot be written at all.
- It says what is wanted, not what happened: after a rolled-back update, a
  rewritten file would no longer say what was asked for.
- A bad write, or lost comments and layout, would damage the file Vigil runs
  from.

The running release is reported where it already is: `vigil version`,
`vigil status`, and the metrics Vigil sends. That is where a fleet operator
sees which machines have caught up.

## Fleets

- **Identity:** every metric and log record carries `host` (set
  automatically) and `instance` (§14.6). Machines sharing one fetched file
  share `instance`, which names the group (`db-windows`); `host` tells them
  apart. A file per machine is needed only for its own jobs or a canary.
- **Canaries and waves:** point a few machines at their own `config_file`
  with the new `version`, then move one group file at a time. The
  documentation should recommend this, not just allow it: rollback catches
  a release that does not run, not one that runs and misbehaves.
- **Load:** each machine checks its source `check_every` after its own last
  check, so a fleet's checks are spread, not simultaneous: about 3 requests
  a second for 1,000 machines on `5m`. A release is downloaded once per
  machine, only when `version` changes, spread over one `check_every`.
  Nothing caps this further, deliberately: a fleet that size runs its own
  git server and secret store, and has `check_every` and the size of each
  wave to control it.

## Not part of this

- **Package-manager installs** (backlog 30): parked. A packaged install
  refuses self update, so `version` will need to say so there; decided with
  backlog 30.
- **A release mirror** for machines that cannot reach GitHub: its own item.
  Until then such machines log the version as unavailable and carry on.

## Done when

- `version` is validated in `[vigil]` (an exact release number) and refused
  in a pointer file, in both twins.
- A supervisor whose configuration names another release updates or
  downgrades to it, and carries on with what it has when the release is
  unavailable, fails its proofs, or would cross a data format change; each
  logged as above, a failed version tried again only once the line changes.
- `vigil self update` refuses while `version` is set; `--check` still works.
- `vigil precheck` reports whether the machine can update itself.
- Integration tests on Linux, macOS and Windows: update, downgrade, an
  unavailable release, a release that fails to start, and a fetched
  configuration moving a machine, against the mock release server
  `upgrade.sh` uses.
- SPECIFICATION (§6.8, §18.7) and README document it, with the canary and
  wave practice.

## Closed

Closed on 2026-11-05.

**Done:**
- `[vigil] version`, validated in both twins (`E_VERSION`; `E_POINTER_ONLY`
  in a pointer file), documented in SPECIFICATION §18.11 (with §6.8, §18.7,
  §16.3) and the README.
- `vigil_update`, Vigil's own worker, moves the install to the version named
  and records the outcome in `state/update.state`. Unavailable: retried
  after 5 minutes. Installed but failed, or refused: not tried again until
  the line changes. The supervisor logs each outcome once; `jobs.log` shows
  a `VERSION` block while the release is not the one named.
- `vigil self update` refuses while the line is set; `--check` still works.
- `vigil precheck` notes the version and whether this account can update
  Vigil.
- System installs: the `--update-by` rule gains a second command,
  `self update --from-config`, in which root reads the version itself; the
  Windows task follows the configuration's version the same way. Up and
  down, as decided.
- Tests: conformance cases; `version-config.sh` (47 passed on Fedora and on
  macOS) and `Version-Config.ps1` (45 passed on Windows PowerShell 5.1); the
  sudo rule's second command in `self-update.sh`.
- A real fleet in `tests/integration/fleet`: seven Debian containers on
  Fedora following git over SSH, https, sftp and a local folder, macOS on
  git and Windows on https and sftp through tunnels. A canary, the fleet, a
  downgrade, a release not yet published (taken at the 5-minute retry), a
  release that does not run (rolled back everywhere, tried once), and
  `vigil self update` refused, with no run crashed. Evidence in
  `tests/integration/fleet/reports/2026-11-05`.

**Different from the plan:**
- The installer had to learn `--reload` (`-Reload`). Without a registered
  service it did not wait for the supervisor to reload, so a downgrade past
  a data format change was reported as done while the supervisor stayed on
  the newer release. The worker now says a supervisor is running, and the
  installer waits and rolls back as it does for a service.
- So a release from before this item cannot be named: its installer does
  not know `--reload`, and the update is recorded as failed.

**Not done:**
- **A release mirror:** separate, as planned.
- **Package-manager installs:** parked with backlog 30.
- **Seen on the way, not changed:** `vigil status` on a host with a pointer
  file reads only that file, so it says "no backend" though the fetched
  configuration has one.
