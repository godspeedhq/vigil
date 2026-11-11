# 46. pack enable: write the configuration safely, and say when a pack has nothing for this platform

Found in the engineering-challenges review of 2026-11-10 (challenges 4.2 and
7.4, [the review](reviews/2026-11-10_engineering_challenges.md)).

## The problems

**The configuration is rewritten in place.** `pack enable` and `pack
disable` write the new `vigil.config` straight over the old one
(`Set-VigilPackConfig`, `[IO.File]::WriteAllText($cfg, ...)` in
`app/lib/windows/Pack.ps1`; `cat "$new" > "$cfg"` in `_vigil_pack_apply`,
`app/lib/posix/pack.sh`). A crash, power cut or full disk mid-write leaves a
truncated file, which the validator can accept: an empty one is valid, and
one cut inside a job only invalidates that job. The supervisor would load it
and run fewer jobs, quietly. Every other writer of a configuration (`vigil
config`, fetched configurations, `secret set`) writes a file beside it and
replaces.

**A pack with no scripts for this platform is "already on" (reproduced).**
The release ships every pack's `pack.config`, but nginx has no `windows\`
scripts. On Windows:

```
PS> vigil pack enable nginx
nginx is already on
needs its stub_status page, reachable from this machine only: ...
(exit 0)
```

Nothing was turned on. The same logic is in `pack.sh`.

## Proposed

- Write the new configuration to a file beside it and replace (`File.Replace`
  / `mv`), keeping the owner and mode on POSIX as `configedit.sh` does.
- A pack with no scripts here: `pack nginx has no scripts for Windows`, exit
  1; `pack list` shows it as not available here.

## Done when

- Pack tests (both shells) check the message and exit code for a pack with
  no scripts for the platform, and that `vigil.config` is replaced, not
  rewritten (no partial file is ever visible).

## Built (2026-11-11)

As proposed:

- **Checked, then replaced.** `pack enable` and `pack disable` write the new
  configuration to a file beside it, validate that file (judged by the
  pack's own jobs, as before), and only then replace `vigil.config` with it.
  Before, the new text was written over `vigil.config` and the old text
  written back when it failed.
  - POSIX: `cp -p` of the old file (owner and mode stay), the new text into
    it, `mv -f` over `vigil.config`.
  - Windows: `Write-VigilFileAtomic`, whose `File.Replace` keeps the old
    file's ACL and retries while another process holds it.
  - A failure to save says `cannot save <file>; nothing was changed`.
- **A pack with no scripts here:**
  - `pack enable nginx` on Windows: `vigil: pack nginx has no scripts for
    Windows`, exit 1, and the configuration untouched;
  - `pack list` shows the pack with `not available here: no scripts for
    Windows` instead of an empty list of jobs;
  - the same on Linux and macOS, with their names.
- **Specification:** §18.10, both rules.
- **Tests:** `pack.sh` and `Pack.ps1`.
  - The configuration is held open across `pack enable`. Replaced, the open
    file still reads as it was; written over, it would read as the new
    one. On POSIX, also that its mode (640) stays.
  - A pack `elsewhere` with a `pack.config` and no script: refused, saying
    so, the configuration unchanged, and listed as not available here.
  - Fedora 66/66, the Mac 66/66 (bash 3.2), Windows 11 PowerShell 5.1
    65/65. On main (0.6.5) the 4 new checks fail on each: the held file
    reads as the new one, and `elsewhere is already on`, exit 0.
