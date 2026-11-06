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
| [ ] | 0 | Groundwork: a packaged program, read-only, with its root elsewhere | n/a | nothing |
| [ ] | 1 | `.deb` and `.rpm`, on each release and in `SHA256SUMS` | `sudo apt install ./vigil_….deb`, `sudo dnf install ./vigil-….rpm` | nothing |
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
- Packaged system root: `/var/lib/vigil`, or keep `/opt/vigil` for our own
  repositories and use `/var/lib/vigil` only for official distribution packages?
- Should a package upgrade also refresh `<root>/packs`, or leave that to
  `vigil pack update` as now?
- Which account owns a packaged system root: the `vigil` service account,
  created by the package, as `vigil service install --system` does now?
- Where to host the apt repository: GitHub Pages, or a hosted service
  (Cloudsmith, packagecloud).

## Done when
- A packaged program runs read-only, with its root elsewhere, on Linux, macOS
  and Windows, and the tests cover it.
- Each step in the table is ticked: released, and installed, upgraded and
  removed on a clean machine.
