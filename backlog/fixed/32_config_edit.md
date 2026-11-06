# vigil config: edit the configuration like crontab -e

`vigil config` opens `config/vigil.config` in the user's editor, checks what
was saved, and puts it in place only when it is valid, as `crontab -e` does.
The supervisor already reloads the file at its next tick (§16.1); what this
adds is the check before the change goes live.

## Today

Any editor can change `config/vigil.config`. The supervisor checks it every
tick and reloads it when it changed. A save with a mistake is rejected as a
whole: the previous configuration keeps running and `jobs.log` says why
(§16.3). A job with a mistake is skipped as `INVALID` and the others run.

So a typo is never fatal, but it is found only after the save, in a log,
and an `INVALID` job silently stops running until someone looks.

## What `vigil config` does

1. Copies the configuration to a private folder beside it and opens the copy
   in `$VISUAL`, else `$EDITOR`, else `vi` (Notepad on Windows). The editor
   value may carry arguments (`code --wait`).
2. When the editor exits:
   - an editor that failed (non-zero exit) changes nothing;
   - no change: says so and changes nothing.
3. Checks the copy with the same parser and validation as the supervisor
   and `vigil precheck` (§16.3).
   - Any `ERROR` or `INVALID` line: the copy is not saved. The report is
     shown, in file order with line numbers, and at a terminal it asks
     `Edit again? [Y/n]`: yes reopens the same copy, no throws it away.
     Not at a terminal, it exits 1.
   - Warnings are shown and do not stop the save.
4. Saves by renaming the copy over `config/vigil.config`, so the supervisor
   never reads half a file, keeping the file's permissions.
5. If someone else changed the file while it was being edited, nothing is
   overwritten: the edited copy is kept as `config/vigil.config.edited`, and
   the command says so.

Exit codes: 0 saved or nothing to save, 1 not saved.

## What it refuses

- **No configuration:** `vigil init` writes one.
- **A file it cannot write:** a system install's configuration belongs to
  root (Administrators on Windows): run `sudo vigil config` or an elevated
  prompt, as for `sudoedit`.
- **A pointer file** (`config_source`, §6.8): the configuration lives in the
  source. It says where, and that the pointer itself is edited with any
  editor. A local configuration that only fetches scripts (`[source.*]`) is
  edited as usual.

## What it does not do

No new supervisor behaviour, no locking, no history of versions, no editing
of scripts, secrets or packs. Pre-flight's other checks (programs, folders,
backends) stay in `vigil precheck`: they read the machine, and a typo check
should not wait on the network.

## Done when

- `vigil config` on Linux, macOS and Windows, both twins alike.
- Spec §16 and §18.5, and the README, describe it.
- Integration tests with a scripted editor: no change, a valid change saved
  and reloaded by the supervisor, an `ERROR` refused with the file untouched,
  an `INVALID` job refused, a failing editor, a file changed during the edit,
  a pointer file refused, an unwritable file refused, `$VISUAL` over
  `$EDITOR`, an editor with arguments.

## Closed (2026-11-06)

Done as described: `app/lib/posix/configedit.sh` and
`app/lib/windows/ConfigEdit.ps1`, spec §16.6 and §18.5, the README.

One addition from testing: an editor setting that is the path of a program
is used whole, so an unquoted `C:\Program Files\...` (or any path with a
space) works. Found because the test's temporary folder was under
`C:\Users\Bankole Ogundero`.

Checked:
- `tests/integration/config-edit.sh`: 42 passed on Fedora (bash 5.3) and on
  macOS with bash 5.2 and the system's bash 3.2.
- `tests/integration/Config-Edit.ps1`: 40 passed under Windows PowerShell 5.1
  and PowerShell 7.
- The `Edit again? [Y/n]` prompt, which needs a terminal, by hand on macOS
  through `script`: yes reopened the copy with the mistake still in it and
  saved the fix; no left the file byte for byte as it was.

On Windows, saving from an elevated prompt (as CI runs) makes the file's
inherited access rules explicit as well: `ReplaceFile` writes them onto the
file. Who may do what is unchanged, and the test checks exactly that, but a
later tightening of `config\`'s permissions would not reach this file
without a reset (`icacls vigil.config /reset`). Not worth a non-atomic save
to avoid.
