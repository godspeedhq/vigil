# Default scripts and the pack format

Someone installs Vigil and has useful metrics straight away, as with Datadog.

## Scope
- A pack: a set of scripts and jobs, with a version and a list of metrics, in
  this repository under `packs/`, with scripts per platform.
- A base pack per platform: CPU, memory, disk, network, load, service state,
  written only in bash and PowerShell.
- `vigil pack update` gets a release's packs without `vigil self update`.
  Updates stay manual. An update changes scripts and never the configuration,
  a new script stays off until it is enabled, and a user's own scripts are
  never overwritten.
- `vigil init` sets up the defaults, and `vigil init empty` nothing but the
  structure.

## Done when
- A fresh install turns on the base pack, and its metrics reach a backend on
  all three platforms.
