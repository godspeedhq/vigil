# Upgrades across releases

Every release must upgrade from the one before it. Nothing tests that with
two real releases, and a state file format change would make old files
unreadable.

## Done when
- CI installs the previous published release and self-updates to the
  current build, with jobs running, on all three platforms.
- State, cursors, spool and checkpoints carry a version, with a migration
  path when a format changes.
