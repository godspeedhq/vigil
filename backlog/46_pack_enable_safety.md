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
