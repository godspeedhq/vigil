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
