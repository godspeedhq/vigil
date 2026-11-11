# 36. Updates from a file path (`release_path`): a local folder or a file share

Asked by the owner on 2026-11-08: a fleet whose releases sit on a file share
every machine can reach, with no web server in front of it. Backlog 35 left
a local folder out ("one way is simpler than two"); this takes it back up.

## Proposed

1. **A new key, `release_path`**, under `[vigil]`, beside `release_url`
   (the owner's choice, 2026-11-08: a path isn't a URL, and each gets its
   own checks and messages):
   - Linux and macOS: an absolute path, `/mnt/releases/vigil` (a local
     folder, or an NFS or SMB share mounted there).
   - Windows: a UNC path, `\\server\share\vigil`, or a local
     `C:\...` path.

   Setting both `release_url` and `release_path` is invalid: Vigil must
   know which one to use. Neither set: GitHub, as now. Like `release_url`,
   not a pointer-file key.
2. **The same layout as a web copy**:
   `<path>/releases/download/v<version>/<file>` and
   `<path>/releases/latest/VERSION`. A folder can be moved behind a web
   server, or back, without changing it.
3. **The files are copied, not downloaded**, then checked exactly as a
   download is: `SHA256SUMS.sig` against the installed release key, then
   each file against `SHA256SUMS`. A share many people can write to still
   can't slip in a forged release, and an unpinned update still never goes
   back.
4. **Used by everything that uses `release_url`**: self update, `--check`,
   the update notice, `pack update` and `version =`. `vigil about` shows the
   path on its `Releases` line.
5. **Errors name the path**: missing, not a folder, or not readable by the
   account Vigil runs as.

## To settle when building it

- **Who reads the share.** A Windows service running as LocalSystem reaches
  a share as the computer account (`DOMAIN\HOST$`), so the share has to
  allow it. Mapped drive letters don't exist for a service: refuse
  `X:\...` when `X:` is a network drive, or only document it? On Linux and
  macOS the share must be mounted at boot, for the `vigil` account.
- **A share that hangs.** An unreachable NFS or SMB mount can block a read
  for minutes. The update notice must not hold up a command; the refresh
  already runs in the background, so check that the same holds for a path.
- **`file://` URLs**: accept them as another spelling of a path, or not?
  One spelling is simpler.

## Built (2026-11-09)

Where it differs from the proposal, and how the open points were settled:

- **Mapped drive letters: documented, not refused.** Whether `X:` is a
  network drive depends on the account and the session, so a check would
  answer for the wrong one. The README and the specification say to use a
  UNC path for a service.
- **A share that hangs:** no timeout of Vigil's own (macOS has no
  `timeout`). The notice's check already runs detached, so a hung share
  holds up only an update someone asked for, as a hung server would.
- **`file://` URLs: not accepted.** One spelling.
- **One error for the folder**, rather than missing / not a folder / not
  readable: `cannot read the latest release from <path> (as <account>): is
  it there, and readable by this account?`. The account is what usually
  tells which of the three it is.
- **Validation accepts every platform's absolute form** (`/…`,
  `\\server\share\…`, `C:\…`) on every platform, with the same answer from
  both validators, since one fetched configuration may serve all three. A
  machine takes only its own form when it reads the folder.
- **Codes:** `E_RELEASE_PATH` (not absolute) and `E_RELEASE_BOTH` (both
  set).
- **Tests:**
  - `self-update.sh` and `Self-Update.ps1`: a folder, with the mock's log
    showing nothing was downloaded: `about`, `--check`, the update, an older
    latest not taken, a changed `SHA256SUMS` refused, a missing folder
    named with the account, `pack update --check`, the notice's check, both
    keys refused, a relative path refused. On Windows also by UNC path,
    through the drive's administrative share, where the account may open
    it (CI's administrator).
  - Conformance: `validate/26` to `30`.
- **Not tried:** a real SMB or NFS server. The folder tests use a local
  folder on all three platforms and, on Windows, `\\localhost`'s
  administrative share; no share on another machine, no mounted NFS or SMB
  share on Linux or macOS, and no LocalSystem service reading a share as the
  computer account. (Noted 2026-11-11, from the engineering-challenges
  review.)

## Not included

- **SFTP.** It needs a key and a known-hosts entry on every machine, the
  tools differ (macOS's `curl` has no SFTP; Windows would need `sftp.exe`),
  and a file share or HTTPS covers the same places.

## Found on the way: a copy that needs a login

Testing `release_url` against Artifactory OSS 7.161.26 (2026-11-08): most
company Artifactory servers require a login, and `release_url` can't send
one (credentials in the URL are refused, by design). The free edition only
lets an anonymous read be granted through its web UI. A read token kept in
Vigil's secret store would close this; not decided, and not part of this
item. (Decided and built as backlog 37, in 0.6.2.)

## Done when

- A fleet with `release_path` set to a local folder, an NFS or SMB mount
  (Linux, macOS) or a UNC path (Windows) installs, updates (by hand, by
  `version =`, and from the notice) and updates its packs from it.
- A changed archive or `SHA256SUMS` on the share is refused, and an older
  `VERSION` is not taken.
- The tests cover a local folder on all three platforms; the specification
  (18.7) and the README's "A fleet that doesn't reach GitHub" describe it.
