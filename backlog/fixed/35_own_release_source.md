# 35. Updates from a release source other than GitHub

Asked by the owner on 2026-11-08: a fleet whose machines may not reach
GitHub, or whose company won't let them, and which keeps Vigil's releases
somewhere of its own (an internal mirror such as Artifactory, a web server,
a file share).

## What works today

- **The installer from a local archive.** With the archive and `SHA256SUMS`
  in one folder: `sh install.sh --upgrade --archive <file>` (`--reload` to
  restart a running supervisor), or `install.ps1 -Archive <file>`. Only
  `app/` is replaced; the configuration, scripts and state are kept.
  Configuration management (Ansible, Puppet, Intune) can copy the files and
  run that command on each machine.
- **The `.deb` and `.rpm`**, from an internal repository or mirror, as any
  other package.

## What doesn't

`vigil self update`, `self update --check`, the update notice,
`vigil pack update` and `version =` in the configuration all download from
`https://github.com/godspeedhq/vigil`, which is fixed in the code
(`VIGIL_RELEASES` in `app/lib/posix/selfupdate.sh`, `VigilPackReleases` in
`app/lib/windows/Pack.ps1`, and three places in `SelfUpdate.ps1`). The one
override, `VIGIL_TEST_RELEASE_URL`, is for the tests and refuses anything
but `http://127.0.0.1:<port>`. So a fleet following `version = 0.5.4` from a
configuration it fetches from its own git or sftp server still downloads
the release from GitHub.

## Proposed

1. **A setting**, for example `release_url = https://artifacts.example.com/vigil`
   under `[vigil]`. Unset, GitHub, as now.
2. **The same layout as GitHub's**, so a mirror is a copy of the release
   files: `<release_url>/releases/download/v<version>/<file>`. For the
   latest release, a mirror can't answer GitHub's redirect, so it also
   serves a small file naming it (for example
   `<release_url>/releases/latest/VERSION`, one line). A fleet that sets
   `version =` never needs it.
3. **Used by every download**: self update, `--check`, the update notice and
   `pack update`. `vigil about` shows it as `Source`, as it shows GitHub
   today.
4. **Only `https://`.** Certificate checks stay on. A company's own
   certificate authority goes in the system's trust store, not in Vigil.
5. **The signature check does not change.** Self update already verifies
   `SHA256SUMS.sig` against the release key shipped in `app/`, so a mirror
   can serve only releases we signed, unchanged. That is what makes a
   mirror safe to allow.
6. **Maybe a local folder** (`release_url = /mnt/share/vigil` or
   `\\server\share\vigil`), with the same layout, for a file share. Decide
   when building it: it is cheap, but it is a second way.

## Built (2026-11-08)

Where it differs from the proposal above:

- **`https`, or plain `http` to this machine only**, as for a log
  destination (`E_URL` otherwise, and with credentials). That lets the tests
  use the mock server with no test hook. `VIGIL_TEST_RELEASE_URL` still
  stands for GitHub only; a `release_url` wins over it.
- **No local folder.** A file share is served by any web server, and one
  way is simpler than two.
- **`vigil about` shows it as `Releases`**, beside `Source`, which stays the
  project's GitHub page: that is where the code is, wherever releases come
  from.
- **An unpinned update never goes back.** When the latest release named is
  older than the one installed, self update says so and changes nothing, so
  a copy that names an old, signed release cannot move a fleet back. Going
  back is asked for by number: `--version`, or `version =`. This holds for
  GitHub too. The comment in `selfupdate.sh` that refused an address in the
  configuration ("a way to redirect updates") now says why it is safe.
- **The installers don't read it.** A machine is installed from a copy with
  the reviewed path: the files downloaded from it, `--archive` and `--key`.
- **Not a pointer-file key** (`E_POINTER_ONLY`), like `version`: it goes in
  the fetched configuration, where the fleet's other settings are.
- **Tests:**
  - `self-update.sh` and `Self-Update.ps1`, against a copy on the mock, with
    GitHub's stand-in naming no latest at all, and the mock's log showing
    nothing else was asked: `about`, `--check`, the update, the notice's
    check, `pack update --check`, an older latest not taken, a changed
    `SHA256SUMS` refused, and an unreachable copy named.
  - `version-config.sh` and `Version-Config.ps1`: a fetched configuration
    with a `release_url` moves the machine to a release that is only on the
    copy.
  - Conformance: `validate/23` to `25` (http to another host, credentials,
    http to this machine), and `01-valid`.

## A gap found on the way: the installer doesn't check the signature

`install.sh` and `install.ps1` check the archive's SHA-256 against
`SHA256SUMS`, but not `SHA256SUMS.sig`. Downloading from GitHub over HTTPS,
that trusts GitHub, as the `curl | sh` quick start already does. With
`--archive` from a share, anyone who can replace both files on the share
can replace the archive. Self update does check the signature.

- When there is a `SHA256SUMS.sig` beside `SHA256SUMS`, the installer checks
  it, against the key in the archive being installed for a new install (that
  only proves the files match each other) and against the installed
  `app/release-key.pem` on `--upgrade` (that proves the release is ours).
- A key to check against for a new install, given on the command line
  (`--key <file>`), for those who keep their own copy.

This can be done on its own, before the setting.

**Built (2026-11-08):** the key is `--key` (`-Key`), else, on an upgrade,
the installed `app/release-key.pem`; with a key, `SHA256SUMS.sig` is
required, not checked only when present (whoever can replace the archive can
remove it). A fresh install without `--key` checks no signature, as before.
Not the archive's own key: a key that comes with the files proves nothing
about them. Self update needs no change: the `.sig` it has already checked
is beside the archive it hands the installer. Tests: `install.sh` and
`Install.ps1` (a forged `SHA256SUMS`, no `.sig`, another key, a missing
key, an upgrade checked against the installed key).

## Done when

- A fleet with `release_url` set installs, updates (by hand, by `version =`,
  and from the notice) and updates its packs from a mirror, with no request
  to GitHub, on Linux, macOS and Windows; the tests cover it against the
  mock server.
- A mirror serving a changed archive or `SHA256SUMS` is refused.
- The installer checks `SHA256SUMS.sig` when it is there, and the
  specification's install and self-update sections say how each is checked.
