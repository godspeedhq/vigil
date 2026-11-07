# Package managers

Install Vigil through the package managers people already use: `.deb` and
`.rpm` files, Homebrew, Scoop and MacPorts. The install script stays the
quick start.

The owner settled the scope on 2026-11-07: after MacPorts, packages are
done. The MSI and winget wait for a code-signing certificate (backlog 33, on
hold). COPR, an apt repository, Chocolatey and a macOS `.pkg` are not needed
(not_needed/34).

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
| [x] | 2 | Homebrew tap (macOS, Linux) (0.5.1) | `brew install godspeedhq/vigil/vigil` | a `homebrew-vigil` repository |
| [x] | 2 | Scoop bucket (Windows) (0.5.1) | `scoop bucket add vigil …`, `scoop install vigil` | a `scoop-vigil` repository |
| [ ] | 3 | MacPorts (macOS), in the MacPorts ports tree | `sudo port install vigil` | a pull request to `macports/macports-ports`, from the owner's GitHub account |

Not `.app` (a bundle is for programs with a window; Vigil is a command and a
service). The MSI and winget are backlog 33; NSIS, COPR, apt, Chocolatey and
the `.pkg` are not_needed/34.

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

## Step 2 as built

- The formula and manifest are made from `packaging/homebrew/vigil.rb.in` and
  `packaging/scoop/vigil.json.in` by `tools/release/tap-bucket.sh`. The tap
  `godspeedhq/homebrew-vigil` and the bucket `godspeedhq/scoop-vigil` run it
  hourly from the latest release's tag, after verifying its `SHA256SUMS`
  against the release key they keep.
- `PACKAGED` gains `service`: how the package starts the service. With it,
  `vigil service install` refuses and names that command.
- CI on every change: `tests/packages/homebrew.sh` (Homebrew 7, macOS arm64)
  and `tests/packages/Scoop.ps1` (Windows).
- **Released in 0.5.1** (2026-11-07):
  - Scoop, on the Windows 11 test machine as a standard user: `scoop bucket
    add` and `scoop install` from the bucket minutes after the release, `vigil
    service install --user`, and `scoop uninstall` (the logon entry removed,
    the persist folder kept).
  - Homebrew, on the macOS test machine (Intel, macOS 12.7.6): Homebrew's
    installer refuses Intel Macs, but Homebrew 7.0.12 cloned into `~/homebrew`
    runs there (Tier 3, until September 2027). `brew install` from the tap,
    the refusals, `brew services start vigil` (`sh.brew.vigil`) and `vigil
    status` on it. Upgrade and uninstall are CI's (macOS arm64).
  - Homebrew on Linux (`brew services` there is a systemd user unit): untested.
- **Homebrew 7 deprecates `post_install`** for `post_install_steps`.
  Installing 0.5.1 and 0.5.2 printed `Warning: Calling post_install is
  deprecated! Use post_install_steps instead.` and worked. That was wrongly
  noted here as having no step that runs a command: it has `run` (from
  Homebrew 6.0.x), with a literal argument list, inside Homebrew's sandbox,
  writing only where `writable_paths` allows. The formula now makes
  `var/vigil` and, unless `var/vigil/config/vigil.config` exists, runs
  `vigil init --backend file` with `var/vigil` writable. On the Intel test Mac
  (Homebrew 7.0.12): no warning on install, reinstall or `brew postinstall`,
  the configuration written, an edited one kept, and `brew audit --strict`
  and `brew style` clean once the description was cut to under 80
  characters. The CI test now fails on `deprecated` in the install output.

## Step 3 as built

- **The Portfile**: `packaging/macports/Portfile.in`, written for a release by
  `tools/release/portfile.sh` (category `sysutils`, `noarch`, maintainer
  `@bjo004`). MacPorts asks for the archive's RIPEMD-160 and size as well as
  its SHA-256, which `SHA256SUMS` does not hold, so the script reads the
  archive, and refuses one whose SHA-256 differs from the signed
  `SHA256SUMS`.
- **Layout**: the program in `${prefix}/libexec/vigil`, read-only, with
  `app/PACKAGED` (MacPorts; `sudo port selfupdate && sudo port upgrade
  vigil`; `sudo port load vigil`); `${prefix}/bin/vigil` runs it with
  `/bin/bash`; the root `${prefix}/var/vigil`, made on activation, kept on
  deactivation and uninstall. `post-activate` runs `vigil init --backend
  file` only when there is no configuration.
- **The service**: a LaunchDaemon of Vigil's own (`startupitem.custom_file`,
  label `org.macports.vigil`, as root like the install script's system
  service: KeepAlive on failure only, AbandonProcessGroup, its log in
  `logs/supervisor/service.log`), disabled until `port load`. MacPorts
  unloads it on deactivation, and `port upgrade` loads it again after.
- **Vigil**: `service.sh` knows `org.macports.vigil.plist` as a package's
  registration (MacPorts; `sudo port load` and `unload vigil`). Found while
  testing beside the install script's Vigil: with two registrations,
  `_vigil_svc_paths` took the first that existed, so each install's `vigil
  status` could report the other's service. Once `_vigil_svc_find` has set
  the root, the first registration that is that root's now wins.
- **Tested on the Intel test Mac** (MacPorts 2.11.1, macOS 12.7.6), test
  builds 0.5.3 and 0.5.4 from the branch, beside the install script's
  Vigil: install, the refusals, `port load`, `vigil status`, `stop` and
  `start`, the upgrade with the service running (unloaded, swapped, loaded
  again), the configuration kept, `port unload`, uninstall, the root kept.
  `port lint --nitpick`: 0 errors, 0 warnings. The first of three runs also
  ran `port uninstall inactive`, which removed every inactive version of
  every port on that Mac, not only vigil's: the test scripts now uninstall
  vigil by exact version and nothing else.
- **CI**: `tests/packages/macports.sh` on macos-latest, on MacPorts' own
  installer for the runner's macOS.
- **Still to do**: the pull request adding `sysutils/vigil/Portfile` to
  `macports/macports-ports`, from the owner's account; then, at each
  release, a pull request updating the version and checksums
  (`portfile.sh`). Step 3 is ticked once the port is in the ports tree and
  installed from it.

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

## Done when
- A packaged program runs read-only, with its root elsewhere, on Linux, macOS
  and Windows, and the tests cover it.
- Each step in the table is ticked: released, and installed, upgraded and
  removed on a clean machine.
