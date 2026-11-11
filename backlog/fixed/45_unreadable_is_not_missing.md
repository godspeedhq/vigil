# 45. Unreadable is not missing: the commands backlogs 39 and 40 did not cover

Found in the engineering-challenges review of 2026-11-10 (challenges 4.1,
2.4 and 6.1, [the review](reviews/2026-11-10_engineering_challenges.md)).

## The problem

Backlog 39 (`pack update`) and 40 (`status`, and the Windows configuration
parser) fixed two commands that called an inaccessible file missing. The
same mistake remains elsewhere. Reproduced on Windows PowerShell 5.1 by
denying this account read on `config\` (as an ordinary account sees a
system install), or only on `config\secrets`:

| Command | Says | Truth |
| --- | --- | --- |
| `vigil config` | `no configuration at ...: vigil init writes one` | it is there |
| `vigil pack enable base` | `no configuration here: run vigil init first` | it is there |
| `vigil pack list` | every base job `off`, exit 0 | they are on |
| `vigil init` | a raw `Exception calling "Move"`, and leaves `vigil.config.tmp.<pid>` behind | should refuse cleanly |
| `vigil secret list` | two raw .NET errors, exit 0 | cannot be read |
| `vigil secret delete FOO` | `no secret FOO` | it exists |
| `vigil precheck` | `secret:FOO unavailable: not found ... (vigil secret set FOO)` | unreadable: the advice is wrong |

From reading, not run: the POSIX twins do the same (`config.sh` `[ ! -f ]`
gives `config file not found`; `pack.sh`, `configedit.sh`, `secrets.sh`
`list` prints nothing); precheck says `file not found` for a job script it
cannot read; and when the configuration cannot be read, `self update
--check` and the update notice quietly use GitHub instead of the configured
`release_url` or `release_path`.

**`release_path` hides why it failed.** With `version =` set, the fleet path,
a share that is down or refuses the service's account gives `cannot download
Vigil X: is there such a release?`: the error that names the folder and the
account is only reached when the latest version is looked up.

## Proposed

The rule backlogs 39 and 40 follow, applied to each: tell "cannot read" from
"absent" (list the parent folder, catch the access error), and say which
path and which account, and how to run it instead. No new mechanism: one
helper per shell, used where a decision is made.

## Done when

- Each command above refuses with "cannot read <path> from this account"
  (exit 1), or for `pack list` says the state is unknown, on both platforms.
- `release_path` failures name the folder and the account.
- Tests in Config-Edit, Pack, Secrets and Self-Update (both shells) deny read
  and check the message; each fails on 0.6.5.

## Built (2026-11-11)

As proposed: one helper per shell, `vigil_denied` (`config.sh`) and
`Get-VigilDenied` (`Config.ps1`). It names what stops this account telling
whether a path is there: the path itself, or the nearest folder above it
that exists and that it may not enter (POSIX) or list (Windows). On Windows
only an access refusal counts, not a file busy in another process. Used
where each decision is made:

- `vigil config`, `pack enable` (and `disable`), `pack list`, `init`:
  `cannot read <folder> from this account: run this as the account that
  installed Vigil (sudo for a system install)` (Windows: `... from an
  elevated prompt ...`), exit 1. `pack list` refuses rather than show every
  job off; `init` refuses before writing anything, so no
  `vigil.config.tmp.<pid>` is left.
- `secret list`, `secret delete`, and a `secret:` reference (precheck, a
  run): `cannot read <folder> from this account: secrets are set and read as
  the account Vigil runs as`.
- `precheck`: a job script it cannot read says so, not `file not found`; a
  configuration it cannot read was already `E_FILE_UNREADABLE`, and bash now
  gives that too instead of `E_FILE_NOT_FOUND`.
- **Self update.** A configuration this account cannot read may name a copy
  of the releases, so GitHub is no longer asked instead:
  - `--check` and `pack update` refuse, naming the folder;
  - the daily notice records that it found nothing, and says nothing;
  - a plain `vigil self update` goes straight to the `--update-by` sudo rule
    or the `-UpdateBy` task, which read the configuration as root or SYSTEM.
    Before, an ordinary account first looked up the latest release on GitHub,
    so a fleet with a `release_url` and no way to GitHub failed there.
- **`release_path`:** a version asked for (`version =`, `--version`) that
  cannot be read names the folder and the account, as the latest did.
- **Tests:** one new pair, `unreadable.sh` and `Unreadable.ps1`, rather than
  a section in each of four files, so that every command is checked the
  same way on both shells. Added to CI.
  - POSIX closes folders with `chmod 000`; as root it only says that root
    reads everything.
  - Windows adds a deny entry for Everyone and removes it after. Not one
    for this account: `icacls /deny` would also take the rights out of the
    account's own allow entry, for good.
  - On Windows, closing `config\` does not close `config\secrets`, which
    has its own ACL: Windows lets an account through a folder it may not
    list to one it may read. So the Windows test closes the store itself.
  - Results: Fedora and the Mac 25/25; Windows 11, PowerShell 5.1 and 7,
    25/25.
  - On main (0.6.5) the same tests fail: bash 14 checks, Windows 15. Among
    them `self update --check` printed "0.6.5 is available", from GitHub,
    and `secret delete` deleted the secret.
  - Unchanged on Fedora and the Mac: config-edit 42, pack 60, secrets 19,
    precheck 34, init-uninstall 38, self-update 131, version-config 50.
  - The route straight to the task or sudo rule runs only elevated: CI's
    `update-by` checks in `Self-Update.ps1` and `self-update.sh` cover it.
