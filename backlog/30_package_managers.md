# Package managers

Install Vigil through the package managers people already use: `.deb` and
`.rpm` files, Homebrew, Scoop, Chocolatey, COPR, and later winget. The
install script stays the quick start.

The reason is servers more than convenience: many companies forbid piping a
script to a shell there, and install only through internal mirrors
(Artifactory, Satellite, an internal Chocolatey feed) and configuration
management (Ansible, Puppet, Intune). Those take a package and cannot easily
take an install script.

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
5. **Services**: a package installs no unit and starts nothing; `vigil service
   install` does, as now, and the unit points at the package's fixed path, so
   it survives upgrades. A package's upgrade script restarts a service that is
   running, as self update does. Removing the package stops and removes the
   service; the root's data stays (`vigil uninstall` removes it, and says the
   package must be removed with the package manager).
6. **Builds in the release workflow**, from the same signed tarball:
   - `.deb` and `.rpm` with `nfpm`, attached to the release and in
     `SHA256SUMS`.
   - The Homebrew formula in our own tap (`godspeedhq/homebrew-vigil`) and the
     Scoop manifest in our own bucket, updated by the workflow.
   - Then a Chocolatey package (moderated by hand, days per version) and a
     Fedora COPR.
   - winget after backlog 12: it takes an MSI, EXE or MSIX installer, not a
     PowerShell script, and its checks and SmartScreen work against an unsigned
     one.
7. **The specification**: §12.1 and §18.6 (two layouts, and why), the self
   update section, and uninstall. The one-root rationale stays true for the
   install script.

Not now: Homebrew core (it needs Vigil to be well known first), official
Fedora and Debian packages (a sponsor, a review, and their rule against bundled
code like `vendor/`), MacPorts and the AUR. Each when someone asks.

## Open questions
- Packaged system root: `/var/lib/vigil`, or keep `/opt/vigil` for our own
  repositories and use `/var/lib/vigil` only for official distribution packages?
- Should a package upgrade also refresh `<root>/packs`, or leave that to
  `vigil pack update` as now?
- Which account owns a packaged system root: the `vigil` service account,
  created by the package, as `vigil service install --system` does now?

## Done when
- A packaged program runs read-only, with its root elsewhere, on Linux, macOS
  and Windows, and the tests cover it.
- Each release publishes the `.deb`, `.rpm`, Homebrew formula and Scoop
  manifest, each installed and run on a clean machine (Fedora, Debian or Ubuntu,
  macOS, Windows).
