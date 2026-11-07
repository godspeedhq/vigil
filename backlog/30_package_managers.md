# Package managers

Install Vigil through the package managers people already use: `.deb` and
`.rpm` files, Homebrew, Scoop, Chocolatey, COPR, an MSI, winget and a macOS
`.pkg`. The install script stays the quick start.

The reason is servers more than convenience: many companies forbid piping a
script to a shell there, and install only through internal mirrors
(Artifactory, Satellite, an internal Chocolatey feed) and configuration
management (Ansible, Puppet, Intune). Those take a package and cannot easily
take an install script, and they manage services with the system's own tools
(`systemctl enable vigil`), not a Vigil command.

## Progress

Ticked as each is released and installed on a clean machine.

| Done | Step | Format | Installs with | Needs from the owner |
| --- | --- | --- | --- | --- |
| [x] | 0 | Groundwork: a packaged program, read-only, with its root elsewhere (0.5.0) | n/a | nothing |
| [x] | 1 | `.deb` and `.rpm`, on each release and in `SHA256SUMS` (0.5.0) | `sudo apt install ./vigil_….deb`, `sudo dnf install ./vigil-….rpm` | nothing |
| [ ] | 2 | Homebrew tap (macOS, Linux) | `brew install godspeedhq/vigil/vigil` | a `homebrew-vigil` repository |
| [ ] | 2 | Scoop bucket (Windows) | `scoop bucket add vigil …`, `scoop install vigil` | a `scoop-vigil` repository |
| [ ] | 3 | Fedora COPR, so `dnf upgrade` updates it | `sudo dnf copr enable godspeedhq/vigil`, `sudo dnf install vigil` | a COPR account |
| [ ] | 3 | An apt repository, so `apt upgrade` updates it | `sudo apt install vigil` | where to host it |
| [ ] | 3 | Chocolatey (moderated by hand, days per version) | `choco install vigil` | a Chocolatey account |
| [ ] | 4 | MSI built with WiX, for Intune, Group Policy and SCCM | `msiexec /i vigil-….msi /qn` | the code-signing certificate (backlog 12) |
| [ ] | 4 | winget, from the MSI | `winget install GodspeedHQ.Vigil` | the MSI |
| [ ] | 5 | macOS `.pkg`, for Jamf, Intune and Kandji | `sudo installer -pkg vigil-….pkg -target /` | an Apple Developer ID, for signing and notarizing |

Not `.app` (a bundle is for programs with a window; Vigil is a command and a
service) and not NSIS (an `.exe` wizard: companies ask for an MSI, and winget
takes the MSI).

## What the code does today (checked 2026-11-05)

Vigil assumes one root holding everything, its own program included (§12.1,
§18.6). A package splits the program, read-only and owned by the package
manager, from the data.

Already fine:
- The root can be anywhere: `--root` (`-Root`) overrides it on every command.
- The service unit and launchd plist name the program and the root separately
  (`app/lib/posix/service.sh:124`, `:136`); the supervisor launches workers
  through the program's own path (`supervisor.sh:1038`).
- Nothing writes into `app/` but self update. Packs and `vigil pack update`
  write only `<root>/packs`; the release key is only read from `app/`.
- The update notice keeps its cache per user, outside the install, already
  "because a read-only system install has to be able to show the notice too"
  (`selfupdate.sh:108`).

Assumes the program sits in the root:
- **The default root is the folder above `app/`** (`app/vigil`, `vigil.ps1`).
  A link `/usr/bin/vigil` to `/usr/lib/vigil/app/vigil` would make
  `/usr/lib/vigil` the root. There is no `VIGIL_ROOT` or other default.
- **Self update replaces `app/` and `vendor/`** in place, and the sudoers rule
  names `<root>/app/vigil` (`service.sh:530`, `selfupdate.sh:220`).
- **Uninstall** looks for `<root>/app/vigil` (`service.sh:475`, `:483`;
  `Service.ps1:422`, `:429`).
- **Windows permissions** are set on `<root>\app` (`Service.ps1:154`); NSSM is
  found next to the program (`Service.ps1:218`), which still works if `vendor\`
  ships beside `app\`.
- **The first packs** are copied into the root by the installer
  (`install.sh:331`), not by `vigil init`, so a package's packs would never
  reach a root.

## Proposed

Items 1 to 4 and 7 are step 0, built on the `packaged-root` branch: see
"Step 0 as built" below.

1. **A marker for a packaged program**, `app/PACKAGED`, written by the
   package build: which package manager, and its upgrade command
   (`brew upgrade vigil`, `sudo dnf upgrade vigil`, `choco upgrade vigil`).
2. **Where the root comes from**: `--root`, else `VIGIL_ROOT`, else, when
   packaged, the platform's root for this mode, else the folder above `app/` as
   now. Packaged roots: `/var/lib/vigil` for a `.deb` or `.rpm` system install
   (`/opt` belongs to software outside the distribution, and official Fedora and
   Debian packages may not use it); Homebrew's `$(brew --prefix)/var/vigil`;
   `C:\ProgramData\Vigil` on Windows; `~/.local/share/vigil` in user mode, as
   now.
3. **Self update, when packaged**, changes nothing and says how to upgrade:
   `vigil was installed by Homebrew: brew upgrade vigil`, with its own exit
   code. The update notice says the same. `vigil pack update` keeps working: it
   writes only the root.
4. **`vigil init` puts the first packs in place** from the program's `packs/`
   when the root has none, so a package and the tarball do the same thing. The
   installer then stops doing it.
5. **The package sets up the service**, as packages of other services do, and
   follows each platform's convention for starting it:
   - It creates the `vigil` service account (Linux) and the root.
   - It writes a starting configuration only when there is none, with the
     defaults `vigil init` offers on Enter: the host name as the instance,
     metrics to a file, the base pack. An existing configuration is never
     touched, so it is not a package-owned config file and upgrades never ask
     about it.
   - It ships the service definition natively: a systemd unit in
     `/usr/lib/systemd/system`, a Homebrew `service` block, an MSI
     `ServiceInstall`. The unit names the package's fixed program path, so it
     survives upgrades.
   - Starting, by convention:

     | Package | After install |
     | --- | --- |
     | `.deb` | enabled and running |
     | `.rpm` | installed, off (Fedora's preset policy): `sudo systemctl enable --now vigil` |
     | Homebrew | `brew services start vigil` |
     | MSI, Chocolatey | running; the MSI takes the instance and backends as properties, for silent installs |
     | Scoop | no service (Scoop installs commands for one user): `vigil service install --user` |

   - An upgrade restarts a running service, as self update does. Removing the
     package stops and removes the service and keeps the root's data; purging a
     `.deb` removes it too. `vigil uninstall` on a packaged install says to
     remove it with the package manager.
   - `vigil service install` stays, for the install script.
6. **Builds in the release workflow**, from the same signed tarball:
   - `.deb` and `.rpm` with `nfpm`, attached to the release and in
     `SHA256SUMS`.
   - The Homebrew formula in our own tap (`godspeedhq/homebrew-vigil`) and the
     Scoop manifest in our own bucket, updated by the workflow.
   - Then a Chocolatey package and a Fedora COPR, and an apt repository.
   - The MSI with WiX after backlog 12, then winget: it takes an MSI, EXE or
     MSIX installer, not a PowerShell script, and its checks and SmartScreen
     work against an unsigned one. The workflow opens the `winget-pkgs` pull
     request with `wingetcreate` each release.
7. **The specification**: §12.1 and §18.6 (two layouts, and why), the self
   update section, the service section, and uninstall. The one-root rationale
   stays true for the install script.

Not now: Homebrew core (it needs Vigil to be well known first), official
Fedora and Debian packages (a sponsor, a review, and their rule against bundled
code like `vendor/`), MacPorts, the AUR, Alpine. Each when someone asks.

## Step 0 as built

Where it differs from the proposal above:

- `app/PACKAGED` also carries the root (`manager`, `upgrade`, `root`, as
  `key = value` lines), so each package names its own and Vigil holds no list
  of packaged roots. Which root each package writes is decided in step 1.
- Self update on a packaged program exits 1, as its other refusals do, not
  with an exit code of its own; it is refused before anything is downloaded,
  and ahead of the configured-version refusal. `--check` and the notice name
  the package's command.
- `vigil init` copies the packs only for a packaged program; the install
  script keeps copying them itself, so a fresh install with an existing
  configuration, where `vigil init` does not run, still gets them.
- `vigil uninstall` on a packaged program is refused and names the package
  manager.
- `vigil about` shows the program's folder and its package manager.
- Tests: `tests/integration/packaged.sh` and `Packaged.ps1` lay out a
  read-only packaged program and check the root, init's packs, both refusals,
  and that nothing is written into the program.

## Step 1 as built

- **The root is `/opt/vigil`**, as the install script's, not `/var/lib/vigil`:
  one path on every Linux machine whichever way Vigil came, and a move from
  the install script keeps everything in place. `/var/lib/vigil` is for an
  official distribution package, if one ever comes.
- **The program is in `/usr/lib/vigil`** (`app/`, and `packs/` with Linux's
  scripts for `vigil init` to copy), with `/usr/bin/vigil` linking to it. Not
  in `/opt/vigil/app`: the package's files and the root's never mix, and the
  root's `packs/` (flat, rewritten by `vigil pack update`) stays apart from the
  package's.
- **Built by nfpm** (pinned, v2.48.0) from the release's `.tar.gz`:
  `tools/release/linux-packages.sh` and `packaging/linux/`. `package.sh` builds
  them when nfpm is on `PATH`; the release workflow installs it and fails
  without them. Files: `vigil_<version>-1_all.deb`,
  `vigil-<version>-1.noarch.rpm`, both in `SHA256SUMS`.
- **`PACKAGED`** says `manager = apt` or `dnf`, and until the repositories of
  step 3, `upgrade` names installing the newer file from the releases page.
- **The service**: the unit in `/usr/lib/systemd/system`, as `vigil`. The
  `.deb` enables and starts it once pre-flight passes as `vigil`; the `.rpm`
  applies the distribution's preset, which leaves it off on Fedora and RHEL,
  and says how to start it. An upgrade stops a running service before any file
  changes (`preinstall.sh`) and starts it after: the package manager replaces
  files one at a time, and the supervisor, which reloads itself on a new
  `VERSION`, must never load half a version. `vigil
  status`, `start`, `stop` and `restart` find the package's unit;
  `vigil service install` and `remove` refuse it.
- **Moving from the install script** is detected (its unit in `/etc` names
  `/opt/vigil/app/vigil`) and not done for the operator: the package leaves the
  old service running and prints the three commands that finish the move.
- **Dependencies**: bash, curl, openssl, procps, hostname, tar, gzip, and the
  account tools (`passwd` on Debian; `shadow-utils`, `util-linux`,
  `findutils`, `gawk` on the `.rpm` side).
- **Tests**: `tests/packages/linux.sh` installs one version, upgrades to the
  next and removes it, in Debian 13, Ubuntu 24.04, Fedora 43 and Rocky 9
  containers, and on the CI runner with systemd for the service (the
  `linux-packages` job of the conformance workflow).
- **Found on the way**: the supervisor's background `sleep` between ticks kept
  its lock open, and outlived a stop (`KillMode=process`), so a supervisor
  started within seconds of a stop (`vigil restart`, a package upgrade) found
  the lock held and exited. The `sleep` now closes it.
- **Released in 0.5.0** (2026-11-07) and installed by hand:
  - The Fedora 44 test machine, running 0.4.0 from the install script as a
    system service, moved to the `.rpm` with the three printed commands: same
    configuration and jobs, now on `/usr/lib/vigil`.
  - Fresh in Fedora 44 and Debian 13 containers with systemd running: the
    `.rpm` leaves the service off until enabled, the `.deb` starts it; both
    run the base pack, refuse `self update`, and keep `/opt/vigil` on
    remove (`apt purge` deletes it).
  - Found on the way, fixed before publishing (#110): `vigil init` in the
    package's install said to run `vigil service install`, which refuses there.
- The `.rpm` upgrade with systemd running, on the Fedora test machine, 0.5.0
  to 0.5.1 (2026-11-07): the service stopped, and started 8 seconds later on
  0.5.1 with the configuration untouched. Found on the way (#114): without
  sudo, `vigil service install` and `service remove` advised commands that
  refuse anyway; they now name the package's `systemctl` command.
- The `.rpm` with systemd running is not tested in CI (the Fedora and Rocky
  containers have none): only by hand, as above.
- Not yet: `lintian` and `rpmlint`, GPG signatures on the `.rpm`, SELinux
  enforcing, openSUSE.

## Also to settle

- **Signing for the repositories.** `SHA256SUMS.sig` (OpenSSL, our own key)
  covers the files on the release page. `dnf` and `apt` check GPG signatures
  instead: the `.rpm` itself, and an apt repository's `Release` file. A GPG key
  for packages, kept as a CI secret like the release key, with its public half
  published.
- **Dependencies** declared in each package: `bash`, `curl`, `coreutils`,
  `openssl`, and what the backends and stores call.
- **Distributions covered:** Debian and Ubuntu; Fedora, RHEL, Rocky, Alma and
  Amazon Linux from the one `.rpm`. openSUSE uses `.rpm` with other package
  names: tested later. Hosts without systemd (OpenRC, containers) get the
  program, and `vigil service install` says what it supports.
- **SELinux** on Fedora and RHEL: workers running scripts from `/var/lib/vigil`
  under a systemd service, checked enforcing.
- **Moving from an install-script install** (`/opt/vigil`) to a package: the
  configuration, scripts and state carried over, and the old service and
  `/usr/local/bin/vigil` link removed. A documented command, not left to the
  user.
- **Checks in CI:** `lintian` and `rpmlint` clean; install, upgrade from the
  previous release, and remove in clean Debian, Ubuntu, Fedora and Rocky
  containers on every release.

## Open questions
- Should a package upgrade also refresh `<root>/packs`, or leave that to
  `vigil pack update` as now?
- Where to host the apt repository: GitHub Pages, or a hosted service
  (Cloudsmith, packagecloud).

## Done when
- A packaged program runs read-only, with its root elsewhere, on Linux, macOS
  and Windows, and the tests cover it.
- Each step in the table is ticked: released, and installed, upgraded and
  removed on a clean machine.
