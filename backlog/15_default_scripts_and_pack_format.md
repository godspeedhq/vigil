# Default scripts and the pack format

After the Vigil scaffold is finished. Someone installs Vigil and has useful
metrics straight away, as with Datadog.

## Scope
- A pack: a set of scripts and jobs, with a version and a list of metrics.
- A base pack per platform: CPU, memory, disk, network, load, service state,
  written only in bash and PowerShell.
- Packs update on their own, without a Vigil release. Updates stay manual,
  and a user's own scripts are never overwritten.

## Done when
- A fresh install offers the base pack, and its metrics reach a backend on
  all three platforms.
