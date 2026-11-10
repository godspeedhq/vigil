# 39. pack update: say when the installed packs cannot be read

Found on 2026-11-10 while updating the test machines to 0.6.3; the owner
asked for the fix, then for this backlog.

## The problem

On the Windows test machine, `vigil pack update --check` run as an ordinary
account (`vigil-test`) against the system install said, for every pack:

```
pack base none is here; 1.1.1 is available: vigil pack update
pack nginx none is here; 1.1.0 is available: vigil pack update
pack postgres none is here; 1.1.0 is available: vigil pack update
```

The packs were there. A system install's root on Windows is closed to all
but SYSTEM and Administrators, so the account could not read
`C:\ProgramData\Vigil\packs`, and every pack looked missing. The same could
happen on Linux or macOS with a `packs/` folder the account cannot read.

## Proposed

- `vigil pack update` and `--check` first check that the installed packs can
  be read: `packs/`, each pack's folder and its `pack.config`; when there is
  no `packs/`, the root itself, since a root that cannot be looked into
  hides one.
- When they cannot, both refuse, exit 1, before downloading anything, and
  say why: `cannot read <root>/packs from this account: run this as the
  account that installed Vigil (sudo for a system install)`; on Windows,
  `run this from an elevated prompt for a system install`.
- Windows: .NET reports a folder in a closed root as not existing rather
  than unreadable, so the root is listed too.

## Done when

- The message above, not `none is here`, on the Windows test machine.
- `pack.sh` and `Pack.ps1` cover a pack folder this account cannot read.
- Specification §18.10 says so.

## Built (2026-11-10)

As proposed, in #138.

- **Both shells check before fetching,** so nothing is downloaded for a
  check that cannot be answered. The existing "not writable" refusal for an
  update still follows it.
- **Tests:** `pack.sh` makes a pack folder `chmod 000` (skipped as root,
  which reads everything); `Pack.ps1` denies read on it with `icacls`. Each
  checks the refusal of `--check` and of the update, the message, and that
  nothing changed. 60/60 on Fedora 44 and macOS 12, and in Windows
  PowerShell 5.1.
- **On the real install:** this branch's `app`, run as `vigil-test` on the
  Windows test machine against `C:\ProgramData\Vigil`:

  ```
  vigil: cannot read C:\ProgramData\Vigil\packs from this account: run this from an elevated prompt for a system install
  ```

  On Fedora and the Mac, whose `/opt/vigil/packs` the account can read,
  `--check` lists each pack as before.
